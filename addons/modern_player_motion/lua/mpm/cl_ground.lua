local A = MPM.Anim or {}
MPM.Anim = A

local CV = {
    ik = CreateClientConVar("mpm_footik", "1", true, false, "Feet stand on the real ground (slopes, steps, edges)", 0, 1),
    lock = CreateClientConVar("mpm_footlock", "1", true, false, "Planted feet stay put while standing still", 0, 1),
    tilt = CreateClientConVar("mpm_prone_tilt", "1", true, false, "Prone body follows the slope of the ground", 0, 1),
    range = CreateClientConVar("mpm_footik_range", "1500", true, false, "No foot IK on players further than this (u)", 100, 10000),
}
A.GroundCV = CV

local LEGS = {
    { "ValveBiped.Bip01_L_Thigh", "ValveBiped.Bip01_L_Calf", "ValveBiped.Bip01_L_Foot" },
    { "ValveBiped.Bip01_R_Thigh", "ValveBiped.Bip01_R_Calf", "ValveBiped.Bip01_R_Foot" },
}
local PELVIS = "ValveBiped.Bip01_Pelvis"
local UP = Vector(0, 0, 1)
local NO_IK_SHOT = { mantle = true, slide = true, dive = true, takeoff = true }

local function ids(ply)
    local c = ply.MPM_LegIds
    if c and c.model == ply:GetModel() then return c end
    c = { model = ply:GetModel(), pelvis = ply:LookupBone(PELVIS) }
    for i, leg in ipairs(LEGS) do
        c[i] = { ply:LookupBone(leg[1]), ply:LookupBone(leg[2]), ply:LookupBone(leg[3]) }
    end
    ply.MPM_LegIds = c
    return c
end

local function translateSubtree(ent, bone, d)
    local m = ent:GetBoneMatrix(bone)
    if m then
        m:SetTranslation(m:GetTranslation() + d)
        ent:SetBoneMatrix(bone, m)
    end
    for _, ch in ipairs(ent:GetChildBones(bone) or {}) do translateSubtree(ent, ch, d) end
end

local function solveLeg(ply, leg, T)
    local su, sk, sf = leg[1], leg[2], leg[3]
    if not (su and sk and sf) then return end
    local mu, mk, mf = ply:GetBoneMatrix(su), ply:GetBoneMatrix(sk), ply:GetBoneMatrix(sf)
    if not (mu and mk and mf) then return end
    local footRot = Matrix(mf)
    local S, K, F = mu:GetTranslation(), mk:GetTranslation(), mf:GetTranslation()
    local a, b = (K - S):Length(), (F - K):Length()
    local d = math.Clamp((T - S):Length(), math.abs(a - b) + 0.01, a + b - 0.01)
    local dir = (T - S):GetNormalized()
    local pole = (K - S) - dir * (K - S):Dot(dir)
    if pole:LengthSqr() < 1e-4 then return end
    pole:Normalize()
    local cosA = math.Clamp((a * a + d * d - b * b) / (2 * a * d), -1, 1)
    local newK = S + dir * (a * cosA) + pole * (a * math.sqrt(1 - cosA * cosA))
    A.RotateSubtree(ply, su, S, A.RotBetween((K - S):GetNormalized(), (newK - S):GetNormalized()))
    local mf2 = ply:GetBoneMatrix(sf)
    if not mf2 then return end
    A.RotateSubtree(ply, sk, newK, A.RotBetween((mf2:GetTranslation() - newK):GetNormalized(), ((S + dir * d) - newK):GetNormalized()))
    local mf3 = ply:GetBoneMatrix(sf)
    if not mf3 then return end
    local cur = Matrix(mf3)
    cur:SetTranslation(vector_origin)
    footRot:SetTranslation(vector_origin)
    A.RotateSubtree(ply, sf, mf3:GetTranslation(), footRot * cur:GetInverseTR())
end

local function groundAt(ply, p, base)
    local tr = util.TraceLine({ start = Vector(p.x, p.y, base + 22), endpos = Vector(p.x, p.y, base - 26),
        mask = MASK_PLAYERSOLID_BRUSHONLY, filter = ply })
    if not tr.Hit or tr.StartSolid or tr.HitNormal.z < 0.5 then return nil end
    return tr.HitPos.z - base, tr.HitNormal
end

local function weightFor(ply, out)
    if not out or not ply:IsOnGround() then return 0 end
    local st = MPM.GetState(ply)
    if st ~= MPM.S.NONE and st ~= MPM.S.SPRINT and st ~= MPM.S.TAC then return 0 end
    if out.shot and NO_IK_SHOT[out.shot] then return 0 end
    local sp = ply:GetVelocity():Length2D()
    return math.Clamp(1 - (sp - 40) / 120, 0, 1)
end

function A.GroundSolve(ply)
    if not CV.ik:GetBool() or not A.RotateSubtree then return end
    local out = ply.MPM_AnimOut
    local now = CurTime()
    local dt = math.Clamp(now - (ply.MPM_FootT or now), 0, 0.1)
    ply.MPM_FootT = now
    local w = weightFor(ply, out)
    local eye = EyePos()
    if ply:GetPos():DistToSqr(eye) > CV.range:GetFloat() ^ 2 then w = 0 end
    ply.MPM_FootW = Lerp(math.min(1, dt * 8), ply.MPM_FootW or 0, w)
    local fw = ply.MPM_FootW
    if fw < 0.01 then ply.MPM_FootLock = nil return end
    local c = ids(ply)
    if not c.pelvis then return end
    local base = ply:GetPos().z
    local offs, feet = {}, {}
    ply.MPM_FootOff = ply.MPM_FootOff or { 0, 0 }
    for i, leg in ipairs(c) do
        local m = leg[3] and ply:GetBoneMatrix(leg[3])
        if not m then return end
        feet[i] = m:GetTranslation()
        local off = groundAt(ply, feet[i], base) or 0
        off = math.Clamp(off, -20, 20)
        ply.MPM_FootOff[i] = Lerp(math.min(1, dt * 12), ply.MPM_FootOff[i], off)
        offs[i] = ply.MPM_FootOff[i] * fw
    end
    local drop = math.Clamp(math.min(offs[1], offs[2], 0), -18, 0)
    if drop < -0.05 then translateSubtree(ply, c.pelvis, UP * drop) end

    local still = CV.lock:GetBool() and out and not out.shot and (ply.MPM_Gait == "idle" or ply.MPM_Gait == "cidle")
        and ply:GetVelocity():Length2D() < 5
    local lock = still and (ply.MPM_FootLock or {}) or nil
    for i, leg in ipairs(c) do
        local T = feet[i] + UP * offs[i]
        if lock then
            local L = lock[i]
            if not L or Vector(L.x - T.x, L.y - T.y, 0):Length() > 10 then
                lock[i] = Vector(T.x, T.y, 0)
            else
                T = Vector(L.x, L.y, T.z)
            end
        end
        if math.abs(offs[i] - drop) > 0.05 or lock then solveLeg(ply, leg, T) end
    end
    ply.MPM_FootLock = lock
end

function A.ProneTilt(ply, ang)
    if not CV.tilt:GetBool() or not MPM.IsProneState(MPM.GetState(ply)) or not ply:IsOnGround() then
        ply.MPM_Tilt = nil
        return ang
    end
    local pos = ply:GetPos()
    local f, r = ang:Forward(), ang:Right()
    local function h(p)
        local z = groundAt(ply, p, pos.z)
        return z or 0
    end
    local front, back = h(pos + f * 24), h(pos - f * 24)
    local right, left = h(pos + r * 10), h(pos - r * 10)
    local pitch = math.Clamp(-math.deg(math.atan2(front - back, 48)), -30, 30)
    local roll = math.Clamp(math.deg(math.atan2(left - right, 20)), -20, 20)
    local now = CurTime()
    local dt = math.Clamp(now - (ply.MPM_TiltT or now), 0, 0.1)
    ply.MPM_TiltT = now
    local t = ply.MPM_Tilt or { p = pitch, r = roll }
    local k = math.min(1, dt * 6)
    t.p, t.r = Lerp(k, t.p, pitch), Lerp(k, t.r, roll)
    ply.MPM_Tilt = t
    return Angle(t.p, ang.y, t.r)
end
