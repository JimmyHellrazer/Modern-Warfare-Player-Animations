-- Scenario tests for the MPM movement core. Each returns ok, detail.
local W, SH, D, J = IN_FORWARD, IN_SPEED, IN_DUCK, IN_JUMP
local T = {}

local function fresh()
    ResetCVs(); SetCV("mpm_mwspeeds", 0); EVENTS = {}; WORLD.slope = 0; WORLD.ceiling = nil
    local p = NewPlayer()
    for _, fn in pairs(HOOKS.PlayerSpawn) do fn(p) end
    return p
end

local function timeUntil(p, raw, cond, max)
    local t = 0
    while t < (max or 5) do
        Tick(p, raw); t = t + DT_TICK
        if cond(p) then return t end
    end
    return nil
end

T[#T + 1] = { "inertia: walk start ramps, slower than vanilla", function()
    local p = fresh()
    local t1 = timeUntil(p, W, function(q) return q.vel:Length2D() >= 190 end)
    local q = fresh(); SetCV("mpm_inertia", 0)
    local t0 = timeUntil(q, W, function(r) return r.vel:Length2D() >= 190 end)
    return t1 and t0 and t1 > t0, ("mpm %.3fs vs vanilla %.3fs"):format(t1 or -1, t0 or -1)
end }

T[#T + 1] = { "inertia: run start reaches run speed in ~accel_time", function()
    local p = fresh()
    local t = timeUntil(p, W + SH, function(q) return q.vel:Length2D() >= 390 end)
    return t and t > 0.2 and t < 0.6, ("%.3fs"):format(t or -1)
end }

T[#T + 1] = { "inertia: stop from run takes ~decel_time and is slower than vanilla", function()
    local p = fresh(); Run(p, W + SH, 1.5)
    local t1 = timeUntil(p, 0, function(q) return q.vel:Length2D() < 5 end)
    local q = fresh(); SetCV("mpm_inertia", 0); Run(q, W + SH, 1.5)
    local t0 = timeUntil(q, 0, function(r) return r.vel:Length2D() < 5 end)
    return t1 and t0 and t1 > t0 and t1 < 0.5, ("mpm %.3fs vs vanilla %.3fs"):format(t1 or -1, t0 or -1)
end }

T[#T + 1] = { "sprint state while W+shift", function()
    local p = fresh(); Run(p, W + SH, 1)
    return SN(p) == "SPRINT" and math.abs(p.vel:Length2D() - 400) < 5, SN(p) .. " " .. p.vel:Length2D()
end }

T[#T + 1] = { "tac sprint: double tap, faster, meter runs out -> SPRINT", function()
    local p = fresh(); Run(p, W + SH, 1); Run(p, W, 0.08); Run(p, W + SH, 0.5)
    local st, sp = SN(p), p.vel:Length2D()
    if st ~= "TAC" then return false, "state " .. st end
    local tEnd = timeUntil(p, W + SH, function(q) return SN(q) ~= "TAC" end, 10)
    return sp > 470 and tEnd and SN(p) == "SPRINT",
        ("speed %.0f, ran out after %.2fs more -> %s"):format(sp, tEnd or -1, SN(p))
end }

T[#T + 1] = { "tac sprint: meter recharges", function()
    local p = fresh(); Run(p, W + SH, 1); Run(p, W, 0.08)
    timeUntil(p, W + SH, function(q) return SN(q) == "TAC" end, 1)
    timeUntil(p, W + SH, function(q) return SN(q) ~= "TAC" end, 10)
    local m0 = MPM.Meter(p); Run(p, 0, 1.5)
    return m0 < 0.01 and MPM.Meter(p) > 1.5, ("%.2f -> %.2f"):format(m0, MPM.Meter(p))
end }

T[#T + 1] = { "single shift tap does not trigger tac", function()
    local p = fresh(); Run(p, W + SH, 1.5)
    return SN(p) == "SPRINT", SN(p)
end }

local function slide(p)
    Run(p, W + SH, 1); Run(p, W + SH + D, 0.05); Run(p, W + SH, DT_TICK)
end

T[#T + 1] = { "slide: tap crouch while sprinting -> SLIDE, ends crouched", function()
    local p = fresh(); slide(p)
    if SN(p) ~= "SLIDE" then return false, "state " .. SN(p) end
    local v0, x0 = p.vel:Length2D(), p.pos.x
    Tick(p, W + SH)
    local btn = LAST_BTN
    local t = timeUntil(p, W + SH, function(q) return SN(q) ~= "SLIDE" end)
    local ok = v0 > 420 and t and t <= 1.15 and SN(p) == "NONE" and MPM.HasFlag(p, MPM.F.STAY_CROUCH)
        and bit.band(btn, IN_SPEED) == 0 and bit.band(btn, IN_DUCK) ~= 0
    return ok, ("entry %.0f u/s, %.2fs, %.0f units, crouch-after=%s"):format(v0, t or -1, p.pos.x - x0,
        tostring(MPM.HasFlag(p, MPM.F.STAY_CROUCH)))
end }

T[#T + 1] = { "slide: still crouched after, sprint press stands up", function()
    local p = fresh(); slide(p); Run(p, W, 1.5)
    local crouched = p.ducked
    Run(p, W + SH, 0.3)
    return crouched and not p.ducked and SN(p) == "SPRINT", ("crouched=%s then %s"):format(tostring(crouched), SN(p))
end }

T[#T + 1] = { "slide: jump cancels and keeps momentum", function()
    local p = fresh(); slide(p); Run(p, W + SH, 0.2)
    local v = p.vel:Length2D()
    Tick(p, W + SH + J)
    Run(p, W + SH, 0.05)
    return SN(p) ~= "SLIDE" and not p.onGround and p.vel:Length2D() > v * 0.85,
        ("%s air=%s %.0f -> %.0f"):format(SN(p), tostring(not p.onGround), v, p.vel:Length2D())
end }

T[#T + 1] = { "slide: cooldown blocks an immediate second slide", function()
    local p = fresh(); slide(p); Run(p, W + SH, 0.25); Tick(p, W + SH + J); Run(p, W + SH, 0.05)
    Run(p, W + SH + D, 0.05); Run(p, W + SH, DT_TICK)
    return SN(p) ~= "SLIDE", SN(p)
end }

T[#T + 1] = { "slide: downhill goes further than flat", function()
    local p = fresh(); slide(p); local x0 = p.pos.x
    timeUntil(p, W + SH, function(q) return SN(q) ~= "SLIDE" end, 6); local flat = p.pos.x - x0
    local q = fresh(); WORLD.slope = -0.25; slide(q); x0 = q.pos.x
    local t = timeUntil(q, W + SH, function(r) return SN(r) ~= "SLIDE" end, 6); local down = q.pos.x - x0
    return down > flat * 1.3, ("flat %.0f, downhill %.0f (%.2fs)"):format(flat, down, t or 6)
end }

T[#T + 1] = { "slide: walking speed can't slide", function()
    local p = fresh(); Run(p, W, 1); Run(p, W + D, 0.05); Run(p, W, 0.1)
    return SN(p) ~= "SLIDE", SN(p)
end }

T[#T + 1] = { "dive: hold crouch while sprinting -> DIVE -> belly PRONE", function()
    local p = fresh(); Run(p, W + SH, 1); Run(p, W + SH + D, 0.3)
    local st = SN(p); local air = not p.onGround
    local t = timeUntil(p, W + SH + D, function(q) return SN(q) == "PRONE" end, 3)
    local belly = MPM.HasFlag(p, MPM.F.BELLY)
    local x0 = p.pos.x
    timeUntil(p, 0, function(q) return not MPM.HasFlag(q, MPM.F.BELLY) end, 3)
    return st == "DIVE" and air and t and belly and p.duckMaxs.z == 22,
        ("%s air=%s, prone after %.2fs, belly slide %.0f units, hull %.0f"):format(st, tostring(air), t or -1,
            p.pos.x - x0, p.duckMaxs.z)
end }

T[#T + 1] = { "prone: double-tap crouch while still", function()
    local p = fresh(); Run(p, 0, 0.2); Run(p, D, 0.06); Run(p, 0, 0.08); Run(p, D, 0.06)
    local st = SN(p)
    Run(p, D, 0.7)
    return st == "PRONE_IN" and SN(p) == "PRONE" and p.duckMaxs.z == 22 and p.viewDuck.z == 14,
        ("%s -> %s hull %.0f view %.0f"):format(st, SN(p), p.duckMaxs.z, p.viewDuck.z)
end }

T[#T + 1] = { "prone: holding crouch does NOT go prone (GMod hold-to-crouch)", function()
    local p = fresh(); Run(p, D, 2)
    return SN(p) == "NONE" and p.ducked, SN(p)
end }

local function getProne(p) Run(p, 0, 0.2); Run(p, D, 0.06); Run(p, 0, 0.08); Run(p, D, 0.06); Run(p, 0, 0.8) end

T[#T + 1] = { "prone: crawl speed", function()
    local p = fresh(); getProne(p); Run(p, W, 1)
    local sp = p.vel:Length2D()
    return SN(p) == "PRONE" and math.abs(sp - 45) < 3, ("%s %.1f"):format(SN(p), sp)
end }

T[#T + 1] = { "prone: no firing while crawling, firing allowed when still", function()
    local p = fresh(); getProne(p); Run(p, W, 0.5); Tick(p, W + IN_ATTACK)
    local moving = bit.band(LAST_BTN, IN_ATTACK)
    Run(p, 0, 0.5); Tick(p, IN_ATTACK)
    return moving == 0 and bit.band(LAST_BTN, IN_ATTACK) ~= 0, ""
end }

T[#T + 1] = { "prone: jump stands up, hull restored", function()
    local p = fresh(); getProne(p); Tick(p, J)
    local st = SN(p)
    Run(p, 0, 0.85)
    return st == "PRONE_OUT" and SN(p) == "NONE" and p.duckMaxs.z == 36 and p.viewDuck.z == 28 and not p.ducked,
        ("%s -> %s hull %.0f ducked=%s"):format(st, SN(p), p.duckMaxs.z, tostring(p.ducked))
end }

T[#T + 1] = { "prone: crouch press -> crouched after", function()
    local p = fresh(); getProne(p); Tick(p, D); Run(p, 0, 0.85)
    return SN(p) == "NONE" and p.ducked, ("%s ducked=%s"):format(SN(p), tostring(p.ducked))
end }

T[#T + 1] = { "prone: low ceiling (40) -> jump gets you to crouch, not standing", function()
    local p = fresh(); getProne(p); WORLD.ceiling = 40; Tick(p, J); Run(p, 0, 0.8)
    return SN(p) == "NONE" and p.ducked, ("%s ducked=%s"):format(SN(p), tostring(p.ducked))
end }

T[#T + 1] = { "prone: very low ceiling (30) -> stays prone", function()
    local p = fresh(); getProne(p); WORLD.ceiling = 30; Tick(p, J); Tick(p, 0); Tick(p, D); Run(p, 0, 0.8)
    return SN(p) == "PRONE" and p.duckMaxs.z == 22, SN(p)
end }

T[#T + 1] = { "prone key (+alt1) toggles", function()
    local p = fresh(); SetCV("mpm_prone_button", 1); Tick(p, IN_ALT1); Run(p, 0, 0.7)
    local st = SN(p); Tick(p, IN_ALT1); Run(p, 0, 0.85)
    return st == "PRONE" and SN(p) == "NONE" and not p.ducked, st .. " -> " .. SN(p)
end }

T[#T + 1] = { "disabled: nothing happens", function()
    local p = fresh(); SetCV("mpm_enabled", 0); Run(p, W + SH, 1); Run(p, W + SH + D, 0.4)
    return SN(p) == "NONE", SN(p)
end }

T[#T + 1] = { "state change events fire", function()
    local p = fresh(); slide(p)
    local n = 0
    for _, e in ipairs(EVENTS) do if e[1] == "MPM_StateChanged" then n = n + 1 end end
    return n >= 2, n .. " events"
end }


local function tacSlide(p)
    Run(p, W + SH, 1); Run(p, W, 0.08); Run(p, W + SH, 0.4)   -- tac sprint
    Run(p, W + SH + D, 0.05); Run(p, W + SH, DT_TICK)          -- tap crouch -> slide
end

T[#T + 1] = { "slide cancel: crouch mid-slide -> standing, back in TAC, speed kept", function()
    local p = fresh(); tacSlide(p)
    if SN(p) ~= "SLIDE" then return false, "no slide: " .. SN(p) end
    Run(p, W + SH, 0.2)
    local v = p.vel:Length2D()
    Run(p, W + SH + D, 0.05)          -- cancel press (held a few ticks)
    local st = SN(p)
    Run(p, W + SH, 0.1)
    return st == "TAC" and SN(p) == "TAC" and not p.ducked and p.vel:Length2D() >= 470,
        ("slide %.0f -> %s, after %.0f u/s ducked=%s"):format(v, st, p.vel:Length2D(), tostring(p.ducked))
end }

T[#T + 1] = { "slide cancel: holding the cancel press doesn't crouch you", function()
    local p = fresh(); tacSlide(p); Run(p, W + SH, 0.2); Run(p, W + SH + D, 0.3)
    return not p.ducked and SN(p) == "TAC", ("ducked=%s %s"):format(tostring(p.ducked), SN(p))
end }

T[#T + 1] = { "slide cancel: too early is ignored", function()
    local p = fresh(); Run(p, W + SH, 1); Run(p, W + SH + D, 0.05); Run(p, W + SH, DT_TICK)
    Tick(p, W + SH + D)
    return SN(p) == "SLIDE", SN(p)
end }

T[#T + 1] = { "slide cancel loop: over 8 s it beats plain tac sprint (meter never runs dry)", function()
    local p = fresh(); Run(p, W + SH, 1); Run(p, W, 0.08); Run(p, W + SH, 0.3)
    local x0, t0 = p.pos.x, NOW
    local slides = 0
    for _ = 1, 8 do
        Run(p, W + SH + D, 0.03); Run(p, W + SH, DT_TICK)
        if SN(p) == "SLIDE" then slides = slides + 1 end
        Run(p, W + SH, 0.3); Run(p, W + SH + D, 0.03); Run(p, W + SH, 0.65)
    end
    local dist, dt = p.pos.x - x0, NOW - t0
    local q = fresh(); Run(q, W + SH, 1); Run(q, W, 0.08); Run(q, W + SH, 0.3)
    local qx = q.pos.x; Run(q, W + SH, dt)
    local plain = q.pos.x - qx
    return slides == 8 and dist > plain and SN(p) == "TAC",
        ("%d slides, %.0f units vs %.0f plain tac in %.2fs, meter %.2f, end %s"):format(slides, dist, plain, dt,
            MPM.Meter(p), SN(p))
end }

T[#T + 1] = { "slide refills tac meter", function()
    local p = fresh(); Run(p, W + SH, 1); Run(p, W, 0.08); Run(p, W + SH, 2.5)
    local m0 = MPM.Meter(p)
    Run(p, W + SH + D, 0.05); Run(p, W + SH, DT_TICK)
    return SN(p) == "SLIDE" and m0 < 1.5 and MPM.Meter(p) > 3.4, ("%.2f -> %.2f"):format(m0, MPM.Meter(p))
end }

T[#T + 1] = { "slide cancel off: crouch mid-slide does nothing", function()
    local p = fresh(); SetCV("mpm_slide_cancel", 0); tacSlide(p); Run(p, W + SH, 0.2); Run(p, W + SH + D, 0.05)
    return SN(p) == "SLIDE", SN(p)
end }


-- MW speeds (mpm_mwspeeds 1): measured clip speeds per direction --------------------------------------------------
local function mwfresh() local p = fresh(); SetCV("mpm_mwspeeds", 1); return p end
local function settle(p, raw) Run(p, raw, 1.5); return p.vel:Length2D() end
local function want(name, n) return MPM.Clips[name].dirs[n].speed end

T[#T + 1] = { "mw speeds: normal move fwd / right / back = MW jog", function()
    local f = settle(mwfresh(), W); local r = settle(mwfresh(), IN_MOVERIGHT); local b = settle(mwfresh(), IN_BACK)
    return math.abs(f - want("jog_ar", 8)) < 3 and math.abs(r - want("jog_ar", 6)) < 3 and math.abs(b - want("jog_ar", 2)) < 3,
        ("fwd %.0f (%.0f) right %.0f (%.0f) back %.0f (%.0f)"):format(f, want("jog_ar", 8), r, want("jog_ar", 6), b, want("jog_ar", 2))
end }

T[#T + 1] = { "mw speeds: slow walk = MW walk, sprint = MW sprint, tac = MW tac", function()
    local w = settle(mwfresh(), W + IN_WALK); local p = mwfresh(); local s = settle(p, W + SH)
    Run(p, W, 0.08); local t = settle(p, W + SH)
    return math.abs(w - want("walk_ar", 8)) < 3 and math.abs(s - want("sprint_ar", 8)) < 3 and math.abs(t - want("tac_ar", 8)) < 3
        and SN(p) == "TAC", ("walk %.0f sprint %.0f tac %.0f (%s)"):format(w, s, t, SN(p))
end }

T[#T + 1] = { "mw speeds: sprint key sideways = jog speed (MW can't sprint sideways)", function()
    local v = settle(mwfresh(), IN_MOVERIGHT + SH)
    return math.abs(v - want("jog_ar", 6)) < 3, ("%.0f"):format(v)
end }

T[#T + 1] = { "mw speeds: slide still reachable from MW sprint, crawl = MW crawl", function()
    local p = mwfresh(); Run(p, W + SH, 1); Run(p, W + SH + D, 0.05); Run(p, W + SH, DT_TICK)
    local slid = SN(p) == "SLIDE"
    local q = mwfresh(); Run(q, 0, 0.2); Run(q, D, 0.06); Run(q, 0, 0.08); Run(q, D, 0.06); Run(q, 0, 0.7)
    local c = settle(q, W)
    return slid and math.abs(c - want("crawl_ar", 8)) < 2, ("slide %s, crawl %.1f (%.1f)"):format(tostring(slid), c, want("crawl_ar", 8))
end }

return T
