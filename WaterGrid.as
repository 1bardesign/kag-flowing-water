//WaterGrid.as

#include "WaterCommon.as"

void onInit(CRules@ this)
{
	//setup cmds
	this.addCommandID("water_init");
	this.addCommandID("water_update");

	//set up watermap
	onRestart(this);
}

bool need_send_all;
u16[] need_send_direct;

void onRestart(CRules@ this)
{
	initWaterMap();
	if(getNet().isServer())
	{
		need_send_all = true;
	}
}

void onNewPlayerJoin(CRules@ this, CPlayer@ player)
{
	//send water state on new player
	if(!player.isLocal())
	{
		need_send_direct.push_back(player.getNetworkID());
	}
}

void sendWaterMap(CRules@ this, CPlayer@ to_player)
{
	WaterMap@ water = getWaterMap();
	if (water is null) return;

	u8 id = this.getCommandID("water_init");
	CBitStream params;
	water.Serialise(params);

	//debug
	//print("water: sending init bytes "+params.getBytesUsed());

	if (to_player is null)
	{
		//send to everyone
		this.SendCommand(id, params);
	}
	else
	{
		//send only to specific player
		this.SendCommand(id, params, to_player);
	}
}

void onTick(CRules@ this)
{
	//only update water on server
	if(getNet().isServer())
	{
		WaterMap@ water = getWaterMap();
		if (water !is null)
		{
			//handle sync
			if(need_send_all)
			{
				need_send_all = false;
				//send to everyone on init
				sendWaterMap(this, null);
				//(don't need direct if we've just sent to all)
				need_send_direct.clear();
			}

			//send directly to new joined players
			while(need_send_direct.length > 0)
			{
				u16 nid = need_send_direct[need_send_direct.length - 1];
				need_send_direct.pop_back();
				CPlayer@ p = getPlayerByNetworkId(nid);
				if (p !is null)
				{
					sendWaterMap(this, p);
				}
			}

			//update the water
			water.update();

			//if there's changes, sync
			CBitStream params;
			if(water.WriteChanges(params))
			{
				//debug
				//print("water: sending change bytes "+params.getBytesUsed());
				this.SendCommand(this.getCommandID("water_update"), params);
			}
		}
	}
}

void onCommand( CRules@ this, u8 cmd, CBitStream @params )
{
	WaterMap@ water = getWaterMap();
	if (water is null)
	{
		warn("Missing water map in WaterGrid.as onCommand");
		return;
	}

	//server doesn't read water cmds
	if(getNet().isServer()) return;

	if(cmd == this.getCommandID("water_init"))
	{
		water.Unserialise(params);
	}
	else if(cmd == this.getCommandID("water_update"))
	{
		water.ReadChanges(params);
	}
}