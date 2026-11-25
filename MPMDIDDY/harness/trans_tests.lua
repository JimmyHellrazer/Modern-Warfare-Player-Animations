-- Transitions (sh_anim_trans.lua): pure helpers + start / stop / stance flows on a mock player.
local A, S = MPM.Anim, MPM.S
local T = {}
local function near(a, b, e) return math.abs(a - b) <= (e or 0.01) end

T[#T + 1] = { "NearestDir: all 8 and restricted to sprint dirs", function()
    local sprint = MPM.Clips.start_sprint_ar.dirs
    local r = { A.NearestDir(10), A.NearestDir(100), A.NearestDir(-170), A.NearestDir(-60), (A.NearestDir(90, sprint)) }
    return r[1] == 8 and r[2] == 4 and r[3] == 2 and r[4] == 9 and r[5] == 7, table.concat(r, " ")
end }

T[#T + 1] = { "DistToCycle: 0 at 0, ~1 at total, monotonic", function()
    local i = MPM.Clips.start_jog_ar.dirs[8]
    local c0, c1 = A.DistToCycle(i, 0), A.DistToCycle(i, i.total)
    local prev, mono = -1, true
    for d = 0, i.total, i.total / 20 do
        local c = A.DistToCycle(i, d); if c < prev then mono = false end; prev = c
    end
    return c0 == 0 and c1 > 0.9 and mono, ("total %.1f u, c(total) %.2f"):format(i.total, c1)
end }

T[#T + 1] = { "DistToCycle: clips that barely move are time-driven (nil)", function()
    return A.DistToCycle(MPM.Clips.stopl_walk_ar.dirs[8], 3) == nil, ("walk stop total %.1f"):format(MPM.Clips.stopl_walk_ar.dirs[8].total)
end }

T[#T + 1] = { "StopFoot: next foot to plant", function()
    local li = { rplant = { 0.5 } }
    return A.StopFoot(li, 0.2) == "r" and A.StopFoot(li, 0.7) == "l", ""
end }

T[#T + 1] = { "HandoffCycle: same foot, same time since plant", function()
    local c = A.HandoffCycle({ lplant = { 0.3 }, rplant = { 0.6 }, dur = 1 }, 0.7, { rplant = { 0.5 }, dur = 0.7 })
    return near(c, 0.5 + 0.1 / 0.7, 0.001), ("%.3f"):format(c)
end }

T[#T + 1] = { "InputAngle / IntentGait", function()
    local W, B, L, R = IN_FORWARD, IN_BACK, IN_MOVELEFT, IN_MOVERIGHT
    local ok = A.InputAngle(W) == 0 and A.InputAngle(R) == -90 and near(A.InputAngle(W + L), 45) and A.InputAngle(0) == nil
        and A.IntentGait(W, false) == "jog" and A.IntentGait(W + IN_WALK, false) == "walk"
        and A.IntentGait(W, true) == "cwalk" and A.IntentGait(W + IN_SPEED, true) == "cjog"
    return ok, ""
end }

-- mock player for the flows -------------------------------------------------------------------------------------------
local function mockPly()
    local p = { cyc = 0, seq = 1, dti = {}, dtf = {}, crouch = false }
    function p:GetCycle() return self.cyc end
    function p:GetSequence() return self.seq end
    function p:Crouching() return self.crouch end
    function p:GetDTInt(i) return self.dti[i] or 0 end
    function p:GetDTFloat(i) return self.dtf[i] or 0 end
    return p
end
local seqFor = function() return 5 end

local function ctx(over)
    local c = { set = "ar", gait = "idle", prev = "idle", speed = 0, velAng = 0, inAng = nil, prevInput = false,
                st = S.NONE, prevSt = S.NONE, crouch = false, prevCrouch = false, decel = 700, intent = "jog",
                eyeYaw = 0, bodyYaw = 0, diff = 0 }
    for k, v in pairs(over or {}) do c[k] = v end
    return c
end
local function step(dt) NOW = NOW + dt end

T[#T + 1] = { "flow: start (jog fwd) -> distance-matched -> hands off to the loop", function()
    ResetCVs(); local p = mockPly(); p.MPM_LastEval = NOW
    local shot = A.UpdateShot(p, ctx({ inAng = 0, speed = 0 }), seqFor)
    if not shot or shot.kind ~= "start" or shot.info.seq ~= "mpm_start_jog_ar_8" then return false, "no jog start" end
    local speed, t = 0, 0
    while p.MPM_Shot and t < 4 do
        step(1 / 66); t = t + 1 / 66; speed = math.min(199, speed + 650 / 66)
        A.UpdateShot(p, ctx({ gait = speed > 135 and "jog" or "walk", prev = "jog", inAng = 0, prevInput = true, speed = speed }), seqFor)
    end
    return p.MPM_Shot == nil and p.MPM_Handoff ~= nil and t > 0.3,
        ("start lasted %.2fs over %.0f u (clip %.0f u)"):format(t, shot.dist, shot.info.total)
end }

T[#T + 1] = { "flow: start aborts when keys are released", function()
    ResetCVs(); local p = mockPly(); p.MPM_LastEval = NOW
    A.UpdateShot(p, ctx({ inAng = 0 }), seqFor); step(0.1)
    local s = A.UpdateShot(p, ctx({ gait = "walk", prev = "walk", speed = 60, prevInput = true }), seqFor)
    return (s == nil or s.kind == "stop") and p.MPM_Handoff == nil, s and s.kind or "none"
end }

T[#T + 1] = { "flow: stop on release from a jog, picks foot + direction, ends", function()
    ResetCVs(); local p = mockPly(); p.MPM_LastEval = NOW; p.cyc = 0.7
    local shot = A.UpdateShot(p, ctx({ gait = "jog", prev = "jog", speed = 199, prevInput = true, velAng = 0 }), seqFor)
    if not shot or shot.kind ~= "stop" then return false, "no stop" end
    local name = shot.info.seq
    local speed, t = 199, 0
    while p.MPM_Shot and t < 3 do
        step(1 / 66); t = t + 1 / 66; speed = math.max(0, speed - 700 / 66)
        A.UpdateShot(p, ctx({ gait = speed > 8 and "jog" or "idle", prev = "jog", speed = speed, velAng = 0 }), seqFor)
    end
    return name == "mpm_stopl_jog_ar_8" and p.MPM_Shot == nil, ("%s, %.2fs"):format(name, t)
end }

T[#T + 1] = { "flow: sideways stop uses the side clip; sprint stop only forward", function()
    ResetCVs(); local p = mockPly(); p.MPM_LastEval = NOW; p.cyc = 0.2
    local a = A.UpdateShot(p, ctx({ gait = "jog", prev = "jog", speed = 130, prevInput = true, velAng = -90 }), seqFor)
    local q = mockPly(); q.MPM_LastEval = NOW
    local b = A.UpdateShot(q, ctx({ gait = "jog", prev = "sprint", speed = 267, prevInput = true, velAng = -90 }), seqFor)
    return a and a.info.seq == "mpm_stopr_jog_ar_6" and b == nil, (a and a.info.seq or "none") .. " / " .. tostring(b and b.info.seq)
end }

T[#T + 1] = { "flow: crouch while standing still -> stand_2_crouch", function()
    ResetCVs(); local p = mockPly(); p.MPM_LastEval = NOW
    local s = A.UpdateShot(p, ctx({ gait = "cidle", prev = "idle", crouch = true }), seqFor)
    return s and s.kind == "stance" and s.info.seq == "mpm_s2c_ar", s and s.info.seq or "none"
end }

T[#T + 1] = { "flow: prone in from standing -> stand_2_prone timed to mpm_prone_in_time", function()
    ResetCVs(); local p = mockPly(); p.MPM_LastEval = NOW
    local s = A.UpdateShot(p, ctx({ gait = "pidle", prev = "idle", st = S.PRONE_IN, prevSt = S.NONE }), seqFor)
    local want = s and s.info.dur / MPM.CV.prone_in_time:GetFloat()
    return s and s.info.seq == "mpm_s2p_ar" and near(s.rate, want, 0.001), s and ("%s rate %.2f"):format(s.info.seq, s.rate) or "none"
end }


T[#T + 1] = { "flow: start drops into the loop when the input turns away (no glide), keeping the foot phase", function()
    ResetCVs(); local p = mockPly(); p.MPM_LastEval = NOW
    A.UpdateShot(p, ctx({ inAng = 0 }), seqFor); step(0.1)
    local kept = A.UpdateShot(p, ctx({ gait = "walk", prev = "walk", inAng = 20, prevInput = true, speed = 60 }), seqFor)
    step(0.05)
    local s = A.UpdateShot(p, ctx({ gait = "walk", prev = "walk", inAng = -90, prevInput = true, speed = 80 }), seqFor)
    return kept ~= nil and s == nil and p.MPM_Handoff ~= nil, ("20 deg kept=%s, 90 deg -> %s"):format(tostring(kept ~= nil), s and s.kind or "loop")
end }


T[#T + 1] = { "AngDelta / YawAt", function()
    local i = MPM.Clips.turnl_ar
    local ok = near(A.AngDelta(10, 350), 20) and near(A.AngDelta(350, 10), -20) and near(A.YawAt(i, 0), 0)
        and near(A.YawAt(i, 1), 90, 0.5) and A.YawAt(i, 0.5) > 20 and A.YawAt(i, 0.5) < 70
    return ok, ("half-way %.1f deg"):format(A.YawAt(i, 0.5))
end }

T[#T + 1] = { "turn-in-place: view 75 deg left of a planted body -> left turn, body ends at the view", function()
    ResetCVs(); local p = mockPly(); p.MPM_LastEval = NOW; p.MPM_BodyYaw = 0
    local s = A.UpdateShot(p, ctx({ eyeYaw = 75, bodyYaw = 0, diff = 75 }), seqFor)
    if not s or s.kind ~= "turn" or s.info.seq ~= "mpm_turnl_ar" then return false, s and s.info.seq or "none" end
    local mid, t = nil, 0
    while p.MPM_Shot and t < 3 do
        step(1 / 66); t = t + 1 / 66
        A.UpdateShot(p, ctx({ eyeYaw = 75, bodyYaw = p.MPM_BodyYaw, diff = A.AngDelta(75, p.MPM_BodyYaw) }), seqFor)
        if not mid and t > 0.2 then mid = p.MPM_BodyYaw end
    end
    return near(p.MPM_BodyYaw, 75, 0.5) and mid > 5 and mid < 70, ("mid %.0f, end %.1f after %.2fs"):format(mid or -1, p.MPM_BodyYaw, t)
end }

T[#T + 1] = { "turn-in-place: small view offsets keep the feet planted (aim layer covers it)", function()
    ResetCVs(); local p = mockPly(); p.MPM_LastEval = NOW
    local s = A.UpdateShot(p, ctx({ eyeYaw = 40, bodyYaw = 0, diff = 40 }), seqFor)
    local c = ctx({ eyeYaw = 40, bodyYaw = 0, diff = 40 }); p.MPM_BodyYaw = 0; p.MPM_LastBodyT = NOW; step(0.2)
    local b = A.UpdateBodyYaw(p, c, nil)
    return s == nil and near(b, 0), ("body %.1f"):format(b)
end }

T[#T + 1] = { "turn-in-place: crouched and prone use their own clips / limits", function()
    ResetCVs(); local p = mockPly(); p.MPM_LastEval = NOW
    local a = A.UpdateShot(p, ctx({ gait = "cidle", prev = "cidle", crouch = true, eyeYaw = -70, diff = -70 }), seqFor)
    local q = mockPly(); q.MPM_LastEval = NOW
    local b = A.UpdateShot(q, ctx({ gait = "pidle", prev = "pidle", crouch = true, st = S.PRONE, prevSt = S.PRONE, eyeYaw = 30, diff = 30 }), seqFor)
    return a and a.info.seq == "mpm_cturnr_ar" and b and b.info.seq == "mpm_pturnl_ar",
        (a and a.info.seq or "none") .. " / " .. (b and b.info.seq or "none")
end }

T[#T + 1] = { "body follows the view while moving", function()
    ResetCVs(); local p = mockPly(); p.MPM_BodyYaw = 0; p.MPM_LastBodyT = NOW
    local c = ctx({ gait = "jog", prev = "jog", inAng = 0, eyeYaw = 90, diff = 90, speed = 199 })
    local t = 0
    while t < 0.3 do step(1 / 66); t = t + 1 / 66; A.UpdateBodyYaw(p, c, nil) end
    return near(p.MPM_BodyYaw, 90, 0.5), ("%.1f after 0.3s"):format(p.MPM_BodyYaw)
end }

return T
