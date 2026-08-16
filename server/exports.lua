--[[
    tickwatch — server/exports.lua

    The API other resources call. See docs/design.md, Public API.

    A write never raises into the caller: an export call runs inside somebody
    else's function on the main thread, and a metrics tool that can take down the
    thing it observes is worse than one whose graph goes flat. Rejections are
    counted, printed once, and returned as false.

    Register is the exception and raises — a declaration is made once at startup
    by a developer who is looking.
]]

local Exports = {}

-- nil until the startup sequence binds it. main.lua deliberately does not bind
-- when the exporter has refused to serve, so callers get false rather than
-- writing into a registry nothing will render.
local registry = nil

-- Distinct mistakes already printed. A caller in a hot path repeats its mistake
-- at the rate of that hot path.
local reported = {}
local reportedCount = 0
local REPORT_CAP = 64

-- Declarations that arrived before bind, replayed in arrival order at bind. The
-- cap is a runaway guard: this list is only ever as long as the number of
-- metrics the server's resources declare at startup.
local pending = {}
local pendingNames = {}
local pendingCount = 0
local PENDING_CAP = 256

-- Startup has three states, and queuing is only right in one of them. While the
-- decision is outstanding a declaration is held; once the exporter has refused
-- to serve, holding one would be a lie — nothing will ever replay it.
local refusedToStart = false

--------------------------------------------------------------------------------

local function countError(reason)
    if registry then
        -- pcall: this counter is itself a metric, and a capped or odd registry
        -- must not turn error reporting into a second error.
        pcall(registry.inc, registry, 'tickwatch_export_errors_total', { reason = reason })
    end
end

--- Refuse a call: count it, say so once, and return false.
local function refuse(reason, fmt, ...)
    countError(reason)

    local message = fmt:format(...)

    if not reported[message] and reportedCount < REPORT_CAP then
        reported[message] = true
        reportedCount = reportedCount + 1
        print(('[tickwatch] export rejected: %s'):format(message))

        if reportedCount == REPORT_CAP then
            print('[tickwatch] further export errors will be counted but not printed')
        end
    end

    return false
end

--- Arguments cross a serialization boundary, so nothing about their type is
--- guaranteed the way it would be inside this resource.
local function checkWrite(name, labels, value, needsValue)
    if registry == nil then
        return refuse('not_ready', 'tickwatch is not serving; %s was dropped', tostring(name))
    end

    if type(name) ~= 'string' then
        return refuse('bad_argument', 'metric name must be a string, got %s', type(name))
    end

    -- Never created on demand: a mistyped name would open a series that looks
    -- almost right, is never graphed, and consumes a slot under the cap.
    if registry.metrics[name] == nil then
        return refuse('unknown_metric',
            '%s is not registered — declare it with Register first', name)
    end

    if labels ~= nil and type(labels) ~= 'table' then
        return refuse('bad_argument', '%s labels must be a table or nil, got %s', name, type(labels))
    end

    if needsValue and (type(value) ~= 'number' or value ~= value) then
        return refuse('bad_argument', '%s value must be a number, got %s', name, type(value))
    end

    return true
end

--- Run a registry write, turning anything it raises into a refusal. The
--- registry's guards are worth keeping; reaching the caller's stack is not.
local function attempt(reason, fn, ...)
    local ok, err = pcall(fn, ...)
    if ok then return true end

    -- Strip Lua's chunk:line prefix, which points into this file and tells the
    -- caller nothing. The registry's own message already names the problem.
    local message = tostring(err):gsub('^.-:%d+:%s*', '')
    return refuse(reason, '%s', message)
end

--------------------------------------------------------------------------------
-- The API
--------------------------------------------------------------------------------

--- Declare a metric. Raises: see the header.
---
--- Callable before tickwatch has finished starting. The startup sequence yields
--- on an HTTP round trip to /info.json before it binds, so a resource that
--- registers at load time will always get here first, whatever the start order.
--- Definitions that arrive early are held and replayed at bind rather than
--- refused, because "declare your metrics at startup" is the documented usage
--- and it must not depend on which resource the server happened to load first.
function Exports.Register(def)
    if type(def) ~= 'table' then
        error('tickwatch: Register expects a definition table', 2)
    end

    if registry == nil then
        if refusedToStart then
            error('tickwatch: not serving — startup refused, so ' .. tostring(def.name)
                .. ' was not registered. Check the console for the reason.', 2)
        end

        if pendingCount >= PENDING_CAP then
            error('tickwatch: too many metrics registered before startup completed', 2)
        end

        -- Held, so the duplicate check below still catches a name declared twice
        -- before tickwatch was ready.
        if pendingNames[def.name] then
            error(('tickwatch: metric %s is already registered'):format(tostring(def.name)), 2)
        end

        pendingCount = pendingCount + 1
        pending[pendingCount] = def
        if type(def.name) == 'string' then pendingNames[def.name] = true end

        return true
    end

    registry:register(def)
    return true
end

--- Lets a caller register defensively without knowing who got there first.
--- Counts a queued declaration, so it answers the same before and after bind.
function Exports.IsRegistered(name)
    if type(name) ~= 'string' then return false end
    if pendingNames[name] then return true end
    return registry ~= nil and registry.metrics[name] ~= nil
end

--- Value is optional and defaults to 1, so it is only checked when supplied.
function Exports.Inc(name, labels, value)
    if not checkWrite(name, labels, value, value ~= nil) then return false end
    return attempt('bad_write', registry.inc, registry, name, labels, value)
end

function Exports.Set(name, labels, value)
    if not checkWrite(name, labels, value, true) then return false end
    return attempt('bad_write', registry.set, registry, name, labels, value)
end

function Exports.Observe(name, labels, value)
    if not checkWrite(name, labels, value, true) then return false end
    return attempt('bad_write', registry.observe, registry, name, labels, value)
end

--- Observe the time since a GetGameTimer() reading the caller took itself.
---
--- There is no StartTimer, and the design specified one twice: a returned
--- closure costs 6.2 us to call across the boundary, and a version returning a
--- plain number would charge ~7 us for a GetGameTimer() the caller can do for
--- 0.093 us. What is worth the crossing is the conversion — Prometheus base
--- units are seconds, and milliseconds passed to Observe give a histogram wrong
--- by a factor of a thousand that looks entirely plausible.
function Exports.ObserveSince(name, labels, startedAt)
    if type(startedAt) ~= 'number' then
        return refuse('bad_argument', '%s ObserveSince needs a GetGameTimer() reading, got %s',
            tostring(name), type(startedAt))
    end

    local elapsed = (GetGameTimer() - startedAt) / 1000

    -- Negative means the reading was not GetGameTimer's — os.time() is the likely
    -- culprit. Not a duration, and a histogram cannot be un-poisoned.
    if elapsed < 0 then
        return refuse('bad_argument',
            '%s ObserveSince got a start time in the future — is it a GetGameTimer() reading?',
            tostring(name))
    end

    return Exports.Observe(name, labels, elapsed)
end

--------------------------------------------------------------------------------
-- Convenience wrappers for the four pre-declared metrics
--------------------------------------------------------------------------------
-- One agreed name and unit across every server running this, and two registry
-- writes behind one boundary crossing instead of two.

--- Count an event, and optionally record how long it took.
function Exports.Event(name, seconds)
    if type(name) ~= 'string' then
        return refuse('bad_argument', 'Event needs a name, got %s', type(name))
    end

    local ok = Exports.Inc('fivem_events_total', { event = name })

    if seconds ~= nil then
        ok = Exports.Observe('fivem_event_duration_seconds', { event = name }, seconds) and ok
    end

    return ok
end

--- Count a database query by operation and outcome, and record its duration.
function Exports.Query(op, status, seconds)
    if type(op) ~= 'string' then
        return refuse('bad_argument', 'Query needs an op, got %s', type(op))
    end

    -- Collapsed to two values: free text here would be unbounded, and a failed
    -- query is exactly when a caller passes the driver's message straight through.
    local outcome = status == 'error' and 'error' or 'ok'

    local ok = Exports.Inc('fivem_db_queries_total', { op = op, status = outcome })

    if seconds ~= nil then
        ok = Exports.Observe('fivem_db_query_duration_seconds', { op = op }, seconds) and ok
    end

    return ok
end

--------------------------------------------------------------------------------
-- Wiring
--------------------------------------------------------------------------------

--- Called by the startup sequence once every check has passed, and not at all
--- when one has not.
---
--- Replays anything registered while we were still starting. A bad definition
--- cannot be raised into its caller from here — that stack is long gone — so it
--- is printed and counted, which is the same bargain every other write makes.
function Exports.bind(reg)
    registry = reg
    refusedToStart = false

    for i = 1, pendingCount do
        local def = pending[i]
        local ok, err = pcall(reg.register, reg, def)

        if not ok then
            local message = tostring(err):gsub('^.-:%d+:%s*', '')
            refuse('bad_registration', 'deferred registration of %s failed: %s',
                tostring(def.name), message)
        end

        pending[i] = nil
    end

    pending = {}
    pendingNames = {}
    pendingCount = 0
end

--- How many declarations are still waiting for bind. For tests and diagnostics.
function Exports.pending()
    return pendingCount
end

--- Called by the startup sequence on every path that will not serve. Turns the
--- queue from "waiting" into "never", which is the difference between a caller
--- being early and a caller being wrong — and says so once, naming the metrics,
--- because otherwise a resource that registered during startup simply never
--- appears and nothing anywhere explains why.
function Exports.refuseToStart()
    refusedToStart = true

    if pendingCount > 0 then
        local names = {}
        for i = 1, pendingCount do names[i] = tostring(pending[i].name) end
        print(('[tickwatch] not serving, so %d metric(s) declared by other resources were dropped: %s')
            :format(pendingCount, table.concat(names, ', ')))
    end

    pending = {}
    pendingNames = {}
    pendingCount = 0
end

--- For tests, and for the state where startup refused.
function Exports.unbind()
    registry = nil
    reported = {}
    reportedCount = 0
    pending = {}
    pendingNames = {}
    pendingCount = 0
    refusedToStart = false
end

-- Registered at load rather than at bind, so a caller that starts first gets a
-- refusal it can see instead of "no such export", which reads like a missing
-- dependency rather than a server that declined to start.
exports('Register', Exports.Register)
exports('IsRegistered', Exports.IsRegistered)
exports('Inc', Exports.Inc)
exports('Set', Exports.Set)
exports('Observe', Exports.Observe)
exports('ObserveSince', Exports.ObserveSince)
exports('Event', Exports.Event)
exports('Query', Exports.Query)

_G.Exports = Exports
