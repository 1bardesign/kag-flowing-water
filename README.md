# Mass-Preserving Water for King Arthur's Gold

A flowing water example for KAG. Open sourced and heavily commented for the community.

[img]https://i.imgur.com/VwpXouy.gif[/img]

# Installation

- Add all the repo files to a "Water" folder under your mods directory and add "Water" to mods.cfg
- Start Sandbox
- `!spawnwater` in chat to test
- See included gamemode.cfg for integration with other gamemodes (basically add `WaterGrid.as` and `WaterRender.as` before `Holiday.as` in scripts.)

# Features:

- simple `!spawnwater` override showing how to set water in-game
- lots of configuration features
	- flow amounts
	- evaporation to limit the burden of "stray" water
	- support for both easy and fast rendering modes (fast preferred)
	- support for lighting enabled/disabled (faster disabled)
	- update/render/remesh costs (pre-tweaked but open for inspection)
- deferred tilemap mesh updates (update a few per frame rather than tank fps)
- fixed-cost flow updates (huge water flows more slowly instead of tanking fps)
- network sync

# Ideas for Expansion

- Make blobs react to the water - (modify ShapeVars.inwater directly for relevant blobs. Probably best to do in WaterGrid rather than modify every blob script!)
- Allow "picking up" and "putting out" an area of water with the bucket
- Add "real velocity" splashing water + push blobs with the current
- Make water pumps for moving water around
- Add multiple fluids + mixing
- Make a "water rush" gamemode; 10min to collect a tank full of spring water in the desert.
- Make an "underseige" gamemode; try to flood the enemy tent. Start with under-sea castle. Water spawns at top left and right.

# Enjoy!

Code is 0BSD licensed - free to use for all purposes and intended for open modification by the community.