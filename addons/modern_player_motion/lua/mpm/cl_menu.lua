-- Spawn menu: Utilities -> Modern Player Motion (Movement / Animation / Guns & Hands / Debug).
-- Movement + animation settings are server convars (replicated): only the host / an admin can change them.

local function reset(names)
    for _, n in ipairs(names) do
        local c = GetConVar(n)
        if c then RunConsoleCommand(n, c:GetDefault()) end
    end
end

-- rows: { "check", label, cvar } / { "slider", label, cvar, min, max, decimals } / { "text", label, cvar } /
-- { "help", text } / { "header", text }
local function build(panel, rows)
    panel:ClearControls()
    local names = {}
    for _, r in ipairs(rows) do
        local kind = r[1]
        if kind == "check" then
            local cb = panel:CheckBox(r[2], r[3])
            if r[4] then cb:SetTooltip(r[4]) end
            names[#names + 1] = r[3]
        elseif kind == "slider" then
            local s = panel:NumSlider(r[2], r[3], r[4], r[5], r[6] or 2)
            if r[7] then s:SetTooltip(r[7]) end
            names[#names + 1] = r[3]
        elseif kind == "text" then
            panel:TextEntry(r[2], r[3])
            names[#names + 1] = r[3]
        elseif kind == "help" then
            panel:Help(r[2])
        elseif kind == "header" then
            local l = panel:Help(r[2])
            if IsValid(l) then l:SetFont("DermaDefaultBold") end
        end
    end
    local b = panel:Button("Reset this page to defaults")
    b.DoClick = function() reset(names) end
end

local MOVEMENT = {
    { "help", "Server settings: in multiplayer only the host / an admin can change these." },
    { "check", "Modern Player Motion on", "mpm_enabled" },
    { "check", "MW movement speeds (per direction)", "mpm_mwspeeds" },
    { "header", "Inertia" },
    { "check", "Acceleration / deceleration ramps", "mpm_inertia" },
    { "slider", "Accelerate time (s)", "mpm_accel_time", 0.01, 2, 2 },
    { "slider", "Decelerate time (s)", "mpm_decel_time", 0.01, 2, 2 },
    { "header", "Tactical sprint (double-tap sprint)" },
    { "check", "Tactical sprint", "mpm_tacsprint" },
    { "slider", "Speed (x run)", "mpm_tacsprint_mult", 1, 3, 2 },
    { "slider", "Duration (s)", "mpm_tacsprint_time", 0.1, 60, 1 },
    { "slider", "Recharge (s)", "mpm_tacsprint_recharge", 0.1, 60, 1 },
    { "slider", "Double-tap window (s)", "mpm_tacsprint_window", 0.05, 1, 2 },
    { "header", "Slide (crouch while sprinting)" },
    { "check", "Slide", "mpm_slide" },
    { "slider", "Min speed (x run)", "mpm_slide_minspeed", 0, 2, 2 },
    { "slider", "Entry boost", "mpm_slide_boost", 0.5, 3, 2 },
    { "slider", "Speed cap (x run)", "mpm_slide_maxspeed", 0.5, 5, 2 },
    { "slider", "Deceleration", "mpm_slide_decel", 0, 5000, 0 },
    { "slider", "Slope effect", "mpm_slide_slope", 0, 5, 2 },
    { "slider", "Steering (deg/s)", "mpm_slide_steer", 0, 720, 0 },
    { "slider", "Longest slide (s)", "mpm_slide_maxtime", 0.1, 10, 2 },
    { "slider", "Cooldown (s)", "mpm_slide_cooldown", 0, 10, 2 },
    { "header", "Slide cancel (crouch again mid-slide)" },
    { "check", "Slide cancel", "mpm_slide_cancel" },
    { "slider", "Earliest cancel (s)", "mpm_slide_cancel_mintime", 0, 2, 2 },
    { "slider", "Cooldown after cancel (s)", "mpm_slide_cancel_cooldown", 0, 10, 2 },
    { "slider", "Speed kept", "mpm_slide_cancel_keep", 0, 1.5, 2 },
    { "check", "Slides refill the tac sprint meter", "mpm_slide_cancel_refill" },
    { "check", "Cancel back into tac sprint", "mpm_slide_cancel_tac" },
    { "header", "Dive (hold crouch while sprinting)" },
    { "check", "Dive", "mpm_dive" },
    { "slider", "Hold time (s)", "mpm_dive_hold", 0.05, 1, 2 },
    { "slider", "Forward speed (x current)", "mpm_dive_fwd", 0, 3, 2 },
    { "slider", "Upward launch", "mpm_dive_up", 0, 600, 0 },
    { "slider", "Belly slide deceleration", "mpm_dive_landdecel", 0, 5000, 0 },
    { "header", "Prone" },
    { "check", "Prone", "mpm_prone" },
    { "check", "Double-tap crouch to go prone", "mpm_prone_doubletap" },
    { "slider", "Double-tap window (s)", "mpm_prone_window", 0.05, 1, 2 },
    { "slider", "Hold crouch to go prone (s, 0 = off)", "mpm_prone_hold", 0, 3, 2 },
    { "slider", "Extra prone key (0 none, 1 +alt1, 2 +alt2)", "mpm_prone_button", 0, 2, 0 },
    { "slider", "Crawl speed", "mpm_prone_speed", 1, 300, 0 },
    { "slider", "Crawl acceleration", "mpm_prone_accel", 1, 5000, 0 },
    { "slider", "Hull height", "mpm_prone_height", 8, 36, 0 },
    { "slider", "Eye height", "mpm_prone_view", 4, 36, 0 },
    { "slider", "Get down (s)", "mpm_prone_in_time", 0, 3, 2 },
    { "slider", "Up to crouch (s)", "mpm_prone_out_crouch", 0, 3, 2 },
    { "slider", "Up to standing (s)", "mpm_prone_out_stand", 0, 3, 2 },
    { "check", "Fire while crawling", "mpm_prone_crawlfire" },
    { "header", "Mantle (jump at a ledge)" },
    { "check", "Mantle", "mpm_mantle" },
    { "check", "Hold jump in the air to grab ledges", "mpm_mantle_air" },
    { "check", "Vault over thin obstacles", "mpm_mantle_vault" },
    { "slider", "Lowest ledge (u)", "mpm_mantle_min", 0, 64, 0 },
    { "slider", "Highest ledge (u)", "mpm_mantle_max", 20, 190, 0 },
    { "slider", "Reach (u)", "mpm_mantle_reach", 4, 96, 0 },
    { "slider", "Climb speed (u/s)", "mpm_mantle_speed", 50, 1000, 0 },
    { "header", "Hard landing" },
    { "check", "Big falls slow you down", "mpm_hardland" },
    { "slider", "Fall speed that counts (u/s)", "mpm_hardland_speed", 100, 2000, 0 },
    { "slider", "Speed kept on landing (x)", "mpm_hardland_keep", 0, 1, 2 },
    { "slider", "Recovery time (s)", "mpm_hardland_time", 0, 3, 2 },
}

local ANIMATION = {
    { "help", "Server settings: in multiplayer only the host / an admin can change these." },
    { "check", "MPM player animations", "mpm_anims" },
    { "check", "Upper body follows the view (aim)", "mpm_anim_aim" },
    { "check", "Per-gun reloads / draws / inspects", "mpm_anim_actions" },
    { "check", "Per-gun firing kick", "mpm_anim_fire" },
    { "check", "Starts / stops / transitions / idle variety", "mpm_anim_transitions" },
    { "check", "Pin HL2's hidden aim layers (keeps the MW pose clean)", "mpm_anim_neutralpose" },
    { "header", "Tuning" },
    { "slider", "Direction blend speed", "mpm_anim_dirblend", 1, 30, 1 },
    { "slider", "Fastest clip playback", "mpm_anim_maxrate", 1, 5, 2 },
    { "slider", "Start: turn away this far drops the start (deg)", "mpm_anim_startturn", 10, 180, 0 },
    { "slider", "Turn in place, standing (deg)", "mpm_anim_turn_stand", 10, 90, 0 },
    { "slider", "Turn in place, crouched (deg)", "mpm_anim_turn_crouch", 10, 90, 0 },
    { "slider", "Turn in place, prone (deg)", "mpm_anim_turn_prone", 5, 90, 0 },
    { "slider", "Turn in place rate", "mpm_anim_turnrate", 0.5, 4, 2 },
    { "slider", "Stand <-> crouch rate", "mpm_anim_stancerate", 0.5, 4, 2 },
    { "check", "Slopes: downhill lean, uphill sprint clips", "mpm_anim_slopes" },
    { "check", "Body-part flinches when hit", "mpm_flinch" },
    { "header", "Non-MW-Base weapons" },
    { "text", "HL2 holdtypes -> MW rifle anims", "mpm_anim_holdtypes" },
    { "text", "HL2 holdtypes -> MW pistol anims", "mpm_anim_holdtypes_pi" },
    { "text", "HL2 holdtype = MW kit", "mpm_anim_kits" },
}

local GUNS = {
    { "help", "Your own settings (this client only)." },
    { "header", "Gun" },
    { "check", "Place guns where MW does", "mpm_gun_track" },
    { "check", "Move gun parts (lids, belts, bolts...)", "mpm_gun_parts" },
    { "check", "Move magazines in reloads", "mpm_gun_mags" },
    { "check", "ADS: line the sight up with the eye", "mpm_gun_ads_align" },
    { "slider", "ADS alignment: most the gun moves (u)", "mpm_gun_ads_max", 0, 10, 1 },
    { "header", "Hands" },
    { "check", "Right hand onto MW's grip", "mpm_gun_rik" },
    { "check", "Left hand onto the gun", "mpm_gun_ik" },
    { "check", "MW finger poses", "mpm_gun_fingers" },
    { "check", "Fingers never bend backwards", "mpm_finger_clamp" },
    { "slider", "Left hand: full IK within (u)", "mpm_gun_ik_reach", 0, 30, 1 },
    { "slider", "Left hand: fade over (u)", "mpm_gun_ik_fade", 0, 30, 1 },
    { "slider", "No hand IK beyond (u)", "mpm_gun_ik_dist", 200, 5000, 0 },
    { "header", "Grip hand spots (forward left up, in the grip's frame)" },
    { "text", "Vertical grip", "mpm_gun_grip_vert" },
    { "text", "Angled grip", "mpm_gun_grip_ang" },
    { "text", "Side grip", "mpm_gun_grip_side" },
    { "header", "Feet and body" },
    { "check", "Foot IK (feet on slopes / steps)", "mpm_footik" },
    { "check", "Foot lock while standing still", "mpm_footlock" },
    { "check", "Prone follows the ground slope", "mpm_prone_tilt" },
    { "slider", "Foot IK distance (u)", "mpm_footik_range", 100, 10000, 0 },
    { "slider", "Flinch strength", "mpm_flinch_scale", 0, 2, 2 },
    { "header", "Calibration nudges" },
    { "text", "All guns: offset (fwd left up)", "mpm_gun_cal_pos" },
    { "text", "All guns: rotation (p y r)", "mpm_gun_cal_ang" },
    { "text", "Pistols: extra offset (fwd left up)", "mpm_gun_cal_pistol" },
}

local DEBUG = {
    { "check", "Movement / animation overlay", "mpm_debug" },
    { "check", "Left-hand IK target", "mpm_gun_ik_debug" },
    { "help", "Overlay: state, the playing sequence + layers, the gun (calibration, action, let-go, IK weights, grip), "
        .. "the hold layer. Screenshot it when something looks wrong." },
}

hook.Add("PopulateToolMenu", "MPM_Menu", function()
    spawnmenu.AddToolMenuOption("Utilities", "Modern Player Motion", "mpm_movement", "Movement", "", "",
        function(p) build(p, MOVEMENT) end)
    spawnmenu.AddToolMenuOption("Utilities", "Modern Player Motion", "mpm_animation", "Animation", "", "",
        function(p) build(p, ANIMATION) end)
    spawnmenu.AddToolMenuOption("Utilities", "Modern Player Motion", "mpm_guns", "Guns & Hands", "", "",
        function(p) build(p, GUNS) end)
    spawnmenu.AddToolMenuOption("Utilities", "Modern Player Motion", "mpm_debugmenu", "Debug", "", "",
        function(p) build(p, DEBUG) end)
end)
