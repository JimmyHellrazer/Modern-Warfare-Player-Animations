-- Minimal GMod mock + simplified Source walk move for the MPM movement core.
ADDON = ADDON or ""
SERVER, CLIENT = true, false
FCVAR_REPLICATED, FCVAR_ARCHIVE, FCVAR_NOTIFY = 1, 2, 4
MOVETYPE_WALK, MASK_PLAYERSOLID = 2, 1
IN_ATTACK, IN_JUMP, IN_DUCK, IN_FORWARD, IN_BACK = 1, 2, 4, 8, 16
IN_MOVELEFT, IN_MOVERIGHT, IN_ATTACK2, IN_RELOAD = 512, 1024, 2048, 8192
IN_ALT1, IN_ALT2, IN_SPEED, IN_WALK = 16384, 32768, 131072, 262144

function math.Clamp(v, a, b) return math.min(math.max(v, a), b) end
function Lerp(t, a, b) return a + (b - a) * t end
function LerpVector(t, a, b) return a + (b - a) * t end
function LerpAngle(t, a, b) return Angle(a.p + (b.p - a.p) * t, a.y + (b.y - a.y) * t, a.r + (b.r - a.r) * t) end
function math.NormalizeAngle(a) return (a + 180) % 360 - 180 end
ACT_MP_STAND_IDLE = 1
GESTURE_SLOT_ATTACK_AND_RELOAD, GESTURE_SLOT_CUSTOM, GESTURE_SLOT_GRENADE, GESTURE_SLOT_FLINCH = 0, 6, 1, 4
function AddCSLuaFile() end
function FindMetaTable() return nil end
function IsValid(x) return x ~= nil end
function IsFirstTimePredicted() return true end

-- Vector ---------------------------------------------------------------------------------------------------
local V = {}
V.__index = V
function Vector(x, y, z) return setmetatable({ x = x or 0, y = y or 0, z = z or 0 }, V) end
V.__add = function(a, b) return Vector(a.x + b.x, a.y + b.y, a.z + b.z) end
V.__sub = function(a, b) return Vector(a.x - b.x, a.y - b.y, a.z - b.z) end
V.__mul = function(a, b)
    if type(a) == "number" then a, b = b, a end
    return Vector(a.x * b, a.y * b, a.z * b)
end
V.__div = function(a, b) return Vector(a.x / b, a.y / b, a.z / b) end
function V:Length() return math.sqrt(self.x ^ 2 + self.y ^ 2 + self.z ^ 2) end
function V:Length2D() return math.sqrt(self.x ^ 2 + self.y ^ 2) end
function V:LengthSqr() return self.x ^ 2 + self.y ^ 2 + self.z ^ 2 end
function V:Dot(o) return self.x * o.x + self.y * o.y + self.z * o.z end
function V:GetNormalized() local l = self:Length(); if l == 0 then return Vector() end return self / l end
function V:Normalize() local l = self:Length(); if l > 0 then self.x, self.y, self.z = self.x / l, self.y / l, self.z / l end end
function V:Copy() return Vector(self.x, self.y, self.z) end
function V:IsZero() return self.x == 0 and self.y == 0 and self.z == 0 end
function V:DistToSqr(o) return (self - o):LengthSqr() end

local A = {}
A.__index = A
function Angle(p, y, r) return setmetatable({ p = p or 0, y = y or 0, r = r or 0 }, A) end
function A:Forward() local y = math.rad(self.y) return Vector(math.cos(y), math.sin(y), 0) end
function A:Right() local y = math.rad(self.y) return Vector(math.sin(y), -math.cos(y), 0) end

-- convars ---------------------------------------------------------------------------------------------------
CVARS = {}
local CVM = {}
CVM.__index = CVM
function CVM:GetFloat() return tonumber(self.v) end
function CVM:GetInt() return math.floor(tonumber(self.v)) end
function CVM:GetBool() return tonumber(self.v) ~= 0 end
local function mkcv(name, v) local c = setmetatable({ v = v, def = v }, CVM); CVARS[name] = c; return c end
function CreateConVar(name, def) return CVARS[name] or mkcv(name, def) end
function CreateClientConVar(name, def) return CreateConVar(name, def) end
function GetConVar(name) return CVARS[name] end
mkcv("sv_friction", "8"); mkcv("sv_stopspeed", "100"); mkcv("sv_gravity", "600"); mkcv("sv_accelerate", "10")
function SetCV(name, v) CVARS[name].v = tostring(v) end
function ResetCVs() for _, c in pairs(CVARS) do c.v = c.def end end

-- hooks -------------------------------------------------------------------------------------------------------
HOOKS = {}
EVENTS = {}
hook = {
    Add = function(ev, id, fn) HOOKS[ev] = HOOKS[ev] or {}; HOOKS[ev][id] = fn end,
    Run = function(ev, ...) EVENTS[#EVENTS + 1] = { ev, ... } end,
}
local function call(ev, ...) for _, fn in pairs(HOOKS[ev] or {}) do local r = fn(...) if r ~= nil then return r end end end

-- world: ground z = slope * x, optional ceiling --------------------------------------------------------------
WORLD = { slope = 0, ceiling = nil, boxes = {} }
local function groundZ(x) return WORLD.slope * x end

local function sweepBox(s, e, mins, maxs, b)
    local lo = Vector(b.min.x - maxs.x, b.min.y - maxs.y, b.min.z - maxs.z)
    local hi = Vector(b.max.x - mins.x, b.max.y - mins.y, b.max.z - mins.z)
    if s.x > lo.x and s.x < hi.x and s.y > lo.y and s.y < hi.y and s.z > lo.z and s.z < hi.z then
        return 0, Vector(0, 0, 1), true
    end
    local t0, t1, n = 0, 1, nil
    for _, ax in ipairs({ "x", "y", "z" }) do
        local d = e[ax] - s[ax]
        if math.abs(d) < 1e-9 then
            if s[ax] <= lo[ax] or s[ax] >= hi[ax] then return nil end
        else
            local a, c = (lo[ax] - s[ax]) / d, (hi[ax] - s[ax]) / d
            local na = Vector(); na[ax] = d > 0 and -1 or 1
            if a > c then a, c = c, a end
            if a > t0 then t0, n = a, na end
            if c < t1 then t1 = c end
            if t0 > t1 then return nil end
        end
    end
    if not n or t0 > 1 then return nil end
    return t0, n, false
end

local function trace(t, mins, maxs)
    local s, e = t.start, t.endpos
    local best, bn, solid = 1, nil, false
    for _, b in ipairs(WORLD.boxes or {}) do
        local f, n, ss = sweepBox(s, e, mins, maxs, b)
        if ss then solid = true end
        if f and not ss and f < best then best, bn = f, n end
    end
    if e.z < s.z then
        local gz = groundZ(s.x)
        if e.z <= gz + 0.01 and s.z >= gz then
            local f = (s.z - gz) / (s.z - e.z)
            if f < best then best, bn = f, Vector(-WORLD.slope, 0, 1):GetNormalized() end
        end
    end
    if WORLD.ceiling and (s.z + maxs.z > WORLD.ceiling or e.z + maxs.z > WORLD.ceiling + 0.01) then
        if s.z + maxs.z > WORLD.ceiling then solid = true end
        local f = (WORLD.ceiling - maxs.z - s.z) / math.max(e.z - s.z, 1e-9)
        if e.z > s.z and f < best then best, bn = math.max(f, 0), Vector(0, 0, -1) end
    end
    local hit = solid or bn ~= nil
    return { StartSolid = solid, AllSolid = solid, Hit = hit, Fraction = solid and 0 or best,
             HitPos = s + (e - s) * (solid and 0 or best), HitNormal = bn or Vector(0, 0, 1) }
end

util = {
    TraceHull = function(t) return trace(t, t.mins or Vector(), t.maxs or Vector()) end,
    TraceLine = function(t) return trace(t, Vector(), Vector()) end,
    AddNetworkString = function() end,
}
MASK_PLAYERSOLID_BRUSHONLY = 2
HITGROUP_GENERIC, HITGROUP_HEAD, HITGROUP_CHEST, HITGROUP_STOMACH = 0, 1, 2, 3
HITGROUP_LEFTARM, HITGROUP_RIGHTARM, HITGROUP_LEFTLEG, HITGROUP_RIGHTLEG = 4, 5, 6, 7
GESTURE_SLOT_SWIM, GESTURE_SLOT_VCD, GESTURE_SLOT_JUMP = 3, 5, 2
vector_origin = Vector(0, 0, 0)
FL_DUCKING = 2
net = { Start = function() end, WriteEntity = function() end, WriteUInt = function() end, SendPVS = function() end,
        Receive = function() end }
function CallHook(ev, ...) for _, fn in pairs(HOOKS[ev] or {}) do local r = fn(...) if r ~= nil then return r end end end

-- time ----------------------------------------------------------------------------------------------------------
NOW, DT_TICK = 0, 1 / 66
function CurTime() return NOW end
function FrameTime() return DT_TICK end

-- player ---------------------------------------------------------------------------------------------------------
local P = {}
P.__index = P
function NewPlayer()
    local p = setmetatable({
        dti = {}, dtf = {}, dtv = {},
        pos = Vector(0, 0, 0), vel = Vector(), onGround = true, ducked = false,
        hullMins = Vector(-16, -16, 0), hullMaxs = Vector(16, 16, 72),
        duckMins = Vector(-16, -16, 0), duckMaxs = Vector(16, 16, 36),
        viewDuck = Vector(0, 0, 28), yaw = 0, prevEngineBtn = 0,
    }, P)
    return p
end
function P:GetDTInt(i) return self.dti[i] or 0 end
function P:SetDTInt(i, v) self.dti[i] = v end
function P:GetDTFloat(i) return self.dtf[i] or 0 end
function P:SetDTFloat(i, v) self.dtf[i] = v end
function P:GetDTVector(i) return (self.dtv[i] or Vector()):Copy() end
function P:SetDTVector(i, v) self.dtv[i] = v:Copy() end
function P:Alive() return true end
function P:GetMoveType() return MOVETYPE_WALK end
function P:InVehicle() return false end
function P:WaterLevel() return 0 end
function P:GetPos() return self.pos:Copy() end
function P:GetVelocity() return self.vel:Copy() end
function P:IsOnGround() return self.onGround end
function P:Crouching() return self.ducked end
function P:GetWalkSpeed() return 200 end
function P:GetRunSpeed() return 400 end
function P:GetCrouchedWalkSpeed() return 0.3 end
function P:GetFriction() return 1 end
function P:GetForward() return Angle(0, self.yaw, 0):Forward() end
function P:GetHull() return self.hullMins, self.hullMaxs end
function P:GetStepSize() return 18 end
function P:AddFlags(f) if f == FL_DUCKING then self.ducked = true end end
function P:EyeAngles() return Angle(0, self.yaw, 0) end
function P:GetHullDuck() return self.duckMins:Copy(), self.duckMaxs:Copy() end
function P:SetHullDuck(a, b) self.duckMins, self.duckMaxs = a:Copy(), b:Copy() end
function P:GetViewOffsetDucked() return self.viewDuck:Copy() end
function P:SetViewOffsetDucked(v) self.viewDuck = v:Copy() end

-- mv / cmd ----------------------------------------------------------------------------------------------------------
local MV = {}
MV.__index = MV
function MV:GetVelocity() return self.vel:Copy() end
function MV:GetOrigin() return self.origin:Copy() end
function MV:SetOrigin(v) self.origin = v:Copy() end
function MV:SetVelocity(v) self.vel = v:Copy() end
function MV:GetForwardSpeed() return self.fwd end
function MV:SetForwardSpeed(v) self.fwd = v end
function MV:GetSideSpeed() return self.side end
function MV:SetSideSpeed(v) self.side = v end
function MV:SetUpSpeed(v) self.up = v end
function MV:GetMoveAngles() return Angle(0, self.yaw, 0) end
function MV:GetMaxClientSpeed() return self.maxc end
function MV:SetMaxClientSpeed(v) self.maxc = v end
function MV:SetMaxSpeed(v) self.maxs = v end

local CMD = {}
CMD.__index = CMD
function CMD:GetButtons() return self.b end
function CMD:SetButtons(b) self.b = b end

-- one tick: hooks, then a simplified CGameMovement walk/air move --------------------------------------------------------
LAST_BTN = 0
function Tick(ply, raw)
    NOW = NOW + DT_TICK
    local cmd = setmetatable({ b = raw }, CMD)
    call("StartCommand", ply, cmd)
    local b = cmd.b
    LAST_BTN = b
    local fwd = (bit.band(b, IN_FORWARD) ~= 0 and 10000 or 0) - (bit.band(b, IN_BACK) ~= 0 and 10000 or 0)
    local side = (bit.band(b, IN_MOVERIGHT) ~= 0 and 10000 or 0) - (bit.band(b, IN_MOVELEFT) ~= 0 and 10000 or 0)
    local running = bit.band(b, IN_SPEED) ~= 0 and (fwd ~= 0 or side ~= 0)
    local mv = setmetatable({ vel = ply.vel:Copy(), origin = ply.pos:Copy(), fwd = fwd, side = side, up = 0, yaw = ply.yaw,
        maxc = running and ply:GetRunSpeed() or ply:GetWalkSpeed() }, MV)
    mv.maxs = mv.maxc
    call("SetupMove", ply, mv, cmd)
    if call("Move", ply, mv) then
        ply.pos, ply.vel = mv.origin:Copy(), mv.vel:Copy()
        return
    end
    if (mv.origin - ply.pos):LengthSqr() > 1e-6 then ply.pos = mv.origin:Copy() end

    local v = mv.vel
    -- duck (instant in the sim)
    if bit.band(b, IN_DUCK) ~= 0 then ply.ducked = true
    elseif ply.ducked then
        local solid = WORLD.ceiling and (ply.pos.z + ply.hullMaxs.z > WORLD.ceiling)
        if not solid then ply.ducked = false end
    end
    -- jump
    local jumpHit = bit.band(b, IN_JUMP) ~= 0 and bit.band(ply.prevEngineBtn, IN_JUMP) == 0
    ply.prevEngineBtn = b
    if ply.onGround then
        local sp = math.sqrt(v.x ^ 2 + v.y ^ 2)
        if sp > 0.1 then
            local drop = math.max(sp, 100) * 8 * DT_TICK
            local ns = math.max(sp - drop, 0) / sp
            v.x, v.y = v.x * ns, v.y * ns
        end
        if jumpHit then v.z = 200 end
    end
    -- accelerate
    local ang = Angle(0, mv.yaw, 0)
    local wish = ang:Forward() * mv.fwd + ang:Right() * mv.side
    local ws = wish:Length2D()
    if ws > 0 then
        local wd = wish / ws
        ws = math.min(ws, mv.maxc)
        if ply.ducked and ply.onGround then ws = ws * ply:GetCrouchedWalkSpeed() end
        local cur = v.x * wd.x + v.y * wd.y
        local add = (ply.onGround and ws or math.min(ws, 30)) - cur
        if add > 0 then
            local acc = math.min(10 * ws * DT_TICK, add)
            v.x, v.y = v.x + wd.x * acc, v.y + wd.y * acc
        end
    end
    if not ply.onGround then v.z = v.z - 600 * DT_TICK end
    local np = ply.pos + v * DT_TICK
    local tr = trace({ start = ply.pos, endpos = np }, ply.hullMins, ply.ducked and ply.duckMaxs or ply.hullMaxs)
    if tr.Hit and not tr.StartSolid and tr.HitNormal.z < 0.7 then
        np = ply.pos + (np - ply.pos) * math.max(tr.Fraction - 0.01, 0)
        if tr.HitNormal.x ~= 0 then v.x = 0 end
        if tr.HitNormal.y ~= 0 then v.y = 0 end
    end
    ply.pos = np
    local gz = groundZ(ply.pos.x)
    for _, b in ipairs(WORLD.boxes or {}) do
        if ply.pos.x + ply.hullMaxs.x > b.min.x and ply.pos.x + ply.hullMins.x < b.max.x and ply.pos.z >= b.max.z - 1 then
            gz = math.max(gz, b.max.z)
        end
    end
    if not ply.onGround and ply.pos.z > gz + 0.5 then ply.wasAir = true end
    if v.z > 140 then ply.onGround = false end
    if ply.pos.z <= gz + 0.5 and v.z <= 0.01 or (ply.onGround and v.z <= 140) then
        ply.pos.z = gz
        if not ply.onGround and v.z < 0 then CallHook("OnPlayerHitGround", ply, false, false, -v.z) end
        if v.z < 0 or ply.onGround then v.z = 0 end
        ply.onGround = true
    end
    ply.vel = v
end

function Run(ply, raw, seconds)
    local n = math.floor(seconds / DT_TICK + 0.5)
    for _ = 1, n do Tick(ply, raw) end
end

-- state name helper
function SN(ply) return MPM.SName[MPM.GetState(ply)] end

timer = { Simple = function() end }
weapons = { GetStored = function() return nil end }
PLAYERANIMEVENT_ATTACK_PRIMARY, PLAYERANIMEVENT_ATTACK_SECONDARY, PLAYERANIMEVENT_RELOAD = 0, 1, 3
ACT_INVALID = -1
