-- Gun placement + hands (client). v0.10.0 rework.
--
-- PLACEMENT: MW's own model, not MW Base's hand-tuned offset. MW Base's world models are MW's gun models (rooted on the
-- right hand bone, gun body on tag_sling / tag_pistol_offset, bonemerged to the player). The gun goes where MW puts it:
--   held        right hand * J * T(gt)   J = MW's gun bone (j_gun) under the right hand for the current hold / action
--               (baked: gunhold_<st> / gunads_<st>, entry.gun), gt = the model's origin in j_gun's frame, solved per gun
--               so MW's right wrist lands on the model's own tag_ik_loc_ri (pistols: estimated from the ejection port).
--   let go      where MW's clip has the gun relative to the right CLAVICLE (entry.gunc: MW's MP gun chain hangs off it),
--               when the clip's gun moves off MW's grip (LMG lids, charging handles, the 725's reload, draws from the
--               back / sling) - blended in by how far off the grip it is.
-- Applied by setting MW Base's WorldModelOffsets for its own RenderOverride, from the player's bones of THIS frame.
--
-- HANDS (player BuildBonePositions): the left hand goes onto the gun - MW's tag_ik_loc_le, or a fitted grip's mount with
-- MW's hand rotation for that grip (vertical / side; angled keeps the clip's) - and MW's finger poses go on whichever
-- hand holds the gun (right: whenever the gun is in it; left: with the IK).
if not MPM or not MPM.Anim then return end
local A = MPM.Anim

local CV = {
    place  = CreateClientConVar("mpm_gun_track", "1", true, false, "Place MW Base guns where MW does (grip + gun bone)"),
    ik     = CreateClientConVar("mpm_gun_ik", "1", true, false, "Left hand IK onto the gun's grip"),
    fing   = CreateClientConVar("mpm_gun_fingers", "1", true, false, "MW's per-gun finger poses on the hands holding the gun"),
    calpos = CreateClientConVar("mpm_gun_cal_pos", "0 0 0", true, false, "Gun calibration offset (fwd left up, gun space)"),
    calang = CreateClientConVar("mpm_gun_cal_ang", "0 0 0", true, false, "Gun calibration rotation (p y r)"),
    pical  = CreateClientConVar("mpm_gun_cal_pistol", "0 0 0", true, false, "Extra offset for pistols (estimated grips)"),
    lod    = CreateClientConVar("mpm_gun_ik_dist", "1500", true, false, "No hand IK beyond this distance"),
    ikfull = CreateClientConVar("mpm_gun_ik_reach", "8", true, false, "Left hand within this of the grip: full IK"),
    ikfade = CreateClientConVar("mpm_gun_ik_fade", "8", true, false, "...fading out over this much further away"),
    rik    = CreateClientConVar("mpm_gun_rik", "1", true, false, "Right hand IK onto MW's real grip (the hold clips bend the wrist)"),
    adsal  = CreateClientConVar("mpm_gun_ads_align", "1", true, false, "ADS: line the sight (optic / hybrid alternate) up with the eye"),
    adsmax = CreateClientConVar("mpm_gun_ads_max", "4", true, false, "ADS alignment: most the gun moves (u)"),
    cache  = CreateClientConVar("mpm_ik_cache", "1", true, false, "Solve the IK once per frame and reuse it for the other render passes"),
    gripvert = CreateClientConVar("mpm_gun_grip_vert", "-5.44 -0.17 -2.04", true, false, "Left wrist on a vertical grip (fwd left up)"),
    gripang  = CreateClientConVar("mpm_gun_grip_ang", "-1.8 1.6 -1.6", true, false, "Left wrist on an angled grip (fwd left up)"),
    gripside = CreateClientConVar("mpm_gun_grip_side", "-1.5 3 0.8", true, false, "Left wrist on a side grip (fwd left up)"),
}

local function vecOf(s)
    local x, y, z = string.match(s or "", "([%-%d%.]+)%s+([%-%d%.]+)%s+([%-%d%.]+)")
    return tonumber(x) or 0, tonumber(y) or 0, tonumber(z) or 0
end
local function cvVec(cv) return Vector(vecOf(cv:GetString())) end
local function cvAng(cv) local p, y, r = vecOf(cv:GetString()) return Angle(p, y, r) end

local function gunEntry(wep)
    return MPM.Guns and A.GunKey and MPM.Guns[A.GunKey(wep) or ""]
end

local function rotOf(ang)
    local m = Matrix()
    m:SetAngles(ang)
    return m
end

local function angDiff(a, b)
    return math.max(math.abs(math.AngleDifference(a.p, b.p)), math.abs(math.AngleDifference(a.y, b.y)),
        math.abs(math.AngleDifference(a.r, b.r)))
end

-- tag_sling's rest under the hand bone (pos parent space, angles), read once per model while MW Base's own offset is on
local slingRest = {}
local function slingRestOf(wep, boneName, g)
    -- v0.10.2: measured right after every draw against the exact offset that draw used (wrapRender), so it can't go
    -- stale. (The model's bind pose is NOT the rest: the world models' own idle sequence turns tag_sling - M4 / MG34 /
    -- 725 by 90 deg, which is why MW Base's per-gun offsets differ by 90 deg - v0.10.1's baked srest broke those guns;
    -- v0.10.0's once-per-model live read could catch a stale frame.)
    if wep.MPM_RestM then return wep.MPM_RestM end
    local key = wep:GetModel() .. "|" .. boneName
    local r = slingRest[key]
    if r ~= nil then return r or nil end
    local b = wep:LookupBone(boneName)
    local par = b and wep:GetBoneParent(b)
    local bm, pm = b and wep:GetBoneMatrix(b), par and par >= 0 and wep:GetBoneMatrix(par)
    if not (bm and pm) then return nil end -- not set up yet: try again next frame
    local loc = pm:GetInverseTR() * bm
    local mm = rotOf(wep:GetManipulateBoneAngles(b))
    r = { pos = loc:GetTranslation() - wep:GetManipulateBonePosition(b), ang = (loc * mm:GetInverseTR()):GetAngles() }
    slingRest[key] = r
    return r
end

-- MW's gun bone under the right hand for the hold (stance, hip -> ADS)
local function holdOff(g)
    if g.MPM_HoldOff ~= nil then return g.MPM_HoldOff end
    g.MPM_HoldOff = false
    local h, j = g.gunhold_stand, g.jg
    if h and j then
        local a, b = Angle(h[4], h[5], h[6]), Angle(j[4], j[5], j[6])
        local f = math.deg(math.acos(math.Clamp(a:Forward():Dot(b:Forward()), -1, 1)))
        local u = math.deg(math.acos(math.Clamp(a:Up():Dot(b:Up()), -1, 1)))
        g.MPM_HoldOff = math.max(f, u) > 60
    end
    return g.MPM_HoldOff
end

local function holdJ(ply, g)
    if holdOff(g) then
        local j = g.jg
        return Vector(j[1], j[2], j[3]), Angle(j[4], j[5], j[6])
    end
    local st = A.Stance(ply)
    local h = g["gunhold_" .. st] or g.gunhold_stand
    if not h then return nil end
    local p, a = Vector(h[1], h[2], h[3]), Angle(h[4], h[5], h[6])
    local d = g["gunads_" .. st] or (st == "stand" and nil or g.gunads_stand)
    local f = d and A.AdsAmount and A.AdsAmount(ply) or 0
    if d and f > 0 then
        p = LerpVector(f, p, Vector(d[1], d[2], d[3]))
        a = LerpAngle(f, a, Angle(d[4], d[5], d[6]))
    end
    return p, a
end

local BONE_RH, BONE_RC = "ValveBiped.Bip01_R_Hand", "ValveBiped.Bip01_R_Clavicle"

-- The gun's world pos / ang (tag_sling) from the player's current bones, plus how much it hangs off the body (0..1) and
-- the action weight. nil when this gun has no calibration (MW Base's own placement then).
function A.GunWorld(ply, wep, g)
    g = g or gunEntry(wep)
    if not (g and g.gt and CV.place:GetBool()) then return nil end
    local hb = ply:LookupBone(BONE_RH)
    local hm = hb and ply:GetBoneMatrix(hb)
    if not hm then return nil end
    local jp, ja = holdJ(ply, g)
    if not jp then return nil end
    local bodyW, actW, cp, ca = 0, 0, nil, nil
    local a = ply.MPM_Act
    local e = a and a.entry
    if e and e.gun and #e.gun >= 12 and a.gun == A.GunKey(wep) then
        local c = math.Clamp((CurTime() - a.t0) / a.dur, 0, 1)
        local w = A.ActionWeight(c, a.dur, a.nofadein, a.chain)
        if a.cut then w = w * math.Clamp(1 - (CurTime() - a.cut) / 0.12, 0, 1) end
        local frames = math.floor(e.dur * 30 + 1.5)
        local tp, ta = A.TrackAt(e.gun, c, frames)
        if tp and w > 0 then
            actW = w
            if e.gunc and e.lg then
                -- MW's right hand let go of the gun (baked against MW's REAL grip - v0.10.0 compared with the hold's bent
                -- wrist, so most reloads / draws hung off the shoulder start to finish): it hangs where MW's chain has it
                local jw = A.ScalarAt(e.lg, c, frames)
                -- a draw ends with the gun in the hand (MW's idle takes it from there): let-go eases out over the last
                -- 15 %, or guns whose draw ends a few degrees off MW's grip snapped from the shoulder to the hand
                if a.kind == "raise" or a.kind == "draw" or a.kind == "drawc" then
                    jw = jw * math.Clamp((1 - c) / 0.15, 0, 1)
                end
                if jw > 0.001 then
                    cp, ca = A.TrackAt(e.gunc, c, frames)
                    if cp then bodyW = jw * w end
                end
            end
            jp, ja = LerpVector(w, jp, tp), LerpAngle(w, ja, ta)
        end
    end
    local gp, ga = LocalToWorld(jp, ja, hm:GetTranslation(), hm:GetAngles())
    -- bolt / pump cycles: the RIGHT hand leaves the grip to work the bolt and the LEFT hand holds the gun - it hangs
    -- off the left hand by MW's left grip (jl) instead of riding the bolt hand (v0.10.5: "a major shake on the hand
    -- holding the gun")
    if e and a.kind == "rech" and g.jl and actW > 0 then
        local lb = ply:LookupBone("ValveBiped.Bip01_L_Hand")
        local lm = lb and ply:GetBoneMatrix(lb)
        if lm then
            local ip, ia = WorldToLocal(vector_origin, angle_zero, Vector(g.jl[1], g.jl[2], g.jl[3]), Angle(g.jl[4], g.jl[5], g.jl[6]))
            local lp, la = LocalToWorld(ip, ia, lm:GetTranslation(), lm:GetAngles())
            gp, ga = LerpVector(actW, gp, lp), LerpAngle(actW, ga, la)
        end
    end
    if bodyW > 0 then
        local cb = ply:LookupBone(BONE_RC)
        local cm = cb and ply:GetBoneMatrix(cb)
        if cm then
            local bp, ba = LocalToWorld(cp, ca, cm:GetTranslation(), cm:GetAngles())
            gp, ga = LerpVector(bodyW, gp, bp), LerpAngle(bodyW, ga, ba)
        else
            bodyW = 0
        end
    end
    -- j_gun -> the model's origin (gt), then the user's nudges
    local t = Vector(g.gt[1], g.gt[2], g.gt[3])
    -- MWII-clip guns: their holds are on MW19's rig (gun bone elsewhere on the gun) - the hold's own calibration,
    -- crossfaded with the action
    if g.gth then t = LerpVector(actW, Vector(g.gth[1], g.gth[2], g.gth[3]), t) end
    t = t + cvVec(CV.calpos)
    if g.cls == "pi" then t = t + cvVec(CV.pical) end
    local wp, wa = LocalToWorld(t, cvAng(CV.calang), gp, ga) -- the model's origin sits at +gt in j_gun's frame
    local ap, aa = A.SightAlign(ply, wep, g, wp, wa)
    if ap then
        wp, wa = ap, aa
        gp, ga = LocalToWorld(-t, angle_zero, wp, wa)
    end
    return wp, wa, bodyW, actW, hm, gp, ga
end

-- a per-sample scalar track (every 2 frames, like the gun tracks) at cycle c
function A.ScalarAt(tr, c, frames)
    local n = #tr
    if n < 1 then return 0 end
    local x = c * ((frames or 2) - 1) / 2
    local i = math.Clamp(math.floor(x), 0, n - 1)
    local j = math.min(i + 1, n - 1)
    local f = math.Clamp(x - i, 0, 1)
    return tr[i + 1] + (tr[j + 1] - tr[i + 1]) * f
end

-- ADS: line the sight up with the eye. MW's third-person ADS is one pose per gun (authored round its iron sights), so
-- a taller optic sat above the eye line; this moves the gun (up / down / sideways in its own frame, at most
-- mpm_gun_ads_max) so the optic's reticle point is in front of the eye, and for hybrids whose alternate sight is CANTED
-- (offset sideways) it rolls the gun so that sight comes up - by how far round it sits, so inline flip-up magnifiers
-- don't roll. Weighted by MW Base's aim delta and, for the alternate, its aim-mode delta. Hands follow via the IK.
local eyeOff = {}
local function eyePos(ply)
    local hb = ply:LookupBone("ValveBiped.Bip01_Head1")
    local hm = hb and ply:GetBoneMatrix(hb)
    local off = eyeOff[ply:GetModel()]
    if not (hm and off) then return nil end
    return LocalToWorld(off, angle_zero, hm:GetTranslation(), hm:GetAngles())
end
hook.Add("PrePlayerDraw", "MPM_EyeOffset", function(ply)
    local mdl = ply:GetModel()
    if eyeOff[mdl] then return end
    local id = ply:LookupAttachment("eyes")
    local at = id and id > 0 and ply:GetAttachment(id)
    local hb = ply:LookupBone("ValveBiped.Bip01_Head1")
    local hm = hb and ply:GetBoneMatrix(hb)
    if at and hm then eyeOff[mdl] = WorldToLocal(at.Pos, angle_zero, hm:GetTranslation(), hm:GetAngles()) end
end)

-- a sight's reticle point in the gun's frame (from the optic model as last drawn, re-expressed against the gun then)
local function sightLocal(wep, sight, name)
    local tp = sight and sight.m_TpModel
    if not (IsValid(tp) and name) then return nil end
    local id = tp:LookupAttachment(name)
    local at = id and id > 0 and tp:GetAttachment(id)
    local bone = (wep.MPM_OrigWMO or wep.WorldModelOffsets or {}).Bone or "tag_sling"
    local sb = wep:LookupBone(bone)
    local ms = sb and wep:GetBoneMatrix(sb)
    if not (at and ms) then return nil end
    return WorldToLocal(at.Pos, angle_zero, ms:GetTranslation(), ms:GetAngles())
end

local function rollX(th)
    local c, s = math.cos(th), math.sin(th)
    return Matrix({ { 1, 0, 0, 0 }, { 0, c, -s, 0 }, { 0, s, c, 0 }, { 0, 0, 0, 1 } })
end

function A.SightAlign(ply, wep, g, wp, wa)
    if not CV.adsal:GetBool() then return nil end
    local f = A.AdsAmount and A.AdsAmount(ply) or 0
    if f < 0.01 or not wep.GetSight then return nil end
    local sight = wep:GetSight()
    if not sight then return nil end -- iron sights: MW's own ADS pose
    local s1 = sightLocal(wep, sight, sight.Reticle and sight.Reticle.Attachment or "reticle")
    local s2 = sight.ReticleHybrid and sightLocal(wep, sight, sight.ReticleHybrid.Attachment)
    local amd = (s2 and wep.GetAimModeDelta) and math.Clamp(wep:GetAimModeDelta() or 0, 0, 1) or 0
    if not s1 and not s2 then return nil end
    s1 = s1 or s2
    local eye = eyePos(ply)
    if not eye then return nil end
    local e = WorldToLocal(eye, angle_zero, wp, wa)
    -- canted alternate: roll so it comes round toward the eye (0 for an inline magnifier sitting on top)
    local th = 0
    if s2 and amd > 0 then
        local want = math.atan2(e.z, e.y)
        local have = math.atan2(s2.z, s2.y)
        th = math.Clamp(math.NormalizeAngle(math.deg(want - have)), -60, 60) * amd * f
    end
    local R = rollX(math.rad(th))
    local sa = R * s1
    if s2 then sa = LerpVector(amd, sa, R * s2) end
    local d = Vector(0, e.y - sa.y, e.z - sa.z)
    local mx = CV.adsmax:GetFloat()
    if d:Length() > mx then d = d:GetNormalized() * mx end
    local M = Matrix()
    M:SetTranslation(wp)
    M:SetAngles(wa)
    local T = Matrix()
    T:SetTranslation(d * f)
    local out = M * T * R
    return out:GetTranslation(), out:GetAngles()
end

-- MW Base's offsets for this frame's gun pose (bone-manipulation conventions: position in the parent = the hand bone's
-- frame, angles post-multiplied on the bone's rest)
local function applyPlacement(wep, ply)
    local g = gunEntry(wep)
    local base = wep.MPM_OrigWMO or wep.WorldModelOffsets
    if not (base and ply.MPM_AnimOut) then return false end
    local bone = base.Bone or "tag_sling"
    local rest = slingRestOf(wep, bone, g)
    if not rest then return false end
    -- the gun as computed in the bone callback BEFORE the right hand was pulled onto its grip (the model hangs off the
    -- hand bone, so it's placed relative to the hand as it ends up)
    local gw = ply.MPM_GW
    local hb = ply:LookupBone(BONE_RH)
    local hm = hb and ply:GetBoneMatrix(hb)
    if not hm then return false end
    local wp, wa
    if gw and gw.lp then
        wp, wa = LocalToWorld(gw.lp, gw.la, hm:GetTranslation(), hm:GetAngles())
    elseif gw and gw.f == FrameNumber() then
        wp, wa = gw.wp, gw.wa
    else
        wp, wa = A.GunWorld(ply, wep, g)
    end
    if not wp then return false end
    local fp, fa = hm:GetTranslation(), hm:GetAngles()
    if rest.ppos then fp, fa = LocalToWorld(rest.ppos, rest.pang, fp, fa) end -- the placement bone's real parent
    local lp, la = WorldToLocal(wp, wa, fp, fa)
    local ang = (rotOf(rest.ang):GetInverseTR() * rotOf(la)):GetAngles()
    if wep.MPM_OrigWMO == nil then wep.MPM_OrigWMO = wep.WorldModelOffsets end
    wep.WorldModelOffsets = { Bone = bone, Pos = lp - rest.pos, Angles = ang }
    return true
end

local function restore(wep)
    if wep.MPM_OrigWMO ~= nil then
        wep.WorldModelOffsets = wep.MPM_OrigWMO
        wep.MPM_OrigWMO = nil
    end
end

-- old placement (guns without a calibration): MW Base's offset times MW's motion since the clip's first frame
function A.GunLocal(ply, wep)
    local base = wep.MPM_OrigWMO or wep.WorldModelOffsets
    if not (base and base.Pos and base.Angles) then return nil end
    local dp, da, w = vector_origin, angle_zero, 0
    if CV.place:GetBool() and A.GunDelta then dp, da, w = A.GunDelta(ply, wep) end
    local rest = slingRestOf(wep, base.Bone or "tag_sling")
    if not rest then
        local p, a = LocalToWorld(dp, da, base.Pos, base.Angles)
        return p, a, w
    end
    local mr, ma, md = rotOf(rest.ang), rotOf(base.Angles), rotOf(da)
    local frame = (mr * ma):GetAngles()
    return base.Pos + LocalToWorld(dp, angle_zero, vector_origin, frame), (ma * md):GetAngles(), w
end

-- MW Base draws the world model in its RenderOverride: set the offsets right before, from this frame's bones
local function wrapRender(wep)
    if not wep.RenderOverride or wep.RenderOverride == wep.MPM_ROFn then return end
    if wep.MPM_ROFn then
        wep.MPM_OrigWMO, wep.MPM_RestM, wep.MPM_GripMount = nil, nil, nil
    end
    local orig = wep.RenderOverride
    wep.MPM_RO = true
    wep.RenderOverride = function(self, flags)
        local ply = self:GetOwner()
        if IsValid(ply) and ply:IsPlayer() and ply:GetActiveWeapon() == self and ply.MPM_AnimOut then
            ply:SetupBones()
            if not applyPlacement(self, ply) then
                local g = gunEntry(self)
                if g and g.gt then restore(self) end
            end
            -- (v0.10.5) the hand IK reads the gun's / attachments' bones earlier in the frame, which caches them from
            -- LAST frame's placement; MW Base re-sets the bones without clearing that cache (its InvalidateBoneCache is
            -- commented out) - the gun and its bonemerged attachments (barrels, suppressors, optics) drew stale, apart
            -- from the receiver and lagging when turning / shooting
            self:InvalidateBoneCache()
            if self.GetAllAttachmentsInUse then
                for _, att in pairs(self:GetAllAttachmentsInUse() or {}) do
                    if IsValid(att.m_TpModel) then att.m_TpModel:InvalidateBoneCache() end
                end
            end
        end
        local r = orig(self, flags)
        if A.GripMountOf then self.MPM_GripMount = A.GripMountOf(self) end
        -- the rest under the hand as this draw posed it: (parent^-1 * bone) with this draw's manipulation taken off
        local base = self.MPM_OrigWMO or self.WorldModelOffsets
        local b = base and self:LookupBone(base.Bone or "tag_sling")
        local par = b and self:GetBoneParent(b)
        local bm, pm = b and self:GetBoneMatrix(b), par and par >= 0 and self:GetBoneMatrix(par)
        if bm and pm then
            local loc = pm:GetInverseTR() * bm
            local mm = rotOf(self:GetManipulateBoneAngles(b))
            local rest = { pos = loc:GetTranslation() - self:GetManipulateBonePosition(b),
                           ang = (loc * mm:GetInverseTR()):GetAngles() }
            -- and the bone's PARENT relative to the player's right hand: not always the hand (the MG34's tag_sling hangs
            -- off ValveBiped.Anim_Attachment_RH, turned against the hand - it came out 90 deg off, v0.10.2)
            local hb = IsValid(ply) and ply:LookupBone(BONE_RH)
            local hm = hb and ply:GetBoneMatrix(hb)
            if hm then
                rest.ppos, rest.pang = WorldToLocal(pm:GetTranslation(), pm:GetAngles(), hm:GetTranslation(), hm:GetAngles())
            end
            self.MPM_RestM = rest
        end
        return r
    end
    wep.MPM_ROFn = wep.RenderOverride
end

hook.Add("PrePlayerDraw", "MPM_GunPlace", function(ply)
    local wep = ply:GetActiveWeapon()
    if not IsValid(wep) or not wep.WorldModelOffsets then return end
    wrapRender(wep)
    local g = gunEntry(wep)
    if not (CV.place:GetBool() and ply.MPM_AnimOut) then restore(wep) return end
    if g and g.gt then return end -- placed in the render override (this frame's bones)
    local pos, ang = A.GunLocal(ply, wep)
    if not pos then restore(wep) return end
    if wep.MPM_OrigWMO == nil then wep.MPM_OrigWMO = wep.WorldModelOffsets end
    wep.WorldModelOffsets = { Bone = wep.MPM_OrigWMO.Bone or "tag_sling", Pos = pos, Angles = ang }
end)

-- hands -----------------------------------------------------------------------------------------------------------------

-- rotate a bone and its whole subtree by matrix D (rotation) about a pivot
local function rotateSubtree(ent, bone, pivot, D)
    local m = ent:GetBoneMatrix(bone)
    if m then
        local p = m:GetTranslation()
        local r = D * m
        r:SetTranslation(pivot + D * (p - pivot))
        ent:SetBoneMatrix(bone, r)
    end
    for _, ch in ipairs(ent:GetChildBones(bone) or {}) do rotateSubtree(ent, ch, pivot, D) end
end

-- rotation taking direction a to b (unit vectors)
local function rotBetween(a, b)
    local axis = a:Cross(b)
    local s = axis:Length()
    local c = a:Dot(b)
    if s < 1e-6 then return Matrix() end
    axis:Normalize()
    -- Rodrigues as a matrix
    local x, y, z = axis.x, axis.y, axis.z
    local t = 1 - c
    return Matrix({
        { t * x * x + c, t * x * y - s * z, t * x * z + s * y, 0 },
        { t * x * y + s * z, t * y * y + c, t * y * z - s * x, 0 },
        { t * x * z - s * y, t * y * z + s * x, t * z * z + c, 0 },
        { 0, 0, 0, 1 } })
end

A.RotateSubtree = rotateSubtree
A.RotBetween = rotBetween

-- a grip's mount (tag_grip_attach) in the gun's frame: on the gun, or on the barrel / handguard attachment carrying it
local function tagInGun(wep, sb, ent, name)
    local b = ent:LookupBone(name)
    if not b then return nil end
    local mt, ms = ent:GetBoneMatrix(b), wep:GetBoneMatrix(sb)
    if not (mt and ms) then return nil end
    return ms:GetInverseTR() * mt
end

local function gripMount(wep, sb)
    local m = tagInGun(wep, sb, wep, "tag_grip_attach")
    if m then return m end
    if wep.GetAllAttachmentsInUse then
        for _, att in pairs(wep:GetAllAttachmentsInUse() or {}) do
            local tp = att.m_TpModel
            if IsValid(tp) then
                local mm = tagInGun(wep, sb, tp, "tag_grip_attach")
                if mm then return mm end
            end
        end
    end
    return nil
end

function A.GripMountOf(wep)
    local base = wep.MPM_OrigWMO or wep.WorldModelOffsets
    local sb = base and wep:LookupBone(base.Bone or "tag_sling")
    return sb and gripMount(wep, sb) or nil
end

-- hand rotations on grips (ValveBiped left hand: +x wrist -> knuckles, index side +z, palm toward -y), from the gun axes
local function handFrame(X, Z)
    X = X - Z * X:Dot(Z)
    X:Normalize()
    local Y = Z:Cross(X)
    local m = Matrix()
    m:SetForward(X)
    m:SetRight(-Y)
    m:SetUp(Z)
    return m
end
local function gripHandRot(kind, ga)
    local F, U, Rt = ga:Forward(), ga:Up(), ga:Right()
    if kind == "vert" or kind == "vertpro" then
        -- knuckles forward and a little round to the right, index on top, palm onto the grip's left side (TIF 0.19.5)
        return handFrame(F * 0.93 + Rt * 0.36, U)
    elseif kind == "side" then
        -- over the top of a handle sticking out to the left: knuckles forward, index toward the gun, palm down
        return handFrame(F * 0.95 - U * 0.3, Rt)
    end
    return nil
end

local GRIP_CV = { vert = CV.gripvert, vertpro = CV.gripvert, ang = CV.gripang, side = CV.gripside }
-- the left hand's target (world pos, world rotation Matrix or nil = keep the clip's) on this gun
local function leftTarget(ply, wep, g, wp, wa)
    local bone = (wep.MPM_OrigWMO or wep.WorldModelOffsets).Bone or "tag_sling"
    local sb = wep:LookupBone(bone)
    if not sb then return nil end
    local v = (A.GripVariant and A.GripVariant(wep.MPM_Grip)) or g.integ
    -- MW's real left hand on the gun (v0.10.4: from MW's draw / reload end frames; the hold clips bend the left wrist
    -- 30-63 deg off it, so the hand turned "wrong" as a draw handed over to the idle)
    local mwPos, mwRot
    if g.jl and g.gt then
        local jp, ja = LocalToWorld(Vector(-g.gt[1], -g.gt[2], -g.gt[3]), angle_zero, wp, wa)
        local lp, la = LocalToWorld(Vector(g.jl[1], g.jl[2], g.jl[3]), Angle(g.jl[4], g.jl[5], g.jl[6]), jp, ja)
        mwPos, mwRot = lp, rotOf(la)
    end
    if not v and g.lhg then
        -- MW puts this gun's left hand where MW Base's tag isn't (the AK's 3P magwell hold): MW's own clips' spot
        return LocalToWorld(Vector(g.lhg[1], g.lhg[2], g.lhg[3]), angle_zero, wp, wa), mwRot, nil
    end
    local gm = GRIP_CV[v or ""] and (wep.MPM_GripMount or gripMount(wep, sb))
    local gunM = Matrix()
    gunM:SetTranslation(wp)
    gunM:SetAngles(wa)
    if gm then
        local off = cvVec(GRIP_CV[v])
        local mw = gunM * gm
        local p = LocalToWorld(off, angle_zero, mw:GetTranslation(), mw:GetAngles())
        return p, gripHandRot(v, wa) or mwRot, v, mw
    end
    if v and v ~= "ang" and v ~= "gl" then mwRot = nil end -- (grips above build their own hand)
    local le = tagInGun(wep, sb, wep, "tag_ik_loc_le")
    if le then return (gunM * le):GetTranslation(), mwRot, nil end
    -- no grip tag (pistols): where MW's own clips have the left hand on the gun
    if mwPos then return mwPos, mwRot, nil end
    return nil
end

local L_ARM = { "ValveBiped.Bip01_L_UpperArm", "ValveBiped.Bip01_L_Forearm", "ValveBiped.Bip01_L_Hand" }
local R_ARM = { "ValveBiped.Bip01_R_UpperArm", "ValveBiped.Bip01_R_Forearm", "ValveBiped.Bip01_R_Hand" }
local function boneIds(ply, key, names)
    local ids = ply[key]
    if not ids or ids.model ~= ply:GetModel() then
        ids = { model = ply:GetModel() }
        for i, n in ipairs(names) do ids[i] = ply:LookupBone(n) or false end
        ply[key] = ids
    end
    return ids
end

-- rotation blending through quaternions (v0.10.3: LerpAngle - per-component Euler blending - took odd paths between
-- distant rotations: fingers / the hand corkscrewed mid-fade)
local function m2q(m)
    local a, b, c = m:GetField(1, 1), m:GetField(2, 2), m:GetField(3, 3)
    local t = a + b + c
    local w, x, y, z
    if t > 0 then
        local r = math.sqrt(1 + t) * 2
        w, x, y, z = 0.25 * r, (m:GetField(3, 2) - m:GetField(2, 3)) / r, (m:GetField(1, 3) - m:GetField(3, 1)) / r,
            (m:GetField(2, 1) - m:GetField(1, 2)) / r
    elseif a > b and a > c then
        local r = math.sqrt(1 + a - b - c) * 2
        w, x, y, z = (m:GetField(3, 2) - m:GetField(2, 3)) / r, 0.25 * r, (m:GetField(1, 2) + m:GetField(2, 1)) / r,
            (m:GetField(1, 3) + m:GetField(3, 1)) / r
    elseif b > c then
        local r = math.sqrt(1 + b - a - c) * 2
        w, x, y, z = (m:GetField(1, 3) - m:GetField(3, 1)) / r, (m:GetField(1, 2) + m:GetField(2, 1)) / r, 0.25 * r,
            (m:GetField(2, 3) + m:GetField(3, 2)) / r
    else
        local r = math.sqrt(1 + c - a - b) * 2
        w, x, y, z = (m:GetField(2, 1) - m:GetField(1, 2)) / r, (m:GetField(1, 3) + m:GetField(3, 1)) / r,
            (m:GetField(2, 3) + m:GetField(3, 2)) / r, 0.25 * r
    end
    return w, x, y, z
end
local function q2m(w, x, y, z)
    return Matrix({
        { 1 - 2 * (y * y + z * z), 2 * (x * y - z * w), 2 * (x * z + y * w), 0 },
        { 2 * (x * y + z * w), 1 - 2 * (x * x + z * z), 2 * (y * z - x * w), 0 },
        { 2 * (x * z - y * w), 2 * (y * z + x * w), 1 - 2 * (x * x + y * y), 0 },
        { 0, 0, 0, 1 } })
end
-- rotation part of a toward b by t (0..1), as a rotation-only Matrix
local function slerpRot(a, b, t)
    if t >= 0.999 then local r = Matrix(b) r:SetTranslation(vector_origin) return r end
    local aw, ax, ay, az = m2q(a)
    local bw, bx, by, bz = m2q(b)
    local d = aw * bw + ax * bx + ay * by + az * bz
    if d < 0 then bw, bx, by, bz, d = -bw, -bx, -by, -bz, -d end
    local k0, k1
    if d > 0.9995 then
        k0, k1 = 1 - t, t
    else
        local th = math.acos(d)
        local sn = math.sin(th)
        k0, k1 = math.sin((1 - t) * th) / sn, math.sin(t * th) / sn
    end
    local w, x, y, z = aw * k0 + bw * k1, ax * k0 + bx * k1, ay * k0 + by * k1, az * k0 + bz * k1
    local n = math.sqrt(w * w + x * x + y * y + z * z)
    return q2m(w / n, x / n, y / n, z / n)
end
A.SlerpRot = slerpRot

-- two-bone solve of the left arm toward T (elbow keeps its bend plane), then the hand turned toward rot (weight w)
local function solveArm(ply, T, rot, w, right)
    local ids = right and boneIds(ply, "MPM_RIKBones", R_ARM) or boneIds(ply, "MPM_IKBones", L_ARM)
    local su, sf, sh = ids[1], ids[2], ids[3]
    if not (su and sf and sh) then return end
    local mu, mf, mh = ply:GetBoneMatrix(su), ply:GetBoneMatrix(sf), ply:GetBoneMatrix(sh)
    if not (mu and mf and mh) then return end
    local S, E, H = mu:GetTranslation(), mf:GetTranslation(), mh:GetTranslation()
    local a, b = (E - S):Length(), (H - E):Length()
    local d = math.Clamp((T - S):Length(), math.abs(a - b) + 0.01, a + b - 0.01)
    local dir = (T - S):GetNormalized()
    local pole = (E - S) - dir * (E - S):Dot(dir)
    if pole:LengthSqr() < 1e-4 then return end
    pole:Normalize()
    local cosA = math.Clamp((a * a + d * d - b * b) / (2 * a * d), -1, 1)
    local newE = S + dir * (a * cosA) + pole * (a * math.sqrt(1 - cosA * cosA))
    rotateSubtree(ply, su, S, rotBetween((E - S):GetNormalized(), (newE - S):GetNormalized()))
    local mh2 = ply:GetBoneMatrix(sh)
    if mh2 then
        local want = S + dir * d
        rotateSubtree(ply, sf, newE, rotBetween((mh2:GetTranslation() - newE):GetNormalized(), (want - newE):GetNormalized()))
    end
    if rot then
        local mh3 = ply:GetBoneMatrix(sh)
        if mh3 then
            local curR = Matrix(mh3)
            curR:SetTranslation(vector_origin)
            local D = slerpRot(curR, rot, w) * curR:GetInverseTR()
            rotateSubtree(ply, sh, mh3:GetTranslation(), D)
        end
    end
end

-- MW's finger pose (local rotations, baked from the hold) blended onto a hand's fingers
local R_F, L_F = {}, {}
for a = 0, 4 do
    for _, s in ipairs({ "", "1", "2" }) do
        R_F[#R_F + 1] = "ValveBiped.Bip01_R_Finger" .. a .. s
        L_F[#L_F + 1] = "ValveBiped.Bip01_L_Finger" .. a .. s
    end
end

local function applyFingers(ply, key, names, data, w)
    if not data or w <= 0.01 then return end
    local ids = boneIds(ply, key, names)
    local mine = {}
    for i = 1, #names do if ids[i] then mine[ids[i]] = true end end
    local par, loc, extra = {}, {}, {}
    for i = 1, #names do
        local b = ids[i]
        local p = b and ply:GetBoneParent(b)
        local mb, mp = b and ply:GetBoneMatrix(b), p and p >= 0 and ply:GetBoneMatrix(p)
        if mb and mp then
            par[i], loc[i] = p, mp:GetInverseTR() * mb
            -- bones under this finger that aren't one of the 15 (fingertip nubs / helper bones on many models): carried
            -- along rigidly, or the mesh stretched between the moved finger and the helper left behind
            for _, c in ipairs(ply:GetChildBones(b) or {}) do
                if not mine[c] then
                    local mc = ply:GetBoneMatrix(c)
                    if mc then extra[#extra + 1] = { b = b, c = c, l = mb:GetInverseTR() * mc } end
                end
            end
        end
    end
    for i = 1, #names do
        local l = loc[i]
        local mp = l and ply:GetBoneMatrix(par[i])
        local k = (i - 1) * 3
        if mp and data[k + 3] then
            local target = Matrix()
            target:SetAngles(Angle(data[k + 1], data[k + 2], data[k + 3]))
            local nl = slerpRot(l, target, w)
            nl:SetTranslation(l:GetTranslation())
            ply:SetBoneMatrix(ids[i], mp * nl)
        end
    end
    local function carry(c, m)
        ply:SetBoneMatrix(c, m)
    end
    for _, x in ipairs(extra) do
        local mb = ply:GetBoneMatrix(x.b)
        if mb then
            local old = ply:GetBoneMatrix(x.c)
            local nw = mb * x.l
            carry(x.c, nw)
            -- and anything under the helper
            if old then
                local D = nw * old:GetInverseTR()
                for _, cc in ipairs(ply:GetChildBones(x.c) or {}) do
                    local m = ply:GetBoneMatrix(cc)
                    if m then carry(cc, D * m) end
                end
            end
        end
    end
end

local function solve(ply)
    if not ply.MPM_AnimOut then return end
    if ply ~= LocalPlayer() and ply:GetPos():DistToSqr(EyePos()) > CV.lod:GetFloat() ^ 2 then return end
    local wep = ply:GetActiveWeapon()
    if not IsValid(wep) then return end
    local g = gunEntry(wep)
    if not g then return end
    if g.kit then
        -- kits (fists, knife...): no world model to place, but MW's finger pose on both hands - the hold's additive
        -- offset alone left the fists half open (v0.10.3)
        if CV.fing:GetBool() then
            local w = 1 - math.Clamp(ply.MPM_ActW or 0, 0, 1)
            applyFingers(ply, "MPM_RFIds", R_F, g.fr, w)
            applyFingers(ply, "MPM_LFIds", L_F, g.fl, w)
        end
        return
    end
    if not wep.WorldModelOffsets then return end
    local now = RealTime()
    local dt = math.Clamp(now - (ply.MPM_IKT or now), 0, 0.1)
    ply.MPM_IKT = now

    local wp, wa, bodyW, actW, _, gp, ga = A.GunWorld(ply, wep, g)
    ply.MPM_GW = wp and { wp = wp, wa = wa, f = FrameNumber() } or nil
    ply.MPM_LetGo = bodyW or 0
    -- right hand onto MW's REAL grip (gun * J^-1, J from MW's action end frames): the hold clips bend the wrist ~24 deg
    -- against the gun, MW's game pulls the hand onto the gun - so does this (off while MW's hand has let go)
    -- (not during bolt / pump cycles: MW's hand leaves the grip to work the bolt - the IK held it on the grip)
    local act = ply.MPM_Act
    local addW = (act and act.kind == "rech") and (actW or 0) or 0
    local rw = (CV.rik:GetBool() and wp and g.jg) and (1 - (bodyW or 0)) * (1 - addW) or 0
    ply.MPM_RIKW = math.Approach(ply.MPM_RIKW or rw, rw, dt * 6)
    if ply.MPM_RIKW > 0.01 and gp then
        local jg = g.jg
        local ip, ia = WorldToLocal(vector_origin, angle_zero, Vector(jg[1], jg[2], jg[3]), Angle(jg[4], jg[5], jg[6]))
        -- the grip is physical: hand = model * T(-gt) * J^-1 with the ACTION rig's calibration (J came from its clips)
        local jp, ja = LocalToWorld(Vector(-g.gt[1], -g.gt[2], -g.gt[3]), angle_zero, wp, wa)
        local hp, ha = LocalToWorld(ip, ia, jp, ja)
        ply.MPM_RHTarget = hp
        local rids = boneIds(ply, "MPM_RIKBones", R_ARM)
        local mrh = rids[3] and ply:GetBoneMatrix(rids[3])
        if mrh then ply.MPM_RHDist = { d = mrh:GetTranslation():Distance(hp), f = FrameNumber() } end
        if mrh and mrh:GetTranslation():Distance(hp) < 14 then
            local k = ply.MPM_RIKW
            solveArm(ply, mrh:GetTranslation() + (hp - mrh:GetTranslation()) * k, rotOf(ha), k, true)
            if k > 0.9 then
                local m2 = ply:GetBoneMatrix(rids[3])
                if m2 then
                    local f = math.deg(math.acos(math.Clamp(m2:GetForward():Dot(ha:Forward()), -1, 1)))
                    local u = math.deg(math.acos(math.Clamp(m2:GetUp():Dot(ha:Up()), -1, 1)))
                    ply.MPM_RHErr = { d = m2:GetTranslation():Distance(hp), a = math.max(f, u), f = FrameNumber() }
                end
            end
        end
    end
    if wp and ply.MPM_GW then
        local rb = boneIds(ply, "MPM_RIKBones", R_ARM)[3]
        local mh2 = rb and ply:GetBoneMatrix(rb)
        if mh2 then ply.MPM_GW.lp, ply.MPM_GW.la = WorldToLocal(wp, wa, mh2:GetTranslation(), mh2:GetAngles()) end
    end
    -- right hand: MW's grip fingers while the gun is in it
    local rfw = CV.fing:GetBool() and wp and (1 - (bodyW or 0)) * (1 - addW) or 0
    ply.MPM_RFW = math.Approach(ply.MPM_RFW or rfw, rfw, dt * 6)
    applyFingers(ply, "MPM_RFIds", R_F, g.fr, ply.MPM_RFW)

    if not CV.ik:GetBool() then return end
    local w = A.LeftHandWeight and A.LeftHandWeight(ply, actW) or (1 - (actW or 0))
    if ply.MPM_Gait == "tac" then w = 0 end -- tac sprint: the gun up one-handed
    w = w * (1 - addW) -- bolt / pump cycle: the gun hangs off the left hand (GunWorld), nothing to pull
    local T, rot, kind, mountM
    if wp then
        T, rot, kind, mountM = leftTarget(ply, wep, g, wp, wa)
    end
    if not T then
        -- no grip tag (MW Base's pistols): the left hand where MW's hold has it relative to the right hand
        local st = A.Stance(ply)
        local hip, ads = g["lh_" .. st], g["lhads_" .. st]
        local rh = ply:LookupBone(BONE_RH)
        local mr = rh and ply:GetBoneMatrix(rh)
        if hip and mr then
            local tl = Vector(hip[1], hip[2], hip[3])
            if ads then tl = LerpVector(math.Clamp(A.AdsAmount and A.AdsAmount(ply) or 0, 0, 1), tl, Vector(ads[1], ads[2], ads[3])) end
            T = LocalToWorld(tl, angle_zero, mr:GetTranslation(), mr:GetAngles())
        end
    end
    if not T then ply.MPM_IKW = 0 return end
    ply.MPM_IKTarget = T
    local ids = boneIds(ply, "MPM_IKBones", L_ARM)
    local mh = ids[3] and ply:GetBoneMatrix(ids[3])
    if not mh then return end
    if mountM then
        local lp, la = WorldToLocal(mh:GetTranslation(), mh:GetAngles(), mountM:GetTranslation(), mountM:GetAngles())
        local tl = WorldToLocal(T, angle_zero, mountM:GetTranslation(), mountM:GetAngles())
        local rd
        if rot then
            local hr = Matrix(mh)
            hr:SetTranslation(vector_origin)
            rd = math.deg(math.acos(math.Clamp(hr:GetForward():Dot(rot:GetForward()), -1, 1)))
        end
        ply.MPM_GripCal = { kind = kind, p = lp, a = la, t = tl, rd = rd, f = FrameNumber() }
    end
    local dist = mh:GetTranslation():Distance(T)
    local w0 = w
    w = w * (1 - math.Clamp((dist - CV.ikfull:GetFloat()) / math.max(CV.ikfade:GetFloat(), 0.1), 0, 1))
    local gv = A.GripVariant and A.GripVariant(wep.MPM_Grip) or g.integ
    ply.MPM_LHDist = { d = dist, w0 = w0, w = w, kind = (kind or (g.lhg and "lhg") or "tag/mw")
        .. (gv and (mountM and " (grip " .. gv .. ", mount found)" or " (grip " .. gv .. ", NO MOUNT)") or ""),
        grip = wep.MPM_Grip, f = FrameNumber() }
    ply.MPM_IKW = math.Approach(ply.MPM_IKW or w, w, dt * 6)
    w = ply.MPM_IKW
    if w <= 0.01 then return end
    solveArm(ply, mh:GetTranslation() + (T - mh:GetTranslation()) * w, rot, w)
    if w > 0.9 then
        local m2 = ply:GetBoneMatrix(ids[3])
        if m2 then ply.MPM_LHErr = { d = m2:GetTranslation():Distance(T), f = FrameNumber() } end
    end
    if CV.fing:GetBool() then
        applyFingers(ply, "MPM_LFIds", L_F, (kind and g["fl_" .. kind]) or (kind == "vertpro" and g.fl_vert) or g.fl, w)
    end
end

-- Finger joints never bend backwards (v0.10.3). The retarget can't line up a fingertip bone (it has no child to aim at),
-- so the skeletons' different resting curl becomes a constant bias: the RIGHT INDEX tip bent backwards in 54 % of all
-- clip frames (median +10, up to +63 deg; the other right tips 2-4 %) - "the pointer fingertip goes insane". Clamped
-- in each joint's parent frame (the bend about the parent's up axis, + = backwards); thumbs keep theirs (they bend
-- the other way by design).
CV.fclamp = CreateClientConVar("mpm_finger_clamp", "1", true, false, "Finger joints never bend backwards")
local CLAMP = {}
for _, side in ipairs({ "R", "L" }) do
    for f = 1, 4 do
        for _, j in ipairs({ "1", "2" }) do CLAMP[#CLAMP + 1] = ("ValveBiped.Bip01_%s_Finger%d%s"):format(side, f, j) end
    end
end
local function rotZ(deg)
    local r = math.rad(deg)
    local c, s = math.cos(r), math.sin(r)
    return Matrix({ { c, -s, 0, 0 }, { s, c, 0, 0 }, { 0, 0, 1, 0 }, { 0, 0, 0, 1 } })
end
local function clampFingers(ply)
    if not CV.fclamp:GetBool() then return end
    local ids = boneIds(ply, "MPM_ClampIds", CLAMP)
    for i = 1, #CLAMP do -- parents first (Finger1 before Finger11 before Finger12)
        local b = ids[i]
        local p = b and ply:GetBoneParent(b)
        local mb, mp = b and ply:GetBoneMatrix(b), p and p >= 0 and ply:GetBoneMatrix(p)
        if mb and mp then
            local loc = mp:GetInverseTR() * mb
            local x = loc:GetForward()
            local bend = math.deg(math.atan2(x.y, x.x))
            if bend > 0 then
                local child = ply:GetChildBones(b) or {}
                local before = {}
                for _, c in ipairs(child) do
                    local mc = ply:GetBoneMatrix(c)
                    if mc then before[c] = mb:GetInverseTR() * mc end
                end
                local nl = rotZ(-bend) * loc
                nl:SetTranslation(loc:GetTranslation())
                local nw = mp * nl
                ply:SetBoneMatrix(b, nw)
                for c, l in pairs(before) do ply:SetBoneMatrix(c, nw * l) end -- the tip follows its joint
            end
        end
    end
end

local function sameM(a, b)
    return a and b and a:GetTranslation():DistToSqr(b:GetTranslation()) < 1e-6
        and a:GetForward():DistToSqr(b:GetForward()) < 1e-8 and a:GetUp():DistToSqr(b:GetUp()) < 1e-8
end

function A.BoneCallback(e, n)
    if A.TraceHook then A.TraceHook(e, "anim") end
    local frame = FrameNumber()
    local root = e:GetBoneMatrix(0)
    local key = root and (root:GetTranslation() + root:GetForward() * 7 + root:GetUp() * 13)
    local c = e.MPM_BoneCache
    if CV.cache:GetBool() and c and key and c.frame == frame and c.n == n and c.key:DistToSqr(key) < 1e-4 then
        local skipped = 0
        for _, i in ipairs(c.changed) do
            local cur = e:GetBoneMatrix(i)
            if cur and (cur:GetTranslation():DistToSqr(c.t[i]) > 1e-6 or cur:GetForward():DistToSqr(c.f[i]) > 1e-8) then
                e:SetBoneMatrix(i, c[i])
            else
                skipped = skipped + 1
            end
        end
        if skipped == #c.changed and skipped > 0 then e.MPM_PartialN = (e.MPM_PartialN or 0) + 1 end
    else
        if e.MPM_SolveF == frame then
            e.MPM_SolveN = e.MPM_SolveN + 1
            if key and e.MPM_SolveK then
                e.MPM_SolveSpread = math.max(e.MPM_SolveSpread, key:Distance(e.MPM_SolveK))
                e.MPM_SolveYaw = math.max(e.MPM_SolveYaw, math.abs(math.AngleDifference(root:GetAngles().y, e.MPM_SolveY)))
            end
        else
            e.MPM_SolveF, e.MPM_SolveN, e.MPM_SolveSpread, e.MPM_SolveYaw = frame, 1, 0, 0
            e.MPM_SolveK, e.MPM_SolveY = key, root and root:GetAngles().y or 0
        end
        local pre = key and CV.cache:GetBool() and {} or nil
        if pre then for i = 0, n - 1 do pre[i] = e:GetBoneMatrix(i) end end
        if A.GroundSolve then A.GroundSolve(e) end
        solve(e)
        if e.MPM_AnimOut then clampFingers(e) end
        if pre then
            c = { frame = frame, n = n, key = key, changed = {}, t = {}, f = {} }
            for i = 0, n - 1 do
                local m = e:GetBoneMatrix(i)
                if m and not sameM(m, pre[i]) then
                    c[i], c.t[i], c.f[i] = m, m:GetTranslation(), m:GetForward()
                    c.changed[#c.changed + 1] = i
                end
            end
            e.MPM_BoneCache = c
        end
    end
    if A.TraceHook then A.TraceHook(e, "final") end
end

local function addCb(ent)
    if IsValid(ent) and ent:IsPlayer() and not ent.MPM_IKCb2 then
        if ent.MPM_IKCb then ent:RemoveCallback("BuildBonePositions", ent.MPM_IKCb) end
        ent.MPM_IKCb2 = true
        ent.MPM_IKCb = ent:AddCallback("BuildBonePositions", function(e, n) A.BoneCallback(e, n) end)
    end
end
hook.Add("NetworkEntityCreated", "MPM_GunIK", addCb)
for _, p in ipairs(player.GetAll()) do addCb(p) end
hook.Add("OnEntityCreated", "MPM_GunIK", function(ent) timer.Simple(0, function() addCb(ent) end) end)

-- mag hand-off --------------------------------------------------------------------------------------------------------
-- During a reload with mag notetracks: two-mag world models (j_mag1 + j_mag2, the tactical-reload pair) carry the NEW
-- mag (j_mag2) in the left hand until "mag in", the old one (j_mag1) disappears at "mag out"; one-mag models move j_mag1
-- with the left hand between "mag out" and "mag in". Bone manipulations on the world model, reset when the reload ends.
CV.mags = CreateClientConVar("mpm_gun_mags", "1", true, false, "Move the magazine during reloads (MW's own mag motion)")
local MAG_IN_HAND = Vector(3.5, -1.5, 0) -- mag origin relative to the left hand bone (palm)

local function resetMags(wep)
    if not wep.MPM_MagTouched then return end
    for _, b in ipairs(wep.MPM_MagTouched) do
        wep:ManipulateBonePosition(b, vector_origin)
        wep:ManipulateBoneScale(b, Vector(1, 1, 1))
        wep:ManipulateBoneAngles(b, angle_zero)
    end
    wep.MPM_MagTouched = nil
end

local function touch(wep, b)
    wep.MPM_MagTouched = wep.MPM_MagTouched or {}
    if not table.HasValue(wep.MPM_MagTouched, b) then table.insert(wep.MPM_MagTouched, b) end
end

-- move bone b of the world model so its origin sits at world position p (parent-space offset from its bind spot)
local function boneTo(wep, b, p)
    local par = wep:GetBoneParent(b)
    local pm = par and par >= 0 and wep:GetBoneMatrix(par)
    local bm = wep:GetBoneMatrix(b)
    if not (pm and bm) then return end
    local cur = wep:GetManipulateBonePosition(b)
    -- the bone's bind spot in world space = its current world spot minus the current manipulation (parent space)
    local curWorld = bm:GetTranslation()
    local want = WorldToLocal(p, angle_zero, pm:GetTranslation(), pm:GetAngles())
    local have = WorldToLocal(curWorld, angle_zero, pm:GetTranslation(), pm:GetAngles())
    wep:ManipulateBonePosition(b, cur + (want - have))
    touch(wep, b)
end

-- MW's own gun-part motion (v0.9.3): mags, the 725's break barrel, LMG lids / covers / belt rounds, bolts, charging
-- handles... Baked per action as entry.parts[bone] = { p = offsets from the seat (parent space), a = MW's ABSOLUTE local
-- angles, v = mag visible (0 = parked in the pouch / dropped / far away) } every 2 frames. MW Base's world models carry
-- the same bones (attachments bonemerge onto them). Angles play as rest^-1 * a against the world model's own rest angle
-- (captured before the part is first touched). Applied before the player draws (this frame).
CV.parts = CreateClientConVar("mpm_gun_parts", "1", true, false, "Move gun parts (mags, lids, belts, break barrels, bolts)")
local ONE, ZERO = Vector(1, 1, 1), Vector(0, 0, 0)
local function sample3(t, i, j, f)
    local a, b = i * 3, j * 3
    return t[a + 1] + (t[b + 1] - t[a + 1]) * f, t[a + 2] + (t[b + 2] - t[a + 2]) * f, t[a + 3] + (t[b + 3] - t[a + 3]) * f
end
function A.PartAt(tr, c)
    local n = tr.p and #tr.p / 3 or (tr.a and #tr.a / 3) or 0
    if n < 1 then return nil end
    local x = c * (n - 1)
    local i = math.Clamp(math.floor(x), 0, n - 1)
    local j = math.min(i + 1, n - 1)
    local f = math.Clamp(x - i, 0, 1)
    local pos = tr.p and Vector(sample3(tr.p, i, j, f)) or nil
    local ang
    if tr.a then
        local a, b = i * 3, j * 3
        ang = LerpAngle(f, Angle(tr.a[a + 1], tr.a[a + 2], tr.a[a + 3]), Angle(tr.a[b + 1], tr.a[b + 2], tr.a[b + 3]))
    end
    local vis = true
    if tr.v then vis = (f < 0.5 and tr.v[i + 1] or tr.v[j + 1]) ~= 0 end
    return pos, ang, vis
end

-- the part's own rest angle in its parent (world model as built), captured once before we ever touch it
local function partRest(wep, b)
    wep.MPM_PartRest = wep.MPM_PartRest or {}
    local r = wep.MPM_PartRest[b]
    if r == nil then
        local par = wep:GetBoneParent(b)
        local bm, pm = wep:GetBoneMatrix(b), par and par >= 0 and wep:GetBoneMatrix(par)
        r = false
        if bm and pm then
            local loc = pm:GetInverseTR() * bm
            r = loc:GetAngles()
        end
        wep.MPM_PartRest[b] = r
    end
    return r or nil
end

hook.Add("PrePlayerDraw", "MPM_GunParts", function(ply)
    local wep = ply:GetActiveWeapon()
    if not IsValid(wep) or not wep.WorldModelOffsets then return end
    local a = ply.MPM_Act
    local parts = a and a.entry and a.entry.parts
    local c
    if parts then
        c = math.Clamp((CurTime() - a.t0) / a.dur, 0, 1)
    else
        -- no action moving parts: the last shot's bolt / slide / belt motion
        local fw = ply.MPM_FireW
        if fw and fw.e and CurTime() - fw.t0 < fw.e.dur then
            parts, c = fw.e.parts, (CurTime() - fw.t0) / fw.e.dur
        end
    end
    if not (CV.parts:GetBool() and ply.MPM_AnimOut and parts) then
        if wep.MPM_MagTrack then wep.MPM_MagTrack = nil resetMags(wep) end
        return
    end
    if not CV.mags:GetBool() then parts = table.Copy(parts) parts.j_mag1, parts.j_mag2 = nil, nil end
    wep.MPM_MagTrack = true
    for name, tr in pairs(parts) do
        local b = wep:LookupBone(name)
        if b then
            local rest = tr.a and partRest(wep, b)
            local pos, ang, vis = A.PartAt(tr, c)
            touch(wep, b)
            wep:ManipulateBonePosition(b, pos or ZERO)
            if ang and rest then
                local mr, mt = Matrix(), Matrix()
                mr:SetAngles(rest)
                mt:SetAngles(ang)
                wep:ManipulateBoneAngles(b, (mr:GetInverseTR() * mt):GetAngles())
            end
            if tr.v then wep:ManipulateBoneScale(b, vis and ONE or ZERO) end
        end
    end
end)

hook.Add("PostPlayerDraw", "MPM_GunMags", function(ply)
    local wep = ply:GetActiveWeapon()
    if not IsValid(wep) or not wep.WorldModelOffsets then return end
    local a = ply.MPM_Act
    if a and a.entry and a.entry.parts and CV.parts:GetBool() then return end -- MW's own part tracks drive it
    if not (CV.mags:GetBool() and ply.MPM_AnimOut and a and a.kind == "reload") then
        if not wep.MPM_MagTrack then resetMags(wep) end
        return
    end
    local n = A.ActionNotes(a)
    if not (n and n.magout and n.magin) then resetMags(wep) return end
    local m1, m2 = wep:LookupBone("j_mag1"), wep:LookupBone("j_mag2")
    local lh = ply:LookupBone("ValveBiped.Bip01_L_Hand")
    local lm = lh and ply:GetBoneMatrix(lh)
    if not (m1 and lm) then return end
    local handP = LocalToWorld(MAG_IN_HAND, angle_zero, lm:GetTranslation(), lm:GetAngles())
    local c = math.Clamp((CurTime() - a.t0) / a.dur, 0, 1)
    if m2 then
        if c < n.magin then boneTo(wep, m2, handP) else wep:ManipulateBonePosition(m2, vector_origin) end
        touch(wep, m1); touch(wep, m2)
        wep:ManipulateBoneScale(m1, (c >= n.magout) and Vector(0, 0, 0) or Vector(1, 1, 1))
        wep:ManipulateBoneScale(m2, Vector(1, 1, 1))
    else
        if c >= n.magout and c < n.magin then boneTo(wep, m1, handP) else wep:ManipulateBonePosition(m1, vector_origin) end
        touch(wep, m1)
    end
end)

-- mpm_gun_ik_debug 1: the left-hand target (green) and the left hand (red)
CV.ikdbg = CreateClientConVar("mpm_gun_ik_debug", "0", true, false, "Draw the left-hand IK target")
hook.Add("PostDrawTranslucentRenderables", "MPM_GunIKDebug", function()
    if not CV.ikdbg:GetBool() then return end
    for _, p in ipairs(player.GetAll()) do
        if p.MPM_IKTarget then
            render.SetColorMaterial()
            render.DrawSphere(p.MPM_IKTarget, 1.2, 8, 8, Color(0, 255, 0, 200))
            local lh = p:LookupBone("ValveBiped.Bip01_L_Hand")
            local m = lh and p:GetBoneMatrix(lh)
            if m then render.DrawSphere(m:GetTranslation(), 1, 8, 8, Color(255, 0, 0, 200)) end
        end
    end
end)
