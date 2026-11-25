-- MPM dev tools (LOCAL ONLY - never ship): photo booth + in-game bone dump for Modern Player Motion.
--
--   mpm_photobooth [class ...]   poses each gun (default: one per category) in fixed states (hold, ADS, reload 30 / 70 %,
--                                draw 50 %, bolt / pump 40 %), shoots it from fixed cameras (front, right, three-quarter,
--                                top) and writes garrysmod/data/mpm_booth/<gun>_<state>_<cam>.png + one bone dump .json
--                                per state. Player frozen while it runs; mpm_photobooth_stop aborts.
--   mpm_bones                    dumps the bones / gun / MPM state right now to data/mpm_booth/bones_now.json and prints a
--                                short table to the console.
--   mpm_bones_draw 1             draws the gun's axes (red fwd / green left / blue up), its grip tags, the hands' axes
--                                and the IK target on screen.
if SERVER then
    AddCSLuaFile()
    util.AddNetworkString("mpm_booth")
    net.Receive("mpm_booth", function(_, ply)
        if not (game.SinglePlayer() or ply:IsSuperAdmin()) then return end
        local op, arg = net.ReadString(), net.ReadString()
        if op == "give" then
            if not ply:HasWeapon(arg) then ply:Give(arg) end
            ply:SelectWeapon(arg)
            local w = ply:GetWeapon(arg)
            if IsValid(w) and w.Primary and w.Primary.ClipSize then w:SetClip1(math.max(w.Primary.ClipSize, 1)) end
        elseif op == "freeze" then
            ply:Freeze(arg == "1")
        end
    end)
    return
end

local function V(v) return { math.Round(v.x, 2), math.Round(v.y, 2), math.Round(v.z, 2) } end
local function AN(a) return { math.Round(a.p, 1), math.Round(a.y, 1), math.Round(a.r, 1) } end

local BONES = {
    "ValveBiped.Bip01_Pelvis", "ValveBiped.Bip01_Spine4", "ValveBiped.Bip01_Neck1", "ValveBiped.Bip01_Head1",
    "ValveBiped.Bip01_R_Clavicle", "ValveBiped.Bip01_R_UpperArm", "ValveBiped.Bip01_R_Forearm", "ValveBiped.Bip01_R_Hand",
    "ValveBiped.Bip01_R_Finger1", "ValveBiped.Bip01_R_Finger11",
    "ValveBiped.Bip01_L_Clavicle", "ValveBiped.Bip01_L_UpperArm", "ValveBiped.Bip01_L_Forearm", "ValveBiped.Bip01_L_Hand",
    "ValveBiped.Bip01_L_Finger1", "ValveBiped.Bip01_L_Finger11",
}
for _, side in ipairs({ "R", "L" }) do -- every finger joint (the right index tip was reported "positioned crazy")
    for f = 0, 4 do
        for _, j in ipairs({ "", "1", "2" }) do
            local n = ("ValveBiped.Bip01_%s_Finger%d%s"):format(side, f, j)
            if not table.HasValue(BONES, n) then BONES[#BONES + 1] = n end
        end
    end
end
local WEP_BONES = { "tag_sling", "tag_pistol_offset", "ValveBiped.Bip01_R_Hand", "tag_ik_loc_ri", "tag_ik_loc_le",
    "tag_flash", "tag_mag_attach", "tag_grip_attach" }

-- everything relative to the player's feet, facing the body's yaw (x forward, y left, z up)
local function dump(ply)
    local A = MPM and MPM.Anim
    local base = ply:GetPos()
    local ra = Angle(0, (ply:GetRenderAngles() or ply:GetAngles()).y, 0)
    local function rel(m) local p, a = WorldToLocal(m:GetTranslation(), m:GetAngles(), base, ra) return { pos = V(p), ang = AN(a) } end
    local t = { time = os.date("%H:%M:%S"), body_yaw = math.Round(ra.y, 1), eye = AN(ply:EyeAngles()), bones = {}, gun = {} }
    ply:SetupBones()
    for _, n in ipairs(BONES) do
        local b = ply:LookupBone(n)
        local m = b and ply:GetBoneMatrix(b)
        if m then
            local e = rel(m)
            local pb = ply:GetBoneParent(b)
            local pm = pb and pb >= 0 and ply:GetBoneMatrix(pb)
            if pm then e.from_parent = V(pm:GetInverseTR() * m:GetTranslation()) e.len = math.Round(m:GetTranslation():Distance(pm:GetTranslation()), 2) end
            t.bones[n:gsub("ValveBiped.Bip01_", "")] = e
        end
    end
    -- every bone under the right hand that isn't one of the standard 15 finger joints (tip nubs / helper bones that a
    -- finger pose must carry along, or the mesh stretches)
    t.model = ply:GetModel()
    t.hand_extra = {}
    local rh = ply:LookupBone("ValveBiped.Bip01_R_Hand")
    local function walk(b, depth)
        for _, c in ipairs(ply:GetChildBones(b) or {}) do
            local n = ply:GetBoneName(c)
            if not n:find("^ValveBiped%.Bip01_R_Finger%d%d?$") then
                local m = ply:GetBoneMatrix(c)
                t.hand_extra[#t.hand_extra + 1] = { name = n, parent = ply:GetBoneName(b), pos = m and rel(m).pos }
            end
            if depth < 4 then walk(c, depth + 1) end
        end
    end
    if rh then walk(rh, 0) end
    local wep = ply:GetActiveWeapon()
    if IsValid(wep) then
        t.weapon = wep:GetClass()
        local key = A and A.GunKey and A.GunKey(wep)
        local g = key and MPM.Guns and MPM.Guns[key]
        t.gun_key = key
        t.calib = g and g.gt and (g.gtest and "estimated" or "tags") or (g and "OLD placement" or "no entry")
        t.gt = g and g.gt
        wep:SetupBones()
        for _, n in ipairs(WEP_BONES) do
            local b = wep:LookupBone(n)
            local m = b and wep:GetBoneMatrix(b)
            if m then t.gun[n] = rel(m) end
        end
        -- the gun relative to the player's right hand: what MPM asked for vs what the model actually shows
        local hb = ply:LookupBone("ValveBiped.Bip01_R_Hand")
        local hm = hb and ply:GetBoneMatrix(hb)
        local wmo = wep.WorldModelOffsets
        local sb = wmo and wep:LookupBone(wmo.Bone or "tag_sling")
        local sm = sb and wep:GetBoneMatrix(sb)
        if hm and sm then
            local p, a = WorldToLocal(sm:GetTranslation(), sm:GetAngles(), hm:GetTranslation(), hm:GetAngles())
            t.gun_in_hand_actual = { pos = V(p), ang = AN(a) }
        end
        if hm and A and A.GunWorld then
            -- the gun MPM computed in the bone callback (before the right-hand IK moved the hand) - recomputing it from
            -- the IK'd hand would report the IK's own correction as an error
            local gw = ply.MPM_GW
            local ok, wp, wa = gw ~= nil, gw and gw.wp, gw and gw.wa
            if ok and wp then
                local p, a = WorldToLocal(wp, wa, hm:GetTranslation(), hm:GetAngles())
                t.gun_in_hand_wanted = { pos = V(p), ang = AN(a) }
                if sm then
                    t.placement_error_u = math.Round(sm:GetTranslation():Distance(wp), 2)
                    local d = sm:GetAngles() - wa
                    d:Normalize()
                    t.placement_error_ang = AN(d)
                end
            end
        end
        if wmo then t.wmo = { bone = wmo.Bone, pos = V(wmo.Pos or vector_origin), ang = AN(wmo.Angles or angle_zero) } end
        if wep.MPM_RestM then
            local r = wep.MPM_RestM
            t.rest_measured = { pos = V(r.pos), ang = AN(r.ang), parent_pos = r.ppos and V(r.ppos), parent_ang = r.pang and AN(r.pang) }
        end
        t.grip_param = wep.MPM_Grip
        t.ads = A and A.AdsAmount and math.Round(A.AdsAmount(ply), 2)
        if wep.GetAimModeDelta then t.aim_mode = math.Round(wep:GetAimModeDelta(), 2) end
    end
    local a = ply.MPM_Act
    t.mpm = {
        graph = ply.MPM_AnimOut and ("MPM " .. tostring(ply.MPM_Gait)) or "HL2",
        sequence = ply:GetSequenceName(ply:GetSequence()),
        action = a and { kind = a.kind, from = a.entry and a.entry.from, cycle = math.Round(math.Clamp((CurTime() - a.t0) / a.dur, 0, 1), 3) } or nil,
        hold = ply.MPM_HoldSeq and ply:GetSequenceName(ply.MPM_HoldSeq) or nil,
        letgo = ply.MPM_LetGo, right_ik = ply.MPM_RIKW, left_ik = ply.MPM_IKW, right_fingers = ply.MPM_RFW,
        ik_target = ply.MPM_IKTarget and V(WorldToLocal(ply.MPM_IKTarget, angle_zero, base, ra)) or nil,
    }
    local pp = {}
    for i = 0, ply:GetNumPoseParameters() - 1 do
        local n = ply:GetPoseParameterName(i)
        if n:find("^mpm_") or n:find("aim") or n:find("head") then pp[n] = math.Round(ply:GetPoseParameter(i), 2) end
    end
    t.pose = pp
    local layers = {}
    pcall(function()
        for i = 0, 14 do
            if ply:IsValidLayer(i) and ply:GetLayerWeight(i) > 0.01 then
                layers[#layers + 1] = { slot = i, seq = ply:GetSequenceName(ply:GetLayerSequence(i)),
                    w = math.Round(ply:GetLayerWeight(i), 2), cyc = math.Round(ply:GetLayerCycle(i), 2) }
            end
        end
    end)
    t.layers = layers
    return t
end

local function write(name, t)
    file.CreateDir("mpm_booth")
    file.Write("mpm_booth/" .. name .. ".json", util.TableToJSON(t, true))
end

concommand.Add("mpm_bones", function()
    local ply = LocalPlayer()
    local t = dump(ply)
    write("bones_now", t)
    print(("[MPM] %s  calib %s  action %s  letgo %s  R-IK %s  L-IK %s  placement error %s u"):format(
        tostring(t.weapon), tostring(t.calib), t.mpm.action and (t.mpm.action.kind .. " " .. tostring(t.mpm.action.cycle)) or "-",
        tostring(t.mpm.letgo), tostring(t.mpm.right_ik), tostring(t.mpm.left_ik), tostring(t.placement_error_u)))
    for n, b in SortedPairs(t.bones) do print(("  %-14s pos %7.2f %7.2f %7.2f  ang %6.1f %6.1f %6.1f"):format(n, b.pos[1], b.pos[2], b.pos[3], b.ang[1], b.ang[2], b.ang[3])) end
    for n, b in SortedPairs(t.gun) do print(("  gun %-22s pos %7.2f %7.2f %7.2f  ang %6.1f %6.1f %6.1f"):format(n, b.pos[1], b.pos[2], b.pos[3], b.ang[1], b.ang[2], b.ang[3])) end
    print("[MPM] full dump: garrysmod/data/mpm_booth/bones_now.json")
end)

-- on-screen gun / hand axes -----------------------------------------------------------------------------------------------
local cvDraw = CreateClientConVar("mpm_bones_draw", "0", false, false, "Draw the gun's axes, grip tags, hand axes, IK target")
local function axes(m, len)
    local p = m:GetTranslation()
    render.DrawLine(p, p + m:GetForward() * len, Color(255, 0, 0), false)
    render.DrawLine(p, p - m:GetRight() * len, Color(0, 255, 0), false)
    render.DrawLine(p, p + m:GetUp() * len, Color(0, 120, 255), false)
end
hook.Add("PostDrawTranslucentRenderables", "MPM_BonesDraw", function()
    if not cvDraw:GetBool() then return end
    render.SetColorMaterial()
    for _, ply in ipairs(player.GetAll()) do
        local wep = ply:GetActiveWeapon()
        if IsValid(wep) then
            local wmo = wep.WorldModelOffsets
            local sb = wmo and wep:LookupBone(wmo.Bone or "tag_sling")
            local sm = sb and wep:GetBoneMatrix(sb)
            if sm then axes(sm, 10) end
            for n, col in pairs({ tag_ik_loc_ri = Color(255, 160, 0), tag_ik_loc_le = Color(0, 255, 255) }) do
                local b = wep:LookupBone(n)
                local m = b and wep:GetBoneMatrix(b)
                if m then render.DrawSphere(m:GetTranslation(), 0.8, 8, 8, col) end
            end
        end
        for _, n in ipairs({ "ValveBiped.Bip01_R_Hand", "ValveBiped.Bip01_L_Hand" }) do
            local b = ply:LookupBone(n)
            local m = b and ply:GetBoneMatrix(b)
            if m then axes(m, 4) end
        end
        if ply.MPM_IKTarget then render.DrawSphere(ply.MPM_IKTarget, 1, 8, 8, Color(0, 255, 0, 160)) end
    end
end)

-- photo booth -------------------------------------------------------------------------------------------------------------
local DEFAULT = { "mg_mike4", "mg_akilo47", "mg_pkilo", "mg_mgolf34", "mg_mpapa7", "mg_uzulu", "mg_charlie725",
    "mg_dpapa12", "mg_oscar12", "mg_kilo98", "mg_asierra12", "mg_glock", "mg_p320" }
local STATES = {
    { name = "hold", pin = { kind = "hold" } },
    { name = "ads", pin = { kind = "ads", ads = 1 } },
    { name = "rel30", pin = { kind = "reload", c = 0.3 } },
    { name = "rel70", pin = { kind = "reload", c = 0.7 } },
    { name = "draw50", pin = { kind = "raise", c = 0.5 } },
    { name = "draw95", pin = { kind = "raise", c = 0.95 } }, -- the draw's end, to compare with "hold"
    { name = "bolt40", pin = { kind = "rech", c = 0.4 }, only = "rech" },
}
-- camera around the chest, by the body's yaw: yaw offset, pitch, distance
local CAMS = {
    { name = "front", yaw = 0, pitch = 5, dist = 75 },
    { name = "right", yaw = -90, pitch = 5, dist = 70 },
    { name = "q3", yaw = -40, pitch = 15, dist = 70 },
    { name = "top", yaw = -20, pitch = 65, dist = 65 },
}

local booth -- { co, cam, shot, yaw0 }
local function wait(s)
    local t = CurTime() + s
    while CurTime() < t do coroutine.yield() end
end

local function hasAct(cls, kind)
    local A = MPM.Anim
    local key = cls:match("^mg_(.+)$")
    return key and A.PickAction and A.PickAction(key, kind, "stand") ~= nil
end

local function run(list)
    local ply = LocalPlayer()
    local A = MPM.Anim
    net.Start("mpm_booth") net.WriteString("freeze") net.WriteString("1") net.SendToServer()
    local index = {}
    for _, cls in ipairs(list) do
        if weapons.GetStored(cls) or (list.Get("Weapon") or {})[cls] then -- (HL2's weapon_frag etc. are engine weapons)
            net.Start("mpm_booth") net.WriteString("give") net.WriteString(cls) net.SendToServer()
            ply.MPM_Pin = nil
            booth.cam = CAMS[1] -- third person throughout: in first person the world model isn't drawn (nor placed)
            wait(2.5) -- deploy
            local wep = ply:GetActiveWeapon()
            if IsValid(wep) and wep:GetClass() == cls then
                for _, st in ipairs(STATES) do
                    local kind = st.pin.kind
                    local ok = kind == "hold" or kind == "ads" or hasAct(cls, kind == "reload" and "reload" or kind)
                    if ok then
                        ply.MPM_Pin = table.Copy(st.pin)
                        booth.cam = CAMS[1]
                        wait(0.6)
                        local t = dump(ply)
                        write(("%s_%s"):format(cls, st.name), t)
                        for _, cam in ipairs(CAMS) do
                            booth.cam = cam
                            wait(0.15)
                            booth.shot = ("%s_%s_%s"):format(cls, st.name, cam.name)
                            while booth.shot do coroutine.yield() end
                            index[#index + 1] = ("%s_%s_%s.png"):format(cls, st.name, cam.name)
                        end
                    end
                end
            else
                index[#index + 1] = cls .. ": could not equip"
            end
        else
            index[#index + 1] = cls .. ": not installed"
        end
    end
    ply.MPM_Pin = nil
    booth.cam = nil
    net.Start("mpm_booth") net.WriteString("freeze") net.WriteString("0") net.SendToServer()
    file.Write("mpm_booth/index.txt", table.concat(index, "\n"))
    print("[MPM] photo booth done: garrysmod/data/mpm_booth/ (" .. #index .. " shots)")
end

concommand.Add("mpm_photobooth", function(_, _, args)
    local list = #args > 0 and args or DEFAULT
    local ply = LocalPlayer()
    booth = { yaw0 = ply:EyeAngles().y }
    booth.co = coroutine.create(function() run(list) end)
    print("[MPM] photo booth: " .. #list .. " guns - don't touch anything (mpm_photobooth_stop aborts)")
end)
concommand.Add("mpm_photobooth_stop", function()
    if booth then
        LocalPlayer().MPM_Pin = nil
        net.Start("mpm_booth") net.WriteString("freeze") net.WriteString("0") net.SendToServer()
    end
    booth = nil
end)

hook.Add("Think", "MPM_Booth", function()
    if not (booth and booth.co) then return end
    local ply = LocalPlayer()
    ply:SetEyeAngles(Angle(0, booth.yaw0, 0)) -- aim straight ahead, body faces it
    local ok, err = coroutine.resume(booth.co)
    if not ok then print("[MPM] photo booth error: " .. tostring(err)) booth = nil ply.MPM_Pin = nil return end
    if coroutine.status(booth.co) == "dead" then booth = nil end
end)

hook.Add("CalcView", "MPM_Booth", function(ply, pos, angles, fov)
    if not (booth and booth.cam) then return end
    local c = booth.cam
    local yaw = (ply:GetRenderAngles() or ply:GetAngles()).y
    local center = ply:GetPos() + Vector(0, 0, 50)
    local dir = Angle(-c.pitch, yaw + c.yaw, 0):Forward()
    local eye = center + dir * c.dist
    return { origin = eye, angles = (center - eye):Angle(), fov = 60, drawviewer = true }
end)

hook.Add("HUDShouldDraw", "MPM_Booth", function() if booth and booth.cam then return false end end)

hook.Add("PostRender", "MPM_Booth", function()
    if not (booth and booth.shot) then return end
    local data = render.Capture({ format = "png", x = 0, y = 0, w = ScrW(), h = ScrH(), alpha = false })
    file.CreateDir("mpm_booth")
    if data then file.Write("mpm_booth/" .. booth.shot .. ".png", data) end
    booth.shot = nil
end)

-- finger tracker ------------------------------------------------------------------------------------------------------------
--   mpm_track_finger          arms it: records the RIGHT hand's fingers every frame from the next draw / raise / reload /
--                             inspect you start until it ends (+0.4 s), then writes data/mpm_booth/finger_<time>.json
--   mpm_track_finger 3        records the next 3 seconds instead, whatever plays
-- Per frame: the action (kind, clip, cycle, weight), MPM's finger / IK weights, and for every right finger joint its
-- local rotation, its bend (+ = backwards) and its tip offset from the hand - both as the ANIMATION gave it ("anim") and
-- after MPM's changes ("final": grip finger pose, IK, backward clamp).
local TRACK = { "R_Hand", "R_Finger0", "R_Finger01", "R_Finger02", "R_Finger1", "R_Finger11", "R_Finger12",
    "R_Finger2", "R_Finger21", "R_Finger22", "R_Finger3", "R_Finger31", "R_Finger32", "R_Finger4", "R_Finger41", "R_Finger42" }
local tracker -- { mode = "action"|"time", t_end, frames = {}, started }

local function sample(ply)
    local out = {}
    local hb = ply:LookupBone("ValveBiped.Bip01_R_Hand")
    local hm = hb and ply:GetBoneMatrix(hb)
    for _, n in ipairs(TRACK) do
        local b = ply:LookupBone("ValveBiped.Bip01_" .. n)
        local m = b and ply:GetBoneMatrix(b)
        local p = b and ply:GetBoneParent(b)
        local pm = p and p >= 0 and ply:GetBoneMatrix(p)
        if m and pm then
            local loc = pm:GetInverseTR() * m
            local x = loc:GetForward()
            local e = { ang = AN(loc:GetAngles()), bend = math.Round(math.deg(math.atan2(x.y, x.x)), 1),
                        side = math.Round(math.deg(math.atan2(x.z, x.x)), 1) }
            if hm and n ~= "R_Hand" then e.from_hand = V(hm:GetInverseTR() * m:GetTranslation()) end
            out[n] = e
        end
    end
    return out
end

local function traceHook(ply, phase)
        if not tracker or ply ~= LocalPlayer() then return end
        local a = ply.MPM_Act
        local f = FrameNumber()
        if tracker.mode == "action" and not tracker.started then
            if a and (a.kind == "draw" or a.kind == "raise" or a.kind == "drawc" or a.kind == "reload" or a.kind == "rel"
                or a.kind == "emp" or a.kind == "insp") then
                tracker.started, tracker.act = CurTime(), a
            else
                return
            end
        end
        local rec = tracker.cur
        if not rec or rec.f ~= f then
            if rec then tracker.frames[#tracker.frames + 1] = rec end
            rec = { f = f, t = math.Round(CurTime() - (tracker.started or tracker.t0), 3) }
            if a then
                rec.action = { kind = a.kind, from = a.entry and a.entry.from,
                    cycle = math.Round(math.Clamp((CurTime() - a.t0) / a.dur, 0, 1), 3) }
            end
            rec.act_w, rec.right_fingers, rec.letgo, rec.right_ik = ply.MPM_ActW, ply.MPM_RFW, ply.MPM_LetGo, ply.MPM_RIKW
            rec.hold = ply.MPM_HoldSeq and ply:GetSequenceName(ply.MPM_HoldSeq) or nil
            rec.main = ply:GetSequenceName(ply:GetSequence())
            -- every animation layer playing this frame (something added ~50 deg to the index mid-draw and dropped off)
            rec.layers = {}
            pcall(function()
                for i = 0, 14 do
                    if ply:IsValidLayer(i) then
                        rec.layers[#rec.layers + 1] = { i, ply:GetSequenceName(ply:GetLayerSequence(i)),
                            math.Round(ply:GetLayerWeight(i), 2), math.Round(ply:GetLayerCycle(i), 2) }
                    end
                end
            end)
            rec.pose = {}
            for _, n in ipairs({ "mpm_ads", "mpm_ay", "mpm_ap" }) do
                local i = ply:LookupPoseParameter(n)
                if i and i >= 0 then rec.pose[n] = math.Round(ply:GetPoseParameter(n), 2) end
            end
            tracker.cur = rec
        end
        rec[phase] = sample(ply)
end
-- (this file can load before MPM: autorun order is alphabetical - attach once MPM exists)
local function attach() if MPM and MPM.Anim then MPM.Anim.TraceHook = traceHook end end
attach()
timer.Simple(0, attach)
hook.Add("InitPostEntity", "MPM_FingerTrack", attach)

local function finish()
    if not tracker then return end
    if tracker.cur then tracker.frames[#tracker.frames + 1] = tracker.cur end
    local ply = LocalPlayer()
    local wep = ply:GetActiveWeapon()
    local out = { model = ply:GetModel(), weapon = IsValid(wep) and wep:GetClass() or nil, frames = tracker.frames }
    local name = "finger_" .. os.date("%H%M%S")
    file.CreateDir("mpm_booth")
    file.Write("mpm_booth/" .. name .. ".json", util.TableToJSON(out))
    print(("[MPM] finger track: %d frames -> garrysmod/data/mpm_booth/%s.json"):format(#tracker.frames, name))
    tracker = nil
end

concommand.Add("mpm_track_finger", function(_, _, args)
    local secs = tonumber(args[1] or "")
    tracker = { frames = {}, t0 = CurTime() }
    if secs then
        tracker.mode, tracker.started, tracker.t_end = "time", CurTime(), CurTime() + secs
        print(("[MPM] finger track: recording %.1f s"):format(secs))
    else
        tracker.mode = "action"
        print("[MPM] finger track armed: switch weapons / draw / reload now (records until the action ends)")
    end
end)

hook.Add("Think", "MPM_FingerTrack", function()
    if not tracker then return end
    local ply = LocalPlayer()
    if tracker.mode == "time" then
        if CurTime() >= tracker.t_end then finish() end
    elseif tracker.started then
        local a = ply.MPM_Act
        if not a or a ~= tracker.act then
            tracker.t_end = tracker.t_end or (CurTime() + 0.4) -- a little of what follows the action
            if CurTime() >= tracker.t_end then finish() return end
        end
        if CurTime() - tracker.started > 12 then finish() end
    end
end)

-- spawn menu: Utilities -> Modern Player Motion -> Dev tools (this addon only: never shipped) ------------------------
hook.Add("PopulateToolMenu", "MPM_DevMenu", function()
    spawnmenu.AddToolMenuOption("Utilities", "Modern Player Motion", "mpm_devtools", "Dev tools", "", "", function(p)
        p:ClearControls()
        p:Help("Local dev tools. Output goes to garrysmod/data/mpm_booth/.")
        local function btn(label, cmd)
            local b = p:Button(label)
            b.DoClick = function() LocalPlayer():ConCommand(cmd) end
        end
        p:Help("Photo booth: freezes you and shoots each gun in fixed poses from fixed cameras.")
        btn("Photo booth: one gun per category", "mpm_photobooth")
        btn("Photo booth: fists + frag", "mpm_photobooth weapon_fists weapon_frag")
        btn("Photo booth: the gun in my hands", "mpm_photobooth_current")
        btn("Stop the photo booth", "mpm_photobooth_stop")
        p:Help("Bone dump: the pose right now -> bones_now.json (bind it to a key to catch a glitch mid-animation).")
        btn("Dump bones now", "mpm_bones")
        p:CheckBox("Draw gun / hand axes", "mpm_bones_draw")
        p:Help("Finger tracker: the right fingers every frame through the next draw / reload, or for 3 seconds.")
        btn("Arm the finger tracker (then draw / reload)", "mpm_track_finger")
        btn("Track fingers for 3 s", "mpm_track_finger 3")
    end)
end)

-- the booth for whatever gun is in your hands
concommand.Add("mpm_photobooth_current", function()
    local w = LocalPlayer():GetActiveWeapon()
    if IsValid(w) then LocalPlayer():ConCommand("mpm_photobooth " .. w:GetClass()) end
end)
