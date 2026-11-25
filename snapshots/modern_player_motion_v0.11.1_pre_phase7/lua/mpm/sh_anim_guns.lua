-- Weapon actions (Phase 5/6): MW's per-gun third-person reload / empty reload / inspect / first raise, played as an
-- upper-body gesture over whatever the legs are doing (the sequences carry the mpm_upper weightlist and the aim layer).
-- MW Base drives it: when its Reloading / Drawing / Inspecting flag rises, the matching clip for this gun and stance
-- starts on the grenade gesture slot, time-fitted to MW Base's own action length (it sets NextPrimaryFire to
-- now + that length), so the third-person action ends with the first-person one. Shared: flags and NextPrimaryFire
-- are networked, so server (hitboxes) and every client run the same thing.
-- Data: MPM.Guns[codename] = { cls, rel_stand = { seq, dur, from }, emp_prone = {...}, ... } from mpm_build.py.
local A = MPM.Anim
local FL = bit.bor(FCVAR_REPLICATED, FCVAR_ARCHIVE)
A.CV.actions = CreateConVar("mpm_anim_actions", "1", FL, "MW per-gun reload / inspect / draw gestures", 0, 1)

A.ActionSlot = GESTURE_SLOT_GRENADE
local FLAGS = { Reloading = "reload", Drawing = "draw", Inspecting = "insp", Holstering = "hol", Meleeing = "melee",
                Rechamber = "rech", ReloadEnd = "rele" }
-- MW Base tasks that set no flag: read the running task's name instead
local TASK_FLAGS = { Rechamber = true, ReloadEnd = true }

local function flagOn(wep, flag)
    if TASK_FLAGS[flag] then
        local t = wep.Tasks and wep.GetCurrentTask and wep.Tasks[wep:GetCurrentTask()]
        return t ~= nil and t.Name == flag
    end
    return wep:HasFlag(flag) and true or false
end

-- shell-by-shell guns (MW Base: Reload_Start, then Reload_Loop once per round, then the ReloadEnd task)
function A.LoopGun(wep)
    return wep.GetAnimation ~= nil and wep:GetAnimation("Reload_Loop") ~= nil
end
-- which piece of a loop reload MW Base is playing (its NextReloadSeq at the moment NextPrimaryFire moves)
function A.LoopSegment(name)
    name = string.lower(name or "")
    if name:find("loop", 1, true) then return "rell" end
    if name:find("start", 1, true) then return "rels" end
    return nil
end
-- classes that carry on the chest sling (user: the sling draw); the rest use the back carry
A.ChestCarry = { ar = true, sm = true }
local FADE = 0.12

-- pure (offline-tested) -----------------------------------------------------------------------------------------------

-- The clip entry for a gun action in a stance. Crouched falls back to the standing clip (upper body only, so it sits
-- fine on crouched legs); prone never borrows a standing one. Reloads try the mag variant first (mag "x" = extended,
-- "xl" = large / drum), empty before normal; a normal draw falls back to the first raise and vice versa.
function A.PickAction(gun, kind, stance, empty, mag)
    local g = MPM.Guns and MPM.Guns[gun]
    if not g then return nil end
    local acts
    if kind == "reload" then
        acts = {}
        local sfx = (mag == "x" or mag == "xl") and { mag, "" } or { "" }
        for _, m in ipairs(sfx) do
            if empty then acts[#acts + 1] = "emp" .. m end
            acts[#acts + 1] = "rel" .. m
        end
    elseif kind == "draw" then
        -- never the first-raise flourish for a normal draw (it read as "first draw every time"): no clip beats a wrong one
        acts = A.ChestCarry[g.cls] and { "drawc", "draw" } or { "draw", "drawc" }
    elseif kind == "hol" then
        acts = A.ChestCarry[g.cls] and { "holc", "hol" } or { "hol", "holc" }
    elseif kind == "raise" then acts = { "raise", "drawc", "draw" }
    elseif kind == "rech" then acts = { "rech" }
    elseif kind == "rels" then acts = { "rels", "rell" }  -- no start clip: go straight into the per-shell motion
    elseif kind == "rele" then acts = empty and { "relee", "rele" } or { "rele" }
    else acts = { kind } end
    local stances = (stance == "crouch") and { "crouch", "stand" } or { stance }
    for _, act in ipairs(acts) do
        for _, st in ipairs(stances) do
            local e = g[act .. "_" .. st]
            if e then return e, st, act end
        end
        -- normal draws / holsters exist for only ~10 guns: borrow one from a gun of the same class before ever
        -- falling back to the first raise (which made every draw look like a first draw). Same for the shell-by-shell
        -- pieces: MW only shipped them for a few shotguns / bolt guns (870, R9, Kar98k + MWII), the rest borrow.
        if act == "draw" or act == "hol" or act == "drawc" or act == "holc" or act == "rels" or act == "rell"
            or act == "fire" or act == "fireads"
            or act == "rele" then
            local e, st = A.ClassDonor(g.cls, act, stances)
            if e then return e, st, act end
        end
    end
    return nil
end

local donorCache = {}
-- An action clip from another gun of the same class (sorted, so every realm picks the same donor).
function A.ClassDonor(cls, act, stances)
    for _, st in ipairs(stances) do
        local key = cls .. "|" .. act .. "|" .. st
        local hit = donorCache[key]
        if hit == nil then
            hit = false
            local names = {}
            for name, e in pairs(MPM.Guns or {}) do
                if e.cls == cls and e[act .. "_" .. st] then names[#names + 1] = name end
            end
            table.sort(names)
            if names[1] then hit = MPM.Guns[names[1]][act .. "_" .. st] end
            donorCache[key] = hit
        end
        if hit then return hit, st end
    end
    return nil
end

-- Fade-in / fade-out weight for an action at cycle c (dur seconds long). Draws start at full weight: their first
-- frame is the gun coming from low / the back, a fade from the ready pose scrambled it.
-- Chained pieces (shell-by-shell start / loop) don't fade out at their end: the next piece takes over at full weight.
function A.ActionWeight(c, dur, nofadein, nofadeout)
    local t = c * dur
    local fin = nofadein and 1 or t / FADE
    local fout = nofadeout and 1 or (dur - t) / FADE
    return math.Clamp(math.min(fin, fout), 0, 1)
end

-- Mag variant of the reload MW Base chose (its NextReloadSeq, e.g. "Reload_Empty_XmagLrg"): "xl", "x" or nil.
function A.MagVariant(name)
    name = string.lower(name or "")
    if name:find("xmaglrg", 1, true) or name:find("drum", 1, true) then return "xl" end
    if name:find("xmag", 1, true) then return "x" end
    return nil
end

-- Kits: non-gun HL2 holdtypes MW has a set for (mpm_anim_kits "fist=fists knife=knife ..."): built like a gun entry.
local kitMap, kitStr = {}, nil
function A.KitFor(wep)
    if not (IsValid(wep) and MPM.Guns) or wep.HasFlag then return nil end -- MW Base guns are never kits
    local s = A.CV.kits and A.CV.kits:GetString() or ""
    if s ~= kitStr then
        kitStr, kitMap = s, {}
        for ht, kit in s:gmatch("([%w_]+)=([%w_]+)") do kitMap[ht] = kit end
    end
    local kit = kitMap[wep:GetHoldType() or ""]
    return (kit and MPM.Guns[kit]) and kit or nil
end

function A.GunKey(wep)
    return wep:GetClass():match("^mg_(.+)$") or A.KitFor(wep)
end

-- runtime -------------------------------------------------------------------------------------------------------------

local function setLayerCycle(ply, seq, c)
    pcall(function()
        for i = 0, 14 do
            if ply:IsValidLayer(i) and ply:GetLayerSequence(i) == seq then
                ply:SetLayerPlaybackRate(i, 0)
                ply:SetLayerCycle(i, c)
            end
        end
    end)
end

function A.StopAction(ply)
    ply.MPM_ActW = 0
    if ply.MPM_Act then
        ply:AnimResetGestureSlot(A.ActionSlot)
        ply.MPM_Act = nil
    end
end

local function startAction(ply, wep, seqFor, e, kind, flag, dur)
    local seq = seqFor(ply, e.seq)
    if not (seq and seq > 0) then return end
    if not dur or dur < 0.2 or dur > 10 then dur = e.dur end
    -- draws: MW's 3P raise is longer than MW Base's first-person one; squeezing it read as "sped up"
    if kind == "raise" or kind == "draw" then dur = math.max(dur, e.dur / 1.2) end
    local prev = ply.MPM_Act
    local fromChain = prev ~= nil and prev.chain == true
    ply.MPM_Act = { seq = seq, t0 = CurTime(), dur = dur, kind = kind, flag = flag, entry = e, gun = A.GunKey(wep),
                    nofadein = (kind == "draw" or kind == "raise" or kind == "rell" or (kind == "rele" and fromChain)),
                    chain = (kind == "rels" or kind == "rell") }
    ply:AddVCDSequenceToGestureSlot(A.ActionSlot, seq, 0, true)
    ply:AnimSetGestureWeight(A.ActionSlot, ply.MPM_Act.nofadein and 1 or 0)
end

-- Per frame while MPM drives the player (UpdateAnimation; the client also re-applies the cycle before drawing).
-- Pin (dev tools / photo booth: mpm_devtools): hold an action at a fixed cycle, or no action at all.
-- ply.MPM_Pin = { kind = "hold" | "ads" | <action kind>, c = 0..1 }
local function applyPin(ply, wep, seqFor, pin)
    if pin.kind == "hold" or pin.kind == "ads" then
        if ply.MPM_Act then A.StopAction(ply) end
        ply.MPM_ActW = 0
        return
    end
    local key = A.GunKey(wep)
    local a = ply.MPM_Act
    if not (a and a.pinKind == pin.kind and a.gun == key) then
        local e = key and A.PickAction(key, pin.kind, A.Stance(ply))
        if not e then A.StopAction(ply) ply.MPM_ActW = 0 return end
        startAction(ply, wep, seqFor, e, pin.kind, nil, e.dur)
        a = ply.MPM_Act
        if not a then return end
        a.pinKind = pin.kind
    end
    a.nofadein, a.chain, a.cut = true, true, nil
    a.t0 = CurTime() - math.Clamp(pin.c or 0, 0, 0.999) * a.dur
    ply:AnimSetGestureWeight(A.ActionSlot, 1)
    ply.MPM_ActW = (a.kind == "rech") and 0 or 1
    setLayerCycle(ply, a.seq, math.Clamp(pin.c or 0, 0, 0.999))
end

function A.WeaponActions(ply, seqFor)
    if not A.CV.actions:GetBool() then return A.StopAction(ply) end
    if ply.MPM_Pin and IsValid(ply:GetActiveWeapon()) then return applyPin(ply, ply:GetActiveWeapon(), seqFor, ply.MPM_Pin) end
    local wep = ply:GetActiveWeapon()
    local kit = A.KitFor(wep)
    if not (IsValid(wep) and (wep.HasFlag or kit) and MPM.Guns) then
        ply.MPM_WFlags, ply.MPM_WFlagsWep = nil, nil
        return A.StopAction(ply)
    end
    local now = CurTime()
    local cur = {}
    if kit then
        -- kits have no MW Base flags: the raise plays on switching to it, melee / throw / reload on the HL2 anim events
        if ply.MPM_WFlagsWep ~= wep then
            ply.MPM_WFlagsWep, ply.MPM_WFlags = wep, {}
            local e = A.PickAction(kit, "draw", A.Stance(ply))
            if e then startAction(ply, wep, seqFor, e, "draw", nil, e.dur) end
        end
    end
    local prev = (ply.MPM_WFlagsWep == wep) and ply.MPM_WFlags or {}
    if not kit then for flag in pairs(FLAGS) do cur[flag] = flagOn(wep, flag) end end

    for flag, kind in pairs(FLAGS) do
        if cur[flag] and not prev[flag] then
            local st = MPM.GetState(ply)
            local stance = MPM.IsProneState(st) and "prone" or (ply:Crouching() and "crouch" or "stand")
            local empty, mag = false, nil
            if kind == "reload" then
                local nxt = wep.GetNextReloadSeq and wep:GetNextReloadSeq() or ""
                empty = wep:Clip1() == 0 or string.find(string.lower(nxt), "empty", 1, true) ~= nil
                mag = A.MagVariant(nxt)
                if A.LoopGun(wep) then kind = "rels"; ply.MPM_LoopNPF = wep:GetNextPrimaryFire() end
            elseif kind == "rele" then
                empty = wep.HasFlag and (wep:HasFlag("ReloadEmptyVariant") or not wep:HasFlag("Rechambered")) or false
            elseif kind == "draw" and wep:HasFlag("PlayFirstDraw") then
                kind = "raise" -- MW Base's first draw (Equip); afterwards the normal draw from the back
            end
            local e = A.PickAction(A.GunKey(wep), kind, stance, empty, mag)
            if e then startAction(ply, wep, seqFor, e, kind, flag, wep:GetNextPrimaryFire() - now) end
        end
    end
    ply.MPM_WFlags, ply.MPM_WFlagsWep = cur, wep

    -- shell-by-shell: every time MW Base starts the next piece (NextPrimaryFire moves on) play its 3P piece, fitted to
    -- MW Base's length - one shell-in motion per round, like first person
    if not kit and cur.Reloading and A.LoopGun(wep) and ply.MPM_LoopNPF ~= wep:GetNextPrimaryFire() then
        local npf = wep:GetNextPrimaryFire()
        ply.MPM_LoopNPF = npf
        local seg = A.LoopSegment(wep.GetNextReloadSeq and wep:GetNextReloadSeq() or "")
        local a = ply.MPM_Act
        if seg and npf - now > 0.1 then
            if seg == "rels" and a and a.kind == "rels" then
                a.dur = math.max(npf - a.t0, 0.2) -- MW Base (re)starts the start piece on its first think: re-time it
            else
                local e, _, act = A.PickAction(A.GunKey(wep), seg, A.Stance(ply), false, nil)
                if e then startAction(ply, wep, seqFor, e, act == "rell" and "rell" or seg, "Reloading", npf - now) end
            end
        end
    end

    local a = ply.MPM_Act
    if not a then return end
    local c = (now - a.t0) / a.dur
    -- done, or the action was cut short (reload cancelled by sprint / swap): fade out quickly
    local cancellable = not (a.kind == "draw" or a.kind == "raise" or a.kind == "rech")
    if c >= 1 and a.chain and not a.cut then
        a.cut = now -- a shell piece ran out with no next piece (reload aborted / no end clip): hold its last frame, fade
    elseif c >= 1 or (cancellable and a.flag and not cur[a.flag] and c > 0.05 and not a.cut) then
        if c >= 1 and not a.chain then return A.StopAction(ply) end
        a.cut = a.cut or now
    end
    local w = A.ActionWeight(math.min(c, 1), a.dur, a.nofadein, a.chain)
    if a.cut then w = w * math.Clamp(1 - (now - a.cut) / FADE, 0, 1) end
    if a.cut and now - a.cut >= FADE then return A.StopAction(ply) end
    ply:AnimSetGestureWeight(A.ActionSlot, w)
    ply.MPM_ActW = (a.kind == "rech") and 0 or w -- bolt / pump cycles are additive over the hold: keep the hold
    setLayerCycle(ply, a.seq, math.Clamp(c, 0, 1))
end

-- client: re-apply the cycle right before bones are built (the anim state may advance the layer after our hook)
function A.WeaponActionsDraw(ply)
    local a = ply.MPM_Act
    if a and ply.MPM_Pin and ply.MPM_Pin.c then a.t0 = CurTime() - math.Clamp(ply.MPM_Pin.c, 0, 0.999) * a.dur end
    if a then setLayerCycle(ply, a.seq, math.Clamp((CurTime() - a.t0) / a.dur, 0, 1)) end
end

-- Per-gun holds -------------------------------------------------------------------------------------------------------
-- mpm_h_<gun>_<stance>: the gun's own MW hold offset + finger poses as a delta over the class hold (hip / ADS on
-- mpm_ads), looping on the attack/reload slot (HL2 gestures there are refused). Reload / inspect gestures on the grenade
-- slot sit above it. Off while sprinting / sliding / diving (those clips carry their own carry pose).
A.HoldSlot = GESTURE_SLOT_ATTACK_AND_RELOAD
local NOHOLD = { sprint = true, tac = true }

function A.Stance(ply)
    if MPM.IsProneState(MPM.GetState(ply)) then return "prone" end
    return ply:Crouching() and "crouch" or "stand"
end

-- Left-hand grip variant from MW Base's grip pose parameter (set by grips AND by barrels / handguards that carry their
-- own grip): "grip_vert_offset" -> "vert", "grip_barshort_gripang_offset" -> "ang", ... nil = the gun's default hold.
function A.GripVariant(param)
    param = string.lower(param or "")
    if param == "" then return nil end
    if param:find("side", 1, true) then return "side" end -- Origin 12 / Model 680 side grips (v0.10.0)
    if param:find("ang", 1, true) then return "ang" end
    if param:find("vertpro", 1, true) or param:find("vert_pro", 1, true) then return "vertpro" end
    if param:find("vert", 1, true) or param:find("smg_pose", 1, true) then return "vert" end
    if param:find("m203", 1, true) or param:find("gl_", 1, true) then return "gl" end
    return nil -- barrel / stock / mag offsets: the hand just slides along the gun (the left-hand IK follows the tag)
end
local GRIP_FALLBACK = { vertpro = "vert" }

-- MW Base only hands the grip parameter to the owner's viewmodel (client). Remember it on the weapon in every realm,
-- for every player's gun, by wrapping mg_base once it's registered.
local function hookGrips()
    local base = weapons.GetStored and weapons.GetStored("mg_base")
    if not base or base.MPM_GripHooked or not base.SetGripPoseParameter then return end
    base.MPM_GripHooked = true
    local set, build = base.SetGripPoseParameter, base.BuildCustomizedGun
    base.SetGripPoseParameter = function(self, value)
        self.MPM_Grip = value
        return set(self, value)
    end
    if build then
        base.BuildCustomizedGun = function(self, ...)
            self.MPM_Grip = nil -- attachments re-apply theirs in PostProcess
            return build(self, ...)
        end
    end
end
hook.Add("InitPostEntity", "MPM_GripHook", hookGrips)
hook.Add("OnReloaded", "MPM_GripHook", hookGrips)
timer.Simple(0, hookGrips)

function A.HoldName(g, stance, grip)
    local name = g["hold_" .. stance]
    if not name then return nil end
    local v = A.GripVariant(grip)
    if v and g.grips and not g.grips[v] then v = GRIP_FALLBACK[v] end
    if v and g.grips and g.grips[v] then return name .. "_" .. v end
    return name
end

function A.UpdateHold(ply, seqFor)
    local want
    local wep = ply:GetActiveWeapon()
    local st = MPM.GetState(ply)
    if A.CV.actions:GetBool() and IsValid(wep) and (wep.HasFlag or A.KitFor(wep)) and MPM.Guns and not NOHOLD[ply.MPM_Gait or ""]
        and st ~= MPM.S.SLIDE and st ~= MPM.S.DIVE then
        local g = MPM.Guns[A.GunKey(wep) or ""]
        local name = g and A.HoldName(g, A.Stance(ply), wep.MPM_Grip)
        if name then
            local seq = seqFor(ply, name)
            if seq and seq > 0 then want = seq end
        end
    elseif A.CV.actions:GetBool() and IsValid(wep) and wep.HasFlag and MPM.Guns and NOHOLD[ply.MPM_Gait or ""] then
        -- sprinting: a gun with MW's own sprint carry (the minigun) plays it as its hold (v0.11.1)
        local g = MPM.Guns[A.GunKey(wep) or ""]
        if g and g.hold_sprint then
            local seq = seqFor(ply, g.hold_sprint)
            if seq and seq > 0 then want = seq end
        end
    end
    -- (v0.10.3) re-add the hold when something cleared its slot: the base gamemode resets ATTACK_AND_RELOAD on
    -- PLAYERANIMEVENT_CANCEL_RELOAD (weapon switches / cancelled reloads) and the hold was only added when it CHANGED -
    -- booth dumps showed every gun's hold (and the fists' pose) missing from the layers
    if want and want == ply.MPM_HoldSeq and CurTime() >= (ply.MPM_HoldCheck or 0) then
        ply.MPM_HoldCheck = CurTime() + 0.2
        local found = false
        pcall(function()
            for i = 0, 14 do
                if ply:IsValidLayer(i) and ply:GetLayerSequence(i) == want then found = true break end
            end
        end)
        if not found then ply.MPM_HoldSeq = nil end
    end
    if want ~= ply.MPM_HoldSeq then
        if want then
            ply:AddVCDSequenceToGestureSlot(A.HoldSlot, want, 0, false)
        else
            ply:AnimResetGestureSlot(A.HoldSlot)
        end
        ply.MPM_HoldSeq = want
    end
    -- the hold is an ADDITIVE layer (incl. the gun's finger pose): fade it out while an action (draw / reload / bolt)
    -- plays its own full upper body + fingers, or the two stack (index finger "flying" on draws)
    if want then ply:AnimSetGestureWeight(A.HoldSlot, 1 - math.Clamp(ply.MPM_ActW or 0, 0, 1)) end
end

-- the shot kick fades out over its last third (it used to cut off when the gesture ended: v0.10.2)
function A.UpdateFire(ply)
    local k = ply.MPM_FireK
    if not k then return end
    local t = CurTime() - k.t0
    if t >= k.dur then ply.MPM_FireK = nil return end
    ply:AnimSetGestureWeight(A.FireSlot, math.Clamp((k.dur - t) / (k.dur * 0.35), 0, 1))
end

function A.StopHold(ply)
    if ply.MPM_HoldSeq then
        ply:AnimResetGestureSlot(A.HoldSlot)
        ply.MPM_HoldSeq = nil
    end
end

-- Gun track (Phase 6) ---------------------------------------------------------------------------------------------------
-- The gun's pose under the right hand this frame: the gun's resting hold pose (hip <-> ADS by AimDelta), blended toward
-- MW's own per-frame gun motion while an action plays (reload / bolt / inspect / draw), so the gun moves the way MW
-- animated it instead of being welded to the right hand. Returns pos (Vector), ang (Angle) or nil.
local function trackAt(trk, c, frames)
    local n = #trk / 6
    if n < 1 then return nil end
    local x = c * ((frames or 2) - 1) / 2
    local i = math.Clamp(math.floor(x), 0, n - 1)
    local j = math.min(i + 1, n - 1)
    local f = math.Clamp(x - i, 0, 1)
    local a, b = i * 6, j * 6
    local pos = LerpVector(f, Vector(trk[a + 1], trk[a + 2], trk[a + 3]), Vector(trk[b + 1], trk[b + 2], trk[b + 3]))
    local ang = LerpAngle(f, Angle(trk[a + 4], trk[a + 5], trk[a + 6]), Angle(trk[b + 4], trk[b + 5], trk[b + 6]))
    return pos, ang
end
A.TrackAt = trackAt

-- The gun's motion THIS frame as a delta in its own frame (pos, ang, action weight), or identity when no action plays.
-- MW's MP clips don't carry j_gun's rest offset, so its absolute pose under the hand is off by a constant (~24 u);
-- the motion relative to the clip's first frame (inv(J0) * J(t)) cancels any constant error exactly, so it's applied
-- on top of MW Base's own per-gun world-model offset: the gun sits where MW Base puts it and moves the way MW moved it.
function A.GunDelta(ply, wep)
    local a = ply.MPM_Act
    if not (a and a.entry and a.entry.gun and #a.entry.gun >= 12) then return vector_origin, angle_zero, 0 end
    local trk = a.entry.gun
    local c = math.Clamp((CurTime() - a.t0) / a.dur, 0, 1)
    local w = A.ActionWeight(c, a.dur, a.nofadein, a.chain)
    if a.cut then w = w * math.Clamp(1 - (CurTime() - a.cut) / 0.12, 0, 1) end
    local tp, ta = trackAt(trk, c, math.floor(a.entry.dur * 30 + 1.5))
    if not tp or w <= 0 then return vector_origin, angle_zero, w end
    local rp, ra = Vector(trk[1], trk[2], trk[3]), Angle(trk[4], trk[5], trk[6])
    local dp, da = WorldToLocal(tp, ta, rp, ra)
    return dp * w, LerpAngle(w, angle_zero, da), w
end
-- Notetracks of the running action (MW19 clips carry them; MWII clips borrow the same gun's MW19 reload / empty reload).
function A.ActionNotes(a)
    if not a or not a.entry then return nil end
    if a.entry.notes then return a.entry.notes end
    if a.kind == "reload" and a.gun then
        local g = MPM.Guns[a.gun]
        for _, k in ipairs({ "rel_stand", "emp_stand", "rel_crouch", "rel_prone" }) do
            if g and g[k] and g[k].notes then return g[k].notes end
        end
    end
    return nil
end

-- How much the left hand should IK onto the gun this frame (0..1).
--   bolt / pump cycles: the left hand holds the gun throughout -> 1
--   actions with notetracks: off between the clip's "left hand off" and "back on" (ramped over their start / end)
--   other actions: fades out with the action
function A.LeftHandWeight(ply, actW)
    local a = ply.MPM_Act
    if not a then return 1 end
    if a.kind == "rech" then return 1 end
    local n = A.ActionNotes(a)
    if n and n.ikout and n.ikin then
        local c = math.Clamp((CurTime() - a.t0) / a.dur, 0, 1)
        local o0, o1 = n.ikout, math.max(n.ikoutend or n.ikout + 0.05, n.ikout + 0.01)
        local i0, i1 = n.ikin, math.max(n.ikinend or n.ikin + 0.05, n.ikin + 0.01)
        if c < o0 then return 1 end
        if c < o1 then return 1 - (c - o0) / (o1 - o0) end
        if c < i0 then return 0 end
        if c < i1 then return (c - i0) / (i1 - i0) end
        return 1
    end
    return 1 - (actW or 0)
end

-- Firing (v0.9.3): MW's per-gun shot kick (additive upper body: hip / ADS, stand + prone, crouch borrows stand) on its
-- own slot so it stacks on everything, plus the gun's own per-shot part motion (bolt / slide / belt, cl_gun parts hook).
A.FireSlot = GESTURE_SLOT_FLINCH
A.CV.fire = CreateConVar("mpm_anim_fire", "1", FCVAR_ARCHIVE + FCVAR_REPLICATED, "MW per-gun firing kick + gun parts", 0, 1)
function A.OnFireGesture(ply, act)
    if not A.CV.fire:GetBool() then return end
    local wep = ply:GetActiveWeapon()
    if not (IsValid(wep) and wep.HasFlag and MPM.Guns and wep.HoldTypes and wep.GetCurrentHoldType) then return end
    local ht = wep.HoldTypes[wep:GetCurrentHoldType()]
    if not (ht and ht.Attack == act) then return end
    local key = A.GunKey(wep)
    local g = key and MPM.Guns[key]
    if not g then return end
    local st = A.Stance(ply)
    local e = (A.AdsAmount and A.AdsAmount(ply) > 0.5 and A.PickAction(key, "fireads", st)) or A.PickAction(key, "fire", st)
    local seq = e and A.SeqFor(ply, e.seq)
    if seq and seq > 0 then
        ply:AddVCDSequenceToGestureSlot(A.FireSlot, seq, 0, true)
        ply:AnimSetGestureWeight(A.FireSlot, 1)
        ply.MPM_FireK = { t0 = CurTime(), dur = math.max(e.dur or 0.3, 0.05) }
    end
    if g.firew then ply.MPM_FireW = { t0 = CurTime(), e = g.firew } end
end

-- The base gamemode's PLAYERANIMEVENT_CANCEL_RELOAD resets the ATTACK_AND_RELOAD slot - the slot carrying MPM's hold.
-- While MPM drives the player there is no HL2 reload gesture to cancel: keep the hold.
hook.Add("DoAnimationEvent", "MPM_KeepHold", function(ply, event)
    if event == PLAYERANIMEVENT_CANCEL_RELOAD and ply.MPM_AnimOut then return ACT_INVALID end
end)

-- Kit actions on the HL2 anim events (weapon_crowbar / weapon_frag / fists SWEPs call DoAnimationEvent on attack):
-- MW's melee hits (cycling 01-03), the frag throw, the RPG-7 reload. Returning an act stops the gamemode's HL2 gesture.
local KIT_ATTACK = { fists = { "melee", "melee2", "melee3" }, knife = { "melee", "melee2", "melee3" },
                     frag = { "throw" } }
hook.Add("DoAnimationEvent", "MPM_KitActions", function(ply, event, data)
    if not (ply.MPM_AnimOut and A.CV.actions:GetBool()) then return end
    local wep = ply:GetActiveWeapon()
    local kit = A.KitFor(wep)
    if not kit then return end
    local kind
    if event == PLAYERANIMEVENT_ATTACK_PRIMARY or event == PLAYERANIMEVENT_ATTACK_SECONDARY then
        local list = KIT_ATTACK[kit]
        if not list then return end
        ply.MPM_KitHit = ((ply.MPM_KitHit or 0) % #list) + 1
        -- walk the cycle until a kit clip exists (knife has 3 hits, a kit may have just one)
        for i = 0, #list - 1 do
            local k = list[((ply.MPM_KitHit - 1 + i) % #list) + 1]
            if A.PickAction(kit, k, A.Stance(ply)) then kind = k break end
        end
    elseif event == PLAYERANIMEVENT_RELOAD then
        kind = "reload"
    end
    if not kind then return end
    local e = A.PickAction(kit, kind, A.Stance(ply))
    if not e then return end
    startAction(ply, wep, A.SeqFor, e, kind, nil, e.dur)
    return ACT_INVALID
end)
