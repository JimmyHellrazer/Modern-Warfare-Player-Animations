local DT, S, CV = MPM.DT, MPM.S, MPM.CV

local LEDGE = { 24, 32, 40, 48, 56, 64 }
local UP = Vector(0, 0, 1)

local list
function MPM.MantleList()
    if list and list.src == MPM.Clips then return list end
    local l = { src = MPM.Clips, index = {} }
    for name, c in pairs(MPM.Clips or {}) do
        if type(c) == "table" and c.kind == "mantle" then l[#l + 1] = name end
    end
    table.sort(l)
    for i, n in ipairs(l) do l.index[n] = i end
    list = l
    return l
end

local function has(name)
    return MPM.Clips and MPM.Clips[name] ~= nil
end

function MPM.MantlePick(h, over, run)
    if h <= 64 then
        local nh = 64
        for _, v in ipairs(LEDGE) do if v >= h - 4 then nh = v break end end
        local kind = over and "over" or "up"
        local tries = { ("mantle_%d_%s_%s"):format(nh, kind, run and "run" or "idle"),
                        ("mantle_%d_%s_%s"):format(nh, kind, run and "idle" or "run") }
        if over then tries[#tries + 1] = ("mantle_%d_up_%s"):format(nh, run and "run" or "idle") end
        if run and h <= 34 then
            table.insert(tries, 1, ("mantle_step_%d_%s"):format(h <= 20 and 16 or 32, kind))
        end
        for _, n in ipairs(tries) do if has(n) then return n end end
        return nil
    end
    local n = h <= 120 and "mantle_boost_64_up" or "mantle_boost_190_up"
    if has(n) then return n end
    return has("mantle_boost_190_up") and "mantle_boost_190_up" or nil
end

function MPM.MantleInfo(ply)
    local v = ply:GetDTInt(DT.MANTLE)
    local idx = math.floor(v / 2)
    local l = MPM.MantleList()
    local name = l[idx]
    return name and MPM.Clips[name] or nil, v % 2 == 1, name
end

function MPM.MantleDurFor(h, dist, info, over)
    local t = 0.16 + math.max(h, 0) / math.max(CV.mantle_speed:GetFloat(), 1) + dist / 420
    if over then t = t + 0.08 end
    if info and info.dur then t = math.max(t, info.dur * 0.7) end
    return math.Clamp(t, 0.2, 2.5)
end

function MPM.MantleDur(ply)
    local a, b = ply:GetDTVector(DT.M_START), ply:GetDTVector(DT.M_END)
    local info, over = MPM.MantleInfo(ply)
    return MPM.MantleDurFor(b.z - a.z, Vector(b.x - a.x, b.y - a.y, 0):Length(), info, over)
end

local function smooth(x)
    x = math.Clamp(x, 0, 1)
    return x * x * (3 - 2 * x)
end

local function track(info, t)
    local mt = info and info.mt
    if not mt or #mt < 2 or (info.peak or 0) < 4 then return nil end
    local n = #mt
    local x = math.Clamp(t, 0, 1) * (n - 1) + 1
    local i = math.Clamp(math.floor(x), 1, n)
    local j = math.min(i + 1, n)
    local f = x - i
    local px = Lerp(f, mt[i][1], mt[j][1])
    local pz = Lerp(f, mt[i][3], mt[j][3])
    local peakAt = 1
    for k = 1, n do if mt[k][3] >= info.peak - 0.5 then peakAt = k break end end
    local fz = (x >= peakAt) and 1 or math.Clamp(pz / info.peak, 0, 1)
    local fx = math.Clamp(px / math.max(info.reach or mt[n][1], 1), 0, 1)
    return fx, fz
end

function MPM.MantleFrac(info, over, t)
    local fx, fz = track(info, t)
    if fx then return fx, fz end
    if over then return smooth((t - 0.15) / 0.85), smooth(t / 0.4) end
    return smooth((t - 0.3) / 0.7), smooth(t / 0.6)
end

function MPM.MantlePos(ply, t)
    local a, b = ply:GetDTVector(DT.M_START), ply:GetDTVector(DT.M_END)
    local info, over = MPM.MantleInfo(ply)
    local fx, fz = MPM.MantleFrac(info, over, t)
    return Vector(Lerp(fx, a.x, b.x), Lerp(fx, a.y, b.y), Lerp(fz, a.z, b.z))
end

local function hullClear(ply, from, to, mins, maxs)
    local tr = util.TraceHull({ start = from, endpos = to, mins = mins, maxs = maxs, mask = MASK_PLAYERSOLID, filter = ply })
    return not tr.Hit and not tr.StartSolid, tr
end

function MPM.TryMantle(ply, mv, onGround, hsp, fwdIn)
    if CurTime() < (ply.MPM_MantleNext or 0) then return false end
    local pos = mv:GetOrigin()
    local yaw = mv:GetMoveAngles().y
    local fwd = Angle(0, yaw, 0):Forward()
    local mins, maxs = ply:GetHull()
    local reach = CV.mantle_reach:GetFloat() + math.min(hsp, 400) * 0.08
    local step = math.max(ply:GetStepSize(), 18)
    local hmin, hmax = math.max(CV.mantle_min:GetFloat(), step + 1), CV.mantle_max:GetFloat()

    local wall = util.TraceHull({ start = pos + UP * step, endpos = pos + UP * step + fwd * reach,
        mins = mins, maxs = Vector(maxs.x, maxs.y, maxs.z - step), mask = MASK_PLAYERSOLID, filter = ply })
    if not wall.Hit or wall.StartSolid then return false end
    if math.abs(wall.HitNormal.z) > 0.35 or -wall.HitNormal:Dot(fwd) < 0.5 then return false end

    local into = reach * wall.Fraction + maxs.x * 2 + 2
    local top = pos + fwd * into
    local down = util.TraceHull({ start = Vector(top.x, top.y, pos.z + hmax + 2), endpos = Vector(top.x, top.y, pos.z + step),
        mins = mins, maxs = Vector(maxs.x, maxs.y, mins.z + 2), mask = MASK_PLAYERSOLID, filter = ply })
    if not down.Hit or down.StartSolid or down.HitNormal.z < 0.7 then return false end
    local h = down.HitPos.z - pos.z
    if h < hmin or h > hmax then return false end
    if not onGround and h < 24 then return false end

    local endPos = Vector(top.x, top.y, down.HitPos.z + 0.5)
    local rise = Vector(pos.x, pos.y, endPos.z)
    local crouchEnd = false
    if not (hullClear(ply, pos, rise, mins, maxs) and hullClear(ply, rise, endPos, mins, maxs)) then
        local d = MPM.DefaultDuck(ply)
        if not (hullClear(ply, pos, rise, d.mins, d.maxs) and hullClear(ply, rise, endPos, d.mins, d.maxs)) then
            return false
        end
        crouchEnd = true
    end

    local over = false
    if CV.mantle_vault:GetBool() and h <= 64 and fwdIn > 0 and hsp > MPM.WalkSpeed(ply) * 0.35 and not crouchEnd then
        local beyond = endPos + fwd * (maxs.x * 2 + 10)
        if hullClear(ply, endPos, beyond, mins, maxs) then
            local drop = util.TraceHull({ start = beyond, endpos = beyond - UP * (h + 24), mins = mins, maxs = maxs,
                mask = MASK_PLAYERSOLID, filter = ply })
            if not drop.Hit or endPos.z - drop.HitPos.z > step then over, endPos = true, beyond end
        end
    end

    local run = hsp > MPM.WalkSpeed(ply) * 0.6
    local name = MPM.MantlePick(h, over, run)
    local idx = name and MPM.MantleList().index[name] or 0
    ply:SetDTInt(DT.MANTLE, idx * 2 + (over and 1 or 0))
    ply:SetDTVector(DT.M_START, pos)
    ply:SetDTVector(DT.M_END, endPos)
    ply:SetDTFloat(DT.SPEED, hsp)
    ply.MPM_MantleCrouch = crouchEnd
    MPM.SetFlag(ply, MPM.F.STAY_CROUCH, false)
    MPM.SetState(ply, S.MANTLE)
    mv:SetVelocity(vector_origin)
    return true
end

function MPM.EndMantle(ply, mv)
    local a, b = ply:GetDTVector(DT.M_START), ply:GetDTVector(DT.M_END)
    local _, over = MPM.MantleInfo(ply)
    local fwd = Vector(b.x - a.x, b.y - a.y, 0)
    fwd:Normalize()
    mv:SetOrigin(b)
    local keep = ply:GetDTFloat(DT.SPEED)
    local sp = over and math.max(keep, MPM.WalkSpeed(ply) * 0.8) or math.min(keep, MPM.WalkSpeed(ply)) * 0.5
    mv:SetVelocity(fwd * sp)
    ply:SetDTFloat(DT.SPEED, sp)
    ply.MPM_MantleNext = CurTime() + 0.25
    MPM.SetFlag(ply, MPM.F.STAY_CROUCH, ply.MPM_MantleCrouch and true or false)
    if ply.MPM_MantleCrouch then ply:AddFlags(FL_DUCKING) end
    MPM.SetState(ply, S.NONE)
end

hook.Add("Move", "MPM_Mantle", function(ply, mv)
    if not MPM.Active(ply) or ply:GetDTInt(DT.STATE) ~= S.MANTLE then return end
    local dur = MPM.MantleDur(ply)
    local t = MPM.StateTime(ply) / dur
    if t >= 1 then
        MPM.EndMantle(ply, mv)
        return true
    end
    local p = MPM.MantlePos(ply, t)
    local prev = mv:GetOrigin()
    mv:SetOrigin(p)
    mv:SetVelocity((p - prev) / math.max(FrameTime(), 0.001))
    return true
end)

hook.Add("OnPlayerHitGround", "MPM_HardLand", function(ply, inWater, onFloater, speed)
    if inWater or not MPM.Active(ply) then return end
    ply.MPM_LandSpeed = speed
    if MPM.CV.hardland:GetBool() and speed >= MPM.CV.hardland_speed:GetFloat() then
        ply:SetDTFloat(DT.T_HARD, CurTime())
    end
end)
