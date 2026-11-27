-- Anim graph v1 (Phase 3): picks the MPM locomotion sequence for the player's movement state, drives the direction
-- blend (mpm_mx / mpm_my) and syncs playback to the real ground speed. Shared: the server runs the same graph, so
-- hitboxes follow what clients see.
--
-- v1 covers rifle-type weapons on the ground (idle / walk / jog / run / sprint / tac sprint, crouch, prone, crawl).
-- Anything it has no clips for yet (jumping, swimming, ladders, vehicles, pistols, no weapon...) falls back to HL2's
-- animations untouched. Starts/stops, turn-in-place, aim, per-gun holds come in later phases (MPMDIDDY/PLAN.md).
MPM.Anim = MPM.Anim or {}
local A = MPM.Anim
local S = MPM.S

local FL = bit.bor(FCVAR_REPLICATED, FCVAR_ARCHIVE)
A.CV = {
    enabled   = CreateConVar("mpm_anims", "1", FL, "MPM player animations on/off", 0, 1),
    holdtypes = CreateConVar("mpm_anim_holdtypes", "ar2 smg shotgun crossbow",
        FL, "HL2 holdtypes that get the MW rifle animations (non-MW-Base weapons)"),
    holdtypes_pi = CreateConVar("mpm_anim_holdtypes_pi", "pistol revolver",
        FL, "HL2 holdtypes that get the MW pistol animations (non-MW-Base weapons)"),
    kits      = CreateConVar("mpm_anim_kits",
        "fist=fists knife=knife melee=knife grenade=frag slam=frag rpg=rpg passive=passive",
        FL, "HL2 holdtype=MPM kit (MW fists / knife / prepped frag / RPG-7 / gun-down passive holds + actions)"),
    blend     = CreateConVar("mpm_anim_dirblend", "10", FL, "Direction blend speed (higher = snappier)", 0.5, 100),
    maxrate   = CreateConVar("mpm_anim_maxrate", "2.0", FL, "Fastest a clip may be played to match ground speed", 1, 5),
    neutral   = CreateConVar("mpm_anim_neutralpose", "1", FL,
        "Pin HL2's aim/head pose parameters at neutral while MPM drives the player (stops HL2's aim and autoplay " ..
        "head/body layers acting on the MW pose)", 0, 1),
}

-- MW Base hold categories -> MPM set ("ar" rifle set, "pi" pistol set; others stay on HL2 until their sets exist)
A.MWBRifle = { Rifle = true, RifleWithVerticalGrip = true, BoltAction = true, BigGun = true, TinyGun = true,
               Shotgun = true, Bipod = true, RPG = true, Saw = true }
A.MWBPistol = { Pistol = true, Revolver = true }

-- Numpad direction -> travel angle (deg, 0 fwd, + left)
local DIRANG = { [8] = 0, [7] = 45, [4] = 90, [1] = 135, [2] = 180, [3] = -135, [6] = -90, [9] = -45 }
local ORDER = { 8, 7, 4, 1, 2, 3, 6, 9 } -- counter-clockwise from forward

-- pure helpers (offline-tested) ---------------------------------------------------------------------------------------

-- Ground speed the clip set travels at in direction ang (deg), interpolated between the neighbouring numpad dirs.
function A.ClipSpeed(clip, ang)
    if not clip then return 0 end
    if not clip.dirs then return clip.speed or 0 end
    if clip.kind == "fwd3" then
        local a = math.Clamp(ang, -45, 45)
        local s8 = clip.dirs[8].speed
        if a >= 0 then return Lerp(a / 45, s8, (clip.dirs[7] or clip.dirs[8]).speed) end
        return Lerp(-a / 45, s8, (clip.dirs[9] or clip.dirs[8]).speed)
    end
    ang = math.NormalizeAngle(ang)
    local a = (ang < 0) and (ang + 360) or ang -- 0..360 counter-clockwise
    local i = math.floor(a / 45) % 8
    local t = (a - i * 45) / 45
    local d1, d2 = clip.dirs[ORDER[i + 1]], clip.dirs[ORDER[(i + 1) % 8 + 1]]
    return Lerp(t, d1 and d1.speed or 0, d2 and d2.speed or 0)
end

-- Blend parameters for a travel direction: the unit vector pushed out to the square grid (diagonals = corners).
function A.DirParams(ang)
    local r = math.rad(ang)
    local x, y = math.cos(r), math.sin(r)
    local m = math.max(math.abs(x), math.abs(y), 1e-6)
    return x / m, y / m
end

-- Which clip set for this situation. info: { st, crouch, speed, onGround }. prev = last gait (hysteresis).
function A.PickGait(info, prev)
    local st, sp = info.st, info.speed
    if st == S.PRONE or st == S.PRONE_IN or st == S.PRONE_OUT or st == S.DIVE then
        if st == S.PRONE and sp > 4 then return "crawl" end
        return "pidle"
    end
    if st == S.SLIDE then return "cidle" end
    if not info.onGround then
        -- MW jump-air loops (direction blend); fast set when jumping out of a sprint / slide
        return sp >= 300 and "fair" or "air"
    end
    if st == S.TAC and sp > 150 then return "tac" end
    if st == S.SPRINT and sp > 150 then return "sprint" end

    local function band(lo, gait)
        -- keep the previous gait a little past its edge so it doesn't flicker at the boundary
        if prev == gait then return sp >= lo * 0.85 end
        return sp >= lo
    end
    if info.crouch then
        if not band(6, "cwalk") and not band(6, "cjog") then return "cidle" end
        if band(95, "cjog") then return "cjog" end
        return "cwalk"
    end
    if not band(8, "walk") and not band(8, "jog") and not band(8, "run") then return "idle" end
    if band(260, "run") then return "run" end
    if band(135, "jog") then return "jog" end
    return "walk"
end

-- runtime ----------------------------------------------------------------------------------------------------------

function A.WeaponSet(ply)
    local wep = ply:GetActiveWeapon()
    if not IsValid(wep) then return nil end
    if wep.HoldTypes and wep.HoldType and wep.HasFlag then -- MW Base (mg_base)
        -- a gun with its own animation set (the minigun: MW's low hip carry + its own aim circles)
        local key = wep:GetClass():match("^mg_(.+)$")
        local g = key and MPM.Guns and MPM.Guns[key]
        if g and g.set and MPM.Clips["idle_" .. g.set] then return g.set end
        local cat = wep.GetCurrentHoldType and wep:GetCurrentHoldType() or wep.HoldType
        if A.MWBRifle[cat] then return "ar" end
        if A.MWBPistol[cat] and MPM.Clips.idle_pi then return "pi" end
        return nil
    end
    if A.KitFor and A.KitFor(wep) then return "ar" end -- kits ride the rifle locomotion with their own hold on top
    local ht = wep:GetHoldType()
    if ht and (" " .. A.CV.holdtypes:GetString() .. " "):find(" " .. ht .. " ", 1, true) then return "ar" end
    if ht and MPM.Clips.idle_pi and (" " .. A.CV.holdtypes_pi:GetString() .. " "):find(" " .. ht .. " ", 1, true) then
        return "pi"
    end
    return nil
end

local seqFor
function A.SeqFor(ply, name) return seqFor(ply, name) end
function seqFor(ply, name)
    local mdl = ply:GetModel()
    ply.MPM_SeqCache = ply.MPM_SeqCache or {}
    local c = ply.MPM_SeqCache[mdl]
    if not c then c = {}; ply.MPM_SeqCache[mdl] = c end
    local s = c[name]
    if s == nil then
        s = ply:LookupSequence(name)
        c[name] = s
    end
    return s
end

-- Decide the whole frame's animation once (CalcMainActivity), UpdateAnimation applies it.
function A.Evaluate(ply, vel)
    ply.MPM_AnimOut = nil
    local function bail()
        ply.MPM_Shot, ply.MPM_Handoff = nil, nil -- HL2 takes over: no stale one-shot when we come back
        ply.MPM_BodyYaw = nil                   -- and the body re-plants at the view when we do
        if A.StopAction then A.StopAction(ply) end
        if A.StopHold then A.StopHold(ply) end
        if A.StopSlope then A.StopSlope(ply) end
    end
    if not A.CV.enabled:GetBool() or not MPM.Clips then return bail() end
    if not ply:Alive() or ply:InVehicle() or ply:GetMoveType() ~= MOVETYPE_WALK or ply:WaterLevel() >= 2 then
        return bail()
    end
    local set = A.WeaponSet(ply)
    if not set then return bail() end

    local st = MPM.CV.enabled:GetBool() and MPM.GetState(ply) or S.NONE
    local yaw = ply:EyeAngles().y
    local fwd = Angle(0, yaw, 0):Forward()
    local left = Angle(0, yaw + 90, 0):Forward()
    local hsp = Vector(vel.x, vel.y, 0)
    local speed = hsp:Length()
    local ang = speed > 1 and math.deg(math.atan2(hsp:Dot(left), hsp:Dot(fwd))) or 0

    local gait = A.PickGait({ st = st, crouch = ply:Crouching(), speed = speed, onGround = ply:IsOnGround() },
        ply.MPM_Gait)
    if not gait then return bail() end

    -- transitions (sh_anim_trans.lua): a running start / stop / stance / turn one-shot overrides the loop
    local bodyYaw = yaw
    if A.UpdateShot then
        local c = A.TransContext(ply, set, gait, speed, ang)
        local shot = A.UpdateShot(ply, c, seqFor)
        A.TransRemember(ply, c)
        bodyYaw = A.UpdateBodyYaw(ply, c, shot)
        if shot then
            ply.MPM_Gait = gait
            ply.MPM_AnimOut = { seq = shot.seq, rate = 0, cycle = shot.cyc, mx = 0, my = 0, yaw = yaw, shot = shot.kind,
                                bodyYaw = bodyYaw }
            return ply.MPM_AnimOut
        end
    end

    local name = (gait == "idle" and A.IdleName) and A.IdleName(ply, set, seqFor) or (gait .. "_" .. set)
    if (gait == "pidle" or gait == "crawl") and MPM.HasFlag(ply, MPM.F.BELLY) and MPM.Clips["diveloop_" .. set] then
        name = "diveloop_" .. set
    elseif (gait == "sprint" or gait == "tac") and A.UphillName then
        name = A.UphillName(ply, set, gait, name, hsp)
    end
    local clip = MPM.Clips[name]
    if not clip then return bail() end
    local seq = seqFor(ply, clip.seq)
    if not seq or seq < 0 then return bail() end
    ply.MPM_Gait = gait

    local rate = 1
    local cs = A.ClipSpeed(clip, ang)
    if clip.kind ~= "single" and cs > 1 then
        rate = math.Clamp(speed / cs, 0.3, A.CV.maxrate:GetFloat())
    end
    local mx, my = 0, 0
    if clip.kind == "blend8" and speed > 1 then
        mx, my = A.DirParams(ang)
    elseif clip.kind == "fwd3" then
        my = math.Clamp(ang / 45, -1, 1)
    end
    ply.MPM_AnimOut = { seq = seq, rate = rate, mx = mx, my = my, yaw = yaw, bodyYaw = bodyYaw }
    -- a start just ended: the loop carries on at the same foot phase
    local h = ply.MPM_Handoff
    if h then
        ply.MPM_Handoff = nil
        if clip.dirs and A.HandoffCycle then
            local li = clip.dirs[A.NearestDir(ang, clip.dirs)]
            ply.MPM_AnimOut.setCycle = A.HandoffCycle(h.info, h.cyc, li)
        end
    end
    return ply.MPM_AnimOut
end

hook.Add("CalcMainActivity", "MPM_Anim", function(ply, vel)
    local out = A.Evaluate(ply, vel)
    if out then
        -- Keep the gamemode's own animation state machine ticking (jump / land / ground-time flags) so the
        -- frame we hand back to HL2 (other weapon, ladder, water...) doesn't start from stale state.
        GAMEMODE:CalcMainActivity(ply, vel)
        return ACT_MP_STAND_IDLE, out.seq
    end
end)

-- HL2's fire gestures are full-body deltas (pelvis and legs weighted 1) and its reloads carry a pelvis layer: over
-- the MW pose they shove the hips around ("shooting sends my character in a direction"). While the graph drives the
-- player, the attack/reload slot (MW Base fire, reload, melee) and the custom slot (MW Base draw) stay empty; MW
-- per-gun fire / reload / draw clips replace them in the weapon phase.
A.MutedSlots = { GESTURE_SLOT_ATTACK_AND_RELOAD, GESTURE_SLOT_CUSTOM }

-- Clearing the slots every frame still let a gesture show for ONE frame (MW Base restarts it directly, it rendered
-- before our next clear: the "subtle one-frame glitch when shooting"). So the gesture is refused at the source:
-- Player:AnimRestartGesture is wrapped, and for the muted slots it does nothing while the graph drives that player.
do
    local PLY = FindMetaTable("Player")
    local muted = {}
    for _, s in ipairs(A.MutedSlots) do muted[s] = true end
    if PLY and PLY.AnimRestartGesture and not PLY.MPM_OrigAnimRestartGesture then
        PLY.MPM_OrigAnimRestartGesture = PLY.AnimRestartGesture
        function PLY:AnimRestartGesture(slot, act, autokill)
            if muted[slot] and self.MPM_AnimOut then
                -- MW Base's per-shot gesture is our shot signal (predicted for the shooter, networked for the rest)
                if slot == GESTURE_SLOT_ATTACK_AND_RELOAD and A.OnFireGesture then A.OnFireGesture(self, act) end
                return
            end
            return PLY.MPM_OrigAnimRestartGesture(self, slot, act, autokill)
        end
    end
end

-- m_anm.mdl has hidden AUTOPLAY delta sequences the engine adds on top of every main sequence (ours too):
-- body_rot (aim_yaw, pelvis/thighs), head_rot_z (head_yaw), head_rot_y (head_pitch), plus HL2 aim layers on aim_pitch.
-- They were authored against HL2's poses; on the MW pose looking up folded the whole body forward (user screenshot
-- 2026-11-24: main seq mpm_idle_ar, no overlay layers, eye pitch -51). The engine keeps setting these from the view,
-- so they're pinned at 0 (= the layers' rest frame, no offset) every time before the pose is built.
A.NeutralParams = { "aim_yaw", "aim_pitch", "head_yaw", "head_pitch" }

-- MW aim layer (Phase 5): every aimed MPM sequence carries an addlayer of MW's aim circle as a 5x5 delta blend on
-- mpm_ay (aim yaw, + left of the body) and mpm_ap (aim pitch, + down). Pitch = the view's pitch; yaw = view minus
-- body yaw (0 while the body faces the view; turn-in-place makes it the planted-feet offset).
A.CV.aim = CreateConVar("mpm_anim_aim", "1", FL, "Upper body follows the view (MW aim circles)", 0, 1)

-- How far into aim-down-sights (0..1): MW Base networks its AimDelta; other bases: 0 for now.
function A.AdsAmount(ply)
    if ply.MPM_Pin and ply.MPM_Pin.ads then return ply.MPM_Pin.ads end -- dev tools / photo booth
    local wep = ply:GetActiveWeapon()
    if IsValid(wep) and wep.GetAimDelta then return math.Clamp(wep:GetAimDelta() or 0, 0, 1) end
    return 0
end

function A.AimParams(ply, out)
    ply:SetPoseParameter("mpm_ads", A.AdsAmount(ply))
    local pitch, yaw = 0, 0
    if A.CV.aim:GetBool() then
        pitch = math.Clamp(math.NormalizeAngle(ply:EyeAngles().p), -89, 89)
        yaw = math.Clamp(math.NormalizeAngle(ply:EyeAngles().y - (out.bodyYaw or out.yaw)), -90, 90)
    end
    ply:SetPoseParameter("mpm_ay", yaw)
    ply:SetPoseParameter("mpm_ap", pitch)
end

-- (v0.10.5) gestures that aren't MPM's never show while MPM drives: MW Base's third-person draw (HL2's knife swing,
-- "range_knife", GESTURE_SLOT_CUSTOM) still got through on weapon switches - the finger tracker caught it at full
-- weight for half a Glock draw, dragging the right index ~50 deg backwards, then snapping off when it ended
function A.SilenceForeign(ply)
    ply:AnimSetGestureWeight(GESTURE_SLOT_CUSTOM, 0)
    pcall(function()
        for i = 0, 14 do
            if ply:IsValidLayer(i) and ply:GetLayerWeight(i) > 0 then
                local n = ply:GetSequenceName(ply:GetLayerSequence(i)) or ""
                if not n:find("^mpm_") then ply:SetLayerWeight(i, 0) end
            end
        end
    end)
end

function A.Neutralize(ply)
    if not A.CV.neutral:GetBool() then return end
    for _, name in ipairs(A.NeutralParams) do ply:SetPoseParameter(name, 0) end
end

hook.Add("UpdateAnimation", "MPM_Anim", function(ply, vel, maxSeqGroundSpeed)
    local out = ply.MPM_AnimOut
    if not out then return end
    -- smooth the direction blend (a strafe flip shouldn't snap the legs)
    local k = math.min(1, FrameTime() * A.CV.blend:GetFloat())
    ply.MPM_MX = Lerp(k, ply.MPM_MX or out.mx, out.mx)
    ply.MPM_MY = Lerp(k, ply.MPM_MY or out.my, out.my)
    ply:SetPoseParameter(MPM.ClipParams.mx, ply.MPM_MX)
    ply:SetPoseParameter(MPM.ClipParams.my, ply.MPM_MY)
    if out.cycle then
        -- one-shot: the graph drives the cycle (distance / time matched), the engine must not advance it
        ply:SetPlaybackRate(0)
        ply:SetCycle(out.cycle)
    else
        ply:SetPlaybackRate(out.rate)
        if out.setCycle then ply:SetCycle(out.setCycle) end
    end
    -- HL2 gestures are refused at the source (AnimRestartGesture wrapper); the custom slot is still cleared, the
    -- attack/reload slot now carries the per-gun hold
    ply:AnimResetGestureSlot(GESTURE_SLOT_CUSTOM)
    A.SilenceForeign(ply)
    A.Neutralize(ply)
    A.AimParams(ply, out)
    if A.WeaponActions then A.WeaponActions(ply, seqFor) end
    if A.UpdateHold then A.UpdateHold(ply, seqFor) end
    if A.UpdateFire then A.UpdateFire(ply) end
    if A.UpdateSlope then A.UpdateSlope(ply, out, seqFor) end
    if CLIENT then
        if A.ApplyRenderAngles then A.ApplyRenderAngles(ply) end
        GAMEMODE:GrabEarAnimation(ply)
        GAMEMODE:MouthMoveAnimation(ply)
    end
    return true
end)

if CLIENT then
    -- the body renders at its own yaw (turn-in-place); the aim layer twists the upper body to the view
    function A.ApplyRenderAngles(ply)
        local out = ply.MPM_AnimOut
        if not out then return end
        local ra = Angle(0, out.bodyYaw or out.yaw, 0)
        if A.ProneTilt then ra = A.ProneTilt(ply, ra) end
        ply:SetRenderAngles(ra)
    end

    hook.Add("PreRender", "MPM_AnimYaw", function()
        for _, p in ipairs(player.GetAll()) do
            if p.MPM_AnimOut then A.ApplyRenderAngles(p) end
        end
    end)

    hook.Add("PrePlayerDraw", "MPM_AnimYaw", function(ply)
        local out = ply.MPM_AnimOut
        if out then
            A.ApplyRenderAngles(ply)
            -- again right before the bones are built: the engine's own anim state may set them after our hook
            A.Neutralize(ply)
            A.SilenceForeign(ply)
            if A.WeaponActionsDraw then A.WeaponActionsDraw(ply) end
        end
    end)
end
