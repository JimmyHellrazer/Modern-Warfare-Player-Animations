local A, S, DT = MPM.Anim, MPM.S, MPM.DT
local T = {}

local function fresh(boxes, ceiling)
    ResetCVs()
    WORLD.slope, WORLD.ceiling, WORLD.boxes = 0, ceiling, boxes or {}
    local p = NewPlayer()
    p:SetDTFloat(DT.METER, MPM.CV.tac_time:GetFloat())
    return p
end

local function box(x0, x1, top)
    return { min = Vector(x0, -500, 0), max = Vector(x1, 500, top) }
end

local function mantleRun(top, keys, approach, x1)
    local p = fresh({ box(40, x1 or 300, top) })
    Run(p, keys, approach or 0.05)
    local before = SN(p)
    Tick(p, bit.bor(keys, IN_JUMP))
    local started = SN(p)
    local name = select(3, MPM.MantleInfo(p))
    Run(p, keys, 1.6)
    return p, before, started, name
end

T[#T + 1] = { "mantle: jump at a 40u ledge climbs onto it", function()
    local p, _, started, name = mantleRun(40, IN_FORWARD)
    return started == "MANTLE" and math.abs(p.pos.z - 40) < 1.5 and p.pos.x > 40 and SN(p) ~= "MANTLE",
        ("%s %s end %.1f %.1f state %s"):format(started, tostring(name), p.pos.x, p.pos.z, SN(p))
end }

T[#T + 1] = { "mantle: ledge above mantle_max is a normal jump", function()
    local _, _, started = mantleRun(150, IN_FORWARD)
    return started ~= "MANTLE", started
end }

T[#T + 1] = { "mantle: low step (under the step size) is not a mantle", function()
    local _, _, started = mantleRun(12, IN_FORWARD)
    return started ~= "MANTLE", started
end }

T[#T + 1] = { "mantle: no ledge ahead, no mantle", function()
    local p = fresh({})
    Tick(p, bit.bor(IN_FORWARD, IN_JUMP))
    return SN(p) ~= "MANTLE", SN(p)
end }

T[#T + 1] = { "mantle: sprinting at a thin 36u wall vaults over and lands past it", function()
    local p = fresh({ box(60, 68, 36) })
    Run(p, bit.bor(IN_FORWARD, IN_SPEED), 0.25)
    Tick(p, bit.bor(IN_FORWARD, IN_SPEED, IN_JUMP))
    local started = SN(p)
    local _, over, name = MPM.MantleInfo(p)
    Run(p, bit.bor(IN_FORWARD, IN_SPEED), 1.5)
    return started == "MANTLE" and over and p.pos.x > 68 + 16 and p.pos.z < 1,
        ("%s over %s %s end %.1f %.1f"):format(started, tostring(over), tostring(name), p.pos.x, p.pos.z)
end }

T[#T + 1] = { "mantle: low ceiling over the ledge ends crouched", function()
    local p = fresh({ box(40, 300, 40) }, 100)
    Tick(p, bit.bor(IN_FORWARD, IN_JUMP))
    local started = SN(p)
    Run(p, 0, 1.5)
    return started == "MANTLE" and MPM.HasFlag(p, MPM.F.STAY_CROUCH) and math.abs(p.pos.z - 40) < 1.5,
        ("%s crouch %s z %.1f"):format(started, tostring(MPM.HasFlag(p, MPM.F.STAY_CROUCH)), p.pos.z)
end }

T[#T + 1] = { "mantle: no room at all on the ledge, no mantle", function()
    local p = fresh({ box(40, 300, 40) }, 60)
    Tick(p, bit.bor(IN_FORWARD, IN_JUMP))
    return SN(p) ~= "MANTLE", SN(p)
end }

T[#T + 1] = { "mantle: firing / jumping / crouching are blocked mid-mantle", function()
    local p = fresh({ box(40, 300, 48) })
    Tick(p, bit.bor(IN_FORWARD, IN_JUMP))
    Tick(p, bit.bor(IN_ATTACK, IN_DUCK, IN_JUMP))
    return SN(p) == "MANTLE" and bit.band(LAST_BTN, bit.bor(IN_ATTACK, IN_DUCK, IN_JUMP)) == 0, SN(p)
end }

T[#T + 1] = { "MantlePick: ledge / run / vault / step / boost choices", function()
    local r = { MPM.MantlePick(30, false, false), MPM.MantlePick(62, true, true), MPM.MantlePick(150, false, false),
                MPM.MantlePick(100, false, false), MPM.MantlePick(26, false, true), MPM.MantlePick(62, false, true) }
    return r[1] == "mantle_32_up_idle" and r[2] == "mantle_64_over_run" and r[3] == "mantle_boost_190_up"
        and r[4] == "mantle_boost_64_up" and r[5] == "mantle_step_32_up" and r[6] == "mantle_64_up_idle",
        table.concat(r, " ")
end }

T[#T + 1] = { "MantleFrac: starts at 0, ends at 1, never goes back, for every mantle clip", function()
    local bad = {}
    for _, name in ipairs(MPM.MantleList()) do
        local info = MPM.Clips[name]
        local px, pz = -1, -1
        local ok = true
        for i = 0, 20 do
            local fx, fz = MPM.MantleFrac(info, info.over, i / 20)
            if fx < px - 1e-3 or fz < pz - 1e-3 then ok = false end
            px, pz = fx, fz
        end
        local x0, z0 = MPM.MantleFrac(info, info.over, 0)
        local x1, z1 = MPM.MantleFrac(info, info.over, 1)
        if not ok or x0 > 0.05 or z0 > 0.05 or x1 < 0.95 or z1 < 0.95 then bad[#bad + 1] = name end
    end
    return #bad == 0 and #MPM.MantleList() > 40, #MPM.MantleList() .. " clips, bad: " .. table.concat(bad, " ")
end }

T[#T + 1] = { "hard landing: big fall slows the player, then recovers", function()
    local p = fresh({})
    Run(p, IN_FORWARD, 1.0)
    local full = p.vel:Length2D()
    p.pos.z, p.onGround, p.vel.z = 300, false, -100
    Run(p, IN_FORWARD, 0.9)
    local landed = p.onGround
    Run(p, IN_FORWARD, 0.1)
    local slow = p.vel:Length2D()
    Run(p, IN_FORWARD, 1.0)
    local back = p.vel:Length2D()
    return landed and p:GetDTFloat(DT.T_HARD) > 0 and slow < full * 0.7 and back > full * 0.95,
        ("full %.0f after landing %.0f recovered %.0f"):format(full, slow, back)
end }

T[#T + 1] = { "hard landing: a small drop doesn't count", function()
    local p = fresh({})
    p.pos.z, p.onGround, p.vel.z = 20, false, 0
    Run(p, 0, 0.5)
    return p.onGround and p:GetDTFloat(DT.T_HARD) == 0, ("T_HARD %.2f"):format(p:GetDTFloat(DT.T_HARD))
end }

local function mockPly()
    local p = { cyc = 0, seq = 1, dti = {}, dtf = {}, dtv = {} }
    function p:GetCycle() return self.cyc end
    function p:GetSequence() return self.seq end
    function p:Crouching() return false end
    function p:GetDTInt(i) return self.dti[i] or 0 end
    function p:GetDTFloat(i) return self.dtf[i] or 0 end
    function p:SetDTFloat(i, v) self.dtf[i] = v end
    function p:GetDTVector(i) return (self.dtv[i] or Vector()):Copy() end
    return p
end
local seqFor = function() return 5 end

local function ctx(over)
    local c = { set = "ar", gait = "idle", prev = "idle", speed = 0, velAng = 0, inAng = nil, prevInput = false,
                st = S.NONE, prevSt = S.NONE, crouch = false, prevCrouch = false, decel = 700, intent = "jog",
                eyeYaw = 0, bodyYaw = 0, diff = 0, onGround = true, prevGround = true, vz = 0, airTime = 0 }
    for k, v in pairs(over or {}) do c[k] = v end
    return c
end

local function shotOf(over, setup)
    local p = mockPly()
    if setup then setup(p) end
    local s = A.UpdateShot(p, ctx(over), seqFor)
    return s and s.kind or "none", s and s.info and s.info.seq or "", p, s
end

T[#T + 1] = { "graph: jump off -> takeoff clip (still / jog / fast)", function()
    local k1, s1 = shotOf({ onGround = false, vz = 200 })
    local k2, s2 = shotOf({ onGround = false, vz = 200, speed = 180, gait = "jog", prev = "jog" })
    local k3, s3 = shotOf({ onGround = false, vz = 200, speed = 300, gait = "run", prev = "run" })
    return k1 == "takeoff" and s1 == "mpm_takeoff_ar" and s2:find("takeoff_jog_ar") and s3:find("takeoff_fast_ar"),
        ("%s %s | %s | %s"):format(k1, s1, s2, s3)
end }

T[#T + 1] = { "graph: landing -> land clip; hard landing -> hard land clip", function()
    local k1, s1 = shotOf({ prevGround = false, airTime = 0.6 })
    local k2, s2 = shotOf({ prevGround = false, airTime = 0.6 }, function(p) p.dtf[DT.T_HARD] = CurTime() end)
    local k3, s3 = shotOf({ prevGround = false, airTime = 0.6, speed = 200 }, function(p) p.dtf[DT.T_HARD] = CurTime() end)
    local k4 = shotOf({ prevGround = false, airTime = 0.1 })
    return k1 == "land" and s1 == "mpm_land_ar" and s2 == "mpm_hland_ar" and s3 == "mpm_hlandm_ar" and k4 == "none",
        ("%s %s | %s | %s | short hop %s"):format(k1, s1, s2, s3, k4)
end }

T[#T + 1] = { "graph: slide start -> slide clip held while sliding; slide end -> slide to crouch", function()
    local k1, s1, p, shot = shotOf({ st = S.SLIDE, prevSt = S.NONE, speed = 400, gait = "cidle" })
    NOW = NOW + 5
    local again = A.UpdateShot(p, ctx({ st = S.SLIDE, prevSt = S.SLIDE, speed = 300, gait = "cidle" }), seqFor)
    local held = again == shot and again.cyc < 1
    local k3, s3 = shotOf({ st = S.NONE, prevSt = S.SLIDE, gait = "cidle", prev = "cidle" },
        function(q) q.dti[DT.BTN] = MPM.F.STAY_CROUCH end)
    return k1 == "slide" and s1:find("slide_") and held and s3 == "mpm_slidex_ar", ("%s %s held %s | %s %s"):format(k1, s1,
        tostring(held), k3, s3)
end }

T[#T + 1] = { "graph: dive in / belly loop handled / dive out", function()
    local k1, s1 = shotOf({ st = S.DIVE, prevSt = S.SPRINT, gait = "pidle" })
    local k2, s2 = shotOf({ st = S.PRONE, prevSt = S.PRONE, gait = "pidle", belly = false, prevBelly = true })
    return k1 == "dive" and s1 == "mpm_divein_ar" and s2 == "mpm_diveout_ar" and MPM.Clips.diveloop_ar ~= nil,
        ("%s %s | %s %s"):format(k1, s1, k2, s2)
end }

T[#T + 1] = { "graph: mantle state plays the picked mantle clip", function()
    local name = "mantle_40_up_idle"
    local k, s = shotOf({ st = S.MANTLE, prevSt = S.NONE }, function(p)
        p.dti[DT.MANTLE] = MPM.MantleList().index[name] * 2
        p.dtv[DT.M_END] = Vector(40, 0, 40)
    end)
    return k == "mantle" and s == "mpm_" .. name, k .. " " .. s
end }

T[#T + 1] = { "slopes: grade sign (uphill +, downhill -)", function()
    WORLD.slope, WORLD.boxes = 0.3, {}
    local p = NewPlayer()
    local up, down = A.Grade(p, Vector(1, 0, 0)), A.Grade(p, Vector(-1, 0, 0))
    WORLD.slope = 0
    return up > 15 and down < -15, ("%.1f %.1f"):format(up, down)
end }

T[#T + 1] = { "slopes: built layers + uphill sprint clips exist", function()
    local c = MPM.Clips
    return c.slope15_ar and c.slope30_ar and c.sprintup_ar and c.tacup_ar and c.sprintup_ar.kind == "fwd3", ""
end }

T[#T + 1] = { "flinch: direction from the attacker (front / back / left / right)", function()
    local r = { A.FlinchDir(0, Vector(100, 0, 0)), A.FlinchDir(0, Vector(-100, 0, 0)), A.FlinchDir(0, Vector(0, 100, 0)),
                A.FlinchDir(90, Vector(100, 0, 0)) }
    return r[1] == 1 and r[2] == 2 and r[3] == 3 and r[4] == 4, table.concat(r, " ")
end }

T[#T + 1] = { "flinch: picks a clip for every stance / part / direction", function()
    local miss = {}
    for _, st in ipairs({ "stand", "strafe_crouch", "prone" }) do
        for _, part in ipairs({ "head", "torso", "lleg", "rleg" }) do
            for _, dir in ipairs({ "fr", "bk", "le", "ri" }) do
                for _, side in ipairs({ "center", "left", "right" }) do
                    if not A.PickFlinch(st, part, dir, side) then miss[#miss + 1] = st .. "/" .. part .. "/" .. dir end
                end
            end
        end
    end
    local e = A.PickFlinch("stand", "torso", "fr", "left")
    return #miss == 0 and e and e.seq:find("torso_fr_left"), table.concat(miss, " ")
end }

return T
