# Modern Player Motion (MPM): plan

A new movement + animation system that sits on top of the GMod player. It is not an `m_anm` swap.
MW19/MW22 player clips, MW-style movement (inertia, tac sprint, slide, dive, prone, mantle),
true holds for MW Base (`mg_base`) weapons and a best-average fallback for every other base.

- Addon: `addons/modern_player_motion` (Lua prefix `MPM`, convars `mpm_*`)
- Docs: `addons/MPMDIDDY` (this folder; kept out of the addon so gmad never sees `.md` files)
- Anim build: reuse `K:\mods map pics\smh_cod_anim_baker\tools` (`cod_anim_prep.py` -> `cod_to_breen.py`,
  already retargets CoD rig -> ValveBiped/Breen, extracts root motion). A player-mode builder gets added next
  to `tif_mw_build.py` rather than changing it.

## Layers

| # | Layer | Job |
|---|---|---|
| 1 | Movement core | Predicted state machine in `StartCommand`/`SetupMove`. MW accel/decel, tac sprint, slide, dive, prone, mantle. Single source of truth for everything above it |
| 2 | Anim graph | Replaces `CalcMainActivity`/`UpdateAnimation` as the brain. Picks legs clips by state + direction + speed: starts, stops (left/right planted foot), pivots, leans, stride-synced playback, distance-matched stops |
| 3 | Weapon layer | Upper body via `$weightlist` gesture layers: hold idle/aim per weapon class, aim matrix, fire/reload/inspect/melee, raise/lower (draws), left-hand IK |
| 4 | Ground layer | Foot IK on slopes/stairs, foot lock while planted, prone pelvis pitch to the ground |
| 5 | Adapters | `mg_base` true holds; ARC9 / TFA / generic best-average; gamemode speed compat |
| 6 | Contextual | Clips that exist in the PLAYER list only (see below) |

Shared code on both realms, so server hitboxes follow the same graph as the client.

## Mantling (Phase 7, user asked 2026-11-24)

MW mantles as a real movement state, not just an anim. Clips (rifle set, MW19 `mp_mantle_*` first, MWII fills):

| Family | Clips | Use |
|---|---|---|
| Standard | `mp_mantle_{24,32,40,48,56,64}_{up,over}_{idle,run}` | ledge 24-64 u; `up` = climb onto, `over` = vault across; `idle` from standing, `run` when moving |
| Low step | `mp_mantle_step_{16,32}_{up,over}`, `mp_mantle_far_step_*` | knee-high obstacles |
| Climb | `mp_mantle_climb_{32,64}_{up,over}`, `far_climb_*` | hands-and-knees climbs |
| Boost (tall) | `mp_mantle_boost_{64,190}_{up,over}`, `boost_{up,over}_{idle,run}`, `far_boost_*` | up to ~190 u walls (jump + pull up) |
| Far | `mp_mantle_far_*` | ledge a little out of reach (lean / reach before the pull) |
| MWII | `iw9_mp_mantle_on_weapon_{up,down}_{close,far}_{low,high,extreme}` | weapon-up / weapon-down variants |
| Ladder top | `sdr_mp_mantle_ladder_5_{0,24}` | getting off the top of a ladder (with ladders later) |

Movement core (new state MANTLE, predicted like slide / prone):
- Trigger: jump pressed (or held) while facing a ledge; also from sprint / tac sprint (run variants). Forward hull
  traces find the ledge: height above the feet (16-190 u), distance to it (close / far), depth of the top (a thin
  top with a drop behind = `over` vault; a deep top = `up`), headroom on top (crouched hull must fit, else no mantle).
- Motion: the player is moved along the chosen clip's root curve (built like the starts' `dist`, but full x / z),
  vertical scaled so the clip's height lands exactly on the measured ledge; collision-checked each tick; crouched hull
  during the climb; ends standing (or crouched if no headroom) with the clip's exit speed for `run` / `over`.
- Weapon: lowered / no firing during the climb (weapon-down MWII clips for heavy guns), MW Base flags respected.
- Anim: the graph plays the clip as a one-shot (cycle = mantle progress), aim layer off, hands to the hold at the end.
- Ledge hang / shimmy stays PARKED (ask the user) - it's the natural extension when the ledge is too high to mantle.

## Flair (modern-game detail GMod lacks; found in the rips 2026-11-24)

### Committed (user picked these, 2026-11-24)

| Flair | Clips | Phase |
|---|---|---|
| Slope locomotion: body leans into hills | `sdr_mp_slope_down_jog_N_15/30` (downhill 15/30 deg per dir), `*_sprint/supersprint_<cls>_inclineup_N` | 8 (ground) |
| Sprint-specific starts / stops / exits | `sdr_mp_strafe_sprint_start_<cls>_N`, `sprint_stop_l/r_N`, `crouch_fast_8_to_sprint_8_trans`, `prone_fast_8_to_sprint_8_trans` | 4 |
| Idle variety | `sdr_mp_stand_idle01..04` (rotate, never the same loop twice) | 4 |
| Prone on your side / back (supine; user: later, not in the v0.12.0 Phase 7 pass) | `sdr_mp_prone_{rightside,leftside,chest}_{start,crawl}` | 7 |
| Hard landings (big falls) | `sdr_mp_parachute_{slow,fast}_hard_landing(_legs)` | 7 |
| Hit reactions: directional, per body part, additive over anything | `sdr_mp_pain_sub_{stand,strafe,crouch,prone,ledge,swim,laststand}_<part>_<dir>`, `pain_{stand,crouch,prone}_{head,torso}` | 9 |
| Death anims into ragdoll (per stance, hit spot, run direction) | `sdr_mp_exposed_{stand,crouch,prone}_death01-03_*`, `sdr_mp_strafe_jog_N_death0x_<part>` (TIF's sv_hits_mw handoff idea) | 9 |
| Gun state detail | empty vs tactical reloads, `inspect_empty`, `custom_rechamber` (bolt / pump between shots), `trans_2_ads / nonads` per gun | 6 |
| Moving draws | `sdr_mp_stand_moving_{raise,lower}_*`, `crouch_moving_trans` | 5 |
| Unarmed / FISTS: replaces GMod's `fist` holdtype (weapon_fists, any SWEP holding "fist", MW Base AmmoBox / Shield) | MW melee locomotion `sdr/iw9_mp_me_strafe_*` (walk / jog / run / crouch / prone / slide), fist idles `iw9_mp_me_fists_{stand,crouch}_idle`, `addoff_me_fists_{nonads,ads,nonads_sprint}`, raise / quick raise / lower / inspect / drop (`sdr_mp_{raise,quick_raise,lower}_{,crouch_,prone_}me_fists`, `iw9_mp_me_fists_*`), punches `iw9_mp_melee(_hips)(_crouch)_me_fists_*` (8 each) for GMod fists' attacks, `pushfists` raise / lower. 268 fist clips | 5 |

Phase 9 = contextual (below) grows into "reactions & context".

### Parked: ASK THE USER before building (they see value in some, decide later)

| Flair | Clips |
|---|---|
| Ledge hang, shimmy, peek over | `iw9_mp_ledge_{hang,overhang}_*` (entry air close/far, pullup, peek idle, pain while hanging) |
| Mounting on walls / windows + bipod | `sdr_mp_mount_{stand,crouch}_{vertical,horizontal}_*` |
| Knockdown get-up (explosion knockback -> ragdoll -> stand) | `iw9_mp_ragdoll_recovery_back_to_{stand,crouch,prone}` |
| Stun reactions | `sdr_mp_stand_shellshocked`, `sdr_mp_flashbang_react` |
| Gear flourishes | `sdr_mp_{stand,crouch,prone}_nvg_{on,off}`, `gasmask_{on,off,break}` |
| Faces | `sdr_mp_facial_<operator>_{fire_ads,pain,...}` |
| Finishers | `iw9_mp_execution_*` (514), `sdr_mp_execution_*` (715), `t9_execution_*` (1280); would share with mw22_takedowns |
| Spawn infils | `mp_infil_*`, `iw9_mp_infil_*` heli / vehicle seat intros, `parachute`, `skydive` |

When a phase touching one of these comes up (e.g. Phase 7 traversal -> ledge hang / mount, Phase 9 -> stuns, get-up,
gear, faces), ask the user whether to add it then.

## Gun placement: MW's gun bone (proposal, 2026-11-24)

The problem (user): MW parents the weapon to its own gun bone `j_gun`, animated on its own, so when a hand leaves the
gun (mag swap, right hand cycling a bolt, inspects, draws) the gun stays where the clip puts it. MW Base and nearly all
GMod weapons parent the world model to the RIGHT HAND, so on those moments the gun flies off with the hand.

What we have:
- Every built clip still contains MW's real `j_gun` motion (cod_to_breen re-parents it under the right hand and keeps
  the grip), but playermodels have no `j_gun` bone, so the engine drops it at runtime.
- MW Base world models (`models/viper/mw/weapons/w_*.mdl`) are rooted on `ValveBiped.Bip01_R_Hand` (bonemerged to the
  player), the gun body hangs off `tag_sling`, which MW Base pushes with a hand-tuned HL2 offset
  (`SWEP.WorldModelOffsets` = Bone "tag_sling", Angles, Pos via ManipulateBone*). The models also carry MW's own IK
  tags `tag_ik_loc_le` / `tag_ik_loc_ri`, and mag bones `j_mag1`, `tag_mag_hide` / `tag_mag_show`.

Proposal:
1. **Bake the gun track** (builder): for each sequence, per frame (10-15 fps is enough, lerped), the `j_gun` transform
   relative to R_Hand, L_Hand and Spine4, plus two GRIP WEIGHTS: right hand on the gun / left hand on the gun
   (hand within ~3 u of where it sits on the gun in the clip's hold pose, smoothed). Written to Lua data like
   clips.lua. Locomotion clips (gun rigid in the hand) store one constant, so the data stays small.
2. **Drive the gun from whichever hand holds it** (runtime, client): gun = R_Hand * G_R(t) while the right hand grips,
   L_Hand * G_L(t) when only the left does (mag swaps), Spine4 * G_S(t) when neither (sling / bolt-cycling moments),
   blended by the weights. This follows MW's gun motion exactly, but stays glued to OUR hands where a hand holds it
   (our retargeted arms differ a bit from MW's, so a pure body-relative gun would float off the grip).
3. **MW Base: keep its bonemerge, replace its offset.** The world model already rides on the player's right hand, so
   each frame we set its `tag_sling` manipulation to inv(R_Hand) * gun(t) * CAL instead of MW Base's fixed HL2 offset
   (write `wep.WorldModelOffsets.Pos/Angles` before its RenderOverride runs). CAL = the one constant between MW's
   `j_gun` and the w_ model's `tag_sling`, which should be the same for every MW gun (all rips share the convention):
   found once with an in-game calibration tool (`mpm_guncal`), then per-gun overrides only if a model is off.
4. **Hands follow the gun (IK).** When the gun is driven by one hand, the other hand IKs onto the gun where the clip
   says it should be: MW Base guns -> `tag_ik_loc_le` / `tag_ik_loc_ri`; other weapons -> the baked hand-on-gun offset
   from the clip. Two-bone IK on the arm (upper arm / forearm, elbow toward the clip's elbow direction).
5. **Mags** (Phase 6, per-gun reloads): from the reload's notetracks (mag out / mag in) the mag (`j_mag1` /
   `tag_mag_show/hide`) is handed to the left hand for the swap and back, like TIF's tif_mag bone + reload mag motion.
6. **Other weapon bases** (ARC9 / TFA / HL2): their world models are welded to the right hand with no separate gun bone.
   Default: gun stays in the right hand, left hand IKs to it, and the reload / inspect clips chosen for them are ones
   where the right hand stays on the gun. Optional later: draw a client-side copy of their world model so the same
   gun track works for them too (hide the real one).
7. Server needs none of this (hitboxes are the body; bullets come from the eyes), so it's client-only and can be
   skipped for distant players (LOD).

## MW Base findings (read 2026-11-24)

- `SWEP.HoldType` is a category, not an HL2 holdtype: Rifle(32), TinyGun(7), Pistol(6), BoltAction(5),
  BigGun(2), RifleWithVerticalGrip(2), Shotgun(1), Revolver(1); Bipod when `BipodDeployed`. Mapping table lives in
  `modules/shared/sh_holdtypes.lua` (it maps those to HL2 holdtypes; we read the category instead).
- Weapon state is networked flags: `Sprinting, Reloading, Holstering, Drawing, Inspecting, Meleeing, Lowered,
  Customizing, Aiming, BipodDeployed, OnLadder, TacStance` (`wep:HasFlag(name)`), plus `GetAimDelta()`.
- 3P anims today: `SWEP:PlayerGesture(slot, act)` -> `AnimRestartGesture` + net `mgbase_tpanim`. We wrap that to
  play the real MW clip instead of the HL2 gesture.
- Deploy/holster timings come from `SWEP.Animations[...]` (Length, Fps): `wep:GetAnimLength("Draw")` etc. Use
  them to warp the 3P raise/lower so it ends with the viewmodel.
- Class names are MW codenames (`mg_mike4`, `mg_akilo47`, `mg_romeo870`, `mg_mcharlie`, ...). Many have
  PER-WEAPON 3P clips in the rips (reloads, inspects, raises): mike4 231 clips / 46 reloads, mpapa5 115/44,
  mcharlie 100/34, slima 103/34, mkilo3 56/34, victor 66/34, falpha 65/30, augolf 86/34, alpha50 90/26 ...
  So "true holds" can go further than class: true per-gun reloads where the rip has them, class clip otherwise.
- TRUE HOLDS ARE PER WEAPON (user's intent, 2026-11-24). MW builds a gun's hold as: class base pose (ar/sm/sh/sn/
  lm/pi/la) + a PER-WEAPON additive offset `*_addoff_<cls>_<gun>_{ads,nonads}` (stand, crouch, crouch_moving,
  prone, swim; `_left/_right/_neutral` ADS cants, `_noleft` one-handed, `_gl/_ubgl/_ubsh` underbarrels) + per-gun
  fingers `mp_fingers_<cls>_<gun>`. Plus per-gun reloads (incl. prone/ADS `custom_reload`), fire, butt-hit melee,
  inspects, ADS transitions, raise/lower. 36 of 56 MW Base guns have addoffs under their own name; missing ones
  (anovember94, charlie9, falpha, galima, kilo98, mkilo3, romeo700, secho, sierra552, smgolf45, uzulu, victor + the
  real-name pistols) need an alias check first, then the nearest same-class gun as stand-in. Underbarrel flag
  (`UsingUnderbarrel`) picks the `_gl/_ubsh` offsets.
- Pistols use real names (`mg_glock`, `mg_m1911`, `mg_deagle`, `mg_m9`, `mg_p320`, `mg_makarov`, `mg_357`):
  need an alias table to rip codenames (golf21, mike1911, decho, papa320 ...). 0 matches until aliased.

## Clip inventory (player side)

Directions use the numpad: 8 fwd, 2 back, 4 left, 6 right, 7/9/1/3 diagonals.

| Use | Families | Notes |
|---|---|---|
| Locomotion | `sdr_/iw9_mp_strafe_{walk,jog,run,crouch_walk,crouch_jog,crouch_fast,prone_fast,inplace}_N` | legs; per class variants `_sm/_sh/_sn/_lm/_pi/_la/_me` |
| Start / stop | `*_start_N`, `*_stop_l_N` / `*_stop_r_N` | stop picked by which foot is planted |
| Leans / inertia | `*_lean{fwd,bwd,left,right}_N`, `_accel` | accel/decel/turn blends |
| Sprint / tac sprint | `*_strafe_sprint_<cls>`, `iw9_mp_strafe_supersprint_<cls>` (273) | + lean and incline variants, sprint start |
| Slide | `sdr_mp_strafe_slide_*` (~100) | per class, slide jump takeoff, slide -> crouch trans |
| Dive | `iw9_mp_strafe_dive_2_prone_{in,loop,out}` | also `_la`, `2h`, akimbo, sword |
| Prone | `sdr/iw9_mp_prone_trans_*` (~120), `prone_strafe_fast/inplace(+_start)`, prone turns, `prone_rightside` | |
| Mantle | `*_mantle_*` (~700) | heights 24..64, close/far, on/over, weapon up/down |
| Jump | `*_jump_takeoff/air/land` per gait and class | |
| Weapon upper body | `mp_stand_gun`, `crouch_gun`, `prone_gun`, `stand_ads`, `sdr_mp_aims_*`, `addoff_*` | additive aim sets |
| Draw / holster | `sdr_mp_raise_*` (515), `sdr_mp_lower_*` incl. `lower_2_back`, `lower_2_thigh` | carried-weapon positions |
| Reload / inspect / melee | per weapon codename (see above), `inspect` (904), `melee` (686) | |
| Fingers | `mp_fingers_<cls>_*` | hand grip per gun class |
| Contextual (player list) | plates `*_prepare_eq_vest_plate_*`, stims, offhand throws (381, every stance + swim), `ges_pickup`, briefcase bomb plant/defuse, watch interact, ladder aim + deaths, laststand/self-revive/revive (177), swim (923), emotes `ges_` (635), parachute/skydive | |
| Not in player list | doors | MP has none. AI set `sdr_com_inter_*` (door kick/shoulder/tac) is the same rig: OPTION for later, only if wanted |

## Phases

1. **Movement core** (this build, v0.1.0): state machine + physics, no anims. Inertia, tac sprint, slide,
   dive, prone. Debug HUD. Offline harness.
2. **Anim build pipeline**: player-mode builder (manifest -> retargeted SMDs -> anim MDLs with legs/upper
   `$weightlist`s, root-motion and foot-plant tags as Lua data).
3. **Anim graph v1**: idle/walk/run/crouch/sprint for ar class on stock ValveBiped models; test across
   very different playermodels.
4. **Starts/stops/pivots/leans + MW turn adjustments**, distance matching, stride sync. Turn adjustments (user
   asked to keep them in, 2026-11-24): body no longer snaps to the eyes; feet stay planted until the view yaw
   passes a threshold, then MW's turn clips play: `sdr_mp_stand_turn_l/r`, `sdr_mp_crouch_turn_l/r`, the
   `*_turn_*_constant_loop`s while turning continuously, `sdr_mp_prone_turn_90_l/r` (+ per-class / melee prone turns);
   while moving, direction changes across the side axis use MW's hip flips `sdr_mp_strafe_{walk,inplace,crouch_fast}
   _hipflip_{forward,backward}_N` instead of blending straight through. Upper body keeps aiming at the eyes during
   the turn (aim layer, Phase 5).
   **Stance transitions** (user asked, 2026-11-24): no more snapping between stand / crouch / prone poses.
   - Standing still: `sdr_mp_stance_{stand,crouch,prone}_2_{stand,crouch,prone}_trans` (all 6 pairs exist;
     `_ads_` versions for crouch<->prone, `_akimbo`, `_juggernaut` variants). Durations: stand->crouch 0.70 s,
     crouch->stand 0.60, stand->prone 0.53, crouch->prone 0.53, prone->stand 0.73, prone->crouch 0.70.
     The movement core's `mpm_prone_in_time` / `prone_out_stand` / `prone_out_crouch` (0.50 / 0.60 / 0.40 now) get
     set from these so the hull change and the clip finish together; the engine's own duck speed for stand<->crouch
     is matched to 0.60-0.70 s too (or the crouch transition is played upper-body only if that feels too slow).
   - Moving: `sdr_mp_strafe_crouch_fast_N_to_prone_fast_N_trans` / `prone_fast_N_to_crouch_fast_N_trans` per
     direction, `prone_fast_8_to_run_8_trans`, `prone_fast_8_to_sprint_8_trans`, `crouch_fast_8_to_sprint_8_trans`,
     `strafe_slide_2_strafe_crouch(_N)_trans` (slide exit), `swim_strafe_N_to_crouch_fast_N_trans`.
   - Weapon-up prone: `sdr/iw9_mp_prone_trans_2_{ads,nonads}_<class>_<gun>` per gun (Phase 6 per-gun table).
   - Played as one-shots on top of the locomotion with a short crossfade; foot plants from the clip end hand off to
     the next gait at the matching phase.
5. **Weapon layer**: class holds, aim matrix, gestures, raise/lower + carried weapons, left-hand IK.
6. **MW Base adapter**: true holds + per-gun reloads/inspects, timing sync; ARC9/TFA best-average.
7. **Movement anims**: tac sprint, slide, dive, prone, MANTLE (see "Mantling" below), jump takeoff / land.
8. **Ground layer**: foot IK, foot lock, prone slope.
9. **Contextual**: plates, stims, offhand throws, laststand/revive, swim, emotes, ladders.

## Phase 1 design (movement core)

- State lives in player DT vars (predicted with the player), slots at the top of the range (Int 30-31,
  Float 26-31, Vector 31) to stay clear of gamemodes that allocate from 0. If a gamemode clashes, the slots are
  one table in `sh_config.lua`.
- `StartCommand`: record raw buttons (for edge detection), then rewrite the command for the current state
  (forced crouch during slide/prone, no sprint key during slide so weapons come up, no jump while prone ...).
  Rewriting the command (not just `mv`) means every weapon base sees the same buttons.
- `SetupMove`: transitions + velocity. Engine friction is compensated analytically so slides/decel follow our
  curves; forward/side input is zeroed while sliding/diving so the engine adds nothing.
- Speeds multiply whatever the gamemode set (walk/run), so DarkRP/TTT speed rules still apply.
- Prone = engine duck with a lower duck hull + view offset; restored on exit. Getting up checks space first.
- Hooks for later layers: `MPM_StateChanged(ply, old, new)`; `MPM.GetState(ply)`, `MPM.StateTime(ply)`.

### Controls (defaults)

| Action | Input |
|---|---|
| Sprint | hold sprint (vanilla) |
| Tac sprint | double-tap sprint while moving forward; meter drains, recharges |
| Slide | tap crouch while sprinting fast enough |
| Dive | hold crouch while sprinting (MWII style); lands in prone with a belly slide |
| Prone | double-tap crouch while (nearly) still, or `+alt1`/`+alt2` if `mpm_prone_button` is set. Hold-to-prone exists (`mpm_prone_hold`) but is off: GMod crouch is hold-to-crouch |
| Leave prone | jump = stand, crouch = crouch, sprint forward = stand |
| After a slide | stays crouched until jump / sprint / crouch |
| Slide cancel | press crouch again mid-slide (after 0.1 s): stand straight up, keep the speed, back into tac sprint if the slide came from it. Every slide refills the tac meter, so slide-cancel chains never run dry (Rebirth style). `mpm_slide_cancel*` convars |

## Change log

- 2026-11-24 v0.1.0 Phase 1 movement core written (untested in game). Files: `lua/autorun/mpm_load.lua`,
  `lua/mpm/sh_config.lua` (convars, DT slots), `sh_state.lua` (state, prone hull), `sh_input.lua`
  (StartCommand), `sh_move.lua` (SetupMove), `cl_debug.lua` (`mpm_debug 1`).
  Offline harness `MPMDIDDY/harness` (`python run.py <addon dir>`, needs lupa): 25/25. Simulated numbers:
  walk start 0.29 s (vanilla 0.18), run start 0.36 s, stop from run 0.38 s (vanilla 0.29), tac sprint 488 u/s
  for 3.5 s, slide 448 u/s entry / 0.95 s / 252 units flat (408 on a 25% downhill), dive -> prone 0.52 s +
  94 unit belly slide, crawl 45 u/s.

- 2026-11-24 v0.1.1 slide cancel (flags FROM_TAC, EAT_DUCK; sprint now checks crouch INTENT, not the engine's
  duck state, so the un-duck after a cancel doesn't drop tac sprint). Harness 31/31: 8 cancels in 8.2 s cover
  3865 units vs 3580 plain tac sprint. User tested Phase 1 movement in game: "feels good".
- Slide cancel anim (Phase 7): no dedicated clip in the rips; cut `strafe_slide` into `slide_2_strafe_crouch_trans`
  played fast and blend into `sprint_start` / `supersprint`.

- 2026-11-24 v0.2.0 Phase 2 anim build pipeline (untested in game).
  - Builder: `K:\mods map pics\smh_cod_anim_baker\tools\mpm_build.py` (imports tif_mw_build for the conversion;
    TIF's builder untouched). Manifest: `K:\jimmyproject\mpm\manifest.py`. Build dir `K:\jimmyproject\mpm\build`.
    `python mpm_build.py K:/jimmyproject/mpm/manifest.py --compile`
  - Output: `models/mpm/mpm_anims.mdl` (13 sequences: ar walk/jog/run/crouch walk/crouch jog/crouch fast/crawl as
    8-way blends on pose params `mpm_mx` (fwd +) / `mpm_my` (left +) with a held stance pose in the centre;
    sprint + tac sprint as 3-way forward blends on `mpm_my`; stand/crouch/prone idles), and
    `lua/mpm/data/clips.lua` (per direction: speed, travel dir, duration, foot plants).
  - HOW PLAYERMODELS GET THEM: every stock ValveBiped playermodel `$includemodel`s `models/m_anm.mdl` (464 seqs) or
    `f_anm.mdl`. The addon ships byte copies of those two from garrysmod_dir.vpk with ONE include record appended
    (`models/mpm/mpm_anims.mdl`, header numincludemodels/includemodelindex/length updated, nothing else moved).
    Source builds virtual models recursively, so playermodels -> m_anm -> mpm_anims. Same files on the server, so
    hitboxes follow. Conflicts with any other addon that replaces m_anm.mdl (only one can win).
  - Measured (ValveBiped, in place): walk 69-103 u/s, jog 130-199, run 130-187, crouch walk 46-62, crouch jog 79-126,
    crouch fast 78-106, crawl 23-34, sprint 267, tac 298. GMod's own speeds are higher (walk 200, run 400), so the
    graph will speed clips up (stride sync) or pick the next gait.
  - Check tools (`lua/mpm/sh_animtest.lua`): `mpm_check` (client + server sequence counts on your model, Kleiner,
    female_02, combine), `mpm_preview <clip> [numpad dir]`, `mpm_preview_all [dir]`, `mpm_preview_stop`.

- 2026-11-24 user confirmed Phase 2 in game: `mpm_check` 12/12 on client AND server for their custom model
  (drem/cch/male_08), Kleiner, female_02, combine; `mpm_preview_all` "look good". The m_anm include route works.
- 2026-11-24 v0.3.0 Phase 3 anim graph v1 (untested in game): `lua/mpm/sh_anim.lua`, shared.
  - `CalcMainActivity` returns the MPM sequence, `UpdateAnimation` sets `mpm_mx`/`mpm_my` (smoothed) and the playback
    rate = ground speed / the clip set's speed in that direction (interpolated between numpad dirs), max 2x.
  - Gaits: idle < 8 u/s, walk, jog >= 135, run >= 260 (sideways/back sprint key), sprint / tac sprint from the movement
    state; crouch: idle, walk, jog >= 95; prone: idle, crawl; slide = crouch idle, dive = prone idle (real ones in
    Phase 7). 15% hysteresis at each edge. GMod walk 200 lands on the MW jog at 1.00x.
  - Only rifle-type weapons: MW Base categories Rifle / RifleWithVerticalGrip / BoltAction / BigGun / TinyGun /
    Shotgun / Bipod; other bases by HL2 holdtype (`mpm_anim_holdtypes`, default `ar2 smg shotgun crossbow rpg`).
    Everything else (no weapon, pistols, melee, air, water, ladders, vehicles) is HL2 as before.
  - Body faces the eyes (render angles) until turn-in-place exists; no aim pitch yet (gun doesn't follow looking
    up/down: Phase 5 aim circle); left hand not on the foregrip (Phase 5 IK); HL2 fire/reload gestures still layer on top.
  - Convars: `mpm_anims`, `mpm_anim_holdtypes`, `mpm_anim_dirblend`, `mpm_anim_maxrate`.
  - Harness 41/41 (31 movement + 10 graph: `harness/anim_tests.lua`).

- 2026-11-24 v0.3.1 after the user's first Phase 3 clip (Medal, 35 s): rifle locomotion read as MW (aimed strafes,
  crouch walk OK). Problems: every AIRBORNE rifle frame (graph handed air to HL2) showed the torso folded 90 deg at
  the waist, legs straight, gun pointing down - not our clips (stick-figure render of the built poses is fine).
  Fix: rifle air now uses MW `sdr_mp_strafe_jog_jump_air_N` (`air_ar`) / `fast_jump_air_N` (`fair_ar`, >= 300 u/s)
  8-way blends. Prone clips were centred on the feet (body ~50 u in front of the hull): now centred on the
  pelvis-head midpoint (`{"center": "mid"}` in the manifest). The gun-raised-high pose on equip = MW Base's own
  "Draw" gesture (HL2 knife swing) layered on top; goes when the weapon layer replaces gestures (Phase 5).
  OPEN: is HL2's own jump folded like that on stock GMod too (check `mpm_anims 0` + jump), or did the m_anm patch do it?

- 2026-11-24 v0.3.2 after user report ("starts of walking sped up, idles have really slow walking, shooting sends my
  character in a direction, HL2 anims kinda messed up"):
  - Idle: `strafe_in_place_*` was MW's stepping-in-place clip (foot notes every few frames). Idles now
    `sdr_mp_stand_idle01` / `sdr_mp_crouch_idle` / `sdr_mp_prone_idle_1`, and they give the blend centre poses.
  - Sped-up starts: blend centres were 2-frame poses; the engine weights each blend member's cycle rate, so near the
    centre the whole blend ran ~30x fast. Centres are now as long as the blend's median stride.
  - Direction clips held 1-3 strides each (crouch walk fwd 3, back-right 1): blended by cycle the feet fought.
    Builder now cuts every direction to ONE stride starting on the left plant (`one_stride`), then fixes outliers
    against the blend median (`fix_strides`: halve ~2-stride ones, rebuild too-short ones, else drop and let the
    neighbour stand in: crawl back-right uses crawl back).
  - Shooting: HL2's `range_*` gestures are full-body DELTAS (pelvis/thighs weight 1) and `reload_*` add a pelvis delta
    layer (read straight from m_anm.mdl seqdescs/weightlists). Graph now clears GESTURE_SLOT_ATTACK_AND_RELOAD and
    GESTURE_SLOT_CUSTOM (MW Base fire/reload/melee/draw) while it drives the player. No fire/reload body anim until
    the weapon layer (Phase 5).
  - HL2 handoff: the graph now runs GAMEMODE:CalcMainActivity underneath (discarding its result) so the gamemode's
    jump/land flags aren't stale when HL2 takes over.
  - OPEN: user's "HL2 anims kinda messed up" not yet pinned down; A/B = move the two patched m_anm/f_anm out.
- 2026-11-24 user decompiled m_anm / f_anm with Crowbar 0.74 into `K:\anim\DECOMP` (QC + 3925 SMDs; originals
  `K:\anim\*.mdl/.ani`). Reading it: HL2's `jump_ar2` = jump pose + `addlayer "aimlayer_shotgun"` (9-way DELTA on
  aim_yaw / aim_pitch, pitch -53..+48) + `gmod_jump_delta`. So in the air HL2 bends the torso toward the eye pitch;
  the user films via a camera entity, so the folded-forward / gun-down frames are most likely HL2 aiming where the
  (downward-looking) eyes point, not breakage. Our MW clips have no aim layer yet, so on the ground the torso ignores
  pitch - the contrast reads as "HL2 messed up". Decompile is kept as reference (HL2 aim layers could be borrowed as
  an interim aim layer; also the fallback route if the binary m_anm patch ever misbehaves: recompile with the
  include in the QC). Keep the byte patch for now: it keeps HL2's anim data exact.

- 2026-11-24 v0.3.3:
  - MW SPEEDS (user: "make sure mpm matches mw's speeds"): `mpm_mwspeeds 1` (default). The speed cap each tick is
    the built clip's measured speed for the input direction: normal move = MW jog (199 fwd, 171/163 diagonal,
    130/134 sideways, 145 back), slow walk (+walk) = MW walk (103 fwd), sprint 267, tac 298, crawl 23-34; crouch =
    engine crouch multiplier on the jog speed (~60, MW crouch walk 61). Sprint key while strafing = jog speed (MW
    has no sideways sprint). Slide thresholds / tac / inertia ramps use the MW sprint speed as "run". `0` = the
    gamemode's walk/run as before (DarkRP etc.). Harness 45/45 (4 new speed tests; older tests run with it off).
  - `mpm_debug` now shows what's playing: MPM gait or HL2, sequence name, cycle, rate, blend mx/my, weapon set,
    whether `mpm_air_ar` exists on your model (a REBUILT mpm_anims.mdl needs a GAME RESTART - the engine caches
    models; until then new sequences are missing and the graph falls back to HL2) and aim_pitch.
  - User screenshot: rifle out, airborne, looking UP -> folded forward, gun down. Built jump-air clips render
    upright (stick figures), so this was HL2 fallback (likely old cached model). Re-check after a game restart
    with `mpm_debug 1`.

- 2026-11-24 user: looking UP with the rifle ON THE GROUND (not jumping) folds the body forward and lifts it, gun
  pointing down. Jump = "Mario-esque" (jog_jump_air held as a single pose, no takeoff / land yet). HL2 pistols
  "super broken" (parked until the pistol category). Ruled out: our clips (rendered upright), stale model, the
  playermodel's extra includes (m_gst/m_pst/m_shd/m_ss don't exist on disk, skipped by the engine), other addons
  bending player spines (none). Pitch-driven -> must be an engine layer / pose param. `mpm_debug` now lists every
  pose parameter (index:name=value) and every active anim layer (sequence, weight, cycle) for a screenshot.

- 2026-11-24 v0.3.4: debug screenshot while folded: main seq `mpm_idle_ar` (single clip), NO overlay layers, pose
  params normal (eye pitch -51, head_pitch 0.07, aim_pitch 0.20 normalised). Built idle renders upright on every
  frame. Decompile: m_anm has hidden AUTOPLAY delta sequences played on top of every main sequence -
  `body_rot` (aim_yaw; pelvis 30 deg + thighs), `head_rot_z` (head_yaw), `head_rot_y` (head_pitch; head 22 deg) - plus
  HL2 aim layers on aim_pitch. Fix candidate: `mpm_anim_neutralpose 1` pins aim_yaw / aim_pitch / head_yaw /
  head_pitch at 0 while MPM drives (in UpdateAnimation and again in PrePlayerDraw). Toggle 0/1 to confirm it's the
  cause. Lua-only change (no game restart). Head/upper-body look comes back with the MW aim layer (Phase 5).

- 2026-11-24 user signed off Phase 3 in game: ar locomotion, hold, crouch and both runs "perfect, no looking issues"
  (neutral-pose fix worked). Plain until stops / turning / look direction.
- 2026-11-24 v0.4.0 Phase 4a (untested in game). ORDER CHANGE: turn-in-place + hip flips moved after the Phase 5 aim
  layer (feet planted while the view turns needs the upper body aiming at the view, or the gun points off).
  - Builder: `ONESHOT` sets (one sequence per numpad dir, `mpm_<name>_<n>`) with a cumulative distance curve
    (`dist`, per 2 frames, `total`); centring modes `feet>mid` / `mid>feet` (prone stance clips slide from
    feet-centred to body-centred) and `feet>feet` (stops: MW keeps 10-18 u of in-pose travel in stops; eased out so a
    stop starts on the loop and ends on the idle).
  - New clips: walk / jog starts + left/right-foot stops (8 dirs), crouch walk + crouch fast starts / stops (8 dirs),
    sprint start / stop (7 8 9), the 6 `sdr_mp_stance_*_2_*_trans`, stand idles 01-04.
  - `lua/mpm/sh_anim_trans.lua`: starts are DISTANCE-MATCHED (cycle follows ground covered) and chosen by intent
    (normal = jog start, +walk = walk start, crouched = crouch walk / crouch fast); a finished start hands the loop
    the same foot phase (`HandoffCycle`); stops on key release, distance-matched to v^2/2a then timed, left/right by
    the loop's next planting foot, direction from velocity (sprint stops only within 30 deg of forward); sprint start
    on entering sprint / tac while moving forward-ish; stand<->crouch transitions while still (`mpm_anim_stancerate`
    1.4); prone in / out play the stance clips scaled to the movement core's timings, which now match the clips
    (prone_in 0.53 s, out to stand 0.73, out to crouch 0.70); idles rotate 01-04 every loop. Input for other players
    comes from the raw buttons the movement core already networks. `mpm_anim_transitions 0` = Phase 3 behaviour.
  - Harness 57/57 (+12 transition tests: helpers + start/stop/stance/prone flows on a mock player).

- 2026-11-24 user: Phase 4a "looks awesome, super convincing ... smash success, good to move on". Notes fixed in
  v0.4.1 (Lua only): (1) one-frame glitch when shooting = MW Base restarting HL2's fire gesture, visible for a frame
  before the per-frame slot clear -> Player:AnimRestartGesture is wrapped and refuses the muted slots while MPM
  drives that player; (2) changing direction during a start glided (start clips are one fixed direction) -> a start
  drops into the direction-blended loop when the input turns > `mpm_anim_startturn` (50) deg off it. Harness 58/58.

- 2026-11-24 v0.5.0 Phase 5 start: MW AIM LAYER (untested in game, anim model rebuilt -> restart GMod).
  - Decoded MW's aim circles: `sdr_mp_aims_ar_circle_90` (361 fr, 21 upper-body bones, type 2) are ADDITIVE offsets
    (compose base * offset in the bone's own space) around a 90 deg ring; frame = direction angle: 0 up, 90 right,
    180 down, 270 left (measured on the right->left hand line; the MP j_gun axis is NOT the barrel). MW22 also has
    `iw9_mp_aims_{stand,crouch,prone}_<cls>(_ads/_torso)` (not decoded yet).
  - Builder `AIMS` / `AIM_ON`: each circle -> 5x5 grid (yaw/pitch -90..90; offset weight r/90, angle atan2(-yaw,-pitch))
    composed on the stance's idle, compiled as a hidden DELTA blend `mpm_aim_ar` / `mpm_aimc_ar` (studiomdl subtract of
    the centre) on new pose params `mpm_ay` (+left) / `mpm_ap` (+down), and `addlayer`ed onto every aimed sequence
    (idles, walk/jog/run, air, starts/stops, crouch set, stance changes) - 95 sequences. Engine applies it on server
    and clients (hitboxes follow). Grid check: yaw 45->45, 90->92, -45->-42; pitch +-45 -> +-37..39; +-90 caps at
    -62 up / +70 down (MW's own reach).
  - Graph: `A.AimParams` sets mpm_ap = view pitch, mpm_ay = view yaw - body yaw (0 until turn-in-place).
    `mpm_anim_aim 0` = off. Not on sprint / tac / slide / prone yet (prone circle + ADS circles next).
  - Next: turn-in-place + hip flips (body yaw separate from the view, aim yaw covers the difference), then ADS aim
    (`_ads` circles + MW Base AimDelta), prone aim, per-gun addoffs.

- 2026-11-24 user: aim pitch works ("looking up and down works"); side to side "still slides the whole body".
- 2026-11-24 v0.5.1 TURN-IN-PLACE (untested in game, anim model rebuilt -> restart GMod).
  - MW turn clips keep their rotation in the ROOT (stand/crouch exactly 90 deg over 0.60 / 0.70 s, prone 90 over
    1.07-1.20 s); the built SMDs turn in place. Builder exports one-shot root yaw as `yawc` (per 2 frames); new
    singles `turnl/turnr_ar` (sdr_mp_stand_turn_{l,r}_90), `cturnl/cturnr_ar` (crouch), `pturnl/pturnr_ar` (prone,
    body-centred), stand/crouch ones carry the aim layer.
  - Graph: body yaw is its own value (`MPM_BodyYaw`, rendered via SetRenderAngles). Standing / crouched / prone
    still: the feet stay planted, the aim layer twists the upper body (mpm_ay = view - body); past
    `mpm_anim_turn_stand` 60 / `_crouch` 60 / `_prone` 25 deg the matching turn clip plays, its 90 deg scaled to the
    actual offset (cap 180, rate `mpm_anim_turnrate` 1.2 x offset/90 within 0.8-2) and the body follows the clip's yaw
    curve to land on the view. Moving: body follows the view (720 deg/s, prone 180). Server hitboxes stay on the view
    yaw (no render angles server-side; legs up to the threshold off - acceptable).
  - Harness 63/63 (+5 turn tests). Not yet: constant-turn loops for fast continuous spins (chained 90s for now),
    hip flips while moving.

- 2026-11-24 user: turning "works perfect". Odd idle with toe flicker = `sdr_mp_stand_idle04` (MWII-dump copy) ->
  dropped from the rotation (idles 01-03).
- 2026-11-24 v0.6.0 WEAPON ACTIONS + ADS (untested in game, anim model rebuilt -> restart GMod).
  - Builder `GUNS`: scans MW Base `lua/weapons/mg_*`, finds per-gun rip clips (`GUN_ACTS`: MWII
    `iw9_mp_<cls>_<gun>_{reload,reload_empty,inspect,raise_first}_<stance>` first, then MW19
    `mp/sdr_mp_<stance>_custom_reload(_empty)_<cls>_<gun>`, `sdr_mp_inspect_<stance>_...`, `sdr_mp_raise(_first)_...`),
    class token = the one with the most matches (crossbow / MK14 also hit a few "sn" names). Each -> upper-body sequence
    `mpm_g_<gun>_<act>_<stance>` (weightlist `mpm_upper`: pelvis/legs 0, Spine1 .3, Spine2 .7, Spine4 up 1) with the
    aim layers. Gun clips are cached in the build dir (delete `build/clips/g_<gun>_*` or set REBUILD_GUNS to redo).
    Coverage: 48 MW Base guns; stand + prone nearly complete, crouch only for the MWII-ripped ones (15-18 guns,
    others reuse the standing clip on crouched legs). Aliases: 357 cpapa, deagle decho, glock golf21, m1911 mike1911,
    m9 mike9, makarov (Sykov) mike, p320 papa320 (pistol actions only play once the pistol category exists);
    gamma3 (G3A3, community gun MW19 never had) borrows the FAL's (falpha).
  - Runtime `lua/mpm/sh_anim_guns.lua`: on the rising edge of MW Base's Reloading / Drawing / Inspecting flag the gun's
    clip for the stance (empty reload if the mag is empty; crouch -> stand fallback; prone never borrows stand) plays
    on GESTURE_SLOT_GRENADE, time-fitted to MW Base's NextPrimaryFire (= now + its action length), 0.12 s fade in /
    out, fades out early if the action is cut. Layer cycle driven via SetLayerCycle (pcall). `mpm_anim_actions 0` off.
    Holster (lower), fire kick, melee, per-gun holds (addoffs) + the gun track still to do.
  - ADS (user asked): MW's `sdr_mp_aims_ar_circle_90_ads` / `crouch_90_ads` composed on the idle + the M4's ADS hold
    offset (`sdr_mp_addoff_ar_mike4_ads`: gun ~2 u up, closer to the face - MW's 3P ADS is subtle; the nonads offset is
    identity on the idle), as delta grids `mpm_aimads_ar` / `mpm_aimcads_ar` against the HIP centre. Every aimed
    sequence now carries hip + ADS as two `blendlayer`s on new pose param `mpm_ads` (hip full at 0, ADS full at 1),
    driven by MW Base's networked `AimDelta` (other bases 0 for now). Per-gun ADS holds come with per-gun addoffs.

- 2026-11-24 user after v0.6.0 ("anims work decently"): equip starts in a lowered (passive-looking) pose that the fade
  from our ready pose scrambled; reloads have mag movement / dual mags worth using; use the guns' idles (= per-gun holds);
  a FIRST draw played on every draw. Plus: guns look slightly off until they're on the gun track; attachment-driven anims
  (grip poses, drum-mag reloads); MW19 anims should win (MW Base ships MW19's guns).
- v0.6.1 (untested): GUN_ACTS reordered MW19 first, MWII fills gaps (all gun clips rebuilt). New actions: `relx/empx`
  (extended mag, MWII only), `relxl/empxl` (large mag / drum: MW19 `mp_<st>_custom_reload(_empty)_<c>_<g>_drum`, MWII
  `reload(_empty)_xmaglrg`, `reload(_empty)_drums`), `draw` (MW19 `sdr_mp_raise_back_r<sx>_<c>_<g>`, MWII quickdraw),
  `hol` (MW19 `sdr_mp_lower_2_back_r<sx>...`, MWII quickdraw lower). Runtime: reload variant from MW Base's networked
  `NextReloadSeq` (Empty / Xmag / XmagLrg / Drum); first raise only while MW Base's `PlayFirstDraw` flag is set, else
  the normal draw; Holstering plays the holster; draws start at full weight (no fade from the ready pose).
- STILL TO DO from these notes: per-gun holds = MW `addoff_<c>_<g>_{nonads,ads}` (+ crouch / prone / `_noleft`,
  `_gl`/`_ubsh` underbarrel variants) replacing the generic M4 offset - "the guns' idles"; per-gun / per-grip finger
  poses (`mp_fingers_<c>_<g>(_<grip>)`); gun track + mag hand-off (MW Base `j_mag1` / `tag_mag_show|hide` to the left
  hand between the reload's mag notes, second mag for "dual mag" reloads); shotgun loop reloads (MW Base sets
  NextPrimaryFire = now for Reload_Loop: start / loop / end clips needed).

- 2026-11-24 user: "passive" in GMod is an ARMED, gun-down calm state (not unarmed) - map it to MW's lowered / patrol
  carry sets when the GMod holdtypes get assigned. Normal draws / holsters exist for ~10 guns only: a gun without its
  own borrows a same-class one (sorted, deterministic) before ever falling back to the first raise.
- 2026-11-24 v0.7.0 PISTOL SET (user: "furnish the default pistol hold"; untested in game). MW reuses the same legs
  for every gun and swaps the upper body additively: `sdr_mp_addoff_pi_golf21_nonads` composed on the rifle idle is a
  two-handed pistol grip (hands 12.6 -> 3.2 u apart). Builder: aim grids `aim_pi` / `aimc_pi` / `aimads_pi` /
  `aimcads_pi` (MW19 pistol circles on idle x X16 hold, deltas vs the RIFLE centre so the layer carries the grip);
  `CLASS_SETS` clones every rifle sequence set as `_pi` with the pistol layers - clips are now named `$animation`s
  shared by both sets, so the model barely grows; pistol sprints are MW19's own (`sdr_mp_strafe_sprint_pistol`,
  `supersprint_pistol`). Graph: MW Base Pistol / Revolver categories and HL2 `pistol revolver`
  (`mpm_anim_holdtypes_pi`) use the `pi` set; their per-gun reloads / draws (aliases) now play. Prone pistol still uses
  the rifle prone pose (no prone aim layer yet).

- QUEUED (user, 2026-11-24, after their current test): factor in the DRAW FROM A SLING. In the MP rips that's the chest
  carry: `sdr_mp_raise_chest(_crouch|_prone|_crouch_moving)_<cls>_<gun>` / `sdr_mp_lower_2_chest(...)_<cls>_<gun>`
  (+ `_quick`), next to the back carry already used (`raise_back_r` / `lower_2_back_r`, also `back_l`). Decide with the
  user which carry each gun / class uses (chest sling for rifles / SMGs, back for long guns?) and tie it to the
  carried-weapons display. Only literal "sling" clips are campaign one-offs (`htf_boss_040_get_gun_sling_pull`) -
  confirm which one the user means. -> USER CONFIRMED (2026-11-24): the CHEST CARRY is the sling draw.

- 2026-11-24 v0.8.0 REST OF PHASE 5 + PHASE 6 (user: "do the rest of 5 and all of 6"; untested in game):
  - Per-gun HOLDS (= "the guns' idles"): `mpm_h_<gun>_<stance>` = idle x the gun's MW `addoff_<c>_<g>_{nonads,ads}`
    (+ crouch / prone versions, MW19 first) with the gun's finger poses (`mp_fingers_<c>_<g>_{l,r}`, absolute) baked in,
    as a delta against the class's generic hold (rifles M4, pistols X16, prone M4 for all) - hip / ADS blended on
    mpm_ads, looping on GESTURE_SLOT_ATTACK_AND_RELOAD (HL2 gestures there stay refused; reload gestures sit above on the
    grenade slot); off in sprint / tac / slide / dive. Pistols get a real prone hold this way.
  - New actions: chest-sling draw / holster `drawc` / `holc` (rifles + SMGs prefer it, `A.ChestCarry`; others the back
    carry), rifle-butt / pistol-whip `melee` (MW Base Meleeing), bolt / pump `rech` (MW Base Rechamber TASK - it sets no
    flag, read from the running task's name). MW19's rechamber clips are 60 fps exports: builder halves their key times.
  - GUN TRACK: per action, MW's j_gun local pose under the right hand per 2 frames (`gun`, x y z p y r) + each gun's
    resting gun pose per stance (`gunhold_<st>` / `gunads_<st>`). `cl_gun.lua` replaces MW Base's fixed tag_sling
    offset each frame (`wep.WorldModelOffsets`, applied by MW Base's own RenderOverride) with the hold pose, blended to
    MW's per-frame gun motion while an action plays. tag_sling binds at identity under the hand, so no per-gun offset is
    needed; `mpm_gun_cal_pos` / `mpm_gun_cal_ang` = one global calibration if MW's j_gun and tag_sling differ.
  - LEFT-HAND IK onto the world model's `tag_ik_loc_le` (two-bone, BuildBonePositions, elbow keeps its bend plane,
    `mpm_gun_ik`, LOD `mpm_gun_ik_dist` 1500). Weight from the clip's own notetracks: off between
    `ik_out_start_left_hand` and `ik_in_*_left_hand` in reloads, on through bolt / pump cycles.
  - MAGS / DUAL MAG: MW19 reloads carry `..._magout_npc` / `..._magin_npc` notes (`notes` in the gun table; MWII clips
    borrow the same gun's MW19 ones). 37 MW Base world models have `j_mag1` + `j_mag2`: the new mag (j_mag2) rides the
    left hand until mag in, the old one (j_mag1) disappears at mag out; one-mag guns move j_mag1 with the left hand
    between mag out and mag in (`mpm_gun_mags`).
  - Build: per-gun data written one function per gun in clips.lua (LuaJIT 65536 constants / function); one bad gun clip
    is skipped instead of sinking the table; 32-bit studiomdl ran OUT OF MEMORY on one model -> gun actions + holds split
    into `mpm_guns1.mdl` / `mpm_guns2.mdl` (each with its own copy of the aim layers), `$includemodel`ed by
    mpm_anims.mdl (one include level deeper: player -> m_anm -> mpm_anims -> mpm_guns).
  - NOT YET: per-grip finger variants (`_l_grip`, `_l_gripang`, `_l_gl`, `_l_ubshtgn` from MW Base attachments), world-
    model bolt / charging-handle bones, shotgun shell-by-shell (Reload_Loop) start / loop / end, fire kick, fists set,
    GMod holdtype mapping (passive = armed gun-down, knife, grenade...), prone aim. Lever actions: none in the MW Base set.

- 2026-11-24 v0.8.1: user screenshots of v0.8.0 - every gun misplaced (pistol on the floor, rifles hanging off the
  side): MW's MP clips' j_gun is NOT a usable gun pose. It sits ~24 u from the hand that holds it, and its motion is
  wrong too (X16 reload: barrel turns 104 deg against the gripping hand; M4 reload 17 u / 35 deg). Same problem TIF
  solved for AI clips by fitting j_gun's rest from ~110 clips (cod_anim_prep WEAPON bones); the MP rig needs its own fit.
  Gun placement is back to MW Base's own per-gun offset (`mpm_gun_track` now 0 = off; 1 = experimental frame-relative
  motion). Left-hand IK (to tag_ik_loc_le on MW Base's placement), mag hand-off, holds / fingers / gestures unaffected.
  TODO: decode the MP j_gun (fit rest / parent so the right hand holds the gun rigidly in MP idles + locomotion,
  MWII's j_gun_adjust), then re-enable the gun track.

- 2026-11-24 v0.8.2 MP GUN BONE DECODED (untested in game). The MP rig's gun is a CHAIN: j_clavicle_ri ->
  j_gun_adjust (rotation keys) -> j_gun (position keys + rotation). Fitted rests (rest_adjust 5.77 0.11 -0.09,
  rest_gun -20.84 -5.27 -9.46) hold the gun rigid in the right hand over 449 frames of MP idles / walks / jogs / crouch
  (max 0.08 u, 4 deg; AI-rig reading was ~24 u / 100 deg off). `cod_anim_prep.MP_GUN` (opt-in; set by mpm_build only,
  TIF's AI clips keep WEAPON_BONES). Validated: idle 0.2 deg / 0.0 u, jog 3.9 / 0.1, M4 reload 4 deg / 0.7 u in the
  gripping hand (gun track on again, `mpm_gun_track 1`, MW19 clips only - MWII rigs the gun differently: its M4 reload
  moved 18 u with no rotation, not decoded yet).
  - User: bolt / pump cycles threw the arms straight up -> MW's rechamber clips are ADDITIVE (absolute: right hand at
    89 u; composed on the idle: 49 u). `rech` is now composed on the stance idle and compiled as a delta gesture of its
    own first frame (layers over hold + aim).
  - User: draws twisted the upper body ~90 deg and still played first draws sped up -> normal draws follow each class's
    carry (pistols thigh `raise_thigh` / `lower_2_thigh`, shotguns `raise_2_back`, long guns back, rifles / SMGs chest),
    never fall back to the first-raise flourish, and draws aren't squeezed below 1/1.2 of their natural length (they
    play to the end even after MW Base's flag drops).
  - User: index fingertip "flies" on draws -> the per-gun hold is ADDITIVE (fingers incl.) and stacked on the draw's own
    full pose: the hold layer now fades out by the action's weight (kept during additive bolt / pump cycles).
- 2026-11-24 v0.9.0 LEFT HAND + WEAPON LEFTOVERS (A) (untested in game).
  - User: left hand flung out / up on every gun -> the IK target was rebuilt from MW Base's offset angles (engine
    bone-manipulation angle convention != LocalToWorld: ~90 deg round the gun). Now the drawn world model's REAL
    `tag_ik_loc_le` relative to its own R_Hand bone, re-attached to the player's hand this frame. `mpm_gun_ik_debug 1`
    draws the target (green) and the left hand (red).
  - Shell-by-shell reloads: MW Base Reload_Start -> Reload_Loop per round (each time NextPrimaryFire moves on, piece =
    NextReloadSeq) -> ReloadEnd task (read by task name). GUN_ACTS rels / rell / rele / relee (MW19 870, R9, Kar98k
    stand + prone; MWII mbravo, mike1014, sbeta ...); guns without them borrow a same-class gun's. Pieces chain at full
    weight (no fade dip per shell), a dangling piece holds its last frame and fades.
  - Grip finger variants: MW Base's `SetGripPoseParameter` (grips AND barrels / handguards that carry a grip - user:
    default grips / handguards can change the hand pose) is wrapped on mg_base to remember it on the weapon (all realms,
    every player). grip_*vert* -> vert, *vertpro* / *vert_pro* -> vertpro (falls back to vert), *ang* -> ang, m203 / gl ->
    gl; barrel / stock / mag offsets -> default (the IK follows the tag along the gun). Built as whole hold variants
    `mpm_h_<gun>_<st>_<var>` (holds are 1 frame), gun's own MW finger clip, else the M4's. Gun models now split in 3.
  - Kits (non-gun HL2 holdtypes, `mpm_anim_kits` holdtype=kit): built like a gun on the rifle locomotion.
    fist -> fists (MW fists addoff + raise / lower + melee hits 01-03), knife / melee -> knife, grenade / slam -> frag
    (user: the PREPPED FRAG pose = `sdr_mp_*_prepare_eq_offhand` frame 60, throw on attack - MW holds it in the LEFT
    hand, GMod's frag model sits in the right: mirror / move later if it reads wrong), rpg -> RPG-7 hold + reload,
    passive -> MWII weapon-down (frame 0 of `iw9_mp_ar_mike4_reload_stand_down`; prone keeps the rifle hold).
    Actions fire from DoAnimationEvent (attack / reload) and on switching to the weapon. rpg left mpm_anim_holdtypes.
- 2026-11-24 v0.9.1 MWII GUN RIG DECODED (untested in game). Same chain + composition as MW19 (clavicle ->
  j_gun_adjust rot -> j_gun loc + rot, gun = P * (rest_a + Ra * (rest_g + loc)), rot Rp*Ra*Rg) and nearly the same
  adjust rest (5.16 0.04 0.39 vs 5.77 0.11 -0.09); the GUN rest is ~18 u elsewhere (-2.86 1.01 1.61) - the 18 u drift
  seen before. Fitted over 34 MWII rifle / LMG reloads (17 guns, stand + crouch) + the stand idle pose: rotation in the
  hand 0-4 deg (helima / ngsierra / kilo21 tilt the gun on purpose), origin 0.2-2 u. Pinning MWII's gun origin to
  MW19's fails (6-16 u): MWII weapons are rooted elsewhere, fine since the runtime only uses motion from frame 0.
  `cod_anim_prep.MP_GUN_RIGS["iw9"]`, picked when the clip is read from an iw9_ file (mpm_build wraps read_seanim to
  tag anim["rig"]). M4 MWII reload now moves the gun 0.8 u in the hand (was 18). GunDelta no longer skips iw9_ clips.
  Holds / rechambers composed on an MW19 idle keep the MW19 fit (their base clip's rig).
- 2026-11-24 v0.9.2 GUN MOTION ACTUALLY ON + MW MAG MOTION + MW19 FIRST (untested in game).
  - User: guns still felt parented to the right hand (LMG reloads, bolts). Cause: the builder's gun-clip cache counted
    SMD frames with `startswith("time ")` but the lines are indented -> 0 frames -> every cached gun action had
    dur 0.001 -> the runtime sampled the gun track at frame 0 forever (no gun motion since the cache existed). Fixed
    (lstrip), and the cache now also invalidates when cod_anim_prep / tif_mw_build change or the source clip differs
    (`<smd>.src`). Harness test: no gun action shorter than 0.1 s.
  - User: mags don't move. Only 4 reloads had mag notetracks (most MW19 clips use numbered foley notes). Now MW's OWN
    mag motion: j_mag1 / j_mag2 tracks baked per action (`entry.mags`, x y z p y r vis per 2 frames, offsets from the
    seat; vis 0 = parked > 12 u away and still = pouch / dropped) and played as bone manipulations on the world model
    (MW Base's 3P mag attachment is bonemerged onto those bones). The old left-hand hand-off stays as the fallback.
  - User: MW19 first, MWII patches holes. MW19 shipped NO crouch reloads / inspects (the game plays stand over crouched
    legs), so 21 guns were taking MWII crouch clips over their MW19 stand ones. A MWII crouch clip is now skipped when
    the gun has a MW19 stand clip for that action (runtime crouch -> stand fallback).
  - Starts: a start dropped because the input turned > mpm_anim_startturn (50 deg) off its direction now hands the loop
    its foot phase too (was: loop resumed on its own clock -> stride pop).
  - User: right index "goes nuts", left index rotates and back on draws. MW lays the gun's finger pose
    (mp_fingers_<gun>_r/_l) over EVERY clip and only blends it out / in at the clip's fingers_out_* / fingers_in_*
    notetracks, per hand; outside those windows the clip's raw finger keys are never shown (a normal draw ends with
    the index 36-83 deg off the grip). Now baked into every gun action at build time (finger_overlay, per hand; clips
    without finger notes stay as authored). Gun-clip cache carries a version (GUN_CLIP_VER 2) so it reconverts.
  - User: pistol hands loose when walking. MW Base's pistol world models have NO tag_ik_loc_le, so the left-hand IK
    never ran on pistols and the left hand rode the shared rifle walk bob on its own. The builder now bakes where each
    hold puts the left hand in the right hand's frame (lh_<st> / lhads_<st>, pistols ~3 u: the cupped grip) and the IK
    pins it there when the world model has no grip tag (hip <-> ADS by mpm_ads).
- 2026-11-24 v0.9.3 GUN PARTS + GRIP HAND + PLACEMENT FRAME FIX (untested in game). User: dual mags + pistol hands OK.
  - Gun parts: the mag tracks are now general `entry.parts[bone]` (p = offset from the seat, parent space; a = MW's
    ABSOLUTE local angle, played as rest^-1 * a against the world model's own rest read at runtime; v = mag visible).
    Every j_ bone MW animates that exists on an MW Base weapon / attachment model: 725 break (j_barrel, also on the
    first draw), LMG lids / covers / upper receivers, belt rounds j_b_*, bolts, charging handles. `mpm_gun_parts 0/1`.
    Mags never move on draws / holsters / bolt cycles, and a mag > 30 u from its seat is hidden (some reloads park
    it hundreds of units away mid-move: the stretched line on a draw).
  - PLACEMENT FRAME BUG: MW Base places the gun by manipulating tag_sling (position in the PARENT bone's frame, angles
    in the bone's own - GMod's bone gizmo code). MW's motion translation was added unturned, so big motions (PKM
    reload) went along the wrong axes. GunLocal now turns it by tag_sling's rest (read off the model) * MW Base's angle.
  - Left hand: with a grip fitted (MW Base grip pose parameter) the IK targets the grip mount (tag_grip_attach on the
    gun or on the barrel / handguard attachment carrying it) + `mpm_gun_grip_vert` / `mpm_gun_grip_ang` (fwd left up)
    instead of the handguard tag. IK is off in tac sprint, fades out when the animated hand is > `mpm_gun_ik_reach` (8)
    + `mpm_gun_ik_fade` (8) u from the target, and eases (no pops).
  - Draw fingers: clips that only blend the finger pose IN start from the gun's finger pose and ease into the clip's
    own over 6 frames (no snap on the weapon switch). GUN_CLIP_VER 3.
  - Firing (user: add firing + other gun-specific features): MW19's per-gun shot kick (`mp_{st}_custom_fire_<c>_<g>`
    + `_ads`, ADDITIVE upper body like rechambers; stand + prone, crouch borrows stand, class donor when a gun has none)
    on GESTURE_SLOT_FLINCH so it stacks on everything, triggered by MW Base's per-shot PlayerGesture (predicted for the
    shooter, networked for others; caught in the AnimRestartGesture wrapper). Plus the gun's own per-shot part motion
    (`..._fire_<c>_<g>_weapon` / MWII `_fire_weapon`, 60 fps: M4 bolt, pistol slide + barrel tilt, PKM belt advance +
    flaps) as `entry.firew`, played by the parts hook when no action moves parts. `mpm_anim_fire 0/1`.
  - NOT DONE: gun from the clavicle chain while MW's right hand is off the gun (MW's own parenting; only if the PKM
    still looks wrong after the frame fix). R9: its default pump has no grip parameter in MW Base, so the hand stays
    on the handguard tag; its default MW finger pose is already a closed wrap.

- 2026-11-25 v0.10.0 GUN + HAND REWORK (untested in game). User: "stuff is still subtly fucked up" - guns ride MW Base's
  hand-tuned offset (M4 turned 0/95/-90, PKM 12 u forward), pistols upturned, guns away on draws, the 725 flying off on
  reload / draw, grips not posing (Origin 12 side grip, R9-0), right index finger pointing, fists showing the rifle idle.
  - PLACEMENT from MW's own model: MW Base's world models are MW's gun models with j_gun's axes. Checked on 50 guns: one
    translation per gun puts MW's right AND left wrists on the model's tag_ik_loc_ri / tag_ik_loc_le within 1-2 u. Gun =
    right hand * J * T(gt): J = MW's j_gun under the hand (hold gunhold_/gunads_, actions entry.gun - absolute now, not a
    delta from the clip's first frame), gt = per-gun calibration (`entry.gt`; pistols / guns without the right-hand tag:
    estimated from tag_brass, `entry.gtest`). Set as MW Base's WorldModelOffsets inside its RenderOverride from THIS
    frame's bones (wrapped per weapon). Guns without a calibration keep the old placement.
  - LET GO: where the clip's gun moves off MW's grip (> `mpm_gun_letgo` "2.5 3": start / ramp, u; or > 15 deg) the gun
    hangs where MW's chain has it off the right CLAVICLE (`entry.gunc`, baked from the raw clip): LMG lids, charging
    handles, the 725 reload, draws from the back / sling.
  - LEFT HAND: onto the model's tag_ik_loc_le (moving parts too: the R9's pump) or a fitted grip's mount with MW's grip
    hand rotation - vertical (TIF 0.19.5's fit), side grips (new GripVariant "side": Origin 12 / Model 680; overhand),
    angled keeps the clip's rotation. `mpm_gun_grip_vert` / `_ang` / `_side` (fwd left up in the mount's frame).
  - FINGERS: MW's per-gun finger poses as absolute local rotations (`entry.fr`, `fl`, `fl_<grip>`, from the hold
    SMDs), put on the right hand whenever the gun is in it (fixes the pointing index on draws / reloads) and on the left
    with the IK. `mpm_gun_fingers 0/1`.
  - MAGS (user): a mag shows only while seated (< 2.5 u) or within 8 u of one of MW's wrists - hidden once it's down at
    the pouches.
  - FISTS: MW's fists hold offsets (MW19 `_noright`, MWII full) are IDENTITY on the arms - the guard pose lives in the
    fists' own idles, so the rifle idle showed through. Fists are now held in MWII's fists idle pose
    (`iw9_mp_me_fists_<st>_idle_01` frame 0, like the frag kit) + MWII's fists fingers (kits can name "fingers").
  - Build cache: hold clips were cached on the idle's name alone (a changed hold source kept the old clip); now keyed
    on idle + offset / pose source, so every hold rebuilt once.
  - Calibration skips guns whose left grip tag disagrees across the gun (slima: turned frame) and rifles without a
    right-hand tag (L86 bullpup, augolf, mike14, gamma3, asierra12, dblmg): those keep the old placement.
  - New convars: `mpm_gun_fingers`, `mpm_gun_letgo`, `mpm_gun_grip_side`, `mpm_gun_cal_pistol`.

- 2026-11-25 v0.10.1 GUN FIXES after the v0.10.0 test (untested in game). User: finger still wild, some guns 90 deg off,
  draws / reloads with big offsets that settle on the idle, the Oden flying on reload, AK = magwell in MW19 3P.
  - DRAW / RELOAD JUMPS: found offline over 107 actions - MW's gun relative to the BODY is identical in the idle hold and
    at action ends (0.1 deg), relative to the HAND it's 13 deg / 3.3 u off (M4 24 deg): the hold clips bend the wrist
    against the gun (TIF's KR note). v0.10.0 decided "MW's hand let go" by comparing with that bent hold, so most
    reloads / draws hung off the shoulder start to finish. Now: let-go is baked per sample (`lg`) against MW's REAL grip
    (J from the gun's action end frames); the grip calibration (gt) also comes from those end frames.
  - Body-anchoring the gun everywhere was NOT done: MW's aim circles move the gun through its own chain (j_gun_adjust
    swings 135 deg), which players' models don't have - a clavicle-anchored gun wouldn't follow the aim. The gun stays
    hand-anchored (hand * MW's chain J), the RIGHT HAND is pulled onto MW's real grip (gun * J^-1, `mpm_gun_rik`).
  - FINGERS wild: the right-hand finger pose was off whenever "let go" was on (the bug above).
  - 90-DEG GUNS: tag_sling's rest is baked from the model (`srest`) instead of measured live.
  - Calibration: tagless non-bullpup rifles estimated from the ejection port (the Oden, 357...); outliers on MW19's rig
    rejected (old placement); MWII-clip guns get a separate hold calibration (`gth`) crossfaded with the action.
  - MW19 FIRST: the gun class pick counted MWII clips equally - the AUG (MW19 sm_ / MWII ar_) and M14 (sn_ / dm_) got
    MWII clips. MW19 matches now count 1000x.
  - AK: left hand where MW's own clips have it (magwell, `LEFT_FROM_CLIP`); Oden: built-in vertical grip
    (`INTEGRATED_GRIP`).
  - ADS: the gun moves (<= `mpm_gun_ads_max` 4 u) so an optic's reticle is in front of the eye; hybrids whose alternate
    sight is canted roll the gun by how far round that sight sits (inline magnifiers don't roll), by MW Base's
    aim-mode delta. Irons keep MW's pose. `mpm_gun_ads_align 0/1`.
  - `mpm_debug 1` shows the gun (calibration, action, let-go, right / left IK weights, grip) and the hold layer.
  - NOT DONE (need `mpm_debug 1` screenshots): HL2 no-weapon anims bent over; frag / fists showing a rifle hold;
    sliding when changing direction mid-start.

- 2026-11-25 v0.10.2 (Lua only, untested). User: "nothing's right" - guns turned ~90 deg / off the hands on most guns,
  bolt actions don't move the hands, a pistol kick cuts off.
  - CAUSE: v0.10.1 baked tag_sling's rest from the model's BIND pose, but MW Base's world models pose tag_sling through
    their own idle sequence (M4 / MG34 / 725 etc. turned 90 deg - which is why MW Base's per-gun offsets differ by 90
    deg between guns; where they don't, PKM / Glock, ours matched MW Base within 5-14 deg). Now measured right after
    every draw against the exact offset that draw used. (Offline, the calibration itself checked out: MW's wrist vs
    the model's right grip tag = 0.0 deg rotation, a constant shift.)
  - Bolt / pump cycles: the right-hand IK and finger pose are off while one plays (they held the hand on the grip).
  - Shot kick fades out over its last third instead of cutting when the gesture ends.
  - Shot kicks checked on every gun (muzzle rise at the kick's peak): MW's .357 clip throws the muzzle 42 deg DOWN and
    the RPG hip kick 24 deg down - dropped in the builder (< -10 deg). The M19 has no kick of its own and the runtime
    borrowed the alphabetically first pistol's (the .357): pistols without one now take the Glock's (`FIRE_DONOR`).

- 2026-11-25 dev tools: `addons/mpm_devtools` (local only, never ship). `mpm_photobooth [classes]` poses each gun in
  fixed states (hold / ADS / reload 30 + 70 % / draw 50 % / bolt 40 %) from fixed cameras and writes PNGs + a bone dump
  JSON per state to `garrysmod/data/mpm_booth/` (the dump includes the gun MPM wanted vs the gun the model shows:
  `placement_error_u`). `mpm_bones` dumps the current pose, `mpm_bones_draw 1` draws gun / hand axes. MPM gained a
  dev-only pin hook (`ply.MPM_Pin`: hold an action at a cycle, force the ADS amount).

- 2026-11-25 booth run 1 (v0.10.2), read with MPMDIDDY/render/mpm_render.py (third column GAME = the booth's bone dump,
  plus a per-bone GAME vs MPM table): ACTIONS match the maths in game within ~0.5 u / 2 deg on every gun but the MG34;
  the right hand sits on MW's real grip (0.0 deg) in every hold / ADS (the right-hand IK turns it ~20 deg off the
  hold clip's bent wrist). FOUND: the MG34's tag_sling hangs off ValveBiped.Anim_Attachment_RH (turned vs the hand) -
  placement now measures the bone's real parent (cl_gun wrapRender / applyPlacement). Booth fixes: camera on
  throughout (first-person frames never place the world model), "wanted" = the gun computed before the right-hand
  IK. Hold rows differ from renders by the idle variant playing (idle2/3 vs idle01; MW's MP idles hold the gun
  identically, 0.0 deg). Still open: fists hold, right index tip (dump now has every finger joint).

- 2026-11-25 v0.10.3 (Lua only, untested) from booth run 2 (MG34 placement now 0.0 u in every state):
  - THE HOLD WASN'T PLAYING: GMod's base gamemode resets GESTURE_SLOT_ATTACK_AND_RELOAD (MPM's hold slot) on
    PLAYERANIMEVENT_CANCEL_RELOAD (weapon switches, cancelled reloads) and MPM only re-added the hold when it CHANGED -
    so after a switch most guns showed the bare rifle idle (no per-gun hold / fingers) and the fists the rifle pose; a
    draw looked right and turned wrong as it faded out. Now: that event is swallowed while MPM drives the player, and
    the hold is re-added whenever it's missing from the layers (checked every 0.2 s).
  - RIGHT INDEX FINGERTIP: bone lengths / positions were exact in game; its BEND wasn't - the retarget can't aim a
    fingertip (no child bone), so the skeletons' resting curl turns into a bias: the right index tip bent backwards in
    54 % of all clip frames (median +10, up to +63 deg; other right tips 2-4 %). Runtime clamp: finger joints (not
    thumbs) never bend backwards (`mpm_finger_clamp`).
  - Draw ends: let-go eases out over a draw's last 15 % (Galil / P90 / Bizon / Glock ended "let go" and snapped from
    the shoulder to the hand). Draw ends vs holds otherwise match (median 0.6 deg, worst 5.8).
  - Booth: + draw95 (end of the draw, compare with hold); HL2 engine weapons (weapon_frag) accepted.

- 2026-11-25 booth run 3: the hold layer plays in every hold / ADS (fixed), placement error 0.0 on every gun incl. the
  MG34, fists now in their guard (but fingers half open). Model was Kleiner (no finger helper bones).
  - Fingers: applyFingers carries non-standard child bones + quaternion slerp (A.SlerpRot) instead of LerpAngle for
    finger poses and the IK hand turn. Kits (fists / knife) now get their absolute MW finger pose (solve() stopped for
    non-MW-Base weapons before the fingers).
  - PISTOLS (user: right hand sits to the right of the gun): they have no grip tags; v0.10.1-0.10.3 estimated the grip
    from the ejection port. Now MW's own attach offset: the median calibration of the 44 tag-calibrated MW19 guns
    ([11.2, 5.64, 9.4]; in MW the gun sits at a fixed offset from j_gun and the hand reaches for each gun's grip).

- 2026-11-25 v0.10.4 (data + Lua, untested):
  - LEFT HAND at draw ends vs idle (booth run 3, draw95 vs hold): the idle's left hand kept the HOLD clip's rotation,
    30-63 deg off MW's draw-end hand (AK 63, PKM 49, P320 35, M4 30) - "right, then wrong". `entry.jl` = MW's left
    hand on the gun from the action end frames; the left-hand IK turns the hand to it (handguard tag, AK magwell,
    angled grips; vertical / side grips keep their built hand). Pistols (no tag) take MW's position too.
  - Finger tracker (mpm_devtools): `mpm_track_finger` records the right fingers every frame through the next draw /
    reload (`mpm_track_finger 3` = next 3 s), as the animation gave them and after MPM; `MPMDIDDY/render/finger_track.py`
    plots and lists jumps / backward bends. MPM's bone callback calls `A.TraceHook(ply, "anim" | "final")`.

- 2026-11-25 spawn menu: Utilities -> Modern Player Motion (`lua/mpm/cl_menu.lua`): Movement, Animation, Guns & Hands,
  Debug pages (every MPM convar; per-page reset to defaults; movement / animation are server convars). mpm_devtools
  adds a "Dev tools" page (photo booth incl. "the gun in my hands" = `mpm_photobooth_current`, bone dump, axes,
  finger tracker).

- 2026-11-25 v0.10.5 (untested in game):
  - FINGER CAUSE FOUND (finger tracker, Glock draw): HL2's knife-swing gesture ("range_knife" = MW Base's third-person
    draw, GESTURE_SLOT_CUSTOM) played at full weight for half the draw, dragging the right index ~50 deg backwards and
    snapping off at its end. `A.SilenceForeign`: every frame (UpdateAnimation + right before the bones) any gesture
    layer that isn't MPM's is zeroed.
  - ATTACHMENTS drifting off the gun / lagging on turns + shots: the hand IK read the gun's / attachments' bones early in
    the frame (cached from last frame's placement) and MW Base re-sets the bones without clearing the cache. The render
    override now invalidates the gun's and every attachment model's bone cache before MW Base draws.
  - BOLT / PUMP cycles: the gun hangs off the LEFT hand by MW's left grip (`jl`) while the right hand works the bolt
    (it rode the bolt hand: "a major shake on the hand holding the gun"); the left IK steps aside.
  - PISTOLS: sideways from MW's attach offset, forward / height back on the ejection-port estimate (the full MW offset
    pushed the pistol forward of the hand).

- 2026-11-25 v0.11.0 MINIGUN SET (user: "do the minigun hold"; models rebuilt, untested): MW Base's mg_dblmg gets its own
  animation set "mg" (like the pistol set: the rifle legs cloned, 114 sequences) with MW's minigun aim circles
  (`sdr_mp_aims_dblmg_circle_90`, crouch, ADS) carrying its low hip hold (`sdr_mp_addoff_lm_dblmg_*`). Its per-gun hold is
  measured against that hold (`GUN_SETS` ref), so it isn't applied twice. Runtime: `MPM.Guns[g].set` picks the set.
  NOT DONE: Juggernaut variants.
  - v0.11.1: minigun SPRINT carry: `mpm_hs_dblmg` = MW's `sdr_mp_addoff_lm_dblmg_nonads_sprint` + the minigun's
    fingers on MPM's sprint pose, as a delta against the plain sprint pose; played in the hold slot while sprinting /
    tac sprinting (`GUN_SETS[g].sprint` -> `entry.hold_sprint`). Untested in game. Placement stays on the estimated grip (renders: right hand at the rear grip).

- 2026-11-25 v0.12.0 PHASE 7 + 8 + body-part flinches from 9 (user: "Phase 7, pretty much all of it" except prone on your
  side / back (supine, later), "all of phase 8", "from phase 9, ONLY body part flinches"). Models rebuilt, harness
  123/123, untested in game. Snapshot of the addon before this: `K:\mpm_work\snapshots\modern_player_motion_v0.11.1_pre_phase7`.
  New code has no comments (user rule 2026-11-25); the explanations live here.
  - MANTLE (new state 8, `lua/mpm/sh_mantle.lua`). Jump at a ledge (or hold jump in the air next to one, `mpm_mantle_air`).
    Detection: forward hull trace at step height finds a wall (reach `mpm_mantle_reach` + 8% of speed), a down hull trace
    one hull-width past the wall finds the top (height `mpm_mantle_min` 20 .. `mpm_mantle_max` 96; walkable), the hull
    must fit straight up and then across onto the top (standing, else crouched -> ends crouched, FL_DUCKING + STAY_CROUCH).
    Vault (`over`): moving forward, ledge <= 64 u, room past it and a drop of more than a step behind -> ends one hull past
    the top in the air and falls. DT: Int29 = clip index * 2 + over, Vector30 start, Vector29 end; duration from height
    and distance (`mpm_mantle_speed`), so both realms compute the same path. The `Move` hook moves the player along the
    path (rise first, then across; clips with their own root curve - step / climb / boost - follow it, scaled to the real
    height) and skips the engine move. Firing / reload / jump / crouch / sprint are stripped while mantling.
    Clips: 46 MW19 `mp_mantle_*` (ledge 24-64 up/over idle/run, step 16/32, climb 32/64, boost 64/190, far_*). MPM picks
    ledge clips by height (run variant when moving, step clips for low running climbs, boost above 64). Climb / far_*
    are built but not picked yet. MW's ledge clips are in place (MW's code lifts the player); the boost / climb / step ones
    carry the rise in their root, so `mt` (root path), `peak`, `reach` are in the data.
  - JUMPS / LANDINGS: takeoff one-shots on leaving the ground (still `sdr_mp_stand_jump_takeoff`, jog `iw9_mp_strafe_jog_
    jump_takeoff_N`, fast `sdr_mp_strafe_fast_jump_takeoff_N`), land one-shots after 0.25 s+ in the air (same families).
    HARD LANDING: `OnPlayerHitGround` faster than `mpm_hardland_speed` (560) stamps DT Float25; the movement core caps
    speed at `mpm_hardland_keep` (0.35) of the state's speed, easing back over `mpm_hardland_time` (0.7 s); the graph plays
    `sdr_mp_parachute_fast_hard_landing` (still) / `slow_hard_landing` (moving) stretched to that time.
  - SLIDE / DIVE anims: slide = `sdr_mp_strafe_slide_7/8/9` by travel direction, held on its last frame while the slide
    lasts, `sdr_mp_strafe_slide_2_crouch_trans` when it ends into a crouch (not on a cancel). Dive = `iw9_mp_strafe_dive_
    2_prone_in` held while airborne, `dive_2_prone_loop` as the belly-slide loop, `dive_2_prone_out` when it ends.
  - SLOPES (Phase 8): uphill sprint / tac sprint swap to MW's `iw9_mp_strafe_(super)sprint_ar_inclineup_N` above 11 deg
    (drops below 7). Downhill: MW's single-frame lean poses `sdr_mp_slope_down_jog_N_15 / _30` built as additive 3x3
    direction grids (`mpm_slope15_ar`, `mpm_slope30_ar`, lean minus the flat pose of the same direction), played in
    GESTURE_SLOT_SWIM weighted by the grade (15 deg layer up to 15, 30 deg above) and speed. `mpm_anim_slopes`.
  - FOOT IK / FOOT LOCK / PRONE TILT (Phase 8, `lua/mpm/cl_ground.lua`, client): in MPM's BuildBonePositions callback,
    before the hand IK. Per foot a down trace finds the real floor vs the player's origin floor; the pelvis drops to the
    lower foot (max 18 u), each leg is a two-bone solve to its floor (foot keeps its animated rotation). Full weight
    standing, fades out by 160 u/s, off in the air / slide / dive / mantle / takeoff. Foot lock: standing still in idle,
    each foot stays where it planted until it drifts 10 u. Prone: render angles pitch / roll to the ground under the body
    (front / back / sides probes, smoothed). Convars `mpm_footik`, `mpm_footlock`, `mpm_prone_tilt`, `mpm_footik_range`.
  - BODY-PART FLINCHES (Phase 9, `lua/mpm/sh_flinch.lua`): 55 MW `sdr_mp_pain_sub_<stance>_<part>[_dir]_NN` clips
    (`_noarm` wins: arms stay on the gun) built as additive one-shots over the stance idle, in the split gun models.
    Server `ScalePlayerDamage` -> net `mpm_flinch` (part from the hitgroup, direction from the attacker vs the body yaw,
    left / right / centre from where the hit landed) to the PVS; clients play it in GESTURE_SLOT_VCD. Picks fall back
    (torso side -> centre, legs -> crouch "legs", prone torso -> head). `mpm_flinch` (server), `mpm_flinch_scale` (client).
  - Spawn menu: mantle + hard landing on Movement, slopes + flinch toggles on Animation, feet / prone tilt / flinch
    strength on Guns & Hands.
  - Harness: box obstacles + swept hull traces + the Move hook in `env.lua`; `p789_tests.lua` (mantle onto / vault / too
    high / step / no room / crouched end / blocked keys, clip picks, path fractions for all 46 clips, hard landing, graph
    shots for takeoff / land / hard land / slide / slide exit / dive in / out / mantle, grade sign, flinch picks for every
    stance x part x direction).
  - NOT DONE (asked to leave): prone on your side / back (supine). Not in this pass: death anims, MWII weapon-down mantles,
    ledge hang (parked), far / climb mantle variants picked at runtime.

## Test checklist (in game)

1. `mpm_debug 1`. Walk/run/stop: does the ramp feel weighty but not laggy? Tune `mpm_accel_time`/`mpm_decel_time`.
2. Release and re-press sprint quickly while running -> TAC, faster, meter drains and refills.
3. Tap crouch while sprinting -> slide; you stay crouched after; sprint/jump stands. Jump mid-slide.
4. Hold crouch while sprinting -> dive, belly slide, prone.
5. Double-tap crouch while still -> prone; crawl; jump/crouch/sprint to get up; try under a low table.
6. Online (listen server + a 2nd client or `net_fakelag 100`): any jitter in slide/prone = prediction problem,
   report it first, it decides how the DT state is stored.
7. With an MW Base gun: weapon comes up mid-slide (sprint key stripped), lowered during tac sprint.

Phase 2 (anims, no graph yet: your own player still uses HL2 anims):

8. `mpm_check`: every line should say 12 / 12, client AND server. 0 = the m_anm include isn't being picked up
   (another addon replacing m_anm.mdl, or the engine not following nested includes) - report it, it decides
   the whole approach.
9. `mpm_preview_all` then `mpm_preview_all 4`, `2`, `9`: look for broken limbs, feet through the floor, guns
   off the hands, jitter at the loop point. Try a few different playermodels.
10. Normal HL2 anims on players still fine (patched m_anm keeps all 464 original sequences).

Phase 3 (graph v1, rifle weapons only; watch yourself in third person or a mirror / second client):

11. MW Base rifle out: idle, slow walk (alt), walk, sprint, tac sprint, strafe left/right/back and diagonals,
    sideways with sprint key (run). Legs should match the ground (no ice skating), direction changes blend.
12. Crouch idle / crouch walk / crouch with sprint key, slide (crouch pose), dive + prone idle + crawl.
13. Where does the gun sit in the hands (right hand OK? left hand floating = expected for now)?
14. Switch to a pistol / fists / physgun: back to HL2 anims, no pop or T-pose. Jump: HL2 jump, then back.
15. A second client watching you: same anims (server + other clients run the same graph).

Phase 4a (RESTART GMOD first: the anim model was rebuilt). `mpm_debug 1` shows `[start]` / `[stop]` / `[stance]`:

16. From standing: tap / hold W, +walk W, crouched W, crouched sprint W, and diagonals / back / sideways: a start
    clip, then the loop carries on without a hitch in the stride.
17. Let go of the keys while walking, jogging, crouch-walking, sprinting: stop clip, feet land, ends in the idle with
    no pop. Release mid-start: goes straight to a stop.
18. Crouch / uncrouch while standing still; go prone / get up (to stand and to crouch): transition clips, no snap.
19. Stand still ~10 s: the idle changes between loops.
20. Toggle `mpm_anim_transitions 0/1` to compare.

Phase 5 aim (RESTART GMOD):

21. Rifle out, look up / down standing, walking, crouched, crouch-walking: upper body and gun follow the view
    (MW's own aim poses). Not during sprint / tac / slide / prone yet.
22. `mpm_anim_aim 0/1` to compare. A second client sees the same.

Turn-in-place (RESTART GMOD):

23. Stand still and look left / right slowly: feet stay planted, upper body follows; past ~60 deg the feet step
    around (MW turn) and the body lands facing the view. Same crouched; prone at ~25 deg (slower turn).
24. Whip the view 180 quickly: one big turn. Start moving mid-turn: goes straight into the start / loop.

Weapon actions + ADS (RESTART GMOD):

25. MW Base rifle / SMG / shotgun / sniper / LMG: reload (partial and empty), inspect, draw - standing, crouched,
    prone, while walking. Third-person clip ends with the first-person one; legs keep moving underneath.
26. Sprint mid-reload (cancel): the gesture fades out. Switch guns: the new one plays its raise.
27. Aim down sights standing / crouched, look around while ADS: gun comes up to the face, aim still follows.

v0.8.0 (RESTART GMOD; `mpm_check` should still say found for everything):

28. Different MW Base guns side by side: each holds its own way (grip, fingers); pistols prone have a pistol pose.
29. Gun position in the hands vs before (`mpm_gun_track 0/1`): if every gun is off by the same amount, tune
    `mpm_gun_cal_pos "x y z"` / `mpm_gun_cal_ang "p y r"` live and tell me the numbers.
30. Left hand on the foregrip (`mpm_gun_ik 0/1`), letting go during the mag swap, staying on during bolt pulls.
31. Tac reload on an M4 / AK / FAL: new mag in the left hand, old one gone at mag out (`mpm_gun_mags 0/1`).
32. Kar98k / HDR / 870: bolt / pump cycle after each shot. Melee (rifle butt). Rifle / SMG draws from the chest sling.
33. Left hand on the handguard on several guns (`mpm_gun_ik_debug 1`: green dot on the grip, red hand on it).
34. 870 / Kar98k / model 1887: shell-by-shell - start, one push per shell, end (pump); fire mid-reload ends it.
35. M4 / AK with a vertical grip, then an angled grip, then a grip barrel: left fingers change to wrap the grip.
36. HL2 fists / crowbar / stunstick / frag / RPG / a passive-holdtype SWEP: MW fists, knife, prepped frag + throw,
    RPG-7 hold, gun-down calm carry; punches / swings / throws play MW hits.
37. MWII-only guns (e.g. a MWII-sourced reload, `mpm_gun_track 1`): the gun moves with the hands through the reload
    instead of staying put; compare `mpm_gun_track 0`.
38. LMG reload / bolt cycle: gun leaves the right hand where MW does; mags come out, go to the hand, the new one goes in
    (`mpm_gun_mags 0/1`). Crouched reload on an M4 = the MW19 stand reload.
39. Draw an M4 / any gun: fingers settle onto the grip at the end of the draw (no index flick when it hands back).
40. Pistol walk / jog: left hand stays cupped under the right (`mpm_gun_ik 0/1` to compare).
41. 725: barrels break open on the first draw and reloads. PKM / M91: lid opens, belt moves; PKM reload no longer bobs.
42. M4 with a vertical / angled grip: left hand on the grip (tune `mpm_gun_grip_vert` / `_ang`); tac sprint: hand free.
43. Fire M4 hip / ADS / prone: upper body kicks per shot (other players too); bolt cycles; pistol slide racks; PKM belt
    feeds. `mpm_anim_fire 0` to compare.
44. v0.10.0 (restart GMod): M4 / AK / PKM idle, walk, sprint, ADS: gun in the right hand on its grip, left hand on the
    handguard, nothing tilting between states. `mpm_gun_track 0` shows the old placement for comparison.
45. Pistols: no longer tilted up (grip is estimated: nudge with `mpm_gun_cal_pistol "fwd left up"` and tell me the value).
46. Draws (first draw too) and the 725 reload / draw: the gun comes from the body / sling and stays with the hands.
47. Grips: M4 vertical, angled, Origin 12 side grip, R9-0 pump: hand wrapped on the grip, fingers closed.
48. Right index finger on draws / reloads: on the gun (`mpm_gun_fingers 0/1`).
49. Tactical reloads: the new mag is hidden while it's at the pouches, appears in the hand. Fists: proper guard, no
    rifle arm.
50. v0.10.1 (restart): M4 / MG34 / PKM reload + draw: no jump between the action and the idle; MG34 reload holds
    the gun while the right hand works the cover. Right index finger stays on the gun.
51. Guns that were 90 deg off: straight now. Oden / AUG / M14: no flying on reload (AUG / M14 on MW19 clips now).
52. AK: left hand on the magwell. Oden: left hand on its built-in foregrip.
53. ADS with a tall optic: reticle in front of the eye; a canted hybrid rolls the gun when switched, an inline one
    doesn't. `mpm_gun_ads_align 0` to compare.
54. For the HL2 / frag / fists issues: `mpm_debug 1` screenshot while it happens.
55. v0.10.2: M4 / MCX / MG34 / 725 / Uzi / AK / sniper idle + ADS: gun the right way round in the right hand, left hand
    on it. Bolt action: right hand works the bolt. Pistol shots: kick eases out.
56. v0.12.0 (restart GMod): jump at a waist-high crate / wall (24-64 u): MW climb onto it; sprint at a thin wall / railing:
    vault over and land past it; taller walls up to 96 u: boost climb. Hold jump while falling past a ledge: grabs it.
    Low ceiling over the ledge: ends crouched. No shooting mid-mantle. Try online (`net_fakelag 100`) for jitter.
57. Jump from standing / jogging / sprinting: takeoff clip, air loop, land clip. Fall from a roof (> 560 u/s): hard
    landing clip and a short slowdown (`mpm_hardland_*`).
58. Slide: MW slide pose all the way, slide-to-crouch at the end (not on a slide cancel). Dive: dive in, belly slide loop,
    dive out to prone.
59. Sprint up a hill: MW incline sprint; jog / run down a hill: body leans back (`mpm_anim_slopes 0` to compare).
60. Stand on stairs / a slope / a kerb edge: feet on the steps, hips drop to the lower foot; walk away and it fades.
    Turn on the spot slowly: feet stay planted. Prone on a slope: body follows the ground (`mpm_footik`,
    `mpm_footlock`, `mpm_prone_tilt` to compare).
61. Get shot (or shoot a bot / friend) in the head / chest / legs from the front, back and sides, standing, crouched,
    prone: a matching flinch on top of whatever they're doing, gun stays in the hands (`mpm_flinch_scale`).
