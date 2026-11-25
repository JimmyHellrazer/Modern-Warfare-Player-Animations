-- Anim graph transitions (Phase 4): starts, stops, sprint start / stop, stance changes (stand / crouch / prone) and
-- idle variety. One-shot clips play as the main sequence with their cycle set by the graph every frame:
--   * starts are DISTANCE-MATCHED: the clip's cycle follows the ground distance actually covered since the start, so
--     the feet don't slide whatever the acceleration (clips.lua "dist" = cumulative distance per 2 frames)
--   * stops are matched to the distance still LEFT to stop (v^2 / 2a with the movement core's deceleration) and then
--     play out in time; which stop (left / right foot) comes from where the loop's stride is
--   * stance changes are time-based, scaled to the movement core's prone timings / a fixed crouch rate
-- When a start ends, the loop takes over at the same foot phase (A.HandoffCycle) so the stride carries on unbroken.
-- Everything here is pure data + a per-player table, run identically by server and clients (input bits are the raw
-- buttons the movement core networks in its DT int, so other players' starts / stops are seen too).
local A = MPM.Anim
local S, DT = MPM.S, MPM.DT
local band = bit.band

local FL = bit.bor(FCVAR_REPLICATED, FCVAR_ARCHIVE)
A.CV.trans = CreateConVar("mpm_anim_transitions", "1", FL, "Starts / stops / stance transitions / idle variety", 0, 1)
A.CV.startturn = CreateConVar("mpm_anim_startturn", "50", FL,
    "Input turning this many degrees off a start clip's direction drops into the loop", 10, 180)
A.CV.turnstand = CreateConVar("mpm_anim_turn_stand", "60", FL, "Standing: view this far off the body turns the feet", 10, 90)
A.CV.turncrouch = CreateConVar("mpm_anim_turn_crouch", "60", FL, "Crouched: view this far off the body turns the feet", 10, 90)
A.CV.turnprone = CreateConVar("mpm_anim_turn_prone", "25", FL, "Prone: view this far off the body turns it", 5, 90)
A.CV.turnrate = CreateConVar("mpm_anim_turnrate", "1.2", FL, "Turn-in-place playback rate", 0.5, 4)
A.CV.stancerate = CreateConVar("mpm_anim_stancerate", "1.4", FL, "Playback rate of stand <-> crouch transitions", 0.5, 4)

local DIRANG = { [8] = 0, [7] = 45, [4] = 90, [1] = 135, [2] = 180, [3] = -135, [6] = -90, [9] = -45 }
local MOVE_KEYS = bit.bor(IN_FORWARD, IN_BACK, IN_MOVELEFT, IN_MOVERIGHT)

local MOVING = { walk = true, jog = true, run = true, cwalk = true, cjog = true, sprint = true, tac = true }
local IDLE = { idle = true, cidle = true }
local START = { walk = "start_walk", jog = "start_jog", run = "start_jog", cwalk = "start_cwalk", cjog = "start_cfast" }
local STOP_LR = { walk = "walk", jog = "jog", run = "jog" }                 -- stopl_<x> / stopr_<x>
local STOP_ONE = { cwalk = "stop_cwalk", cjog = "stop_cfast", sprint = "stop_sprint", tac = "stop_sprint" }
local SPRINTS = { sprint = true, tac = true }
local IDLES = { "idle", "idle2", "idle3", "idle4" }

-- pure helpers (offline-tested) -----------------------------------------------------------------------------------

local function angDiff(a, b) return math.abs((a - b + 180) % 360 - 180) end

-- Nearest numpad direction to an angle (deg, 0 fwd, + left), among the keys of dirs (all 8 if nil).
function A.NearestDir(ang, dirs)
    local best, bd
    for n, a in pairs(DIRANG) do
        if not dirs or dirs[n] then
            local d = angDiff(ang, a)
            if not bd or d < bd then best, bd = n, d end
        end
    end
    return best, bd
end

-- Cycle (0..1) at which a one-shot has covered ground distance d. nil if the clip barely moves (time-driven then).
function A.DistToCycle(info, d)
    local arr, n = info.dist, info.frames or 2
    if not arr or #arr < 2 or (info.total or 0) < 2 then return nil end
    if d <= 0 then return 0 end
    for i = 2, #arr do
        if arr[i] >= d then
            local a, b = arr[i - 1], arr[i]
            local f = (b > a) and (d - a) / (b - a) or 0
            return math.min(((i - 2) + f) * 2, n - 1) / math.max(1, n - 1)
        end
    end
    return 1
end

-- Which foot a stop should land on: the foot that plants NEXT in the loop (strides start on the left plant at 0,
-- the right plant sits mid-cycle).
function A.StopFoot(loopInfo, cyc)
    local r = loopInfo and loopInfo.rplant and loopInfo.rplant[1] or 0.5
    return (cyc < r) and "r" or "l"
end

-- Loop cycle that carries on from a start clip: same foot, same time since that foot planted.
function A.HandoffCycle(shotInfo, shotCyc, loopInfo)
    if not loopInfo then return 0 end
    local best, foot = -1, nil
    for _, p in ipairs(shotInfo.lplant or {}) do if p <= shotCyc and p > best then best, foot = p, "l" end end
    for _, p in ipairs(shotInfo.rplant or {}) do if p <= shotCyc and p > best then best, foot = p, "r" end end
    if not foot then return 0 end
    local since = (shotCyc - best) * (shotInfo.dur or 1)
    local base = (foot == "l") and 0 or (loopInfo.rplant and loopInfo.rplant[1] or 0.5)
    return (base + since / math.max(loopInfo.dur or 1, 0.05)) % 1
end

-- Input direction from raw movement buttons (deg, 0 fwd, + left) or nil when no movement key is held.
function A.InputAngle(buttons)
    local f = (band(buttons, IN_FORWARD) ~= 0 and 1 or 0) - (band(buttons, IN_BACK) ~= 0 and 1 or 0)
    local s = (band(buttons, IN_MOVERIGHT) ~= 0 and 1 or 0) - (band(buttons, IN_MOVELEFT) ~= 0 and 1 or 0)
    if f == 0 and s == 0 then return nil end
    return math.deg(math.atan2(-s, f))
end

-- Signed angle from b to a (deg, + = a is left of / counter-clockwise from b).
function A.AngDelta(a, b) return (a - b + 180) % 360 - 180 end

-- |turn| a turn clip has done by cycle c (yawc = root yaw per 2 frames, signed), 0..|total|.
function A.YawAt(info, c)
    local arr = info.yawc
    if not arr or #arr < 2 then return 90 * c end
    local x = c * ((info.frames or 2) - 1) / 2 + 1
    local i = math.Clamp(math.floor(x), 1, #arr)
    local j = math.min(i + 1, #arr)
    local f = math.Clamp(x - i, 0, 1)
    return math.abs(arr[i] + (arr[j] - arr[i]) * f)
end

local function turnTotal(info)
    local arr = info.yawc
    return (arr and #arr > 0) and math.abs(arr[#arr]) or 90
end

-- runtime -------------------------------------------------------------------------------------------------------------

local function clipDir(name, set, dir)
    local c = MPM.Clips[name .. "_" .. set]
    if not c or not c.dirs then return nil end
    return c.dirs[dir], c
end

local function newShot(ply, kind, info, seqFor, extra)
    if not info then return nil end
    local seq = seqFor(ply, info.seq)
    if not seq or seq < 0 then return nil end
    local shot = { kind = kind, info = info, seq = seq, t0 = CurTime(), cyc = 0, dist = 0, rate = 1 }
    for k, v in pairs(extra or {}) do shot[k] = v end
    ply.MPM_Shot = shot
    return shot
end

-- The idle loop to play: rotates through the MW idles each time one finishes a loop.
function A.IdleName(ply, set, seqFor)
    local var = ply.MPM_IdleVar or 1
    local name = IDLES[var] .. "_" .. set
    local c = MPM.Clips[name]
    if not c then return "idle_" .. set end
    local cyc = ply:GetCycle()
    if ply:GetSequence() == seqFor(ply, c.seq) then
        if cyc + 0.5 < (ply.MPM_IdleLastCyc or 0) then -- wrapped: pick another one
            local n = #IDLES
            local new = math.random(1, n - 1)
            if new >= var then new = new + 1 end
            if MPM.Clips[IDLES[new] .. "_" .. set] then ply.MPM_IdleVar = new end
        end
        ply.MPM_IdleLastCyc = cyc
    else
        ply.MPM_IdleLastCyc = 0
    end
    return IDLES[ply.MPM_IdleVar or 1] .. "_" .. set
end

-- c = { set, gait, prev, speed, velAng, inAng (nil = no input), prevInput, st, prevSt, crouch, prevCrouch }
-- Returns the active one-shot (or nil) after advancing / starting / ending transitions for this frame.
function A.UpdateShot(ply, c, seqFor)
    if not A.CV.trans:GetBool() then ply.MPM_Shot = nil return nil end
    local now = CurTime()
    local dt = math.Clamp(now - (ply.MPM_LastEval or now), 0, 0.1)
    ply.MPM_LastEval = now
    local input = c.inAng ~= nil

    -- 1) advance the running one-shot --------------------------------------------------------------------------
    local shot = ply.MPM_Shot
    if shot then
        local info = shot.info
        local dur = math.max(info.dur or 0.5, 0.05)
        local timeCyc = (now - shot.t0) * shot.rate / dur
        local abort, turned = false, false
        local cyc
        shot.dist = shot.dist + c.speed * dt
        if shot.kind == "start" then
            local dc = A.DistToCycle(info, shot.dist)
            cyc = math.max(shot.cyc, dc or timeCyc, timeCyc * 0.6) -- never stall against a wall
            -- intent changed (crouch / walk key / sprint), keys released, left the ground, or the input turned away
            -- from the clip's direction (the start is one fixed direction; the loop blends any direction - without
            -- this, changing direction mid-start glided)
            turned = input and c.inAng ~= nil and angDiff(c.inAng, DIRANG[shot.dir] or 0) > A.CV.startturn:GetFloat()
            abort = not input or (c.intent ~= shot.intent) or (SPRINTS[c.gait] or false) ~= (SPRINTS[shot.gait] or false)
                or not (MOVING[c.gait] or IDLE[c.gait]) or turned
        elseif shot.kind == "stop" then
            local remaining = (c.speed * c.speed) / (2 * math.max(c.decel or 2000, 1))
            local dc = A.DistToCycle(info, (info.total or 0) - remaining)
            cyc = math.max(shot.cyc + dt / dur, dc or 0)
            abort = input or not (IDLE[c.gait] or MOVING[c.gait]) or (c.crouch ~= shot.crouch)
        elseif shot.kind == "turn" then
            cyc = timeCyc
            local done = A.YawAt(info, math.min(cyc, 1)) / turnTotal(info) * shot.amount
            ply.MPM_BodyYaw = shot.yaw0 + shot.sign * done
            abort = input or c.gait ~= shot.gait
        else -- stance
            cyc = timeCyc
            abort = (shot.still and input) or (shot.prone and c.st ~= shot.st)
        end
        shot.cyc = math.min(cyc, 1)
        if abort or shot.cyc >= 0.999 then
            ply.MPM_Shot = nil
            if shot.kind == "turn" and not abort then
                ply.MPM_BodyYaw = shot.yaw0 + shot.sign * shot.amount
            end
            -- a start that ran out, or one dropped because the input turned away (still moving, same intent): the loop
            -- carries on at the same foot phase instead of popping to its own clock
            local turnedOnly = turned and input and c.intent == shot.intent and MOVING[c.gait]
            if shot.kind == "start" and (not abort or turnedOnly) then
                -- the next loop (whichever gait the speed gives) carries on at the same foot phase
                ply.MPM_Handoff = { info = info, cyc = shot.cyc, dir = shot.dir }
            end
        else
            return shot
        end
    end

    -- 2) start a new one-shot -----------------------------------------------------------------------------------
    local set = c.set
    -- prone in / out (movement core states)
    if c.st == S.PRONE_IN and c.prevSt ~= S.PRONE_IN then
        local info = (MPM.Clips[(c.prevCrouch and "c2p_" or "s2p_") .. set])
        if info then
            return newShot(ply, "stance", info, seqFor, { st = c.st, prone = true,
                rate = (info.dur or 0.5) / math.max(MPM.CV.prone_in_time:GetFloat(), 0.05) })
        end
    elseif c.st == S.PRONE_OUT and c.prevSt ~= S.PRONE_OUT then
        local stand = MPM.HasFlag(ply, MPM.F.OUT_STAND)
        local info = MPM.Clips[(stand and "p2s_" or "p2c_") .. set]
        local t = stand and MPM.CV.prone_out_stand:GetFloat() or MPM.CV.prone_out_crouch:GetFloat()
        if info then
            return newShot(ply, "stance", info, seqFor, { st = c.st, prone = true,
                rate = (info.dur or 0.5) / math.max(t, 0.05) })
        end
    end

    -- crouch / stand while standing still
    if IDLE[c.gait] and IDLE[c.prev] and c.gait ~= c.prev and not input then
        local info = MPM.Clips[(c.gait == "cidle" and "s2c_" or "c2s_") .. set]
        if info then
            return newShot(ply, "stance", info, seqFor, { still = true, rate = A.CV.stancerate:GetFloat() })
        end
    end

    -- turn-in-place: standing / crouched / prone still, view far enough off the planted body -> MW turn clip, its 90 deg
    -- scaled to how far the view actually is (the aim layer covers the rest while the feet are planted)
    if IDLE[c.gait] or c.gait == "pidle" then
        if not input and c.st ~= S.PRONE_IN and c.st ~= S.PRONE_OUT then
            local prefix, lim = "turn", A.CV.turnstand:GetFloat()
            if c.gait == "cidle" then prefix, lim = "cturn", A.CV.turncrouch:GetFloat()
            elseif c.gait == "pidle" then prefix, lim = "pturn", A.CV.turnprone:GetFloat() end
            if math.abs(c.diff) > lim then
                local left = c.diff > 0
                local info = MPM.Clips[prefix .. (left and "l_" or "r_") .. set]
                if info then
                    return newShot(ply, "turn", info, seqFor, { gait = c.gait, yaw0 = c.bodyYaw,
                        sign = left and 1 or -1, amount = math.min(math.abs(c.diff), 180),
                        rate = A.CV.turnrate:GetFloat() * math.Clamp(math.abs(c.diff) / 90, 0.8, 2) })
                end
            end
        end
    end

    -- starts: keys pressed from standing (or out of a stop); the clip set comes from what the player INTENDS
    -- (normal = jog, +walk = walk, crouched = crouch walk / crouch fast), not the near-zero current speed
    if input and not SPRINTS[c.gait] and (IDLE[c.prev] or IDLE[c.gait] or c.prevStop) and c.speed < 60
        and START[c.intent] then
        local cl = MPM.Clips[START[c.intent] .. "_" .. set]
        if cl and cl.dirs then
            local dir = A.NearestDir(c.inAng, cl.dirs)
            return newShot(ply, "start", cl.dirs[dir], seqFor, { gait = c.intent, intent = c.intent, dir = dir })
        end
    end

    -- sprint start: into sprint / tac from another moving gait, heading forward-ish
    if SPRINTS[c.gait] and MOVING[c.prev] and not SPRINTS[c.prev] and input and math.abs(c.inAng) <= 60 then
        local cl = MPM.Clips["start_sprint_" .. set]
        if cl and cl.dirs then
            local dir = A.NearestDir(c.inAng, cl.dirs)
            return newShot(ply, "start", cl.dirs[dir], seqFor, { gait = c.gait, intent = c.intent, dir = dir })
        end
    end

    -- stops: movement keys released while still moving
    if c.prevInput and not input and MOVING[c.prev] and c.speed > 25 then
        local name
        if STOP_LR[c.prev] then
            local loop = MPM.Clips[c.prev .. "_" .. set]
            local li = loop and loop.dirs and loop.dirs[A.NearestDir(c.velAng)]
            name = "stop" .. A.StopFoot(li, ply:GetCycle()) .. "_" .. STOP_LR[c.prev]
        else
            name = STOP_ONE[c.prev]
        end
        local cl = name and MPM.Clips[name .. "_" .. set]
        if cl and cl.dirs then
            local dir, off = A.NearestDir(c.velAng, cl.dirs)
            local count = 0
            for _ in pairs(cl.dirs) do count = count + 1 end
            if off <= (count < 8 and 30 or 50) then -- sprint stops (7/8/9 only) just for forward-ish travel
                local info = cl.dirs[dir]
                local shot = newShot(ply, "stop", info, seqFor, { gait = c.prev, dir = dir, crouch = c.crouch })
                if shot then
                    local remaining = (c.speed * c.speed) / (2 * math.max(c.decel or 2000, 1))
                    shot.cyc = A.DistToCycle(info, (info.total or 0) - remaining) or 0
                    return shot
                end
            end
        end
    end
    return nil
end

-- What the player is trying to do (for picking a start set).
function A.IntentGait(raw, crouch)
    if crouch then return band(raw, IN_SPEED) ~= 0 and "cjog" or "cwalk" end
    if band(raw, IN_WALK) ~= 0 then return "walk" end
    return "jog"
end

-- Per-frame context for UpdateShot, built from the player (both realms).
function A.TransContext(ply, set, gait, speed, velAng)
    local raw = band(ply:GetDTInt(DT.BTN), MPM.BTN_MASK)
    local inAng = A.InputAngle(raw)
    local st = MPM.GetState(ply)
    local decel = 2000
    if MPM.CV.inertia:GetBool() then
        decel = MPM.RunSpeed(ply) / math.max(MPM.CV.decel_time:GetFloat(), 0.01)
    end
    local c = {
        set = set, gait = gait, prev = ply.MPM_Gait, speed = speed, velAng = velAng, inAng = inAng,
        prevInput = ply.MPM_PrevInput, st = st, prevSt = ply.MPM_PrevSt,
        crouch = ply:Crouching() or MPM.IsProneState(st), prevCrouch = ply.MPM_PrevCrouch, decel = decel,
        prevStop = ply.MPM_Shot == nil and ply.MPM_WasStop,
    }
    c.intent = A.IntentGait(raw, ply:Crouching())
    c.eyeYaw = ply:EyeAngles().y
    c.bodyYaw = ply.MPM_BodyYaw or c.eyeYaw
    c.diff = A.AngDelta(c.eyeYaw, c.bodyYaw)
    return c
end

function A.TransRemember(ply, c)
    ply.MPM_PrevInput = c.inAng ~= nil
    ply.MPM_PrevSt = c.st
    ply.MPM_PrevCrouch = ply:Crouching()
    ply.MPM_WasStop = ply.MPM_Shot ~= nil and ply.MPM_Shot.kind == "stop"
end

-- Body facing after this frame's transitions: planted while standing still (turn clips move it), otherwise it follows
-- the view (fast standing / crouched, slower prone). Returns the yaw the body renders at.
function A.UpdateBodyYaw(ply, c, shot)
    local now = CurTime()
    local dt = math.Clamp(now - (ply.MPM_LastBodyT or now), 0, 0.1)
    ply.MPM_LastBodyT = now
    local body = ply.MPM_BodyYaw or c.eyeYaw
    if shot and shot.kind == "turn" then return ply.MPM_BodyYaw end
    local still = (IDLE[c.gait] or c.gait == "pidle") and c.inAng == nil
        and not (shot and (shot.kind == "start"))
    if not still then
        local rate = (c.gait == "crawl" or c.gait == "pidle") and 180 or 720
        local d = A.AngDelta(c.eyeYaw, body)
        local step = rate * dt
        body = body + math.Clamp(d, -step, step)
    end
    ply.MPM_BodyYaw = (body + 180) % 360 - 180
    return ply.MPM_BodyYaw
end
