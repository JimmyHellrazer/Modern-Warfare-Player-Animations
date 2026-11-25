-- Phase 2 check tools (until the anim graph exists):
--   mpm_check                 do playermodels see the MPM sequences? (client + server)
--   mpm_preview <clip> [dir]  play a clip on a copy of your playermodel in front of you (dir = numpad, default 8)
--   mpm_preview_all [dir]     every clip in a row
--   mpm_preview_stop
local DIRVEC = { [8] = { 1, 0 }, [2] = { -1, 0 }, [4] = { 0, 1 }, [6] = { 0, -1 },
                 [7] = { 1, 1 }, [9] = { 1, -1 }, [1] = { -1, 1 }, [3] = { -1, -1 }, [5] = { 0, 0 } }

local function countSeqs(ent)
    local n = 0
    for name in pairs(MPM.Clips or {}) do
        if ent:LookupSequence("mpm_" .. name) > 0 then n = n + 1 end
    end
    return n
end

if SERVER then
    concommand.Add("mpm_check_sv", function(ply)
        if not IsValid(ply) then return end
        local total = table.Count(MPM.Clips or {})
        ply:PrintMessage(HUD_PRINTCONSOLE, ("[MPM] server: %s has %d / %d MPM sequences"):format(
            ply:GetModel(), countSeqs(ply), total))
    end)
    return
end

local function clipInfo(name, dir)
    local c = MPM.Clips and MPM.Clips[name]
    if not c then return end
    local d = c.dirs and (c.dirs[dir] or c.dirs[8]) or c
    return c, d
end

concommand.Add("mpm_check", function()
    local total = table.Count(MPM.Clips or {})
    if total == 0 then print("[MPM] no clip data (lua/mpm/data/clips.lua missing)") return end
    local models = { LocalPlayer():GetModel(), "models/player/kleiner.mdl", "models/player/group01/female_02.mdl",
                     "models/player/combine_soldier.mdl" }
    for _, mdl in ipairs(models) do
        local e = ClientsideModel(mdl)
        if IsValid(e) then
            print(("[MPM] client: %-45s %d / %d MPM sequences, gun models %s"):format(mdl, countSeqs(e), total,
                (e:LookupSequence("mpm_h_mike4_stand") > 0 and e:LookupSequence("mpm_h_valpha_stand") > 0)
                    and "found" or "MISSING (nested include not followed?)"))
            e:Remove()
        end
    end
    RunConsoleCommand("mpm_check_sv")
end)

local previews = {}

local function stopAll()
    for _, p in ipairs(previews) do if IsValid(p.ent) then p.ent:Remove() end end
    previews = {}
end
concommand.Add("mpm_preview_stop", stopAll)

local function spawn(name, dir, offset)
    local c, d = clipInfo(name, dir)
    if not c then print("[MPM] unknown clip " .. tostring(name)) return end
    local ply = LocalPlayer()
    local ent = ClientsideModel(ply:GetModel())
    if not IsValid(ent) then return end
    local seq = ent:LookupSequence(c.seq)
    if seq <= 0 then
        print("[MPM] " .. ply:GetModel() .. " has no " .. c.seq .. " (include patch not active?)")
        ent:Remove()
        return
    end
    local fwd = ply:GetForward(); fwd.z = 0; fwd:Normalize()
    local right = fwd:Cross(Vector(0, 0, 1))
    ent:SetPos(ply:GetPos() + fwd * 120 + right * offset)
    ent:SetAngles(Angle(0, ply:EyeAngles().y + 180, 0))
    ent:SetSkin(ply:GetSkin())
    for i = 0, ply:GetNumBodyGroups() - 1 do ent:SetBodygroup(i, ply:GetBodygroup(i)) end
    ent:ResetSequence(seq)
    local v = DIRVEC[dir] or DIRVEC[8]
    previews[#previews + 1] = { ent = ent, seq = seq, dur = math.max(d.dur or 1, 0.05), mx = v[1], my = v[2],
                                name = name, speed = d.speed or 0 }
end

concommand.Add("mpm_preview", function(_, _, args)
    stopAll()
    spawn(args[1] or "walk_ar", tonumber(args[2]) or 8, 0)
end)

concommand.Add("mpm_preview_all", function(_, _, args)
    stopAll()
    local names = table.GetKeys(MPM.Clips or {})
    table.sort(names)
    local dir = tonumber(args[1]) or 8
    for i, n in ipairs(names) do spawn(n, dir, (i - (#names + 1) / 2) * 45) end
end)

hook.Add("Think", "MPM_Preview", function()
    if #previews == 0 then return end
    for _, p in ipairs(previews) do
        local e = p.ent
        if IsValid(e) then
            e:SetCycle((e:GetCycle() + FrameTime() / p.dur) % 1)
            e:SetPoseParameter(MPM.ClipParams.mx, p.mx)
            e:SetPoseParameter(MPM.ClipParams.my, p.my)
            e:InvalidateBoneCache()
        end
    end
end)

hook.Add("PostDrawTranslucentRenderables", "MPM_PreviewLabels", function()
    if #previews == 0 then return end
    local ang = Angle(0, LocalPlayer():EyeAngles().y - 90, 90)
    for _, p in ipairs(previews) do
        if IsValid(p.ent) then
            cam.Start3D2D(p.ent:GetPos() + Vector(0, 0, 80), ang, 0.15)
            draw.SimpleTextOutlined(("%s  %.0f u/s"):format(p.name, p.speed), "DermaLarge", 0, 0, color_white,
                TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER, 1, color_black)
            cam.End3D2D()
        end
    end
end)
