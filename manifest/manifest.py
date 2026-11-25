# Modern Player Motion: which MW clip becomes each player sequence.
# Build: python "K:/mods map pics/smh_cod_anim_baker/tools/mpm_build.py" K:/jimmyproject/mpm/manifest.py --compile
# Numpad directions: 8 fwd, 2 back, 4 left, 6 right, 7/9 fwd-left/right, 1/3 back-left/right. "{}" = the number.
# Plan / phases: addons/MPMDIDDY/PLAN.md

SOURCE = "K:/duglastakedown"                                   # MW19 (wins on shared names)
EXTRA_SOURCES = ["K:/mw22 anims 2/xanims", "K:/mw22 anims"]    # MW22: clean dump first, export 1 last
FIX_FIRST_KEY = ["K:/mw22 anims"]                              # export 1's junk bind-pose key at frame 0
BUILD = "K:/jimmyproject/mpm/build"
ADDON = "K:/SteamLibrary/steamapps/common/GarrysMod/garrysmod/addons/modern_player_motion"

# Phase 2: rifle (ar) locomotion. Other classes reuse these until their own sets are added (Phase 5/6).
BLEND8 = {
    #  name          direction clips                      centre pose (frame 0, stretched to the stride length)
# Direction clips are cut to ONE stride starting on the left foot plant (phase-aligned blends).
    "walk_ar":   ("sdr_mp_strafe_walk_{}",            "sdr_mp_stand_idle01"),
    "jog_ar":    ("sdr_mp_strafe_jog_{}",             "sdr_mp_stand_idle01"),
    "run_ar":    ("iw9_mp_strafe_run_{}",             "sdr_mp_stand_idle01"),
    "cwalk_ar":  ("sdr_mp_strafe_crouch_walk_{}",     "sdr_mp_crouch_idle"),
    "cjog_ar":   ("sdr_mp_strafe_crouch_jog_{}",      "sdr_mp_crouch_idle"),
    "cfast_ar":  ("sdr_mp_strafe_crouch_fast_{}",     "sdr_mp_crouch_idle"),
    "crawl_ar":  ("sdr_mp_prone_strafe_fast_{}",      "sdr_mp_prone_idle_1", {"center": "mid"}),
    # airborne (held loops; takeoff / land one-shots come with the layering work)
    "air_ar":    ("sdr_mp_strafe_jog_jump_air_{}",    "sdr_mp_strafe_jog_jump_air_8", {"air": True}),
    "fair_ar":   ("sdr_mp_strafe_fast_jump_air_{}",   "sdr_mp_strafe_fast_jump_air_8", {"air": True}),
}

FWD3 = {
    "sprint_ar": "iw9_mp_strafe_sprint_ar_{}",
    "tac_ar":    "iw9_mp_strafe_supersprint_ar_{}",
}

SINGLE = {
    # real MW idles (strafe_in_place_* are stepping-in-place clips: "slow walking" when standing still);
    # the graph rotates idle_ar / idle2-4_ar so the same loop never plays twice in a row
    "idle_ar":   ("sdr_mp_stand_idle01", {"loop": True}),
    "idle2_ar":  ("sdr_mp_stand_idle02", {"loop": True}),
    "idle3_ar":  ("sdr_mp_stand_idle03", {"loop": True}),
    # idle04 dropped (user, 2026-11-24): MWII-dump copy, different posture + toe flicker
    # stance transitions (standing still). Prone ones slide from feet-centred to body-centred (recenter_slide)
    "s2c_ar":    ("sdr_mp_stance_stand_2_crouch_trans", {"loop": False}),
    "c2s_ar":    ("sdr_mp_stance_crouch_2_stand_trans", {"loop": False}),
    "s2p_ar":    ("sdr_mp_stance_stand_2_prone_trans", {"loop": False, "center": "feet>mid"}),
    "c2p_ar":    ("sdr_mp_stance_crouch_2_prone_trans", {"loop": False, "center": "feet>mid"}),
    "p2s_ar":    ("sdr_mp_stance_prone_2_stand_trans", {"loop": False, "center": "mid>feet"}),
    "p2c_ar":    ("sdr_mp_stance_prone_2_crouch_trans", {"loop": False, "center": "mid>feet"}),
    # turn-in-place (90 deg each; rotation is in the root, clips.lua "yawc" - the graph turns the body along it)
    "turnl_ar":  ("sdr_mp_stand_turn_l_90", {"loop": False}),
    "turnr_ar":  ("sdr_mp_stand_turn_r_90", {"loop": False}),
    "cturnl_ar": ("sdr_mp_crouch_turn_l_90", {"loop": False}),
    "cturnr_ar": ("sdr_mp_crouch_turn_r_90", {"loop": False}),
    "pturnl_ar": ("sdr_mp_prone_turn_90_l", {"loop": False, "center": "mid"}),
    "pturnr_ar": ("sdr_mp_prone_turn_90_r", {"loop": False, "center": "mid"}),
    "cidle_ar":  ("sdr_mp_crouch_idle", {"loop": True}),
    "pidle_ar":  ("sdr_mp_prone_idle_1", {"loop": True, "center": "mid"}),
}

# Starts / stops: one sequence per direction (mpm_<name>_<n>), driven by distance travelled (clips.lua "dist").
# stopl / stopr = which foot the stop lands on. Crouch sets have one stop per direction.
D8 = (8, 7, 4, 1, 2, 3, 6, 9)
D3 = (7, 8, 9)
ONESHOT = {
    "start_walk_ar":   ("sdr_mp_strafe_walk_start_{}", D8),
    "stopl_walk_ar":   ("sdr_mp_strafe_walk_stop_l_{}", D8, {"center": "feet>feet"}),
    "stopr_walk_ar":   ("sdr_mp_strafe_walk_stop_r_{}", D8, {"center": "feet>feet"}),
    "start_jog_ar":    ("sdr_mp_strafe_jog_start_{}", D8),
    "stopl_jog_ar":    ("sdr_mp_strafe_jog_stop_l_{}", D8, {"center": "feet>feet"}),
    "stopr_jog_ar":    ("sdr_mp_strafe_jog_stop_r_{}", D8, {"center": "feet>feet"}),
    "start_cwalk_ar":  ("sdr_mp_strafe_crouch_walk_start_{}", D8),
    "stop_cwalk_ar":   ("sdr_mp_strafe_crouch_walk_stop_{}", D8, {"center": "feet>feet"}),
    "start_cfast_ar":  ("sdr_mp_strafe_crouch_fast_start_{}", D8),
    "stop_cfast_ar":   ("sdr_mp_strafe_crouch_fast_stop_{}", D8, {"center": "feet>feet"}),
    "start_sprint_ar": ("sdr_mp_strafe_sprint_start_ar_{}", D3),
    "stop_sprint_ar":  ("sdr_mp_strafe_sprint_stop_l_{}", D3, {"center": "feet>feet"}),
}

# Aim layers (Phase 5): MW's additive aim circles as 5x5 delta blends on mpm_ay / mpm_ap, added (addlayer) to
# every aimed sequence so the upper body follows the view on server and clients. Sprint / tac / slide / prone: none yet.
AIMS = {
    "aim_ar":  ("sdr_mp_aims_ar_circle_90", "sdr_mp_stand_idle01"),
    "aimc_ar": ("sdr_mp_aims_ar_circle_crouch_90", "sdr_mp_crouch_idle"),
    # ADS (user, 2026-11-24): MW's ADS circles on the idle + the M4's ADS hold offset (generic until per-gun holds),
    # as deltas against the HIP centre so the raise to the eye is part of the layer
    "aimads_ar":  ("sdr_mp_aims_ar_circle_90_ads", "sdr_mp_stand_idle01",
                   {"hold": "sdr_mp_addoff_ar_mike4_ads", "ref": "aim_ar"}),
    "aimcads_ar": ("sdr_mp_aims_ar_circle_crouch_90_ads", "sdr_mp_crouch_idle",
                   {"hold": "sdr_mp_addoff_crouch_ar_mike4_ads", "ref": "aimc_ar"}),
}
# PISTOL (user, 2026-11-24): MW's pistol aim circles on the idle + the X16's (golf21) pistol hold offset - that offset
# alone turns MW's shared rifle idle into a two-handed pistol grip (hands 12.6 -> 3.2 u apart) - as deltas against the
# RIFLE centre, so the layer carries the hold change and the aim. Per-gun pistol holds come with per-gun addoffs.
AIMS.update({
    "aim_pi":     ("sdr_mp_aims_pi_circle_90", "sdr_mp_stand_idle01",
                   {"hold": "sdr_mp_addoff_pi_golf21_nonads", "ref": "aim_ar"}),
    "aimc_pi":    ("sdr_mp_aims_pi_circle_crouch_90", "sdr_mp_crouch_idle",
                   {"hold": "sdr_mp_addoff_crouch_pi_golf21_nonads", "ref": "aimc_ar"}),
    "aimads_pi":  ("sdr_mp_aims_pi_circle_90_ads", "sdr_mp_stand_idle01",
                   {"hold": "sdr_mp_addoff_pi_golf21_ads", "ref": "aim_ar"}),
    "aimcads_pi": ("sdr_mp_aims_pi_circle_crouch_90_ads", "sdr_mp_crouch_idle",
                   {"hold": "sdr_mp_addoff_crouch_pi_golf21_ads", "ref": "aimc_ar"}),
})
# MINIGUN (user, 2026-11-25 "do the minigun hold"): MW's minigun aim circles + its hold offset (carried low at the
# hip), as deltas against the RIFLE centre like the pistol set
AIMS.update({
    "aim_mg":     ("sdr_mp_aims_dblmg_circle_90", "sdr_mp_stand_idle01",
                   {"hold": "sdr_mp_addoff_lm_dblmg_nonads", "ref": "aim_ar"}),
    "aimc_mg":    ("sdr_mp_aims_dblmg_circle_crouch_90", "sdr_mp_crouch_idle",
                   {"hold": "sdr_mp_addoff_crouch_lm_dblmg_nonads", "ref": "aimc_ar"}),
    "aimads_mg":  ("sdr_mp_aims_dblmg_circle_90_ads", "sdr_mp_stand_idle01",
                   {"hold": "sdr_mp_addoff_lm_dblmg_ads", "ref": "aim_ar"}),
    "aimcads_mg": ("sdr_mp_aims_dblmg_circle_crouch_90_ads", "sdr_mp_crouch_idle",
                   {"hold": "sdr_mp_addoff_crouch_lm_dblmg_ads", "ref": "aimc_ar"}),
})
# hip layer -> its ADS partner: aimed sequences get both, crossfaded by mpm_ads (MW Base AimDelta)
ADS_OF = {"aim_ar": "aimads_ar", "aimc_ar": "aimcads_ar", "aim_pi": "aimads_pi", "aimc_pi": "aimcads_pi",
          "aim_mg": "aimads_mg", "aimc_mg": "aimcads_mg"}

# Weapon-class sets cloned from the rifle set (same clips, the class's own aim layers). Pistol sprints have own clips.
CLASS_SETS = {
    "pi": {"layers": {"mpm_aim_ar": "mpm_aim_pi", "mpm_aimc_ar": "mpm_aimc_pi"}, "include": ["*_ar"]},
    "mg": {"layers": {"mpm_aim_ar": "mpm_aim_mg", "mpm_aimc_ar": "mpm_aimc_mg"}, "include": ["*_ar"]},
}
FWD3.update({
    "sprint_pi": "sdr_mp_strafe_sprint_pistol_{}",
    "tac_pi":    "sdr_mp_strafe_supersprint_pistol_{}",
})
AIM_ON = {
    "aim_ar":  ["idle_ar", "idle?_ar", "walk_ar", "jog_ar", "run_ar", "air_ar", "fair_ar",
                "start_walk_ar", "start_jog_ar", "stop?_walk_ar", "stop?_jog_ar", "c2s_ar", "turn?_ar"],
    "aimc_ar": ["cidle_ar", "cwalk_ar", "cjog_ar", "cfast_ar", "start_cwalk_ar", "start_cfast_ar",
                "stop_cwalk_ar", "stop_cfast_ar", "s2c_ar", "cturn?_ar"],
}

# Per-gun weapon actions (MW Base: mg_<codename> = rip codename). Pistols need aliases (real names) - later.
# GMod holdtypes MW has a kit for (runtime: mpm_anim_kits maps holdtype -> kit). Built like a gun: rifle locomotion,
# the kit's MW hold as a delta, its own actions (raise / lower / melee / throw / reload).
KIT_MELEE = {"melee2": ["mp_{st}_melee_hit_02_{c}_{g}"], "melee3": ["mp_{st}_melee_hit_03_{c}_{g}"]}
KITS = {
    # MW19 only ships the fists hold WITHOUT the right arm (_noright: the rifle idle's right arm showed through);
    # MWII's fists idle pose + fingers (v0.10.0)
    "fists": {"rip": "fists", "cls": "me", "acts": KIT_MELEE,
              # (MW's fists addoffs are identity on the arms: the guard pose is in the fists' own idles)
              "pose": {"stand": (["iw9_mp_me_fists_stand_idle_01"], 0), "crouch": (["iw9_mp_me_fists_crouch_idle_01"], 0),
                       "prone": (["iw9_mp_me_fists_prone_idle_01"], 0)},
              "fingers": ["iw9_mp_me_fists_fingers_r", "iw9_mp_me_fists_fingers_l"]},
    "knife": {"rip": "knife", "cls": "me", "acts": KIT_MELEE},
    "rpg":   {"rip": "rpapa7", "cls": "la"},
    # user: grenades use the prepped frag pose (MW holds the cooked frag up after the pull, ~frame 10 on)
    "frag":  {"rip": "frag", "cls": "eq",
              "pose": {"stand": (["sdr_mp_me_stand_prepare_eq_offhand", "sdr_mp_stand_prepare_eq_offhand"], 60),
                       "crouch": (["sdr_mp_crouch_prepare_eq_offhand", "sdr_mp_crouch_prepare_eq_offhand_hb"], 60),
                       "prone": (["sdr_mp_prone_prepare_eq_offhand", "sdr_mp_prone_prepare_eq_offhand_hb"], 60)},
              "acts": {"throw": ["sdr_mp_me_{st}_throw_eq_offhand", "sdr_mp_{st}_throw_eq_offhand"]}},
    # passive = armed, gun down, calm: MWII's weapon-down stance (first frame of its stand_down reload)
    "passive": {"rip": "passive", "cls": "ar",
                "pose": {st: (["iw9_mp_ar_mike4_reload_stand_down"], 0) for st in ("stand", "crouch")}},  # prone: the rifle hold
}

# v0.10.1: guns whose third-person left hand MW puts somewhere MW Base's tag_ik_loc_le isn't (user: MW19's 3P AK holds
# the magwell) - the left hand goes where MW's own clips have it on the gun
LEFT_FROM_CLIP = ("akilo47",)
# guns with a grip built into the default handguard (the left hand takes that grip's pose without an attachment)
INTEGRATED_GRIP = {"asierra12": "vert"}

# guns with their own animation set (runtime: MPM.Guns[g].set) and the hold that set's aim layer already carries
# (their per-gun hold is measured against it, or the hold would be applied twice)
# ("sprint": MW's own sprint carry offset for that gun, played as a hold while sprinting)
GUN_SETS = {"dblmg": {"set": "mg", "ref": ("lm", "dblmg"), "sprint": "sdr_mp_addoff_lm_dblmg_nonads_sprint"}}

# shot kick for guns MW gave none (v0.10.2): borrow this gun's (the runtime's alphabetical donor picked the .357)
FIRE_DONOR = {"pi": "glock"}

GUNS = {
    "kits": {"kits": KITS},
    "mwb": {
        "glob": "K:/SteamLibrary/steamapps/common/GarrysMod/garrysmod/addons/modern_warfare_2019_sweps_*/lua/weapons/mg_*",
        "prefix": "mg_",
        "skip": ["base"],
        # MW Base real names -> rip codenames; mg_gamma3 (G3A3) is a community gun MW19 never had: borrows the FAL
        "alias": {"357": "cpapa", "deagle": "decho", "glock": "golf21", "m1911": "mike1911", "m9": "mike9",
                  "makarov": "mike", "p320": "papa320", "gamma3": "falpha"},
    },
}

# ---------------------------------------------------------------------------------------------------------------------
# PHASE 7 (2026-11-25): movement animations
# slide: one-shot per direction (time-driven over the slide), its exit into the crouch; dive into prone (MWII in / belly
# loop / out); jump takeoffs + landings (still / jog / fast per direction); hard landings
ONESHOT.update({
    "slide_ar":        ("sdr_mp_strafe_slide_{}", (7, 8, 9)),
    "takeoff_jog_ar":  ("iw9_mp_strafe_jog_jump_takeoff_{}", D8),
    "takeoff_fast_ar": ("sdr_mp_strafe_fast_jump_takeoff_{}", D8),
    "land_jog_ar":     ("iw9_mp_strafe_jog_jump_land_{}", D8),
    "land_fast_ar":    ("sdr_mp_strafe_fast_jump_land_{}", D8),
})
SINGLE.update({
    "slidex_ar":   ("sdr_mp_strafe_slide_2_crouch_trans", {"loop": False, "center": "feet>feet"}),
    "divein_ar":   ("iw9_mp_strafe_dive_2_prone_in", {"loop": False, "center": "feet>mid"}),
    "diveloop_ar": ("iw9_mp_strafe_dive_2_prone_loop", {"loop": True, "center": "mid"}),
    "diveout_ar":  ("iw9_mp_strafe_dive_2_prone_out", {"loop": False, "center": "mid"}),
    "takeoff_ar":  ("sdr_mp_stand_jump_takeoff", {"loop": False}),
    "land_ar":     ("sdr_mp_stand_jump_land", {"loop": False}),
    "hland_ar":    ("sdr_mp_parachute_fast_hard_landing", {"loop": False}),
    "hlandm_ar":   ("sdr_mp_parachute_slow_hard_landing", {"loop": False}),
})
# the upper body keeps aiming through jumps / landings / slides
AIM_ON["aim_ar"] += ["takeoff_ar", "takeoff_jog_ar", "takeoff_fast_ar", "land_ar", "land_jog_ar", "land_fast_ar",
                     "slide_ar"]

# mantles (MW19 mp_mantle_*): built with the root path (tag_origin) and where the feet start / end relative to the
# root, so the movement core moves the player along MW's own path scaled to the measured ledge
MANTLES = sorted(set(
    [f"mp_mantle_{h}_{k}_{m}" for h in (24, 32, 40, 48, 56, 64) for k in ("up", "over") for m in ("idle", "run")]
    + [f"mp_mantle_{p}step_{h}_{k}" for p in ("", "far_") for h in (16, 32) for k in ("up", "over")]
    + [f"mp_mantle_{p}climb_{h}_{k}" for p in ("", "far_") for h in (32, 64) for k in ("up", "over")]
    + [f"mp_mantle_{p}boost_{h}_{k}" for p in ("", "far_") for h in (64, 190) for k in ("up", "over")]))

# ---------------------------------------------------------------------------------------------------------------------
# PHASE 8: ground. Uphill sprint / tac sprint sets; downhill: MW's single-frame lean poses per direction (0 / 15 / 30
# deg) as an additive grid on the locomotion's direction params, weighted by the slope at runtime
FWD3.update({
    "sprintup_ar": "iw9_mp_strafe_sprint_ar_inclineup_{}",
    "tacup_ar":    "iw9_mp_strafe_supersprint_ar_inclineup_{}",
})
SLOPE_DOWN = {"slope15_ar": ("sdr_mp_slope_down_jog_{}", "sdr_mp_slope_down_jog_{}_15"),
              "slope30_ar": ("sdr_mp_slope_down_jog_{}", "sdr_mp_slope_down_jog_{}_30")}

# ---------------------------------------------------------------------------------------------------------------------
# PHASE 9 (only body-part flinches, user): MW's per-body-part hit reactions, additive over anything. _noarm versions
# (arms stay on the gun) win. stance -> the idle they're composed on
PAIN = {"stand": "sdr_mp_stand_idle01", "strafe_crouch": "sdr_mp_crouch_idle", "prone": "sdr_mp_prone_idle_1"}
