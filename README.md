# Modern Player Motion (MPM): work folder

MW-style player movement and animation for Garry's Mod: inertia, tac sprint, slide, dive, prone, mantle, MW19/MWII
player clips, per-gun MW holds/reloads/draws for MW Base guns, hand IK, foot IK and hit flinches.

Current version: **v0.12.0** (Phase 7 movement anims + mantle, Phase 8 ground layer, body-part flinches).
The full design, change log and in-game test checklist are in `MPMDIDDY/PLAN.md`. Read its change log from the bottom up
for the most recent work.

## Read PLS

- RUNS LIKE SHIT RN
- Best with MW Base. MW Base guns get the true MW holds, reloads, draws and hand IK; everything else is a fallback.
- Most of the default GMod holdtypes look meh, and some are completely broken until we swap in the best-matching CoD
  anims for them.
- Attachments still desync from the gun while shooting and during some actions.
- Foregrip poses aren't right yet: the left hand doesn't sit correctly on grips.
- Not tested alongside any other player animation addons (xdr, DynaBase, etc.), or with any weapon base's own TPIK.

## What's here

| Path | What |
|---|---|
| `addons/modern_player_motion` | The addon (v0.12.0). Copy it into `garrysmod/addons/`. Lua is in `lua/mpm`, built models are in `models/` |
| `addons/mpm_devtools` | Local dev tools: photo booth, bone dumps, finger tracker, and a "Dev tools" page in the spawn menu. Don't ship it |
| `snapshots/modern_player_motion_v0.11.1_pre_phase7` | The addon as it was **before** the v0.12.0 additions, kept for comparison or rollback |
| `MPMDIDDY` | Docs and tests: `PLAN.md`, the offline Lua harness (`harness/`), offline renders (`render/`) |
| `tools` | The anim builder `mpm_build.py` and the converters it uses (`tif_mw_build.py`, `cod_anim_prep.py`, `cod_to_breen.py`, `cod_bone_mapping.py`) |
| `tools/rig` | Rig SMDs the converter needs: the CoD body (`PlaceHolder_Body.smd`) and the ValveBiped target (`reference.smd`, `breen_smd/breen_reference.smd`) |
| `manifest/manifest.py` | Which MW clips get built and how |

## Needed from the Workshop (not included)

Subscribe to these, or put them in `garrysmod/addons`:

- MW Base: `modern_wokefare_base` (Workshop 2459720887)
- MW19 SWEP packs (`modern_warfare_2019_sweps_*`): assault rifles 2528829149, DLC assault rifles 2577589751,
  marksman rifles 2864559679, DLC marksman rifles 2864561323, shotguns 2751323984, DLC shotguns 2751325999,
  SMGs 2802430252, DLC SMGs 2802431672, LMGs 2960120610, pistols 2459723892, sniper rifles 2918635913, G3A3 2502495789,
  minigun 2582142302, rigs 2802427264

The builder reads the packs' weapon Lua and world models (`GUNS` glob in the manifest) to calibrate the per-gun holds.
At runtime MPM works without them, but the per-gun holds and actions only apply to MW Base guns.

## Running it

1. Copy `addons/modern_player_motion` (and `addons/mpm_devtools` if you want the dev tools) into `garrysmod/addons/`.
2. Start GMod. **Restart GMod after every model rebuild**, because models don't hot-reload.
3. Settings are in the spawn menu under Utilities -> Modern Player Motion. Turn on `mpm_debug 1` for the overlay.

## Offline tests

```
pip install lupa
cd MPMDIDDY/harness
python run.py ../../addons/modern_player_motion
```

The last line should read `124/124` (one check fails the run if any addon Lua file is over 200 KB). The harness runs the shared Lua (movement core, mantle, anim graph, gun data,
flinch picks) against a mocked GMod with a simple box world (`env.lua`).

## Rebuilding the animations

You need Python 3 with numpy, GMod's `studiomdl.exe`, and the anim rips (below).

```
python tools/mpm_build.py manifest/manifest.py --compile
```

This converts the clips into `BUILD` (about 650 MB, not included), compiles `models/mpm/mpm_anims.mdl` and
`mpm_guns1-3.mdl`, writes the clip data as `lua/mpm/data/clips_pNNN.lua` parts (at most 110 KB each: one big Lua file never reaches multiplayer clients), and patches `models/m_anm.mdl` / `f_anm.mdl` (byte copies of GMod's own,
with one `$includemodel` added). All of it goes into the addon named by `ADDON` in the manifest. Converted clips are
cached in `BUILD/clips`. Set `REBUILD_GUNS = True` in the manifest to force the gun clips to rebuild. `--split-only` just re-splits the existing data into parts.

### Absolute paths to change on another PC

Everything below is hard-coded to the original machine. Point these at your own copies:

| File | Setting | Was |
|---|---|---|
| `manifest/manifest.py` | `SOURCE` (MW19 SEAnim rip; wins on shared names) | `K:/duglastakedown` |
| `manifest/manifest.py` | `EXTRA_SOURCES` (MWII rips) | `K:/mw22 anims 2/xanims`, `K:/mw22 anims` |
| `manifest/manifest.py` | `FIX_FIRST_KEY` (rip with a junk frame 0) | `K:/mw22 anims` |
| `manifest/manifest.py` | `BUILD` (scratch output) | `K:/jimmyproject/mpm/build` |
| `manifest/manifest.py` | `ADDON` (where models + clips.lua go) | `.../garrysmod/addons/modern_player_motion` |
| `manifest/manifest.py` | `GUNS[...]["glob"]` (MW19 SWEP pack weapons) | `.../garrysmod/addons/modern_warfare_2019_sweps_*/lua/weapons/mg_*` |
| `tools/tif_mw_build.py` | `DEFAULT_SOURCE_BODY`, `DEFAULT_TARGET`, `DEFAULT_MESH` | `K:/head2/...`, `K:/duglastakedown_smd/...`: use `tools/rig/` |
| `tools/tif_mw_build.py` | `STUDIOMDL`, `GAMEDIR` | `K:\SteamLibrary\steamapps\common\GarrysMod\...` |

The anim rips aren't included because they're big and aren't ours to redistribute. They are SEAnim exports of the MW19
(`sdr_mp_*`, `mp_*`) and MWII (`iw9_mp_*`) player animations. MW19 clips win over MWII ones with the same name. The
manifest lists every clip name it uses.

## Where things are in the Lua

| File | Job |
|---|---|
| `sh_config.lua` | Convars, DT slots, state ids (`MPM.S`) |
| `sh_state.lua`, `sh_input.lua`, `sh_move.lua` | Predicted movement core: StartCommand rewrite, SetupMove states (sprint, tac, slide, dive, prone, hard landing) |
| `sh_mantle.lua` | Mantle: ledge detection, clip pick, path, `Move` override, hard-landing stamp |
| `sh_anim.lua` | Anim graph: gait pick, main sequence, aim layer, foreign-gesture silencing |
| `sh_anim_trans.lua` | One-shots: starts, stops, turns, stance changes, slide/dive/jump/land/mantle shots, slope layers |
| `sh_anim_guns.lua` | MW Base per-gun holds, actions (reload/draw/inspect), fire kicks, grips |
| `sh_flinch.lua` | Body-part hit flinches (server picks part/direction, clients play it) |
| `cl_gun.lua` | Gun placement on MW's gun bone, ADS sight alignment, hand IK, fingers |
| `cl_ground.lua` | Foot IK, foot lock, prone slope tilt |
| `cl_menu.lua`, `cl_debug.lua` | Spawn menu pages, debug overlay |
| `data/clips_pNNN.lua` | Generated by the builder, split into <=110 KB parts for multiplayer: don't edit, don't merge |

House style: the new code has no comments. Explanations go in `MPMDIDDY/PLAN.md`.

## Open / next

- Untested in game: everything in v0.12.0 (checklist items 56-61 in `PLAN.md`), plus v0.10.5-v0.11.1 items.
- Deferred by request: prone on your side / back (supine).
- Not done yet: death anims, MWII weapon-down mantles, far/climb mantle variants picked at runtime, Juggernaut variants.
