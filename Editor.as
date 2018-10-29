// TEMP!

#define SERVER_ONLY

#include "WaterCommon.as"

void onTick(CRules@ this)
{
	if (!sv_test || !getNet().isServer())
	{
		return;
	}

	CPlayer@ p = getLocalPlayer();
	CMap@ map = getMap();
	if (p !is null && p.isMod())
	{
		// delete blob

		if (getControls().isKeyJustPressed(KEY_KEY_X))
		{
			Vec2f pos = getBottomOfCursor(getControls().getMouseWorldPos());
			CBlob@ behindBlob = getMap().getBlobAtPosition(pos);

			if (behindBlob !is null)
			{
				behindBlob.server_Die();
			}
			else
			{
				map.server_SetTile(pos, CMap::tile_empty);
			}
		}
		if (getControls().isKeyJustPressed(KEY_KEY_Z))
		{
			Vec2f pos = getBottomOfCursor(getControls().getMouseWorldPos());

			WaterMap@ water = getWaterMap();
			if (water is null) return;

			int rad = 3;
			for(int y = -rad; y <= rad; y++)
			{
				for(int x = -rad; x <= rad; x++)
				{
					water.set_worldpos(pos + Vec2f(x * 8, y * 8), 1.0f);
				}
			}

		}
	}
}

void onRender(CRules@ this)
{
}

Vec2f getBottomOfCursor(Vec2f cursorPos)
{
	cursorPos = getMap().getTileSpacePosition(cursorPos);
	cursorPos = getMap().getTileWorldPosition(cursorPos);
	// check at bottom of cursor
	f32 w = getMap().tilesize / 2.0f;
	f32 h = getMap().tilesize / 2.0f;
	int offsetY = Maths::Max(1, Maths::Round(8 / getMap().tilesize)) - 1;
	h -= offsetY * getMap().tilesize / 2.0f;
	return Vec2f(cursorPos.x + w, cursorPos.y + h);
}