-- mpm_debug 1: movement state overlay (top left).
local DT, S = MPM.DT, MPM.S

surface.CreateFont("MPM_Debug", { font = "Consolas", size = 16, weight = 500 })

local function line(y, txt, col)
    draw.SimpleTextOutlined(txt, "MPM_Debug", 24, y, col or color_white, 0, 0, 1, color_black)
    return y + 17
end

hook.Add("HUDPaint", "MPM_Debug", function()
    if not MPM.CVDebug:GetBool() then return end
    local ply = LocalPlayer()
    if not IsValid(ply) then return end

    local st = MPM.GetState(ply)
    local y = 120
    y = line(y, ("MPM %s  %s"):format(MPM.Version, MPM.CV.enabled:GetBool() and "on" or "OFF"),
        Color(120, 200, 255))
    y = line(y, ("state   %-10s %.2fs"):format(MPM.SName[st] or st, MPM.StateTime(ply)))
    y = line(y, ("speed   %6.1f  (walk %d  run %d)"):format(ply:GetVelocity():Length2D(),
        ply:GetWalkSpeed(), ply:GetRunSpeed()))
    y = line(y, ("z vel   %6.1f  %s"):format(ply:GetVelocity().z, ply:IsOnGround() and "ground" or "air"))
    y = line(y, ("meter   %4.2f / %.2f"):format(MPM.Meter(ply), MPM.CV.tac_time:GetFloat()))
    y = line(y, ("dtspeed %6.1f"):format(ply:GetDTFloat(DT.SPEED)))
    local flags = {}
    for name, f in pairs(MPM.F) do
        if f > 1 and MPM.HasFlag(ply, f) then flags[#flags + 1] = name end
    end
    y = line(y, "flags   " .. table.concat(flags, " "))
    local _, maxs = ply:GetHullDuck()
    y = line(y, ("duck h  %.0f  %s  %s"):format(maxs.z, ply:Crouching() and "crouching" or "",
        ply.MPM_ProneHull and "PRONE HULL" or ""))

    -- anim graph: what is actually playing (screenshot this when something looks wrong)
    local seqName = ply:GetSequenceName(ply:GetSequence()) or "?"
    local out = ply.MPM_AnimOut
    y = line(y, ("anim    %s  seq %s  cyc %.2f  rate %.2f"):format(out and ("MPM " .. (ply.MPM_Gait or "?") .. (out.shot and (" [" .. out.shot .. "]") or "")) or "HL2",
        seqName, ply:GetCycle(), ply:GetPlaybackRate()), out and Color(120, 255, 120) or Color(255, 200, 120))
    if out then
        y = line(y, ("blend   mx %.2f  my %.2f"):format(ply.MPM_MX or 0, ply.MPM_MY or 0))
    end
    local wep = ply:GetActiveWeapon()
    y = line(y, ("weapon  %s  set %s  holdtype %s"):format(IsValid(wep) and wep:GetClass() or "-",
        MPM.Anim and tostring(MPM.Anim.WeaponSet(ply)) or "-", IsValid(wep) and wep:GetHoldType() or "-"))
    do -- gun / hands (cl_gun): what the placement + IK are doing this frame
        local g = MPM.Guns and MPM.Anim and MPM.Anim.GunKey and IsValid(wep) and MPM.Guns[MPM.Anim.GunKey(wep) or ""]
        local a = ply.MPM_Act
        y = line(y, ("gun     %s  calib %s  action %s  letgo %.2f  R-IK %.2f  L-IK %.2f  grip %s"):format(
            g and (MPM.Anim.GunKey(wep) or "?") or "-", g and (g.gt and (g.gtest and "est" or "tags") or "OLD") or "-",
            a and (a.kind .. " " .. (a.entry and a.entry.from or "?")) or "-", ply.MPM_LetGo or 0, ply.MPM_RIKW or 0,
            ply.MPM_IKW or 0, IsValid(wep) and tostring(wep.MPM_Grip or (g and g.integ) or "-") or "-"),
            Color(200, 220, 255))
        y = line(y, ("hold    %s  w %.2f"):format(ply.MPM_HoldSeq and (ply:GetSequenceName(ply.MPM_HoldSeq) or "?") or "none",
            1 - math.Clamp(ply.MPM_ActW or 0, 0, 1)), Color(200, 220, 255))
    end
    y = line(y, ("models  mpm_air_ar %s  (rebuilt model needs a GAME RESTART)  eye pitch %.0f"):format(
        ply:LookupSequence("mpm_air_ar") > 0 and "found" or "MISSING", ply:EyeAngles().p))

    -- every pose parameter (index: name = value) - shows if a pitch-driven value lands where it shouldn't
    local parts = {}
    for i = 0, ply:GetNumPoseParameters() - 1 do
        parts[#parts + 1] = ("%d:%s=%.2f"):format(i, ply:GetPoseParameterName(i), ply:GetPoseParameter(i))
        if #parts == 4 then y = line(y, "pose    " .. table.concat(parts, "  ")); parts = {} end
    end
    if #parts > 0 then y = line(y, "pose    " .. table.concat(parts, "  ")) end

    -- active animation layers (gestures / overlays on top of the main sequence)
    local ok, err = pcall(function()
        local any = false
        for i = 0, 14 do
            if ply:IsValidLayer(i) then
                local w = ply:GetLayerWeight(i)
                if w > 0.01 then
                    any = true
                    y = line(y, ("layer %2d  %s  w %.2f  cyc %.2f"):format(i,
                        ply:GetSequenceName(ply:GetLayerSequence(i)) or "?", w, ply:GetLayerCycle(i)), Color(255, 160, 160))
                end
            end
        end
        if not any then y = line(y, "layers  none") end
    end)
    if not ok then line(y, "layers  n/a on client (" .. tostring(err):sub(1, 60) .. ")") end
end)
