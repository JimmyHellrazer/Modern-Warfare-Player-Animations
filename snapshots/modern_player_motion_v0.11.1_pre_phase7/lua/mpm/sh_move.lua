-- SetupMove: state transitions and velocity. Runs predicted on the client and on the server.
-- The engine still does collision, stepping and gravity. We only steer its inputs:
--   * speed caps (inertia ramp, tac sprint, crawl)
--   * velocity during slide / dive / belly slide, pre-compensated for the engine's ground friction
local DT, F, S, CV = MPM.DT, MPM.F, MPM.S, MPM.CV
local band = bit.band

local sv_friction = GetConVar("sv_friction")
local sv_stopspeed = GetConVar("sv_stopspeed")
local sv_gravity = GetConVar("sv_gravity")

-- MW speeds (mpm_mwspeeds 1): ground speeds come from the built MW clips' measured root motion, per direction
-- (walk 103 / jog 199 / sprint 267 / tac 298 forward, slower sideways and back, crawl 23-34). Off = the gamemode's
-- walk / run speeds as before (DarkRP etc. keep control).
local function mw()
    return CV.mwspeeds:GetBool() and MPM.Clips and MPM.Anim and MPM.Clips.jog_ar and MPM.Clips.sprint_ar and true
end
MPM.UsingMWSpeeds = mw

function MPM.RunSpeed(ply)
    if mw() then return MPM.Clips.sprint_ar.dirs[8].speed end
    return ply:GetRunSpeed()
end

function MPM.WalkSpeed(ply)
    if mw() then return MPM.Clips.jog_ar.dirs[8].speed end
    return ply:GetWalkSpeed()
end

-- MW ground speed of a clip set in a direction (deg, 0 fwd, + left); nil if not available
function MPM.MWSpeed(name, ang)
    local c = MPM.Clips and MPM.Clips[name]
    if not c or not MPM.Anim then return nil end
    return MPM.Anim.ClipSpeed(c, ang)
end

local function approach(cur, target, step)
    if cur < target then return math.min(cur + step, target) end
    return math.max(cur - step, target)
end

-- Horizontal speed to hand the engine so that, after its ground friction this tick, the player moves at
-- `target`. Engine: drop = max(speed, stopspeed) * friction * dt (surface friction assumed 1).
function MPM.PreFriction(ply, target, dt)
    local k = sv_friction:GetFloat() * ply:GetFriction() * dt
    if target <= 0 then return 0 end
    if k >= 0.95 then return target end
    local stop = sv_stopspeed:GetFloat()
    local s = target / (1 - k)
    if s < stop then s = target + stop * k end
    return s
end

local function setHorizontal(mv, dir, speed)
    local v = mv:GetVelocity()
    mv:SetVelocity(Vector(dir.x * speed, dir.y * speed, v.z))
end

local function noInput(mv)
    mv:SetForwardSpeed(0)
    mv:SetSideSpeed(0)
    mv:SetUpSpeed(0)
end

-- Ground normal under the player, or nil in the air.
local function groundNormal(ply)
    local pos = ply:GetPos()
    local tr = util.TraceHull({
        start = pos + Vector(0, 0, 2), endpos = pos - Vector(0, 0, 12),
        mins = Vector(-4, -4, 0), maxs = Vector(4, 4, 4), mask = MASK_PLAYERSOLID, filter = ply,
    })
    return tr.Hit and tr.HitNormal or nil
end

-- Unit wish direction from the movement keys (horizontal, world space).
local function wishDir(ply, mv)
    local fwd, side = mv:GetForwardSpeed(), mv:GetSideSpeed()
    if fwd == 0 and side == 0 then return nil end
    local ang = mv:GetMoveAngles()
    local f, r = ang:Forward(), ang:Right()
    f.z, r.z = 0, 0
    f:Normalize(); r:Normalize()
    local d = f * fwd + r * side
    d.z = 0
    if d:LengthSqr() < 1e-6 then return nil end
    d:Normalize()
    return d
end

local function startSlide(ply, mv, now)
    local v = mv:GetVelocity(); v.z = 0
    local hsp = v:Length()
    local dir = hsp > 1 and v:GetNormalized() or (wishDir(ply, mv) or ply:GetForward())
    dir.z = 0
    local run = MPM.RunSpeed(ply)
    local speed = math.min(math.max(hsp, run) * CV.slide_boost:GetFloat(), run * CV.slide_maxspeed:GetFloat())
    MPM.SetFlag(ply, F.FROM_TAC, ply:GetDTInt(DT.STATE) == S.TAC)
    if CV.cancel_refill:GetBool() then ply:SetDTFloat(DT.METER, CV.tac_time:GetFloat()) end
    ply:SetDTVector(DT.DIR, dir)
    ply:SetDTFloat(DT.SPEED, speed)
    ply:SetDTFloat(DT.COOLDOWN, now + CV.slide_cooldown:GetFloat())
    MPM.SetState(ply, S.SLIDE)
    noInput(mv)
    setHorizontal(mv, dir, MPM.PreFriction(ply, speed, FrameTime()))
end

local function startDive(ply, mv, now)
    local v = mv:GetVelocity(); v.z = 0
    local hsp = math.max(v:Length(), MPM.RunSpeed(ply))
    local dir = v:Length() > 1 and v:GetNormalized() or ply:GetForward()
    dir.z = 0
    local speed = hsp * CV.dive_fwd:GetFloat()
    ply:SetDTVector(DT.DIR, dir)
    ply:SetDTFloat(DT.SPEED, speed)
    ply:SetDTFloat(DT.COOLDOWN, now + CV.slide_cooldown:GetFloat())
    mv:SetVelocity(Vector(dir.x * speed, dir.y * speed, CV.dive_up:GetFloat()))
    MPM.SetState(ply, S.DIVE)
end

local function enterProne(ply)
    MPM.ApplyHull(ply, true)
    MPM.SetFlag(ply, F.STAY_CROUCH, false)
    MPM.SetState(ply, S.PRONE_IN)
end

local function leaveProne(ply, toStand)
    if toStand and not MPM.CanStand(ply) then toStand = false end
    if not MPM.CanCrouch(ply) then return false end   -- no room: stay down
    MPM.ApplyHull(ply, false)
    MPM.SetFlag(ply, F.OUT_STAND, toStand)
    MPM.SetFlag(ply, F.BELLY, false)
    MPM.SetState(ply, S.PRONE_OUT)
    return true
end

hook.Add("SetupMove", "MPM_Move", function(ply, mv, cmd)
    if not MPM.Active(ply) then return end
    local raw = ply.MPM_Raw
    if not raw then return end
    local pressed, released = ply.MPM_Pressed, ply.MPM_Released
    ply.MPM_Raw = nil

    local function down(b) return band(raw, b) ~= 0 end
    local function hit(b) return band(pressed, b) ~= 0 end
    local function let(b) return band(released, b) ~= 0 end

    local now, dt = CurTime(), FrameTime()
    local st = ply:GetDTInt(DT.STATE)
    local stT = now - ply:GetDTFloat(DT.T_STATE)
    local onGround = ply:IsOnGround()
    local vel = mv:GetVelocity()
    local hsp = vel:Length2D()
    local walk, run = MPM.WalkSpeed(ply), MPM.RunSpeed(ply)
    -- input direction relative to the view (deg, 0 fwd, + left), taken before any state zeroes the input
    local fwdIn, sideIn = mv:GetForwardSpeed(), mv:GetSideSpeed()
    local moveAng = math.deg(math.atan2(-sideIn, fwdIn))
    local pk = MPM.ProneKey()

    -- double tap = sprint released and pressed again within the window (T_SPEED = last release)
    ply.MPM_DoubleTap = hit(IN_SPEED) and (now - ply:GetDTFloat(DT.T_SPEED)) <= CV.tac_window:GetFloat()
    if let(IN_SPEED) then ply:SetDTFloat(DT.T_SPEED, now) end
    local duckDouble = false
    if hit(IN_DUCK) then
        duckDouble = (now - ply:GetDTFloat(DT.T_DUCK)) <= CV.prone_window:GetFloat()
        ply:SetDTFloat(DT.T_DUCK, now)
    end
    local duckHeld = down(IN_DUCK) and (now - ply:GetDTFloat(DT.T_DUCK)) or 0

    -- tac sprint meter recharges whenever we're not tac sprinting
    local meter = ply:GetDTFloat(DT.METER)
    local full = CV.tac_time:GetFloat()
    if st ~= S.TAC and meter < full then
        ply:SetDTFloat(DT.METER, math.min(full, meter + dt * full / CV.tac_recharge:GetFloat()))
    end

    local sprintKeys = down(IN_SPEED) and down(IN_FORWARD) and not down(IN_BACK)
    local canSlide = CV.slide:GetBool() and now >= ply:GetDTFloat(DT.COOLDOWN)

    -- STAY_CROUCH ends on jump, sprint or another crouch press
    if MPM.HasFlag(ply, F.STAY_CROUCH) and (hit(IN_JUMP) or hit(IN_SPEED) or hit(IN_DUCK)) then
        MPM.SetFlag(ply, F.STAY_CROUCH, false)
    end

    ---------------------------------------------------------------------------------------------------------
    if st == S.NONE or st == S.SPRINT or st == S.TAC then
        -- crouch INTENT, not the engine's duck state: the engine is still un-ducking for a moment after a
        -- slide cancel and that must not knock us out of (tac) sprint
        local function crouchIntent()
            return (down(IN_DUCK) and not MPM.HasFlag(ply, F.EAT_DUCK) and not MPM.HasFlag(ply, F.DIVE_PENDING))
                or MPM.HasFlag(ply, F.STAY_CROUCH)
        end

        -- going prone (prone key, crouch double-tap or crouch hold while nearly still)
        local holdT = CV.prone_hold:GetFloat()
        local still = st == S.NONE and hsp < walk * 0.6
        if CV.prone:GetBool() and onGround and (
            (pk ~= 0 and hit(pk)) or
            (still and duckDouble and CV.prone_doubletap:GetBool()) or
            (still and holdT > 0 and duckHeld >= holdT)) then
            enterProne(ply)
            mv:SetVelocity(Vector(0, 0, vel.z))
            return
        end

        -- slide / dive decision (pending while crouch is held)
        if MPM.HasFlag(ply, F.DIVE_PENDING) then
            if not onGround or not sprintKeys then
                MPM.SetFlag(ply, F.DIVE_PENDING, false)
            elseif not down(IN_DUCK) then
                MPM.SetFlag(ply, F.DIVE_PENDING, false)
                if hsp >= run * CV.slide_minspeed:GetFloat() then startSlide(ply, mv, now) return end
            elseif duckHeld >= CV.dive_hold:GetFloat() then
                MPM.SetFlag(ply, F.DIVE_PENDING, false)
                startDive(ply, mv, now)
                return
            end
        elseif (st == S.SPRINT or st == S.TAC) and hit(IN_DUCK) and canSlide and onGround
            and hsp >= run * CV.slide_minspeed:GetFloat() then
            if CV.dive:GetBool() then
                MPM.SetFlag(ply, F.DIVE_PENDING, true)
            else
                startSlide(ply, mv, now)
                return
            end
        end

        -- sprint / tac sprint bookkeeping
        local new = S.NONE
        if sprintKeys and not crouchIntent() and (onGround or st ~= S.NONE) then
            new = S.SPRINT
            if st == S.TAC then
                new = (meter > 0) and S.TAC or S.SPRINT
            elseif CV.tac:GetBool() and ply.MPM_DoubleTap and meter > full * 0.15 then
                new = S.TAC
            end
        end
        if new ~= st then MPM.SetState(ply, new) end
        st = new

        if st == S.TAC then
            ply:SetDTFloat(DT.METER, math.max(0, meter - dt))
        end

        -- speed cap for this state (inertia below ramps toward it)
        if mw() then
            if fwdIn ~= 0 or sideIn ~= 0 then
                local name = (st == S.TAC and "tac_ar") or (st == S.SPRINT and "sprint_ar")
                    or (down(IN_WALK) and "walk_ar") or "jog_ar"
                local sp = MPM.MWSpeed(name, moveAng)
                if sp and sp > 1 then
                    mv:SetMaxClientSpeed(sp)
                    mv:SetMaxSpeed(sp)
                end
            end
        elseif st == S.TAC then
            local tac = run * CV.tac_mult:GetFloat()
            mv:SetMaxClientSpeed(tac)
            mv:SetMaxSpeed(tac)
        end

        -- inertia: ramp the speed cap up from the current speed, and stretch stops
        if CV.inertia:GetBool() and onGround then
            local target = mv:GetMaxClientSpeed()
            local cap = ply:GetDTFloat(DT.SPEED)
            local moving = mv:GetForwardSpeed() ~= 0 or mv:GetSideSpeed() ~= 0
            if moving then
                cap = math.max(cap, hsp)
                cap = approach(cap, target, run / CV.accel_time:GetFloat() * dt)
                mv:SetMaxClientSpeed(math.min(target, cap))
            else
                cap = hsp
                if hsp > 1 then
                    local want = math.max(0, hsp - run / CV.decel_time:GetFloat() * dt)
                    local d = Vector(vel.x, vel.y, 0); d:Normalize()
                    setHorizontal(mv, d, MPM.PreFriction(ply, want, dt))
                end
            end
            ply:SetDTFloat(DT.SPEED, cap)
        end
        return
    end

    ---------------------------------------------------------------------------------------------------------
    if st == S.SLIDE then
        -- slide cancel: crouch again -> stand straight up, keep the speed, back into (tac) sprint
        if CV.cancel:GetBool() and hit(IN_DUCK) and stT >= CV.cancel_mintime:GetFloat() then
            local keep = ply:GetDTFloat(DT.SPEED) * CV.cancel_keep:GetFloat()
            local sprinting = down(IN_SPEED) and down(IN_FORWARD) and not down(IN_BACK)
            local tac = sprinting and CV.tac:GetBool() and CV.cancel_tac:GetBool()
                and MPM.HasFlag(ply, F.FROM_TAC) and ply:GetDTFloat(DT.METER) > 0
            MPM.SetFlag(ply, F.FROM_TAC, false)
            MPM.SetFlag(ply, F.STAY_CROUCH, false)
            MPM.SetFlag(ply, F.EAT_DUCK, true)
            ply:SetDTFloat(DT.COOLDOWN, now + CV.cancel_cooldown:GetFloat())
            ply:SetDTFloat(DT.SPEED, keep) -- inertia cap starts at the slide speed: no re-acceleration
            MPM.SetState(ply, tac and S.TAC or (sprinting and S.SPRINT or S.NONE))
            noInput(mv)
            setHorizontal(mv, ply:GetDTVector(DT.DIR), MPM.PreFriction(ply, keep, dt))
            return
        end

        if hit(IN_JUMP) and onGround then
            -- jump out keeping momentum; the engine adds the jump
            MPM.SetState(ply, S.NONE)
            ply:SetDTFloat(DT.SPEED, hsp)
            return
        end
        if not onGround and stT > 0.1 then
            MPM.SetState(ply, S.NONE)
            ply:SetDTFloat(DT.SPEED, hsp)
            return
        end

        local dir = ply:GetDTVector(DT.DIR)
        local speed = ply:GetDTFloat(DT.SPEED)

        local wish = wishDir(ply, mv)
        if wish then
            local steer = math.rad(CV.slide_steer:GetFloat()) * dt
            local cross = dir.x * wish.y - dir.y * wish.x
            local ang = math.Clamp(math.atan2(cross, dir:Dot(wish)), -steer, steer)
            local c, s = math.cos(ang), math.sin(ang)
            dir = Vector(dir.x * c - dir.y * s, dir.x * s + dir.y * c, 0)
            ply:SetDTVector(DT.DIR, dir)
        end

        local n = groundNormal(ply)
        local slopeA = n and (n.x * dir.x + n.y * dir.y) * sv_gravity:GetFloat() * CV.slide_slope:GetFloat() or 0
        speed = speed + (slopeA - CV.slide_decel:GetFloat()) * dt
        speed = math.min(speed, run * CV.slide_maxspeed:GetFloat())

        local flatEnd = stT >= CV.slide_maxtime:GetFloat() and slopeA <= 0
        if speed <= walk * ply:GetCrouchedWalkSpeed() * 1.5 or flatEnd then
            MPM.SetState(ply, S.NONE)
            MPM.SetFlag(ply, F.STAY_CROUCH, true)
            ply:SetDTFloat(DT.SPEED, math.max(speed, 0))
            return
        end

        ply:SetDTFloat(DT.SPEED, speed)
        noInput(mv)
        setHorizontal(mv, dir, MPM.PreFriction(ply, speed, dt))
        return
    end

    ---------------------------------------------------------------------------------------------------------
    if st == S.DIVE then
        noInput(mv)
        if onGround and stT > 0.1 then
            MPM.ApplyHull(ply, true)
            MPM.SetFlag(ply, F.BELLY, true)
            ply:SetDTFloat(DT.SPEED, hsp)
            MPM.SetState(ply, S.PRONE)
        end
        return
    end

    ---------------------------------------------------------------------------------------------------------
    if st == S.PRONE_IN then
        MPM.ApplyHull(ply, true)
        noInput(mv)
        if onGround then setHorizontal(mv, Vector(1, 0, 0), 0) end
        if stT >= CV.prone_in_time:GetFloat() then MPM.SetState(ply, S.PRONE) end
        return
    end

    if st == S.PRONE_OUT then
        noInput(mv)
        if onGround then setHorizontal(mv, Vector(1, 0, 0), 0) end
        local stand = MPM.HasFlag(ply, F.OUT_STAND)
        local t = stand and CV.prone_out_stand:GetFloat() or CV.prone_out_crouch:GetFloat()
        if stT >= t then
            MPM.SetState(ply, S.NONE)
            MPM.SetFlag(ply, F.STAY_CROUCH, not stand)
            ply:SetDTFloat(DT.SPEED, 0)
        end
        return
    end

    if st == S.PRONE then
        MPM.ApplyHull(ply, true)
        if not onGround and not MPM.HasFlag(ply, F.BELLY) then
            -- fell off something: drop prone
            MPM.ApplyHull(ply, false)
            MPM.SetState(ply, S.NONE)
            return
        end

        -- getting up
        if (pk ~= 0 and hit(pk)) or hit(IN_JUMP) or (hit(IN_SPEED) and down(IN_FORWARD)) then
            if leaveProne(ply, true) then return end
        elseif hit(IN_DUCK) then
            if leaveProne(ply, false) then return end
        end

        if MPM.HasFlag(ply, F.BELLY) then
            local speed = ply:GetDTFloat(DT.SPEED) - CV.dive_landdecel:GetFloat() * dt
            if speed <= (mw() and MPM.MWSpeed("crawl_ar", 0) or CV.prone_speed:GetFloat()) then
                MPM.SetFlag(ply, F.BELLY, false)
            else
                ply:SetDTFloat(DT.SPEED, speed)
                noInput(mv)
                if onGround then setHorizontal(mv, ply:GetDTVector(DT.DIR), MPM.PreFriction(ply, speed, dt)) end
                return
            end
        end

        -- crawl: driven directly (not through the engine's crouch speed rules)
        local wish = wishDir(ply, mv)
        noInput(mv)
        if onGround then
            local cur = Vector(vel.x, vel.y, 0)
            local crawlSp = mw() and MPM.MWSpeed("crawl_ar", moveAng) or CV.prone_speed:GetFloat()
            local want = wish and wish * crawlSp or Vector(0, 0, 0)
            local step = CV.prone_accel:GetFloat() * dt
            local diff = want - cur
            if diff:Length() > step then diff = diff:GetNormalized() * step end
            local nv = cur + diff
            local sp = nv:Length()
            if sp > 0.5 then
                setHorizontal(mv, nv / sp, MPM.PreFriction(ply, sp, dt))
            else
                setHorizontal(mv, Vector(1, 0, 0), 0)
            end
        end
        return
    end
end)
