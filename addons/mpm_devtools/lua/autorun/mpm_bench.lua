local B = {}

local FUNCS = { "Evaluate", "UpdateShot", "AirShot", "UpdateHold", "WeaponActions", "WeaponActionsDraw", "UpdateFire",
    "UpdateSlope", "SilenceForeign", "Neutralize", "AimParams", "GunWorld", "GunLocal", "SightAlign", "GroundSolve",
    "ProneTilt", "GroundNormal", "PickFlinch" }
local MOVE_FUNCS = { "TryMantle", "MantlePos", "MantleDur" }

local function new()
    return { buckets = {}, wrapped = {}, frames = {}, t0 = SysTime(), ticks = 0 }
end

local function add(run, name, dt)
    local b = run.buckets[name]
    if not b then b = { t = 0, n = 0, max = 0 } run.buckets[name] = b end
    b.t, b.n = b.t + dt, b.n + 1
    if dt > b.max then b.max = dt end
end

local function finish(run, label, s, ...)
    add(run, label, SysTime() - s)
    return ...
end

local function wrapTable(run, tbl, key, label)
    local fn = tbl and tbl[key]
    if type(fn) ~= "function" then return end
    run.wrapped[#run.wrapped + 1] = function() tbl[key] = fn end
    tbl[key] = function(...)
        return finish(run, label, SysTime(), fn(...))
    end
end

local function wrapHooks(run)
    for ev, list in pairs(hook.GetTable()) do
        for id, fn in pairs(list) do
            if isstring(id) and id:find("^MPM_") and ev ~= "PopulateToolMenu" and ev ~= "HUDPaint" then
                local label = "hook " .. ev .. " / " .. id
                run.wrapped[#run.wrapped + 1] = function() hook.Add(ev, id, fn) end
                hook.Add(ev, id, function(...)
                    return finish(run, label, SysTime(), fn(...))
                end)
            end
        end
    end
end

local function wrapBones(run)
    local A = MPM and MPM.Anim
    if not A then return end
    local prev = A.TraceHook
    local starts = {}
    run.wrapped[#run.wrapped + 1] = function() A.TraceHook = prev end
    A.TraceHook = function(ent, phase)
        if phase == "anim" then
            starts[ent] = SysTime()
        elseif phase == "final" and starts[ent] then
            add(run, "bones: IK callback (foot + hand IK, fingers)", SysTime() - starts[ent])
            starts[ent] = nil
        end
        if prev then return prev(ent, phase) end
    end
end

function B.Start()
    if B.run then B.Stop() end
    local run = new()
    wrapHooks(run)
    local A = MPM and MPM.Anim
    for _, f in ipairs(FUNCS) do wrapTable(run, A, f, "fn A." .. f) end
    for _, f in ipairs(MOVE_FUNCS) do wrapTable(run, MPM, f, "fn MPM." .. f) end
    if CLIENT then wrapBones(run) end
    hook.Add(CLIENT and "Think" or "Tick", "MPMBench_Frame", function()
        if CLIENT then run.frames[#run.frames + 1] = RealFrameTime() else run.ticks = run.ticks + 1 end
    end)
    B.run = run
end

function B.Stop()
    local run = B.run
    if not run then return nil end
    B.run = nil
    hook.Remove(CLIENT and "Think" or "Tick", "MPMBench_Frame")
    for i = #run.wrapped, 1, -1 do run.wrapped[i]() end
    run.dur = SysTime() - run.t0
    return run
end

local function frameStats(frames)
    if #frames == 0 then return nil end
    local sum = 0
    local s = {}
    for i, f in ipairs(frames) do sum = sum + f s[i] = f end
    table.sort(s)
    local avg = sum / #frames
    local p99 = s[math.max(1, math.floor(#s * 0.99))]
    return { n = #frames, avg = avg, fps = 1 / avg, p99 = p99, low = 1 / p99 }
end

function B.Report(run, label)
    local lines = {}
    local function P(fmt, ...) lines[#lines + 1] = fmt:format(...) end
    local players, mpm = 0, 0
    for _, p in ipairs(player.GetAll()) do
        players = players + 1
        if p.MPM_AnimOut then mpm = mpm + 1 end
    end
    local per
    if CLIENT then
        local fs = frameStats(run.frames)
        if not fs then P("%s: no frames", label) return lines end
        per = fs.n
        P("== %s: %.1f s, %d frames, %.1f fps avg (%.2f ms), 1%% low %.1f fps (%.2f ms) | players %d, MPM-driven %d",
            label, run.dur, fs.n, fs.fps, fs.avg * 1000, fs.low, fs.p99 * 1000, players, mpm)
    else
        per = math.max(run.ticks, 1)
        P("== %s: %.1f s, %d ticks (%.0f tick/s) | players %d, MPM-driven %d",
            label, run.dur, run.ticks, run.ticks / math.max(run.dur, 0.001), players, mpm)
    end
    local rows, total = {}, 0
    for name, b in pairs(run.buckets) do
        rows[#rows + 1] = { name = name, b = b }
        if name:find("^hook ") or name:find("^bones") then total = total + b.t end
    end
    table.sort(rows, function(x, y) return x.b.t > y.b.t end)
    local unit = CLIENT and "frame" or "tick"
    P("   %-58s %9s %9s %9s %9s", "where", "ms/" .. unit, "calls/" .. unit, "us/call", "max us")
    for _, r in ipairs(rows) do
        P("   %-58s %9.3f %9.1f %9.1f %9.0f", r.name, r.b.t / per * 1000, r.b.n / per, r.b.t / r.b.n * 1e6, r.b.max * 1e6)
    end
    local budget = CLIENT and (frameStats(run.frames).avg * 1000) or (engine.TickInterval() * 1000)
    P("   MPM total (hooks + bone callback, no double counting): %.3f ms per %s = %.1f%% of the %s",
        total / per * 1000, unit, total / per * 1000 / budget * 100, CLIENT and "frame" or "tick budget")
    P("   (fn rows run inside the hooks / callback, so they are already counted in those)")
    return lines
end

local function save(lines)
    file.CreateDir("mpm_bench")
    local name = "mpm_bench/bench_" .. os.date("%Y%m%d_%H%M%S") .. (CLIENT and "_cl" or "_sv") .. ".txt"
    file.Write(name, table.concat(lines, "\n") .. "\n")
    return name
end

if SERVER then
    util.AddNetworkString("mpm_bench")

    local function allowed(ply)
        return not IsValid(ply) or game.SinglePlayer() or ply:IsListenServerHost() or ply:IsSuperAdmin()
    end

    local function reply(ply, lines)
        if not IsValid(ply) then for _, l in ipairs(lines) do print(l) end return end
        for i = 1, #lines, 20 do
            net.Start("mpm_bench")
            net.WriteString("lines")
            net.WriteString(table.concat(lines, "\n", i, math.min(#lines, i + 19)))
            net.Send(ply)
        end
    end

    local saved = {}
    local function setMPM(on)
        for _, n in ipairs({ "mpm_enabled", "mpm_anims" }) do
            local c = GetConVar(n)
            if c then
                if not on then saved[n] = c:GetString() end
                RunConsoleCommand(n, on and (saved[n] or "1") or "0")
            end
        end
    end

    local function run(ply, secs, label)
        B.Start()
        timer.Create("MPMBench_SV", secs, 1, function()
            local r = B.Stop()
            if not r then return end
            local lines = B.Report(r, "SERVER " .. label)
            lines[#lines + 1] = "   saved garrysmod/data/" .. save(lines)
            reply(ply, lines)
        end)
    end

    net.Receive("mpm_bench", function(_, ply)
        local op, secs = net.ReadString(), math.Clamp(net.ReadFloat(), 1, 120)
        if not allowed(ply) then return end
        if op == "start" then run(ply, secs, "MPM on")
        elseif op == "off" then setMPM(false) run(ply, secs, "MPM off")
        elseif op == "restore" then setMPM(true) end
    end)

    concommand.Add("mpm_bench_sv", function(ply, _, args)
        if not allowed(ply) then return end
        run(ply, math.Clamp(tonumber(args[1]) or 10, 1, 120), "MPM on")
    end)
    return
end

local CHECK = {}

local function sample(run, name, state, v)
    run.checks = run.checks or {}
    local key = name .. "|" .. state
    local c = run.checks[key]
    if not c then c = { name = name, state = state, v = {} } run.checks[key] = c end
    c.v[#c.v + 1] = v
end

local function angErr(a, b)
    local f = math.deg(math.acos(math.Clamp(a:Forward():Dot(b:Forward()), -1, 1)))
    local u = math.deg(math.acos(math.Clamp(a:Up():Dot(b:Up()), -1, 1)))
    return math.max(f, u)
end

local function stateOf(ply)
    local a = ply.MPM_Act
    local base = a and a.kind or "hold"
    local ads = MPM.Anim.AdsAmount and MPM.Anim.AdsAmount(ply) or 0
    if base == "hold" and ads > 0.9 then base = "ads" end
    return base .. "/" .. (ply.MPM_Gait or "?")
end

function CHECK.Frame(run)
    local A = MPM and MPM.Anim
    if not A or not MPM.Guns then return end
    local fn = FrameNumber()
    if run.lastCheck == fn then return end
    run.lastCheck = fn
    for _, ply in ipairs(player.GetAll()) do CHECK.Player(run, A, ply, fn) end
end

function CHECK.Player(run, A, ply, fn)
    do
        if not ply.MPM_AnimOut or ply:IsDormant() then return end
        if ply == LocalPlayer() and not ply:ShouldDrawLocalPlayer() then return end
        local wep = ply:GetActiveWeapon()
        if not IsValid(wep) or not wep.WorldModelOffsets then return end
        local g = MPM.Guns[A.GunKey(wep) or ""]
        if not g or g.kit then return end
        local st = stateOf(ply)
        run.checkFrames = (run.checkFrames or 0) + 1
        local wmo = wep.WorldModelOffsets
        local sb = wep:LookupBone(wmo.Bone or "tag_sling")
        local sm = sb and wep:GetBoneMatrix(sb)
        local gw = ply.MPM_GW
        local rhb = ply:LookupBone("ValveBiped.Bip01_R_Hand")
        local rhm = rhb and ply:GetBoneMatrix(rhb)
        if sm and gw and gw.lp and rhm then
            local wp, wa = LocalToWorld(gw.lp, gw.la, rhm:GetTranslation(), rhm:GetAngles())
            sample(run, "gun bone vs MPM placement on the hand (u)", st, sm:GetTranslation():Distance(wp))
            sample(run, "gun bone vs MPM placement on the hand (deg)", st, angErr(sm:GetAngles(), wa))
        elseif gw == nil then
            sample(run, "gun not placed by MPM (frames)", st, 1)
        end
        local rh = ply:LookupBone("ValveBiped.Bip01_R_Hand")
        local lh = ply:LookupBone("ValveBiped.Bip01_L_Hand")
        local mr = rh and ply:GetBoneMatrix(rh)
        local ml = lh and ply:GetBoneMatrix(lh)
        if mr and sm and g.jg and g.gt and (ply.MPM_RIKW or 0) > 0.9 and (ply.MPM_LetGo or 0) < 0.1 then
            local jg = g.jg
            local ip, ia = WorldToLocal(vector_origin, angle_zero, Vector(jg[1], jg[2], jg[3]), Angle(jg[4], jg[5], jg[6]))
            local jp, ja = LocalToWorld(Vector(-g.gt[1], -g.gt[2], -g.gt[3]), angle_zero, sm:GetTranslation(), sm:GetAngles())
            local hp, ha = LocalToWorld(ip, ia, jp, ja)
            sample(run, "R hand vs grip on the drawn gun (u)", st, mr:GetTranslation():Distance(hp))
            sample(run, "R hand vs grip on the drawn gun (deg)", st, angErr(mr:GetAngles(), ha))
        end
        local rd = ply.MPM_RHDist
        if rd and rd.f == fn then sample(run, "R hand to IK target before IK (u, >14 = skipped)", st, rd.d) end
        sample(run, "gun: " .. (A.GunKey(wep) or "?"), st, 1)
        local ld = ply.MPM_LHDist
        if ld and ld.f == fn then
            sample(run, "L hand to target before IK (u, fades past 8)", st, ld.d)
            sample(run, "L hand IK weight after distance fade (x)", st, ld.w)
            sample(run, ("L target: %s, MW Base grip param '%s'"):format(ld.kind, tostring(ld.grip or "")), st, 1)
        end
        local gc = ply.MPM_GripCal
        if gc and gc.f == fn and gc.kind and (ply.MPM_ActW or 0) < 0.05 and (st:find("^hold") or st:find("^ads")) then
            run.grip = run.grip or {}
            local k = run.grip[gc.kind] or { n = 0, p = Vector(), t = Vector(), pp = {}, rd = 0, nrd = 0, gun = {} }
            run.grip[gc.kind] = k
            k.n = k.n + 1
            k.p = k.p + gc.p
            k.t = k.t + gc.t
            k.pp[#k.pp + 1] = gc.p
            if gc.rd then k.rd, k.nrd = k.rd + gc.rd, k.nrd + 1 end
            k.gun[A.GunKey(wep) or "?"] = true
        end
        local re, le = ply.MPM_RHErr, ply.MPM_LHErr
        if re and re.f == fn then
            sample(run, "R hand IK error inside the solve (u)", st, re.d)
            sample(run, "R hand IK error inside the solve (deg)", st, re.a)
        end
        if le and le.f == fn then sample(run, "L hand IK error inside the solve (u)", st, le.d) end
        if ply.MPM_PartialN then
            sample(run, "partial bone builds skipped (count)", st, ply.MPM_PartialN)
            ply.MPM_PartialN = nil
        end
        if ply.MPM_SolveF == fn then
            sample(run, "IK solves this frame (count)", st, ply.MPM_SolveN)
            if ply.MPM_SolveN > 1 then
                sample(run, "2nd solve: root moved vs 1st (u)", st, ply.MPM_SolveSpread)
                sample(run, "2nd solve: root yaw vs 1st (deg)", st, ply.MPM_SolveYaw)
            end
        end
        if ml and ply.MPM_IKTarget and (ply.MPM_IKW or 0) > 0.9 then
            sample(run, "L hand drawn vs last IK target (u)", st, ml:GetTranslation():Distance(ply.MPM_IKTarget))
        elseif ml and ply.MPM_IKTarget and (ply.MPM_IKW or 0) <= 0.1 and st:find("^hold") then
            sample(run, "L hand IK off while holding (frames)", st, 1)
        end
    end
end

local GRIP_CVAR = { vert = "mpm_gun_grip_vert", vertpro = "mpm_gun_grip_vert", ang = "mpm_gun_grip_ang", side = "mpm_gun_grip_side" }
B.GripCal = B.GripCal or {}

function CHECK.GripReport(run, lines)
    local function P(fmt, ...) lines[#lines + 1] = fmt:format(...) end
    if not run.grip then
        P("   FOREGRIP CHECK: no foregrip held (fit a vertical / angled / side grip and idle or aim with it)")
        return
    end
    P("   FOREGRIP CHECK (MW's own left hand from the grip hold, in the grip mount's frame, fwd left up)")
    for kind, k in pairs(run.grip) do
        local mean, tgt = k.p / k.n, k.t / k.n
        local spread = 0
        for _, v in ipairs(k.pp) do spread = math.max(spread, v:Distance(mean)) end
        local guns = {}
        for g in pairs(k.gun) do guns[#guns + 1] = g end
        P("   %-8s n %4d  MW hand %6.2f %6.2f %6.2f (spread %.2f u)  MPM target %6.2f %6.2f %6.2f  off by %.2f u%s  [%s]",
            kind, k.n, mean.x, mean.y, mean.z, spread, tgt.x, tgt.y, tgt.z, mean:Distance(tgt),
            k.nrd > 0 and ("  hand turned %.1f deg off MW's"):format(k.rd / k.nrd) or "", table.concat(guns, " "))
        local cv = GRIP_CVAR[kind]
        if cv then
            B.GripCal[cv] = ("%.2f %.2f %.2f"):format(mean.x, mean.y, mean.z)
            P("     -> %s \"%s\"   (mpm_grip_calibrate applies it)", cv, B.GripCal[cv])
        end
    end
end

concommand.Add("mpm_grip_calibrate", function()
    local n = 0
    for cv, v in pairs(B.GripCal) do
        RunConsoleCommand(cv, v)
        print(("[mpm] %s \"%s\""):format(cv, v))
        n = n + 1
    end
    if n == 0 then print("[mpm] no grip measurement yet: run mpm_bench while holding a gun with a foregrip") end
end)

function CHECK.Report(run, lines)
    local function P(fmt, ...) lines[#lines + 1] = fmt:format(...) end
    CHECK.GripReport(run, lines)
    if not run.checks then
        P("   GUN / HAND CHECK: no MPM player with an MW Base gun was drawn (third person or other players needed)")
        return
    end
    P("   GUN / HAND CHECK (%d player-frames; state = action or hold/ads + gait)", run.checkFrames or 0)
    P("   %-40s %-18s %7s %8s %8s %8s %8s", "check", "state", "n", "mean", "p95", "max", ">1u/>3deg")
    local rows = {}
    for _, c in pairs(run.checks) do rows[#rows + 1] = c end
    table.sort(rows, function(a, b) if a.name ~= b.name then return a.name < b.name end return #a.v > #b.v end)
    local bad = {}
    for _, c in ipairs(rows) do
        local v = c.v
        if c.name:find("%(frames%)") or c.name:find("^gun: ") or c.name:find("^L target: ") then
            P("   %-40s %-18s %7d", c.name, c.state, #v)
        else
            table.sort(v)
            local sum = 0
            for _, x in ipairs(v) do sum = sum + x end
            local lim = c.name:find("deg") and 3 or (c.name:find("%(x%)") and 2 or 1)
            local over = 0
            for _, x in ipairs(v) do if x > lim then over = over + 1 end end
            local mean, p95, mx = sum / #v, v[math.max(1, math.floor(#v * 0.95))], v[#v]
            P("   %-40s %-18s %7d %8.2f %8.2f %8.2f %7.0f%%", c.name, c.state, #v, mean, p95, mx, over / #v * 100)
            if p95 > lim then bad[#bad + 1] = c.name .. " @ " .. c.state end
        end
    end
    P("   %s", #bad == 0 and "all checks within 1 u / 3 deg at p95" or ("OFF at p95: " .. table.concat(bad, "; ")))
end

hook.Remove("PostDrawOpaqueRenderables", "MPMBench_Check")
hook.Add("PostRender", "MPMBench_Check", function()
    if B.run then CHECK.Frame(B.run) end
end)

local baseReport = B.Report
function B.Report(run, label)
    local lines = baseReport(run, label)
    CHECK.Report(run, lines)
    return lines
end

net.Receive("mpm_bench", function()
    if net.ReadString() == "lines" then
        for l in net.ReadString():gmatch("[^\n]+") do print(l) end
    end
end)

local function ask(op, secs)
    net.Start("mpm_bench")
    net.WriteString(op)
    net.WriteFloat(secs or 1)
    net.SendToServer()
end

local function phase(secs, label, done)
    B.Start()
    timer.Create("MPMBench_CL", secs, 1, function()
        local r = B.Stop()
        if not r then return end
        local lines = B.Report(r, "CLIENT " .. label)
        lines[#lines + 1] = "   saved garrysmod/data/" .. save(lines)
        for _, l in ipairs(lines) do print(l) end
        if done then done(r) end
    end)
end

concommand.Add("mpm_bench", function(_, _, args)
    local secs = math.Clamp(tonumber(args[1]) or 10, 1, 120)
    local compare = args[2] == "compare"
    print(("[mpm_bench] measuring %d s%s. Play normally (move, shoot, reload) or stand in a crowd of bots."):format(secs,
        compare and ", then the same again with MPM off" or ""))
    ask("start", secs)
    phase(secs, "MPM on", function(onRun)
        if not compare then return end
        timer.Simple(1, function()
            ask("off", secs)
            phase(secs, "MPM off", function(offRun)
                ask("restore")
                local a, b = frameStats(onRun.frames), frameStats(offRun.frames)
                if a and b then
                    print(("== MPM cost: %.2f ms per frame (%.1f fps with MPM vs %.1f without; 1%% low %.1f vs %.1f)"):format(
                        (a.avg - b.avg) * 1000, a.fps, b.fps, a.low, b.low))
                end
            end)
        end)
    end)
end, nil, "mpm_bench [seconds] [compare]: time MPM's hooks, bone/IK callback and graph functions on client + server")

concommand.Add("mpm_bench_stop", function()
    timer.Remove("MPMBench_CL")
    local r = B.Stop()
    if r then for _, l in ipairs(B.Report(r, "CLIENT (stopped early)")) do print(l) end end
end)
