# inso

An osu! clone with Lua and GLSL shader support for beatmaps. Made for YEAST3, a sightreading tournament that first ran on stage at [COE2026](https://cavoe.events).
Integrates with existing osu! maps; documentation is a bit sparse at the moment. Website for the game is currently WIP.

Written in [Odin](https://odin-lang.org/).

## Installation guide

Get the latest release [here](https://github.com/isakvik/inso/releases/latest). If you run into issues, ensure you have your latest graphics drivers; they may improve OpenGL support and/or performance.

### Windows

Unzip, add songs to your inso folder's songs/ and run inso.exe.

PS: AMD laptops using integrated graphics might have issues in the latest build. Use a dedicated GPU if available.

### Linux

BASS has a dependency on `libasound2`.
OpenGL rendering depends on `libGL` being available; ensure you have supported GPU drivers for your system.

Unzip, add songs to your inso folder's songs/ and run inso.

## Usage

You can open maps/skins with the "open external" button under each dropdown. Ctrl+F5 will refresh the map/skin dropdowns, in case you add things to the folders while the program is open.

The intended workflow for mappers is to create your maps using stable, open your map using "open external", and add an .inso file/scripts/shaders to the map folder. Updates to any relevant file/asset while the map is open will reload the map, and you should see the changes applied at once.

inso command line flags:

| flag | effect |
|---|---|
| `--tournament [path]` | tournament client mode; optional map / song folder path |
| `--gen-lua-docs` | regenerates the lua docs and exits |
| `--disable-raw-input` | disables raw input (NVIDIA Nsight may crash with it enabled) |

inso_lan_broadcast sends a number of packets to an IP, meant for broadcasting start packets to clients waiting in tournament mode. 

Usage: `inso_lan_broadcast [start|abort] [broadcast ip] [wait ms]`

Edit mode keybinds:

| key | action |
|---|---|
| `escape` / `space` | pause / resume playback |
| `left` / `right` | scrub backward / forward one grid step (1/4 beat) |
| `ctrl+left` / `ctrl+right` | jump to previous / next bookmark |
| `ctrl+o` | open a beatmap file |
| `ctrl+c` | copy playhead time in ms |
| `ctrl+shift+c` | copy playhead as osu-style timestamp (`mm:ss:mmm`) |
| `ctrl+v` | jump to the `mm:ss:mmm` timestamp in the clipboard |
| `f5` | play mode from the playhead |
| `shift+f5` | play mode from the first hitobject's preempt window |
| `r` | soft reload the current beatmap |
| `shift+r` | reload beatmap incl. assets |
| `z` | jump to first hitobject (or map start if already there) |
| `home` | reset playback rate to 1x |
| `pageup` / `pagedown` | speed up / slow down playback (x1.5 steps) |
| mouse scroll | scrub along the beat grid (up = backward) |
