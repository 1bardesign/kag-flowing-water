//WaterCommon.as

//deterministic cost per frame - sim slows if there's a heap of water without killing FPS
const int cost_per_frame = 400;
const int cost_per_flip_cheap = 1;
const int cost_per_flip_expensive = 15;
const int cost_per_active = 40;
const int cost_per_inactive = 1;
const int chunk_size = 10;
//limited number of meshes regenerated per frame
const int remesh_limit = 2;
//more regenerated on render-online frames (ie >30fps; no update done so "evens out" the cost)
const int remesh_limit_renderonly = 20;

//how many full updates of the water between syncs (1 == every tick synced)
const int send_ratio = 1;

//whether or not to calculate lighting (per-tile cost)
const bool do_lighting = true;

//(resolution of the tracked daytime changes)
const u16 daytime_resolution = 1000;

//whether or not to use raw vertices (much faster)
const bool raw_vertices = true;

//config vars
//stable slope - adds stability/prevents tiny amounts "getting lost" due to rounding
const float min_flow = 1.0f / 128.0f;
//evaporation - removes random orphan splashes
const float evap_rate = 1.0f / 64.0f;
const float evap_thresh = min_flow * 2.0f;
const float evap_chance = 1.0f / 100.0f;

//rendering stuff
const float frames_width = 16.0f;
const float frames_height = 2.0f;
//(precalculating this so we don't have to do it for every tile)
const float frames_xstep = 1.0f / frames_width;
const float frames_ystep = 1.0f / frames_height;

//(same as builtin water z)
const float water_back_z = -700.0f;
const float water_front_z = 210.0f;

shared void initWaterMap()
{
	WaterMap water;
	getRules().set("water", @water);
}

shared WaterMap@ getWaterMap()
{
	WaterMap@ water;
	getRules().get("water", @water);
	return water;
}

shared void server_setWaterAt(Vec2f pos, float v)
{
	WaterMap@ water = getWaterMap();
	if (water !is null) {
		water.set_worldpos(pos, v);
	}
}

shared float getWaterAt(Vec2f pos)
{
	WaterMap@ water = getWaterMap();
	if (water !is null) {
		return water.get_worldpos(pos);
	}
	return 0.0f;
}

//(internal)
shared class WaterChunk
{
	int tlx, tly, w, h, size;

	float[] current;
	float[] next;

	WaterMap@ parent;

	bool _active;
	bool _has_changes;
	bool _dirty;

	//for speeding up serialisation
	bool _empty;

	CMap@ map;

	Random _r;

	//mesh
	bool _mesh_dirty;

	//slow-style "easy" mesh storage
	Vec2f[] v_pos;
	Vec2f[] v_uv;
	SColor[] v_col;
	//fast-style mesh storage
	Vertex[] verts_front;
	Vertex[] verts_back;

	//daytime change detection (for lighting)
	u16 _seen_daytime;
	bool daytime_changed()
	{
		if(!do_lighting) return false;
		u16 old_daytime = _seen_daytime;
		_seen_daytime = u16(getMap().getDayTime() * daytime_resolution);
		return old_daytime != _seen_daytime;
	}

	WaterChunk(int _x, int _y, int _w, int _h, WaterMap@ _parent)
	{
		//extents + dimensional size for fine bounds checking
		tlx = _x;
		tly = _y;
		w = _w;
		h = _h;
		//total size for rough bounds checking
		size = w * h;
		//reserve and zero-fill the buffers
		current.reserve(size);
		next.reserve(size);
		for(int i = 0; i < size; i++)
		{
			current.push_back(0);
			next.push_back(0);
		}
		//start empty = inactive
		_empty = true;
		_active = false;
		_dirty = false;
		_mesh_dirty = false;
		_has_changes = false;
		@parent = @_parent;

		//(honestly this is just to save typing/function calls)
		@map = getMap();

		if((size+1)/2 > 255) {
			warn("WaterChunk: this size won't work with the current serialisation code; size is too big.");
		}
	}

	void flip()
	{
		//(nothing changed, no need to flip)
		if(!_has_changes) return;

		//otherwise mark off
		_has_changes = false;

		//re-determine activity and emptiness
		_active = false;
		_empty = true;

		//apply the changes and reset the changes buffer
		for (int i = 0; i < size; i++)
		{
			//apply change
			float old_current = current[i];
			current[i] = next[i];
			next[i] = 0;

			//note down any actually changed visual values
			if( //frame changed
				calculate_frame(current[i]) != calculate_frame(old_current)
				//render state changed
				|| ((current[i] == 0) != (old_current == 0))
			) {
				_dirty = true;
				_mesh_dirty = true;
			}
			//active if there's any non-zero cells
			if(current[i] != 0.0f)
			{
				//TODO: if this chunk didn't change, set inactive until tile changes or water change written
				_active = true;
				_empty = false;
			}
		}
	}

	//get the internal index (unsafe, should bounds check first)
	int index(int local_x, int local_y)
	{
		return local_x + (local_y * w);
	}

	//ensure within local boundaries
	bool in_bounds(int local_x, int local_y)
	{
		return local_x >= 0 && local_x < w &&
			   local_y >= 0 && local_y < h;
	}

	//write in a value verbatim
	void set(int local_x, int local_y, float v)
	{
		if (!in_bounds(local_x, local_y))
		{
			parent.set(tlx + local_x, tly + local_y, v);
			return;
		}

		int i = index(local_x, local_y);
		current[i] = v;
		next[i] = v;

		//wake up if we were inactive
		_active = true;
		_mesh_dirty = true;
	}

	//write a change at a local position
	void change(int local_x, int local_y, float v)
	{
		if (!in_bounds(local_x, local_y))
		{
			parent.change(tlx + local_x, tly + local_y, v);
			return;
		}

		int i = index(local_x, local_y);
		next[i] += v;

		//wake up if we were inactive
		_active = true;
		_has_changes = true;
	}

	//read out a value
	float get(int local_x, int local_y)
	{
		if (!in_bounds(local_x, local_y))
		{
			return parent.get(tlx + local_x, tly + local_y);
		}
		return current[index(local_x, local_y)];
	}

	//check if we can pass at a local position
	bool can_pass(int local_x, int local_y)
	{
		int map_x = tlx + local_x;
		int map_y = tly + local_y;
		//bounds check on map
		if( map_x < 0 || map_x >= map.tilemapwidth ||
			map_y < 0 || map_y >= map.tilemapheight )
		{
			return false;
		}
		//water passes check
		int map_offset = map_x + (map_y * map.tilemapwidth);
		if (!map.hasTileFlag(map_offset, Tile::WATER_PASSES))
		{
			return false;
		}

		return true;
	}

	//get implied amount/solid at a given local position
	void get_implied(int local_x, int local_y, bool &out solid, float &out amount)
	{
		if (!can_pass(local_x, local_y))
		{
			solid = true;
			amount = 2.0f;
		}
		else
		{
			solid = false;
			amount = get(local_x, local_y);
		}
	}

	//get all of a cell's neighbour states/amounts
	void get_neighbours(
		int local_x, int local_y,
		bool &out solid_up, bool &out solid_down, bool &out solid_left, bool &out solid_right,
		float &out implied_up, float &out implied_down, float &out implied_left, float &out implied_right
	) {
		get_implied(local_x + 0, local_y - 1,    solid_up,    implied_up);
		get_implied(local_x + 0, local_y + 1,  solid_down,  implied_down);
		get_implied(local_x - 1, local_y + 0,  solid_left,  implied_left);
		get_implied(local_x + 1, local_y + 0, solid_right, implied_right);
	}

	//do actual water flow logic
	void update()
	{
		//bail if we have nothing to do
		if(!_active) return;

		for(int y = 0; y < h; y++)
		{
			for(int x = 0; x < w; x++)
			{
				int i = index(x,y);

				//should water even get here?
				if(!can_pass(x, y))
				{
					//(will be nulled out in flip)
					continue;
				}

				float amount = get(x, y);

				//do evaporation if needed
				if(amount > 0.0f && amount <= evap_thresh)
				{
					if(_r.NextFloat() < evap_chance)
					{
						amount = Maths::Max(0.0f, amount - evap_rate);
					}
				}

				//nothing to do
				if(amount == 0.0f)
				{
					//null out anything that needs it
					continue;
				}

				float target_amount = 1.0f;

				//figure out flow
				bool solid_u, solid_d, solid_l, solid_r;
				float amount_u, amount_d, amount_l, amount_r;
				get_neighbours(
					x, y,
					solid_u, solid_d, solid_l, solid_r,
					amount_u, amount_d, amount_l, amount_r
				);

				//flow amounts
				float flow_d = 0.0f;
				float flow_l = 0.0f;
				float flow_r = 0.0f;
				float flow_u = 0.0f;

				//fill downwards
				if(!solid_d) flow_d = Maths::Max((amount - amount_d) * 0.25f, target_amount - amount_d);
				//flow sideways
				if(!solid_l) flow_l = (amount - amount_l) * 0.5f;
				if(!solid_r) flow_r = (amount - amount_r) * 0.5f;
				//flow upwards under "pressure"
				if(!solid_u) flow_u = (amount - target_amount - amount_u) * 0.5f;

				//minimum horizontal flow (unless overfilled)
				if(amount <= target_amount)
				{
					if(flow_l < min_flow) flow_l = 0;
					if(flow_r < min_flow) flow_r = 0;
				}

				//compute velocity
				//(oposing flows have randomised direction)
				Vec2f vel = Vec2f(0,0);
				if (flow_u > 0 && flow_d > 0)
				{
					float mul_u = (_r.NextFloat() < 0.5f ? 1 : 0);
					float mul_d = 1 - mul_u;
					flow_u *= mul_u;
					flow_d *= mul_d;
				}
				if (flow_u > 0) vel.y -= flow_u;
				if (flow_d > 0) vel.y += flow_d;

				if (flow_l > 0 && flow_r > 0)
				{
					float mul_l = (_r.NextFloat() < 0.5f ? 1 : 0);
					float mul_r = 1 - mul_l;
					flow_l *= mul_l;
					flow_r *= mul_r;
				}
				if (flow_l > 0) vel.x -= flow_l;
				if (flow_r > 0) vel.x += flow_r;

				//figure out prevailing flow direction
				float vellen = vel.Length();
				if(vellen > 0)
				{
					float dx = 0;
					float dy = 0;
					if(Maths::Abs(vel.x) > Maths::Abs(vel.y)) {
						dx = vel.x > 0 ? 1 : -1;
					} else {
						dy = vel.y > 0 ? 1 : -1;
					}

					//can water go in that direction?
					if(can_pass(x + dx, y + dy))
					{
						float flow_amount = Maths::Min(amount, vellen);
						if(flow_amount > 0) {
							amount -= flow_amount;
							change(x + dx, y + dy, flow_amount);
						}
					}
				}

				//keep any remaining water
				change(x, y, amount);

			}
		}
	}

	//frame from amount
	int calculate_frame(float amount)
	{
		return Maths::Clamp(Maths::Floor(amount * 8), 0, 15);
	}

	//regenerate the mesh for rendering
	void regen_mesh()
	{
		_mesh_dirty = false;

		//nuke out the mesh
		if(raw_vertices)
		{
			verts_back.clear();
			verts_front.clear();
		}
		else
		{
			v_pos.clear();
			v_uv.clear();
			v_col.clear();
		}

		//render out the array as fresh quads
		for(int y = 0; y < h; y++)
		{
			for(int x = 0; x < w; x++)
			{
				//(we do direct lookup here for speed as we are definitely within bounds)
				float amount = current[index(x, y)];

				if(amount == 0.0f) continue;

				//calculate the quad topleft
				Vec2f tilepos = Vec2f(tlx + x, tly + y) * map.tilesize;
				u32 map_offset = (tlx + x) + (tly + y) * map.tilemapwidth;

				//figure out lighting (if needed)
				u8 light = do_lighting ? map.getTile(map_offset).light : 0;
				SColor lcol(0xff000000 | light << 16 | light << 8 | light);

				//calculate frame
				float above = get(x, y-1);
				float frame_x = calculate_frame(amount);
				float frame_y = 0.0f;
				if(above != 0.0f)
				{
					frame_y = 1.0f;
				}

				//calculate top left uv coords of the quad
				Vec2f f = Vec2f(frame_x * frames_xstep, frame_y * frames_ystep);

				//add our quad - it's clockwise winding like this ascii art:

				// 0--1
				// |\ |
				// | \|
				// 3--2

				if(raw_vertices)
				{
					//raw 3d vertex
					//(code below is a bit hard to follow;
					// we reuse our local vertex multiple times to avoid setting up 4 locals)
					Vertex v;

					v.z = water_back_z;

					if(do_lighting)
					{
						v.col = lcol;
					}

					//top left corner variables
					v.x = tilepos.x;
					v.y = tilepos.y;

					v.u = f.x;
					v.v = f.y;

					//vertex 0
					verts_back.push_back(v);

					//vertex 1
					v.x += 8;
					v.u += frames_xstep;
					verts_back.push_back(v);
					//vertex 2
					v.y += 8;
					v.v += frames_ystep;
					verts_back.push_back(v);
					//vertex 3
					v.x -= 8;
					v.u -= frames_xstep;
					verts_back.push_back(v);
				}
				else
				{
					//multiple separate arrays

					//v position                                       v texture coord
					v_pos.push_back(tilepos + Vec2f(0,0)); v_uv.push_back(f + Vec2f(           0,           0));
					v_pos.push_back(tilepos + Vec2f(8,0)); v_uv.push_back(f + Vec2f(frames_xstep,           0));
					v_pos.push_back(tilepos + Vec2f(8,8)); v_uv.push_back(f + Vec2f(frames_xstep,frames_ystep));
					v_pos.push_back(tilepos + Vec2f(0,8)); v_uv.push_back(f + Vec2f(           0,frames_ystep));

					if (do_lighting)
					{
						for(int i = 0; i < 4; i++)
						{
							v_col.push_back(lcol);
						}
					}
				}

			}
		}

		//if we made a raw mesh, we don't get "free" z modification at draw call time
		//so we have to copy the vertices and modify the z of each vert
		if(raw_vertices)
		{
			for(int i = 0; i < verts_back.length; i++)
			{
				Vertex v = verts_back[i];
				v.z = water_front_z;
				verts_front.push_back(v);
			}
		}
	}

	//render the water in this chunk (if we have any)
	void render()
	{
		//nothing to render for inactive chunks
		//(much faster than rendering empty mesh)
		if (!_active) return;

		CMap@ map = getMap();

		if(raw_vertices)
		{
			//early out if we have nothing (safety)
			if(verts_back.length == 0) return;

			Render::RawQuads("WaterTexBack.png", verts_back);
			Render::SetAlphaBlend(true);
			Render::RawQuads("WaterTexFront.png", verts_front);
		}
		else
		{
			//early out if we have nothing (safety)
			if(v_pos.length == 0) return;

			//different calls if we are lit or not
			if(do_lighting)
			{
				Render::QuadsColored("WaterTexBack.png", water_back_z, v_pos, v_uv, v_col);
				Render::SetAlphaBlend(true);
				Render::QuadsColored("WaterTexFront.png", water_front_z, v_pos, v_uv, v_col);
			}
			else
			{
				Render::Quads("WaterTexBack.png", water_back_z, v_pos, v_uv);
				Render::SetAlphaBlend(true);
				Render::Quads("WaterTexFront.png", water_front_z, v_pos, v_uv);
			}
		}
	}

	///////////////////////////////////////////////////////////////////////////
	//sync
	//
	// we write a packed format to save on space, but the big savings come
	// from not writing non-dirty chunks at all when syncing changes
	//
	// however, "mostly-still" chunks tend to have a lot of runs,
	// and that also compresses well.
	//
	// todo: delta-compress changes; store a buffer of previous sent data and send
	//       a delta, so it will compress better.

	void Serialise(CBitStream@ bt)
	{
		//write size of bytes to write (rounded up)
		bt.write_u8(u8((size + 1) / 2));

		//if we're empty, we can write out a special "cheat" byte
		bt.write_u8(_empty ? 1 : 0);
		//(the vanilla water also has a "full" cheat byte but we don't have
		// a trivial way to test for that!)

		if(!_empty)
		{
			//pack 2x1 into a byte
			for(int i = 0; i < size; i += 2)
			{
				u8 b = 0;
				//read out values
				float v1 = current[i];
				float v2 = 0;
				if(i < size - 1) v2 = current[i+1];
				//encode values
				int v1_q = calculate_frame(v1) & 0xf;
				int v2_q = calculate_frame(v2) & 0xf;
				b = (v1_q) | (v2_q << 4);
				//write encoded values
				bt.write_u8(b);
			}
		}
	}

	bool Unserialise(CBitStream@ bt)
	{
		u8 enc_size = 0;
		if(!bt.saferead_u8(enc_size)) return false;
		u8 enc_type = 0;
		if(!bt.saferead_u8(enc_type)) return false;

		if(enc_type == 1)
		{
			//"empty" cheat byte
			_active = false;
			for (int i = 0; i < size; i++)
			{
				current[i] = 0;
			}
		}
		else
		{
			_active = true;
			for(int ei = 0; ei < enc_size; ei++)
			{
				//unpack byte into 2x1
				int i = ei * 2;

				u8 b = 0;
				if(!bt.saferead_u8(b)) return false;

				//decode first
				int v1_q = (b & 0x0f);
				float v1 = v1_q / 8.0f;
				current[i] = v1;
				//decode second if needed
				if(i + 1 < size)
				{
					int v2_q = ((b >> 4) & 0x0f);
					float v2 = v2_q / 8.0f;
					current[i+1] = v2;
				}
			}
		}

		//(we only bother sending if this is the case, no need to determine it clientside)
		_mesh_dirty = true;

		return true;
	}
};

shared class WaterMap
{
	int update_pass; //0 = update, 1 = flip
	int chunk_i;
	int chunks_width;
	WaterChunk[] chunks;

	bool wants_sync;
	int sync_count;

	//used to iterate through the chunks to render and ensure everything gets remeshed
	int _current_remesh_offset;

	WaterMap()
	{
		CMap@ map = getMap();

		chunk_i = 0;
		sync_count = 0;
		_current_remesh_offset = 0;

		//build the chunks map
		for(int y = 0; y < map.tilemapheight; y += chunk_size)
		{
			for(int x = 0; x < map.tilemapwidth; x += chunk_size)
			{
				int w = Maths::Min(map.tilemapwidth  - x, chunk_size);
				int h = Maths::Min(map.tilemapheight - y, chunk_size);
				chunks.push_back(WaterChunk(x, y, w, h, this));
			}
			//store how wide the chunks map will be (in chunks)
			if(y == 0)
			{
				chunks_width = chunks.length;
			}
		}
	}

	//update some chunks each frame
	void update()
	{
		int _available_cost = cost_per_frame;
		if (getControls().isKeyPressed(KEY_KEY_V)) {
			_available_cost *= 10;
		}
		//only loop through the entire thing once if it's that cheap
		int _limit = chunks.length * 2;
		while(_available_cost > 0 && _limit-- > 0)
		{
			if(chunk_i < chunks.length)
			{
				WaterChunk@ chunk = chunks[chunk_i];
				chunk_i++;

				//do different things based on what pass we're done
				if (update_pass == 0)
				{
					if(!chunk._active)
					{
						_available_cost -= cost_per_inactive;
						continue;
					}
					_available_cost -= cost_per_active;

					chunk.update();
				}
				else if (update_pass == 1)
				{
					_available_cost -= chunk._has_changes ? cost_per_flip_expensive : cost_per_flip_cheap;

					chunk.flip();

					//check if the lighting changed so we don't get "frozen" lighting on non-changing chunks
					if(chunk.daytime_changed())
					{
						chunk._mesh_dirty = true;
					}
				}
			}
			else
			{
				chunk_i = 0;
				update_pass = (update_pass + 1) % 2;
				//(each time "around" the map)
				if(update_pass == 0) {
					//update sync counter/flag
					sync_count++;
					if(sync_count >= send_ratio)
					{
						wants_sync = true;
						sync_count = 0;
					}
				}
			}
		}
	}

	//render any visible chunks
	void render()
	{
		CMap@ map = getMap();
		Driver@ driver = getDriver();

		//
		Vec2f min = Vec2f(10000, 10000);
		Vec2f max = Vec2f(-10000,-10000);

		//get visible aabb from screen corners
		//TODO: we should really provide an engine side function for this ':D
		{
			//({} scope just limits these variables lifetime)
			Vec2f d = driver.getScreenDimensions();
			Vec2f[] corners = {
				Vec2f(0,0),
				Vec2f(d.x,0),
				d,
				Vec2f(0,d.y)
			};
			for (int i = 0; i < corners.length; i++)
			{
				Vec2f wpos = driver.getWorldPosFromScreenPos(corners[i]);
				min.x = Maths::Min(min.x, wpos.x);
				min.y = Maths::Min(min.y, wpos.y);
				max.x = Maths::Max(max.x, wpos.x);
				max.y = Maths::Max(max.y, wpos.y);
			}
		}

		//clamp within map size
		min.x = Maths::Clamp(min.x, 0, map.tilemapwidth * map.tilesize);
		max.x = Maths::Clamp(max.x, 0, map.tilemapwidth * map.tilesize);
		min.y = Maths::Clamp(min.y, 0, map.tilemapheight * map.tilesize);
		max.y = Maths::Clamp(max.y, 0, map.tilemapheight * map.tilesize);

		//transform to tilespace
		int x1 = int(min.x / map.tilesize);
		int y1 = int(min.y / map.tilesize);
		int x2 = int(max.x / map.tilesize);
		int y2 = int(max.y / map.tilesize);

		array<WaterChunk@> _chunks_to_render;
		//gather on-screen chunks for render/remesh
		for (int y = y1; y < (y2 + chunk_size - 1); y += chunk_size)
		{
			for (int x = x1; x < (x2 + chunk_size - 1); x += chunk_size)
			{
				WaterChunk@ chunk = get_chunk(
					Maths::Min(map.tilemapwidth-1, x),
					Maths::Min(map.tilemapheight-1, y)
				);
				//out of map bounds
				if (chunk is null) continue;
				//empty chunk + doesn't need re-meshing
				if (!chunk._active && !chunk._mesh_dirty) continue;

				_chunks_to_render.push_back(@chunk);
			}
		}

		//
		int len = _chunks_to_render.length;
		if (len > 0)
		{
			//regenerate meshes
			//limit the number of meshes regenerated
			int to_remesh = getInterpolationFactor() == 0.0f ? remesh_limit : remesh_limit_renderonly;
			int limit = len;
			for (int i = 0; i < len && to_remesh > 0; i++)
			{
				//step forward and wrap
				//(done before reading as the array size can change between frames)
				_current_remesh_offset++;
				if (_current_remesh_offset >= len)
				{
					_current_remesh_offset = 0;
				}

				WaterChunk@ chunk = _chunks_to_render[_current_remesh_offset];

				//only regen if we need it
				if (chunk._mesh_dirty)
				{
					to_remesh--;
					chunk.regen_mesh();
				}

			}

			//render chunks (stale or not)
			for (int i = 0; i < len; i++)
			{
				_chunks_to_render[i].render();
			}
		}

	}

	WaterChunk@ get_chunk_and_local_pos(int x, int y, int &out lx, int &out ly)
	{
		//bounds check
		if (x < 0 || y < 0) return null;
		CMap@ map = getMap();
		if (x >= map.tilemapwidth || y >= map.tilemapheight) return null;
		//figure out chunk coords
		int cx = x / chunk_size;
		int cy = y / chunk_size;
		int i = cx + (cy * chunks_width);
		//do lookup (guaranteed safe by bounds check)
		WaterChunk@ chunk = chunks[i];
		//bounds check in-chunk (happens on edges)
		lx = x - chunk.tlx;
		ly = y - chunk.tly;
		if (!chunk.in_bounds(lx, ly)) {
			return null;
		}
		return chunk;
	}

	WaterChunk@ get_chunk(int x, int y)
	{
		int lx, ly;
		return get_chunk_and_local_pos(x, y, lx, ly);
	}

	//safely set from a tilespace position
	void set(int x, int y, float v)
	{
		int lx, ly;
		WaterChunk@ chunk = get_chunk_and_local_pos(x, y, lx, ly);
		if (chunk is null) return;
		chunk.set(lx, ly, v);
	}

	//safely get from a tilespace position
	float get(int x, int y)
	{
		int lx, ly;
		WaterChunk@ chunk = get_chunk_and_local_pos(x, y, lx, ly);
		if (chunk is null) return 0.0f;
		return chunk.get(lx, ly);
	}

	//safely modify from a tilespace position
	void change(int x, int y, float v)
	{
		int lx, ly;
		WaterChunk@ chunk = get_chunk_and_local_pos(x, y, lx, ly);
		if (chunk is null) return;
		chunk.change(lx, ly, v);
	}

	//set from a world position (mouse etc)
	void set_worldpos(Vec2f p, float v)
	{
		CMap@ map = getMap();
		set(
			int(p.x/map.tilesize),
			int(p.y/map.tilesize),
			v
		);
	}

	float get_worldpos(Vec2f p)
	{
		CMap@ map = getMap();
		return get(
			int(p.x/map.tilesize),
			int(p.y/map.tilesize)
		);
	}

	///////////////////////////////////////////////////////////////////////////
	//sync

	//chunk streaming
	void WriteChunk(WaterChunk@ chunk, CBitStream@ bt)
	{
		bt.write_u16(chunk.tlx);
		bt.write_u16(chunk.tly);
		chunk.Serialise(bt);
	}

	bool ReadChunk(CBitStream@ bt)
	{
		u16 tlx = 0, tly = 0;
		if (!bt.saferead_u16(tlx)) return false;
		if (!bt.saferead_u16(tly)) return false;

		WaterChunk@ chunk = get_chunk(tlx, tly);
		if (!chunk.Unserialise(bt)) return false;

		return true;
	}

	//entire read/write

	void Serialise(CBitStream@ bt)
	{
		//write out chunks count/sizes
		bt.write_u16(chunks_width);
		bt.write_u16(chunk_size);
		bt.write_u16(chunks.length);

		//write out chunks
		for(int i = 0; i < chunks.length; i++)
		{
			chunks[i].Serialise(bt);
		}
	}

	bool Unserialise(CBitStream@ bt)
	{
		//read out chunks count/sizes
		u16 _chunks_width;
		u16 _chunk_size;
		u16 _chunks_len;

		if(!bt.saferead_u16(_chunks_width)) return false;
		if(!bt.saferead_u16(_chunk_size)) return false;
		if(!bt.saferead_u16(_chunks_len)) return false;

		//sanity check vs what we're compiled with
		if(_chunks_width != chunks_width) return false;
		if(_chunk_size != chunk_size) return false;
		if(_chunks_len != chunks.length) return false;

		//read out chunks contents
		for(int i = 0; i < chunks.length; i++)
		{
			if(!chunks[i].Unserialise(bt)) return false;
		}

		return true;
	}

	//delta read/write

	bool WriteChanges(CBitStream@ bt)
	{
		if(!wants_sync) return false;

		//clear the flag
		wants_sync = false;

		//gather dirty chunks - we need to know how many we have ahead of writing any
		WaterChunk@[] dirty_chunks;
		for(int i = 0; i < chunks.length; i++)
		{
			if(chunks[i]._dirty)
			{
				dirty_chunks.push_back(@chunks[i]);
			}
		}

		//nothing dirty? nothing sent
		if(dirty_chunks.length == 0) return false;

		bt.write_u16(dirty_chunks.length);
		for(int i = 0; i < dirty_chunks.length; i++)
		{
			WaterChunk@ chunk = dirty_chunks[i];
			WriteChunk(chunk, bt);
			chunk._dirty = false;
		}

		return true;
	}

	bool ReadChanges(CBitStream@ bt)
	{
		u16 len = 0;
		if(!bt.saferead_u16(len)) return false;

		while(len-- > 0)
		{
			if(!ReadChunk(bt)) return false;
		}

		return true;
	}

};
