-- State accessors, transitions, prone hull. Everything here is predicted (player DT vars).
local DT, F, S = MPM.DT, MPM.F, MPM.S

function MPM.Active(ply)
    return MPM.CV.enabled:GetBool() and IsValid(ply) and ply:Alive()
        and ply:GetMoveType() == MOVETYPE_WALK and not ply:InVehicle() and ply:WaterLevel() < 2
end

function MPM.GetState(ply) return ply:GetDTInt(DT.STATE) end
function MPM.StateTime(ply) return CurTime() - ply:GetDTFloat(DT.T_STATE) end
function MPM.Meter(ply) return ply:GetDTFloat(DT.METER) end

function MPM.HasFlag(ply, f) return bit.band(ply:GetDTInt(DT.BTN), f) ~= 0 end

function MPM.SetFlag(ply, f, on)
    local v = ply:GetDTInt(DT.BTN)
    ply:SetDTInt(DT.BTN, on and bit.bor(v, f) or bit.band(v, bit.bnot(f)))
end

function MPM.SetState(ply, new)
    local old = ply:GetDTInt(DT.STATE)
    if old == new then return end
    ply:SetDTInt(DT.STATE, new)
    ply:SetDTFloat(DT.T_STATE, CurTime())
    if SERVER or IsFirstTimePredicted() then
        hook.Run("MPM_StateChanged", ply, old, new)
    end
end

function MPM.IsProneState(st)
    return st == S.PRONE_IN or st == S.PRONE or st == S.PRONE_OUT
end

-- Prone hull --------------------------------------------------------------------------------------------
-- Prone is the engine duck with a lower duck hull. The gamemode's own duck hull / eye height are remembered
-- whenever we're not prone, and put back on the way out.

local function saveDefaults(ply)
    local mins, maxs = ply:GetHullDuck()
    ply.MPM_Def = { mins = mins, maxs = maxs, view = ply:GetViewOffsetDucked() }
end

function MPM.DefaultDuck(ply)
    if not ply.MPM_Def then saveDefaults(ply) end
    return ply.MPM_Def
end

function MPM.ApplyHull(ply, prone)
    if prone then
        if ply.MPM_ProneHull then return end
        if not ply.MPM_Def then saveDefaults(ply) end
        local d = ply.MPM_Def
        local h = MPM.CV.prone_height:GetFloat()
        ply:SetHullDuck(d.mins, Vector(d.maxs.x, d.maxs.y, d.mins.z + h))
        ply:SetViewOffsetDucked(Vector(0, 0, MPM.CV.prone_view:GetFloat()))
        ply.MPM_ProneHull = true
    else
        if not ply.MPM_ProneHull then
            saveDefaults(ply) -- track gamemode changes while not prone
            return
        end
        local d = ply.MPM_Def
        ply:SetHullDuck(d.mins, d.maxs)
        ply:SetViewOffsetDucked(d.view)
        ply.MPM_ProneHull = false
    end
end

-- Is there room for this hull at the player's position?
function MPM.HullFits(ply, mins, maxs)
    local pos = ply:GetPos()
    local tr = util.TraceHull({
        start = pos, endpos = pos + Vector(0, 0, 1),
        mins = mins, maxs = maxs, mask = MASK_PLAYERSOLID, filter = ply,
    })
    return not tr.StartSolid and not tr.AllSolid
end

function MPM.CanStand(ply)
    local mins, maxs = ply:GetHull()
    return MPM.HullFits(ply, mins, maxs)
end

function MPM.CanCrouch(ply)
    local d = MPM.DefaultDuck(ply)
    return MPM.HullFits(ply, d.mins, d.maxs)
end

-- Full reset (death, spawn, noclip, ladder, vehicle, water).
function MPM.Reset(ply)
    if ply:GetDTInt(DT.STATE) ~= S.NONE then MPM.SetState(ply, S.NONE) end
    local v = ply:GetDTInt(DT.BTN)
    ply:SetDTInt(DT.BTN, bit.band(v, MPM.BTN_MASK))
    MPM.ApplyHull(ply, false)
end

hook.Add("PlayerSpawn", "MPM_Reset", function(ply)
    MPM.Reset(ply)
    ply:SetDTFloat(DT.METER, MPM.CV.tac_time:GetFloat())
    ply:SetDTFloat(DT.SPEED, 0)
end)
