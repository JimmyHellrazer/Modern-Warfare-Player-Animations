-- StartCommand: remember the raw buttons, then rewrite the command for the current state.
-- Rewriting the CUserCmd (not just CMoveData) means weapon bases see the same keys the movement does.
local DT, F, S = MPM.DT, MPM.F, MPM.S
local band, bor, bnot = bit.band, bit.bor, bit.bnot

local function proneKey()
    local b = MPM.CV.prone_button:GetInt()
    return (b == 1 and IN_ALT1) or (b == 2 and IN_ALT2) or 0
end
MPM.ProneKey = proneKey

hook.Add("StartCommand", "MPM_Input", function(ply, cmd)
    if not MPM.Active(ply) then
        if ply:GetDTInt(DT.STATE) ~= S.NONE or ply.MPM_ProneHull then MPM.Reset(ply) end
        return
    end

    local raw = band(cmd:GetButtons(), MPM.BTN_MASK)
    local packed = ply:GetDTInt(DT.BTN)
    local prev = band(packed, MPM.BTN_MASK)

    -- consumed by SetupMove in the same RunCommand (transient, never carried across commands)
    ply.MPM_Raw = raw
    ply.MPM_Pressed = band(raw, bnot(prev))
    ply.MPM_Released = band(prev, bnot(raw))

    ply:SetDTInt(DT.BTN, bor(band(packed, bnot(MPM.BTN_MASK)), raw))

    -- rewrite ----------------------------------------------------------------------------------------------
    local st = ply:GetDTInt(DT.STATE)
    local b = cmd:GetButtons()
    local pk = proneKey()
    if pk ~= 0 then b = band(b, bnot(pk)) end

    -- after a slide cancel the crouch press that cancelled it must not crouch us
    if MPM.HasFlag(ply, F.EAT_DUCK) then
        if band(raw, IN_DUCK) ~= 0 then
            b = band(b, bnot(IN_DUCK))
        else
            MPM.SetFlag(ply, F.EAT_DUCK, false)
        end
    end

    if st == S.SLIDE then
        b = bor(band(b, bnot(IN_SPEED)), IN_DUCK)       -- weapons come up mid-slide; stay low
    elseif st == S.DIVE then
        b = bor(band(b, bnot(bor(IN_SPEED, IN_JUMP))), IN_DUCK)
    elseif st == S.MANTLE then
        b = band(b, bnot(bor(IN_SPEED, IN_JUMP, IN_DUCK, IN_ATTACK, IN_ATTACK2, IN_RELOAD)))
    elseif st == S.PRONE_IN or st == S.PRONE_OUT then
        b = bor(band(b, bnot(bor(IN_SPEED, IN_JUMP, IN_ATTACK, IN_ATTACK2))), IN_DUCK)
    elseif st == S.PRONE then
        b = bor(band(b, bnot(bor(IN_SPEED, IN_JUMP))), IN_DUCK)
        if not MPM.CV.prone_crawlfire:GetBool() and ply:GetVelocity():Length2D() > 15 then
            b = band(b, bnot(IN_ATTACK))
        end
    elseif st == S.SPRINT or st == S.TAC then
        if MPM.HasFlag(ply, F.DIVE_PENDING) then
            b = band(b, bnot(IN_DUCK))                  -- don't start crouching until slide/dive is decided
        end
        if st == S.TAC then b = bor(b, IN_SPEED) end
    elseif st == S.NONE and MPM.HasFlag(ply, F.STAY_CROUCH) then
        b = bor(b, IN_DUCK)
    end

    cmd:SetButtons(b)
end)
