-- Pure parts of the anim graph (sh_anim.lua): clip speed interpolation, blend params, gait choice.
local A, S = MPM.Anim, MPM.S
local T = {}
local function near(a, b, e) return math.abs(a - b) <= (e or 0.01) end
local walk = MPM.Clips.walk_ar

T[#T + 1] = { "ClipSpeed: exact numpad dirs", function()
    local ok = near(A.ClipSpeed(walk, 0), walk.dirs[8].speed) and near(A.ClipSpeed(walk, 90), walk.dirs[4].speed)
        and near(A.ClipSpeed(walk, -90), walk.dirs[6].speed) and near(A.ClipSpeed(walk, 180), walk.dirs[2].speed)
        and near(A.ClipSpeed(walk, -180), walk.dirs[2].speed) and near(A.ClipSpeed(walk, 45), walk.dirs[7].speed)
    return ok, ("fwd %.1f left %.1f back %.1f"):format(A.ClipSpeed(walk, 0), A.ClipSpeed(walk, 90), A.ClipSpeed(walk, 180))
end }

T[#T + 1] = { "ClipSpeed: halfway between 8 and 7", function()
    local want = (walk.dirs[8].speed + walk.dirs[7].speed) / 2
    return near(A.ClipSpeed(walk, 22.5), want), ("%.2f vs %.2f"):format(A.ClipSpeed(walk, 22.5), want)
end }

T[#T + 1] = { "ClipSpeed: fwd3 clamps outside +-45", function()
    local c = MPM.Clips.tac_ar
    return near(A.ClipSpeed(c, 90), c.dirs[7].speed) and near(A.ClipSpeed(c, 0), c.dirs[8].speed), ""
end }

T[#T + 1] = { "DirParams: cardinal and diagonal hit grid points", function()
    local x1, y1 = A.DirParams(0); local x2, y2 = A.DirParams(45); local x3, y3 = A.DirParams(-135)
    local x4, y4 = A.DirParams(90)
    return near(x1, 1) and near(y1, 0) and near(x2, 1) and near(y2, 1) and near(x3, -1) and near(y3, -1)
        and near(x4, 0) and near(y4, 1), ("45 -> %.2f %.2f, -135 -> %.2f %.2f"):format(x2, y2, x3, y3)
end }

local function g(st, sp, crouch, air, prev)
    return A.PickGait({ st = st, speed = sp, crouch = crouch or false, onGround = not air }, prev)
end

T[#T + 1] = { "PickGait: standing speeds (GMod slow walk 100, walk 200, run 400 sideways)", function()
    local r = { g(S.NONE, 0), g(S.NONE, 100), g(S.NONE, 200), g(S.NONE, 400) }
    return r[1] == "idle" and r[2] == "walk" and r[3] == "jog" and r[4] == "run", table.concat(r, " ")
end }

T[#T + 1] = { "PickGait: hysteresis keeps jog just under the edge", function()
    return g(S.NONE, 125, false, false, "jog") == "jog" and g(S.NONE, 125, false, false, "walk") == "walk", ""
end }

T[#T + 1] = { "PickGait: crouch (60) / crouch run (120)", function()
    return g(S.NONE, 0, true) == "cidle" and g(S.NONE, 60, true) == "cwalk" and g(S.NONE, 120, true) == "cjog", ""
end }

T[#T + 1] = { "PickGait: sprint / tac / slide / prone / crawl / dive / air", function()
    local r = { g(S.SPRINT, 400), g(S.TAC, 488), g(S.SLIDE, 400, true), g(S.PRONE, 0, true), g(S.PRONE, 45, true),
                g(S.DIVE, 400, true, true), tostring(g(S.NONE, 200, false, true)), tostring(g(S.NONE, 450, false, true)) }
    return r[1] == "sprint" and r[2] == "tac" and r[3] == "cidle" and r[4] == "pidle" and r[5] == "crawl"
        and r[6] == "pidle" and r[7] == "air" and r[8] == "fair", table.concat(r, " ")
end }

T[#T + 1] = { "every gait the picker can return has an _ar clip", function()
    local miss = {}
    for _, n in ipairs({ "idle", "walk", "jog", "run", "sprint", "tac", "cidle", "cwalk", "cjog", "pidle", "crawl", "air", "fair" }) do
        if not MPM.Clips[n .. "_ar"] then miss[#miss + 1] = n end
    end
    return #miss == 0, table.concat(miss, " ")
end }

T[#T + 1] = { "stride sync: GMod walk 200 on jog fwd plays ~1x", function()
    local r = 200 / A.ClipSpeed(MPM.Clips.jog_ar, 0)
    return r > 0.9 and r < 1.15, ("rate %.2f"):format(r)
end }


T[#T + 1] = { "pistol set: every rifle gait has a _pi twin, sprints are pistol clips", function()
    local miss = {}
    for _, n in ipairs({ "idle", "walk", "jog", "run", "sprint", "tac", "cidle", "cwalk", "cjog", "pidle", "crawl", "air",
                         "fair", "start_jog", "stopl_jog", "turnl", "s2c" }) do
        local c = MPM.Clips[n .. "_pi"]
        if not c then miss[#miss + 1] = n end
    end
    local sp = MPM.Clips.sprint_pi
    local ok = #miss == 0 and sp and sp.dirs[8].from:find("pistol") and MPM.Clips.walk_pi.seq == "mpm_walk_pi"
        and MPM.Clips.start_jog_pi.dirs[8].seq == "mpm_start_jog_pi_8"
    return ok, "missing: " .. table.concat(miss, " ") .. (sp and (" sprint from " .. sp.dirs[8].from) or "")
end }

return T
