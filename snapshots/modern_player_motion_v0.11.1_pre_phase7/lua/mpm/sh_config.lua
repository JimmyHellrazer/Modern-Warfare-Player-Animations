-- Config: convars, DT slots, state ids.
MPM = MPM or {}
MPM.Version = "0.1.0"

local FL = bit.bor(FCVAR_REPLICATED, FCVAR_ARCHIVE, FCVAR_NOTIFY)

local function cv(name, def, help, min, max)
    return CreateConVar("mpm_" .. name, def, FL, help, min, max)
end

MPM.CV = {
    enabled         = cv("enabled", "1", "Modern Player Motion on/off", 0, 1),
    mwspeeds        = cv("mwspeeds", "1", "Move at MW's speeds (from the MW clips, per direction) instead of the gamemode's walk/run", 0, 1),

    -- inertia (0 = vanilla GMod feel)
    inertia         = cv("inertia", "1", "MW-style acceleration/deceleration ramps", 0, 1),
    accel_time      = cv("accel_time", "0.30", "Seconds from standing to full speed", 0.01, 2),
    decel_time      = cv("decel_time", "0.38", "Seconds from full run speed to a stop (vanilla is ~0.29)", 0.01, 2),

    -- tactical sprint
    tac             = cv("tacsprint", "1", "Double-tap sprint for tactical sprint", 0, 1),
    tac_mult        = cv("tacsprint_mult", "1.22", "Tac sprint speed as a multiple of run speed", 1, 3),
    tac_time        = cv("tacsprint_time", "3.5", "Seconds of tac sprint on a full meter", 0.1, 60),
    tac_recharge    = cv("tacsprint_recharge", "3.0", "Seconds to refill the meter from empty", 0.1, 60),
    tac_window      = cv("tacsprint_window", "0.30", "Double-tap window in seconds", 0.05, 1),

    -- slide
    slide           = cv("slide", "1", "Crouch while sprinting to slide", 0, 1),
    slide_minspeed  = cv("slide_minspeed", "0.80", "Minimum speed to slide, as a fraction of run speed", 0, 2),
    slide_boost     = cv("slide_boost", "1.12", "Slide entry speed multiplier", 0.5, 3),
    slide_maxspeed  = cv("slide_maxspeed", "1.6", "Slide speed cap, as a multiple of run speed", 0.5, 5),
    slide_decel     = cv("slide_decel", "380", "Slide deceleration on flat ground (units/s^2)", 0, 5000),
    slide_slope     = cv("slide_slope", "1.0", "How much slopes speed up/slow down a slide", 0, 5),
    slide_steer     = cv("slide_steer", "70", "Slide steering in degrees per second", 0, 720),
    slide_maxtime   = cv("slide_maxtime", "1.1", "Longest slide on flat ground (s)", 0.1, 10),
    slide_cooldown  = cv("slide_cooldown", "0.6", "Seconds between slides", 0, 10),

    -- slide cancel (MW19 style: crouch again mid-slide to pop back up and keep running)
    cancel          = cv("slide_cancel", "1", "Press crouch mid-slide to cancel it and stand up running", 0, 1),
    cancel_mintime  = cv("slide_cancel_mintime", "0.10", "Earliest cancel after the slide starts (s)", 0, 2),
    cancel_cooldown = cv("slide_cancel_cooldown", "0.15", "Slide cooldown after a cancel (s)", 0, 10),
    cancel_keep     = cv("slide_cancel_keep", "1.0", "Fraction of slide speed kept on cancel", 0, 1.5),
    cancel_refill   = cv("slide_cancel_refill", "1", "Slides refill the tac sprint meter", 0, 1),
    cancel_tac      = cv("slide_cancel_tac", "1", "Cancelling a slide that came from tac sprint goes straight back to tac sprint", 0, 1),

    -- dive
    dive            = cv("dive", "1", "Hold crouch while sprinting to dive to prone", 0, 1),
    dive_hold       = cv("dive_hold", "0.20", "Crouch hold time that turns a slide into a dive (s)", 0.05, 1),
    dive_fwd        = cv("dive_fwd", "1.05", "Dive forward speed as a multiple of current speed", 0, 3),
    dive_up         = cv("dive_up", "170", "Dive upward launch speed", 0, 600),
    dive_landdecel  = cv("dive_landdecel", "700", "Belly slide deceleration after a dive (units/s^2)", 0, 5000),

    -- prone
    prone           = cv("prone", "1", "Prone on/off", 0, 1),
    prone_doubletap = cv("prone_doubletap", "1", "Double-tap crouch while (nearly) still to go prone", 0, 1),
    prone_window    = cv("prone_window", "0.30", "Crouch double-tap window in seconds", 0.05, 1),
    prone_hold      = cv("prone_hold", "0", "Hold crouch this long while still to go prone (0 = off; GMod crouch is hold-to-crouch)", 0, 3),
    prone_accel     = cv("prone_accel", "260", "Crawl acceleration (units/s^2)", 1, 5000),
    prone_button    = cv("prone_button", "0", "Extra prone toggle key: 0 none, 1 +alt1, 2 +alt2", 0, 2),
    prone_speed     = cv("prone_speed", "45", "Crawl speed", 1, 300),
    prone_height    = cv("prone_height", "22", "Prone hull height", 8, 36),
    prone_view      = cv("prone_view", "14", "Prone eye height", 4, 36),
    prone_in_time   = cv("prone_in_time", "0.53", "Seconds to get down", 0, 3),
    prone_out_crouch = cv("prone_out_crouch", "0.70", "Seconds from prone to crouch", 0, 3),
    prone_out_stand = cv("prone_out_stand", "0.73", "Seconds from prone to standing", 0, 3),
    prone_crawlfire = cv("prone_crawlfire", "0", "Allow firing while crawling", 0, 1),
}

MPM.CVDebug = CLIENT and CreateClientConVar("mpm_debug", "0", true, false, "Movement debug overlay") or nil

-- Player DT slots. Kept at the top of the range; gamemodes allocate from 0.
MPM.DT = {
    STATE    = 30, -- Int: current state
    BTN      = 31, -- Int: raw buttons this command (low 26 bits) | aux flags (high bits)
    T_STATE  = 26, -- Float: CurTime the state began
    METER    = 27, -- Float: tac sprint seconds left
    T_SPEED  = 28, -- Float: last raw sprint press (double tap)
    T_DUCK   = 29, -- Float: last raw crouch press (prone hold / dive hold)
    SPEED    = 30, -- Float: slide/belly speed, or inertia speed cap
    COOLDOWN = 31, -- Float: CurTime the next slide is allowed
    DIR      = 31, -- Vector: slide/dive direction
}

-- Aux flags share the BTN int above the button bits (IN_* tops out at bit 25).
MPM.F = {
    DIVE_PENDING = 2 ^ 26,     -- crouch pressed while sprinting: slide or dive not decided yet
    STAY_CROUCH  = 2 ^ 27,     -- keep crouching after a slide / getting up to crouch
    OUT_STAND    = 2 ^ 28,     -- PRONE_OUT target is standing (else crouch)
    BELLY        = 2 ^ 29,     -- prone entered from a dive: belly slide still running
    FROM_TAC     = 2 ^ 30,     -- the current slide started from tac sprint
    EAT_DUCK     = 2 ^ 31,     -- slide was cancelled: ignore the crouch key until it's released
}
MPM.BTN_MASK = 2 ^ 26 - 1

MPM.S = {
    NONE = 0, SPRINT = 1, TAC = 2, SLIDE = 3, DIVE = 4,
    PRONE_IN = 5, PRONE = 6, PRONE_OUT = 7,
}
MPM.SName = {}
for k, v in pairs(MPM.S) do MPM.SName[v] = k end
