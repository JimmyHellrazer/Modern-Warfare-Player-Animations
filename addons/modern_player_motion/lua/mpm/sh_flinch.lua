local A = MPM.Anim or {}
MPM.Anim = A

local PARTS = { "head", "torso", "lleg", "rleg" }
local PART_ID = {}
for i, p in ipairs(PARTS) do PART_ID[p] = i end
local DIRS = { "fr", "bk", "le", "ri" }
local SIDES = { "center", "left", "right" }

local HITGROUP_PART = {
    [HITGROUP_HEAD] = "head",
    [HITGROUP_CHEST] = "torso", [HITGROUP_STOMACH] = "torso", [HITGROUP_GENERIC] = "torso",
    [HITGROUP_LEFTARM] = "torso", [HITGROUP_RIGHTARM] = "torso",
    [HITGROUP_LEFTLEG] = "lleg", [HITGROUP_RIGHTLEG] = "rleg",
}

function A.FlinchDir(bodyYaw, from)
    local a = math.NormalizeAngle(math.deg(math.atan2(from.y, from.x)) - bodyYaw)
    if math.abs(a) <= 45 then return 1 end
    if math.abs(a) >= 135 then return 2 end
    return a > 0 and 3 or 4
end

function A.FlinchSide(bodyYaw, ply, hitPos)
    if not hitPos then return 1 end
    local right = Angle(0, bodyYaw, 0):Right()
    local x = (hitPos - ply:GetPos()):Dot(right)
    if x > 3 then return 3 end
    if x < -3 then return 2 end
    return 1
end

local function candidates(tbl, part, dir, side, depth)
    local p = tbl[part]
    local out = {}
    local function add(k) if p and p[k] then for _, e in ipairs(p[k]) do out[#out + 1] = e end end end
    if part == "torso" then
        add(dir .. "_" .. side)
        if #out == 0 then add(dir .. "_center") end
        if #out == 0 then add(dir .. "_left") add(dir .. "_right") end
    end
    if #out == 0 then add(dir) end
    if #out == 0 then add("c") end
    if #out == 0 and (part == "lleg" or part == "rleg") then
        p = tbl.legs
        add(dir .. "_" .. side)
        if #out == 0 then add(dir .. "_center") add("fr_left") add("fr_right") add("bk_center") end
    end
    if #out == 0 and (depth or 0) < 1 then
        return candidates(tbl, part == "torso" and "head" or "torso", dir, side, 1)
    end
    return out
end

function A.PickFlinch(stance, part, dir, side)
    local pain = MPM.Clips and MPM.Clips.pain
    if not pain then return nil end
    local tbl = pain[stance] or pain.stand
    if not tbl then return nil end
    local list = candidates(tbl, part, dir, side)
    if #list == 0 then return nil end
    return list[math.random(#list)]
end

function A.FlinchStance(ply)
    if MPM.IsProneState(MPM.GetState(ply)) then return "prone" end
    return ply:Crouching() and "strafe_crouch" or "stand"
end

A.FlinchSlot = GESTURE_SLOT_VCD

if SERVER then
    util.AddNetworkString("mpm_flinch")

    hook.Add("ScalePlayerDamage", "MPM_Flinch", function(ply, hitgroup, dmg)
        if not MPM.CV.flinch:GetBool() or not MPM.Clips or not MPM.Clips.pain then return end
        if (ply.MPM_FlinchNext or 0) > CurTime() then return end
        local part = HITGROUP_PART[hitgroup] or "torso"
        local yaw = ply.MPM_BodyYaw or ply:EyeAngles().y
        local src = dmg:GetReportedPosition()
        local att = dmg:GetAttacker()
        if (not src or src:IsZero()) and IsValid(att) then src = att:WorldSpaceCenter() end
        local hitPos = dmg:GetDamagePosition()
        local from = (src and not src:IsZero()) and (src - ply:GetPos()) or -dmg:GetDamageForce()
        if from:IsZero() then from = ply:GetForward() end
        ply.MPM_FlinchNext = CurTime() + 0.15
        net.Start("mpm_flinch")
        net.WriteEntity(ply)
        net.WriteUInt(PART_ID[part], 3)
        net.WriteUInt(A.FlinchDir(yaw, from), 3)
        net.WriteUInt(A.FlinchSide(yaw, ply, (hitPos and not hitPos:IsZero()) and hitPos or nil), 2)
        net.SendPVS(ply:GetPos())
    end)
else
    local scale = CreateClientConVar("mpm_flinch_scale", "1", true, false, "How strong hit flinches look", 0, 2)

    net.Receive("mpm_flinch", function()
        local ply = net.ReadEntity()
        local part = PARTS[net.ReadUInt(3)] or "torso"
        local dir = DIRS[net.ReadUInt(3)] or "fr"
        local side = SIDES[net.ReadUInt(2)] or "center"
        if not IsValid(ply) or not ply:IsPlayer() or not ply.MPM_AnimOut then return end
        local e = A.PickFlinch(A.FlinchStance(ply), part, dir, side)
        if not e then return end
        local seq = A.SeqFor and A.SeqFor(ply, e.seq) or ply:LookupSequence(e.seq)
        if not seq or seq < 0 then return end
        ply:AddVCDSequenceToGestureSlot(A.FlinchSlot, seq, 0, true)
        ply:AnimSetGestureWeight(A.FlinchSlot, scale:GetFloat())
    end)
end
