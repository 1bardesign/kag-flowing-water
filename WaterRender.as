#define CLIENT_ONLY

#include "WaterCommon.as";

//TODO: (need to determine if we need to re-add this onRestart - not tested tbh!)
void onInit(CRules@ this)
{
	//we render in the post-world layer, because we need "proper" soft alpha over the top of other elements

	//                                         TODO: replace below with actual script name!
	Render::addScript(Render::layer_postworld, "WaterRender.as", "WaterRender", 0.0f);
}

void WaterRender(int id)
{
	WaterMap@ water = getWaterMap();
	if (water !is null) {
		water.render();
	}
}