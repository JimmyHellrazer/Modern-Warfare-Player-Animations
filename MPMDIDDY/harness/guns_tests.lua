-- Weapon actions (sh_anim_guns.lua): per-gun clip picking + fade.
local A = MPM.Anim
local T = {}
local function near(a, b, e) return math.abs(a - b) <= (e or 0.01) end

T[#T + 1] = { "gun table: M4 reload / empty / inspect / raise in every stance, all MW19 (crouch borrows stand)", function()
    local g = MPM.Guns and MPM.Guns.mike4
    if not g then return false, "no MPM.Guns.mike4" end
    local miss = {}
    for _, a in ipairs({ "rel", "emp", "insp", "raise" }) do
        for _, s in ipairs({ "stand", "crouch", "prone" }) do
            local e = g[a .. "_" .. s] or (s == "crouch" and g[a .. "_stand"])
            if not e then miss[#miss + 1] = a .. "_" .. s
            elseif e.from:find("^iw9_") then miss[#miss + 1] = a .. "_" .. s .. "=MWII" end
        end
    end
    return #miss == 0, table.concat(miss, " ")
end }

T[#T + 1] = { "PickAction: empty reload, crouch fallback to stand, prone never borrows stand", function()
    local e1, s1, a1 = A.PickAction("mike4", "reload", "stand", true)
    local e2, s2 = A.PickAction("akilo47", "reload", "crouch", false)   -- AK has no crouch clip
    local e3 = A.PickAction("dblmg", "reload", "prone", false)           -- dblmg has no prone reload
    return a1 == "emp" and s1 == "stand" and s2 == "stand" and e2 ~= nil and e3 == nil,
        ("%s/%s, ak crouch -> %s, dblmg prone -> %s"):format(tostring(a1), tostring(s1), tostring(s2), tostring(e3))
end }

T[#T + 1] = { "PickAction: empty falls back to normal reload when a gun has none", function()
    local e, s, a = A.PickAction("crossbow", "reload", "stand", true)
    return e ~= nil and a == "rel", tostring(a)
end }

T[#T + 1] = { "PickAction: aliased pistol (glock -> golf21) found, unknown gun -> nil", function()
    return A.PickAction("glock", "reload", "stand") ~= nil and A.PickAction("nope", "insp", "stand") == nil
        and MPM.Guns.gamma3 ~= nil, ""
end }

T[#T + 1] = { "ActionWeight: fades in and out, full in the middle", function()
    return near(A.ActionWeight(0, 2), 0) and near(A.ActionWeight(0.5, 2), 1) and near(A.ActionWeight(1, 2), 0)
        and A.ActionWeight(0.02, 2) > 0 and A.ActionWeight(0.02, 2) < 1, ""
end }


T[#T + 1] = { "MagVariant from MW Base's NextReloadSeq", function()
    return A.MagVariant("Reload_Empty_XmagLrg") == "xl" and A.MagVariant("Reload_Xmag_Fast") == "x"
        and A.MagVariant("Reload_Drum") == "xl" and A.MagVariant("Reload_Empty") == nil and A.MagVariant(nil) == nil, ""
end }

T[#T + 1] = { "PickAction: mag variant first, falls back to the plain reload", function()
    local g = MPM.Guns.mike4
    local e1, _, a1 = A.PickAction("mike4", "reload", "stand", true, "xl")
    local e2, _, a2 = A.PickAction("mike4", "reload", "stand", false, "x")
    local want1 = g.empxl_stand and "empxl" or (g.relxl_stand and "relxl" or "emp")
    local want2 = g.relx_stand and "relx" or "rel"
    return a1 == want1 and a2 == want2, ("%s / %s"):format(tostring(a1), tostring(a2))
end }

T[#T + 1] = { "PickAction: normal draw vs first raise, holster", function()
    local _, _, a = A.PickAction("mike4", "draw", "stand")
    local _, _, b = A.PickAction("mike4", "raise", "stand")
    local h = A.PickAction("mike4", "hol", "stand")
    return (a == "drawc" or a == "draw") and b == "raise" and h ~= nil, ("draw->%s raise->%s hol %s"):format(tostring(a), tostring(b), tostring(h and h.from))
end }

T[#T + 1] = { "MW19 wins: M4 standing reload comes from the MW19 set", function()
    local e = MPM.Guns.mike4.rel_stand
    return e and not e.from:find("^iw9_"), e and e.from or "none"
end }

T[#T + 1] = { "ActionWeight: draws start at full weight", function()
    return near(A.ActionWeight(0, 1, true), 1) and near(A.ActionWeight(0, 1, false), 0), ""
end }


T[#T + 1] = { "draw: a gun without its own normal draw borrows a same-class one, not the first raise", function()
    local own = MPM.Guns.akilo47.draw_stand
    local e, _, a = A.PickAction("akilo47", "draw", "stand")
    return own == nil and (a == "draw" or a == "drawc") and e ~= nil and not e.from:find("first"), e and e.from or "none"
end }


T[#T + 1] = { "holds: M4 + X16 have stand / crouch / prone hold layers and gun poses", function()
    local m, gl = MPM.Guns.mike4, MPM.Guns.glock
    local ok = m.hold_stand and m.hold_crouch and m.hold_prone and m.gunhold_stand and #m.gunhold_stand == 6
        and gl.hold_prone ~= nil
    return ok and true or false, ("m4 %s/%s/%s glock prone %s"):format(tostring(m.hold_stand), tostring(m.hold_crouch),
        tostring(m.hold_prone), tostring(gl.hold_prone))
end }

T[#T + 1] = { "gun track: M4 reload has MW's gun motion + mag notetracks", function()
    local r = MPM.Guns.mike4.rel_stand
    local n = r.notes or {}
    local trk = r.gun or {}
    local p0 = A.TrackAt(trk, 0, r.frames)
    return #trk >= 12 and n.magout and n.magin and n.magout < n.magin and p0 ~= nil,
        ("%d samples, magout %.2f magin %.2f ikout %s ikin %s"):format(#trk / 6, n.magout or -1, n.magin or -1,
            tostring(n.ikout), tostring(n.ikin))
end }

T[#T + 1] = { "rechamber: Kar98k / HDR bolt and 870 pump clips", function()
    local k, h, r = MPM.Guns.kilo98, MPM.Guns.hdromeo, MPM.Guns.romeo870
    return k.rech_stand ~= nil and h.rech_stand ~= nil and r.rech_stand ~= nil,
        ("%s / %s / %s"):format(k.rech_stand and k.rech_stand.from or "-", h.rech_stand and h.rech_stand.from or "-",
            r.rech_stand and r.rech_stand.from or "-")
end }

T[#T + 1] = { "chest sling preferred for rifles / SMGs, back carry for snipers", function()
    local _, _, a = A.PickAction("mike4", "draw", "stand")
    local _, _, b = A.PickAction("kilo98", "draw", "stand")
    return a == "drawc" and (b == "draw" or b == "drawc"), ("rifle %s, sniper %s"):format(tostring(a), tostring(b))
end }

T[#T + 1] = { "left hand IK: off inside the reload's hand window, on for bolt cycles", function()
    local e = MPM.Guns.mike4.rel_stand
    local n = e.notes
    if not (n and n.ikout and n.ikin) then return false, "no ik notes" end
    local ply = { MPM_Act = { kind = "reload", entry = e, t0 = NOW - (n.ikout + n.ikin) / 2 * 2, dur = 2 } }
    local mid = A.LeftHandWeight(ply, 1)
    ply.MPM_Act.kind = "rech"
    return mid == 0 and A.LeftHandWeight(ply, 1) == 1, ("mid-window %.2f"):format(mid)
end }

T[#T + 1] = { "shell reloads: MW Base piece names -> start / loop", function()
    return A.LoopSegment("Reload_Start") == "rels" and A.LoopSegment("Reload_Start_Empty") == "rels"
        and A.LoopSegment("Reload_Loop") == "rell" and A.LoopSegment("Reload_Loop_Empty") == "rell"
        and A.LoopSegment("Reload_End") == nil, ""
end }

T[#T + 1] = { "shell reloads: 870 has start / loop / end; a loop gun without them borrows its class's", function()
    local e1, _, a1 = A.PickAction("romeo870", "rels", "stand")
    local e2, _, a2 = A.PickAction("romeo870", "rell", "crouch")   -- no crouch clip: stand
    local e3, _, a3 = A.PickAction("romeo870", "rele", "prone")
    return e1 ~= nil and e2 ~= nil and e3 ~= nil and a1 == "rels" and a2 == "rell" and a3 == "rele",
        ("%s %s %s"):format(tostring(e1 and e1.from), tostring(e2 and e2.from), tostring(e3 and e3.from))
end }

T[#T + 1] = { "chained shell pieces don't fade out at their end", function()
    return near(A.ActionWeight(0.999, 1, true, true), 1) and A.ActionWeight(0.999, 1, true, false) < 0.1, ""
end }

T[#T + 1] = { "grip variants: MW Base grip params -> finger variant (barrels / stocks -> none)", function()
    local ok = A.GripVariant("grip_vert_offset") == "vert" and A.GripVariant("grip_ang_offset") == "ang"
        and A.GripVariant("grip_barshort_gripang_offset") == "ang" and A.GripVariant("grip_vert_pro_offset") == "vertpro"
        and A.GripVariant("grip_gripvertpro_offset") == "vertpro" and A.GripVariant("grip_m203_offset") == "gl"
        and A.GripVariant("grip_barshort_offset") == nil and A.GripVariant(nil) == nil
    return ok, ""
end }

T[#T + 1] = { "grip variants: M4 with a vertical grip gets its grip hold, unknown grip the default", function()
    local g = MPM.Guns.mike4
    if not g.grips then return false, "no grips built" end
    local v = A.HoldName(g, "stand", "grip_vert_offset")
    local d = A.HoldName(g, "stand", "grip_barshort_offset")
    return v == g.hold_stand .. "_vert" and d == g.hold_stand, tostring(v)
end }

T[#T + 1] = { "kits built: fists / knife holds + melee, frag hold + throw, passive hold", function()
    local G, miss = MPM.Guns, {}
    local want = { fists = { "hold_stand", "melee_stand", "draw_stand" }, knife = { "hold_stand", "melee_stand" },
                   frag = { "hold_stand", "throw_stand" }, passive = { "hold_stand" }, rpg = { "hold_stand" } }
    for k, keys in pairs(want) do
        for _, key in ipairs(keys) do
            if not (G[k] and G[k][key]) then miss[#miss + 1] = k .. "." .. key end
        end
    end
    return #miss == 0, table.concat(miss, " ")
end }

T[#T + 1] = { "gun actions have real lengths (cached clips used to read 0 frames -> dur 0.001, no gun motion)", function()
    local bad = {}
    for g, entry in pairs(MPM.Guns) do
        for k, e in pairs(entry) do
            if type(e) == "table" and e.seq and e.dur and e.dur < 0.1 then bad[#bad + 1] = g .. "." .. k end
        end
    end
    return #bad == 0, #bad .. " short: " .. table.concat(bad, " ", 1, math.min(#bad, 8))
end }

T[#T + 1] = { "MWII gun rig: iw9 reloads keep the gun in the right hand (gun track moves < 6 u)", function()
    local n, bad, worst = 0, {}, 0
    -- any MWII reload in use (since v0.10.1 MW19 wins the class pick, so only gaps MW19 lacks are MWII)
    for g, entry in pairs(MPM.Guns) do
      for k, e in pairs(entry) do
        if type(e) == "table" and (k:find("^rel_") or k:find("^emp_")) and e.from and e.from:find("^iw9_")
            and e.gun and #e.gun >= 12 then
            n = n + 1
            local mx = 0
            for i = 1, #e.gun, 6 do
                local dx, dy, dz = e.gun[i] - e.gun[1], e.gun[i + 1] - e.gun[2], e.gun[i + 2] - e.gun[3]
                mx = math.max(mx, math.sqrt(dx * dx + dy * dy + dz * dz))
            end
            worst = math.max(worst, mx)
            if mx > 6 then bad[#bad + 1] = ("%s %.0f"):format(g, mx) end
        end
      end
    end
    return #bad <= n * 0.2, ("%d iw9 reloads, worst %.1f u, over: %s"):format(n, worst, table.concat(bad, " "))
end }

T[#T + 1] = { "gun parts: 725 draw breaks the barrel, PKM reload opens the lid + moves the belt, draws never move mags", function()
    local G = MPM.Guns
    local r725 = G.charlie725 and G.charlie725.raise_stand
    local pk = G.pkilo and G.pkilo.rel_stand
    local okA = r725 and r725.parts and r725.parts.j_barrel and r725.parts.j_barrel.a
    local okB = pk and pk.parts and pk.parts.j_upperreceiver and pk.parts.j_b_01
    local bad = {}
    for g, entry in pairs(G) do
        for k, e in pairs(entry) do
            local kind = type(e) == "table" and k:match("^(%a+)_")
            if kind and (kind == "raise" or kind == "draw" or kind == "drawc" or kind == "hol" or kind == "holc")
                and e.parts and (e.parts.j_mag1 or e.parts.j_mag2) then bad[#bad + 1] = g .. "." .. k end
        end
    end
    return okA and okB and #bad == 0, ("725 break %s, pk lid %s, draws with mags: %s"):format(tostring(okA ~= nil),
        tostring(okB ~= nil), table.concat(bad, " "))
end }

T[#T + 1] = { "gun parts: a visible mag is never more than 30 u from its seat", function()
    local worst, at = 0, ""
    for g, entry in pairs(MPM.Guns) do
        for k, e in pairs(entry) do
            for _, b in ipairs({ "j_mag1", "j_mag2" }) do
                local tr = type(e) == "table" and e.parts and e.parts[b]
                if tr and tr.p and tr.v then
                    for i = 1, #tr.v do
                        local x, y, z = tr.p[i * 3 - 2], tr.p[i * 3 - 1], tr.p[i * 3]
                        local d = math.sqrt(x * x + y * y + z * z)
                        if tr.v[i] == 1 and d > worst then worst, at = d, g .. "." .. k .. "." .. b end
                    end
                end
            end
        end
    end
    return worst <= 30.01, ("worst visible %.1f u at %s"):format(worst, at)
end }

-- v0.10.0 gun rework ---------------------------------------------------------------------------------------------------
T[#T + 1] = { "grip calibration: most MW Base guns placed on MW's grip (gt), M4 matches its tags, pistols estimated", function()
    local n, est = 0, 0
    for _, e in pairs(MPM.Guns) do
        if type(e) == "table" and e.gt then n = n + 1 if e.gtest then est = est + 1 end end
    end
    local m = MPM.Guns.mike4 and MPM.Guns.mike4.gt
    local okM = m and near(m[1], 10.99, 0.3) and near(m[2], 5.69, 0.3) and near(m[3], 9.67, 0.3) -- from action ends
    local g = MPM.Guns.glock
    return n >= 45 and okM and g and g.gt and g.gtest, ("%d calibrated (%d estimated), M4 %s"):format(n, est,
        m and table.concat(m, " ") or "none")
end }

T[#T + 1] = { "body-anchored gun: PKM reload + 725 first raise carry a clavicle track the same length as the hand one", function()
    local pk = MPM.Guns.pkilo and MPM.Guns.pkilo.rel_stand
    local r7 = MPM.Guns.charlie725 and MPM.Guns.charlie725.raise_stand
    local ok = pk and pk.gunc and #pk.gunc == #pk.gun and r7 and r7.gunc and #r7.gunc == #r7.gun
    return ok, ("pkm %s/%s, 725 %s"):format(pk and pk.gunc and #pk.gunc or 0, pk and pk.gun and #pk.gun or 0,
        r7 and r7.gunc and #r7.gunc or 0)
end }

T[#T + 1] = { "mags: the M4 tactical reload hides the new mag while it's at the pouches (not seated, not in a hand)", function()
    local e = MPM.Guns.mike4 and MPM.Guns.mike4.rel_stand
    local tr = e and e.parts and (e.parts.j_mag2 or e.parts.j_mag1)
    if not (tr and tr.v) then return false, "no mag track" end
    local hidden, shown = 0, 0
    for _, v in ipairs(tr.v) do if v == 0 then hidden = hidden + 1 else shown = shown + 1 end end
    return hidden > 0 and shown > 0, ("%d hidden / %d shown samples"):format(hidden, shown)
end }

T[#T + 1] = { "fingers: per-gun right + left finger poses baked (15 bones x 3), grip variants carry their own left hand", function()
    local m = MPM.Guns.mike4
    local ok = m and m.fr and #m.fr == 45 and m.fl and #m.fl == 45
    local nv = 0
    for _, e in pairs(MPM.Guns) do
        if type(e) == "table" and (e.fl_vert or e.fl_ang or e.fl_side) then nv = nv + 1 end
    end
    return ok and nv >= 20, ("mike4 %s/%s, guns with grip hands %d"):format(m and m.fr and #m.fr or 0,
        m and m.fl and #m.fl or 0, nv)
end }

T[#T + 1] = { "grips: side grips recognised, Origin 12 has its own side-grip hand", function()
    local o = MPM.Guns.oscar12
    return A.GripVariant("grip_sidegrip_offset") == "side" and A.GripVariant("grip_vert_offset") == "vert"
        and A.GripVariant("grip_ang_offset") == "ang" and o and o.fl_side ~= nil, tostring(o and o.fl_side ~= nil)
end }

T[#T + 1] = { "fists: held in MWII's fists idle (own hold + fingers); slima / bullpups keep the old placement", function()
    local f = MPM.Guns.fists
    local G = MPM.Guns
    return f and f.hold_stand ~= nil and f.fr ~= nil and G.slima and G.slima.gt ~= nil and G.lima86 and not G.lima86.gt,
        tostring(f and f.hold_stand)
end }

-- v0.10.1 ---------------------------------------------------------------------------------------------------------------
T[#T + 1] = { "let-go is measured against MW's real grip: the M4 reload keeps the gun in hand, the MG34 reload lets go", function()
    local function frac(e)
        if not (e and e.lg) then return nil end
        local n = 0
        for _, v in ipairs(e.lg) do if v > 0.5 then n = n + 1 end end
        return n / #e.lg
    end
    local m4, mg = frac(MPM.Guns.mike4.rel_stand), frac(MPM.Guns.mgolf34.rel_stand)
    return m4 and mg and m4 < 0.1 and mg > 0.4, ("M4 %.2f  MG34 %.2f of the reload let go"):format(m4 or -1, mg or -1)
end }

T[#T + 1] = { "placement data: model rest (srest), real grip (jg) on calibrated guns; AK magwell + Oden built-in grip", function()
    local bad = {}
    for k, e in pairs(MPM.Guns) do
        if type(e) == "table" and e.gt and not (e.srest and e.jg) then bad[#bad + 1] = k end
    end
    local ak, od = MPM.Guns.akilo47, MPM.Guns.asierra12
    return #bad == 0 and ak and ak.lhg ~= nil and od and od.integ == "vert", "missing: " .. table.concat(bad, " ")
end }

T[#T + 1] = { "MW19 first: AUG and M14 use MW19's clips (sm / sn), not MWII's (ar / dm)", function()
    local a, m = MPM.Guns.augolf, MPM.Guns.mike14
    local ra, rm = a and a.rel_stand, m and m.rel_stand
    return a and m and a.cls == "sm" and m.cls == "sn" and ra and not ra.from:find("^iw9_") and rm and not rm.from:find("^iw9_"),
        ("aug %s %s, m14 %s %s"):format(a and a.cls, ra and ra.from, m and m.cls, rm and rm.from)
end }

T[#T + 1] = { "shot kicks: the M19 (p320) borrows the Glock's, the broken .357 / RPG-hip kicks (muzzle down) are gone", function()
    local G = MPM.Guns
    local m19 = G.p320 and G.p320.fire_stand
    local bad = (G["357"] and G["357"].fire_stand and G["357"].fire_stand.from:find("cpapa")) or (G.rpg and G.rpg.fire_stand)
    return m19 and m19.from:find("golf21") ~= nil and not bad, tostring(m19 and m19.from)
end }

T[#T + 1] = { "left hand: every calibrated gun carries MW's real left-hand pose on the gun (jl)", function()
    local miss = {}
    for k, e in pairs(MPM.Guns) do
        if type(e) == "table" and e.gt and not (e.jl and #e.jl == 6) then miss[#miss + 1] = k end
    end
    return #miss == 0, table.concat(miss, " ")
end }

T[#T + 1] = { "minigun: its own animation set (MW's minigun aim circles + hold) is built and the gun points at it", function()
    local g = MPM.Guns.dblmg
    return g and g.set == "mg" and MPM.Clips.idle_mg ~= nil and MPM.Clips.walk_mg ~= nil and g.hold_sprint ~= nil,
        tostring(g and g.set) .. " sprint " .. tostring(g and g.hold_sprint)
end }

return T
