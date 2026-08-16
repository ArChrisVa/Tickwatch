--[[
    tickwatch — server/collectors.lua

    Declares the metric catalog and fills it. The catalog is data, so a test can
    assert against it without running a server.

    Four rules shape this file, argued in docs/design.md:

      * Collection is scheduled, never on demand — a scrape must not be able to
        make the server do work.
      * A pass is bounded and its cost was measured on a live server first. The
        figures are in docs/platform-notes.md.
      * Boolean-shaped and error-shaped native results are normalised at the call
        site: this runtime returns 1/0 for booleans and 0 for "no such player",
        and neither raises.
      * A collector that keeps failing retires rather than printing on the main
        thread every interval for the life of the process.
]]

local Collectors = {}

--------------------------------------------------------------------------------
-- Buckets
--------------------------------------------------------------------------------

-- A ping is a network round trip: the default ladder's bottom three bounds sit
-- below anything GetPlayerPing can report, and players live at 20-300 ms.
local PING_BUCKETS = { 0.01, 0.02, 0.03, 0.05, 0.075, 0.1, 0.15, 0.2, 0.3, 0.5, 1 }

-- Minutes to hours. Every default bound is under a second, so the whole
-- distribution would land in the overflow slot.
local SESSION_BUCKETS = { 60, 300, 900, 1800, 3600, 7200, 14400, 28800 }

-- No bound may sit on the value the mass occupies. This server frames at 20 Hz,
-- so the metric floors at 50 ms — and a bound *at* 0.05 makes histogram_quantile
-- interpolate downward into the bucket below, which read p50 = 45.3 ms for a
-- quantity that cannot go under 50. 0.045/0.055 bracket the baseline instead.
-- 0.15 and 0.5 are exact because alerts fire on them. 0.033 is a sentinel: if it
-- ever fills, the 20 Hz assumption changed and this ladder wants re-deriving.
-- Full derivation in docs/platform-notes.md; a test asserts the rule.
local TICK_BUCKETS = { 0.033, 0.045, 0.055, 0.07, 0.09, 0.12, 0.15, 0.25, 0.5, 1, 2.5, 5 }

--------------------------------------------------------------------------------
-- The catalog
--------------------------------------------------------------------------------

-- Data, not code: a test registers the whole table into a real registry.
local METRICS = {
    ----------------------------------------------------------------------------
    -- The server
    ----------------------------------------------------------------------------
    {
        name = 'fivem_server_up',
        type = 'gauge',
        help = 'Always 1 while the exporter is running. Its absence is the signal.',
    },
    {
        name = 'fivem_server_uptime_seconds',
        type = 'gauge',
        help = 'Seconds since the server process started.',
    },
    {
        -- The info pattern: a gauge fixed at 1 whose labels carry the values.
        name = 'fivem_server_info',
        type = 'gauge',
        help = 'Server build and game, as labels on a constant 1.',
        labels = { 'version', 'gamename' },
        cap = 4,
    },
    {
        name = 'fivem_server_tick_interval_seconds',
        type = 'histogram',
        help = 'Interval between successive frames, observed by the exporter\'s own thread. Scheduler delay, used as a proxy for server load. Healthy is the 20 Hz baseline near 0.05.',
        buckets = TICK_BUCKETS,
    },

    ----------------------------------------------------------------------------
    -- Players
    ----------------------------------------------------------------------------
    {
        name = 'fivem_players_connected',
        type = 'gauge',
        help = 'Players currently connected.',
    },
    {
        name = 'fivem_players_max',
        type = 'gauge',
        help = 'Player slots configured, from sv_maxclients.',
    },
    {
        name = 'fivem_player_ping_seconds',
        type = 'histogram',
        help = 'Distribution of connected players\' ping, sampled once per players pass.',
        buckets = PING_BUCKETS,
    },
    {
        name = 'fivem_player_connections_total',
        type = 'counter',
        help = 'Connection attempts by outcome. attempted is the denominator; joined is the numerator.',
        labels = { 'result' },
        cap = 8,
    },
    {
        name = 'fivem_player_drops_total',
        type = 'counter',
        help = 'Players dropped, by normalised reason.',
        labels = { 'reason' },
        cap = 16,
    },
    {
        name = 'fivem_player_session_duration_seconds',
        type = 'histogram',
        help = 'How long a session lasted, observed when the player drops.',
        buckets = SESSION_BUCKETS,
    },

    ----------------------------------------------------------------------------
    -- Entities
    ----------------------------------------------------------------------------
    {
        name = 'fivem_entities',
        type = 'gauge',
        help = 'Server-side entities by type.',
        labels = { 'type' },
        cap = 8,
    },

    ----------------------------------------------------------------------------
    -- Resources
    ----------------------------------------------------------------------------
    {
        -- One series per resource, so the server sets the label set, not us. At
        -- the measured 583.5 B per labelled gauge series, this cap is ~570 KiB —
        -- the same order as the default cap's worst case.
        name = 'fivem_resource_up',
        type = 'gauge',
        help = 'Resource state: 1 while started, 0 in every other state.',
        labels = { 'resource' },
        cap = 1000,
    },

    ----------------------------------------------------------------------------
    -- Pushed by other resources through the export API
    ----------------------------------------------------------------------------
    -- Declared here so the common cases have one agreed name and unit across
    -- every server running this. A caller with anything else registers its own.
    {
        -- Caller-supplied labels: the one place in the catalog where cardinality
        -- is bounded by the cap rather than by construction.
        name = 'fivem_events_total',
        type = 'counter',
        help = 'Events pushed by other resources, by event name.',
        labels = { 'event' },
    },
    {
        name = 'fivem_event_duration_seconds',
        type = 'histogram',
        help = 'How long a pushed event took, by event name.',
        labels = { 'event' },
    },
    {
        name = 'fivem_db_queries_total',
        type = 'counter',
        help = 'Database queries pushed by other resources, by operation and outcome.',
        labels = { 'op', 'status' },
        cap = 64,
    },
    {
        name = 'fivem_db_query_duration_seconds',
        type = 'histogram',
        help = 'How long a pushed database query took, by operation.',
        labels = { 'op' },
        cap = 32,
    },

    ----------------------------------------------------------------------------
    -- The exporter itself
    ----------------------------------------------------------------------------
    {
        -- Written by the serving layer, declared here so the catalog is one file.
        -- (tickwatch_series_dropped_total is registered by the registry, whose
        -- own guard reports through it.)
        -- A histogram because render cost grows with the series count — 69 us at
        -- 113 series, under the clock floor, but a registry at its cap crosses it
        -- and the buckets start carrying shape.
        name = 'tickwatch_render_duration_seconds',
        type = 'histogram',
        help = 'Wall time of an exposition render. Below the 1 ms clock resolution read _sum over _count, not the buckets.',
    },
    {
        -- Seconds-scale, so well clear of the clock floor: a gauge is right here.
        name = 'tickwatch_cache_age_seconds',
        type = 'gauge',
        help = 'Age of the payload the previous scrape was served. A payload cannot report its own age, so this lags by one scrape.',
    },
    {
        -- A refused or dropped scrape is a loss, and a loss has to be visible.
        name = 'tickwatch_scrapes_total',
        type = 'counter',
        help = 'Scrape requests by outcome: served, deferred, dropped or unauthorized.',
        labels = { 'result' },
        cap = 8,
    },
    {
        -- A caller's mistake, counted rather than raised into their code. Why:
        -- see the header of exports.lua.
        name = 'tickwatch_export_errors_total',
        type = 'counter',
        help = 'Rejected calls to the export API, by reason.',
        labels = { 'reason' },
        cap = 16,
    },
    {
        name = 'tickwatch_lua_memory_bytes',
        type = 'gauge',
        help = 'This resource\'s own Lua heap. Not the server\'s — no interface exposes another resource\'s memory.',
    },
    {
        name = 'tickwatch_collector_overhead_seconds',
        type = 'histogram',
        help = 'Cost of the per-frame tick collector, sampled. Meaningful as _sum over _count across a long window, never per observation — see the note in collectors.lua.',
    },
}

Collectors.METRICS = METRICS

--- Declare every metric in the catalog. Not idempotent: the registry refuses a
--- duplicate name loudly, which is intended.
function Collectors.register(registry)
    for i = 1, #METRICS do
        registry:register(METRICS[i])
    end
end

--------------------------------------------------------------------------------
-- Normalisation
--------------------------------------------------------------------------------

-- A drop reason is free text and cannot be a label as it arrives, so it is
-- reduced to a fixed enum. Order matters: these phrases co-occur — a shutdown
-- message contains "disconnected", a ban contains "kicked" — and first match
-- wins, so the most specific cause is listed first.
local DROP_RULES = {
    { reason = 'server_shutdown', needles = { 'shutting down', 'server shutdown', 'restarting', 'server is restarting' } },
    { reason = 'banned',          needles = { 'banned', 'ban:' } },
    { reason = 'kicked',          needles = { 'kicked', 'kick:' } },
    { reason = 'timeout',         needles = { 'timed out', 'timeout', 'timed-out' } },
    { reason = 'crashed',         needles = { 'crashed', 'crash', 'game error', 'fatal error' } },
    { reason = 'quit',            needles = { 'quit', 'exiting', 'disconnected', 'client disconnected' } },
}

--- Reduce a drop reason to an enum value. Unmatched is 'other' — the series that
--- says the enum needs another rule.
function Collectors.dropReason(text)
    if type(text) ~= 'string' or text == '' then
        return 'other'
    end

    local haystack = text:lower()

    for i = 1, #DROP_RULES do
        local rule = DROP_RULES[i]
        for j = 1, #rule.needles do
            -- Plain find: a reason is operator text and a '-' in it would
            -- silently change what a pattern search means.
            if haystack:find(rule.needles[j], 1, true) then
                return rule.reason
            end
        end
    end

    return 'other'
end

--- Is this resource state the one that counts as up? Tests for the single up
--- state, not against a list of down ones, so a state never seen reads as down.
function Collectors.resourceUp(state)
    return state == 'started'
end

--------------------------------------------------------------------------------
-- Passes
--------------------------------------------------------------------------------

local pass = {}
Collectors.pass = pass

-- One reusable label table per metric shape. The registry never keeps a label
-- table, so a fresh one per write is pure garbage: measured at 10,400 B per
-- resources pass, in the resource whose own heap it publishes as a metric.
--
-- Per shape, not one shared table: the registry checks a label set has exactly
-- the declared keys, and a stale key from another metric would raise. Safe
-- because a pass runs to completion on the main thread and is not reentrant.
local entityLabels = { type = '' }
local resourceLabels = { resource = '' }

--- Players: count, configured maximum, and one ping observation per player.
function pass.players(registry)
    -- GetPlayers() rather than the indexed pair, whose base could not be
    -- established: GetPlayerFromIndex(0) returns nil on an empty server either
    -- way. This returns a Lua array, so its indexing is not in question.
    local players = GetPlayers()
    local connected = players and #players or 0

    registry:set('fivem_players_connected', nil, connected)
    registry:set('fivem_players_max', nil, GetConvarInt('sv_maxclients', 0))

    if connected == 0 then return end

    for i = 1, connected do
        -- Measured: GetPlayerPing returns 0 for a source that is not there and
        -- never raises, so 0 is the runtime's "no answer". Keeping it would pile
        -- players who left mid-pass into the lowest bucket and drag every
        -- percentile down; the only real value lost is a loopback client.
        local ping = GetPlayerPing(players[i])

        if type(ping) == 'number' and ping > 0 then
            registry:observe('fivem_player_ping_seconds', nil, ping / 1000)
        end
    end
end

-- All three enumerators walk one shared entity list and filter by type, so each
-- pays the whole server population. One pass rather than three schedules.
local ENTITY_KINDS = {
    { label = 'ped', native = 'GetAllPeds' },
    { label = 'vehicle', native = 'GetAllVehicles' },
    { label = 'object', native = 'GetAllObjects' },
}

--- Entities: all three enumerators, one pass. ~28 us at 400 entities.
function pass.entities(registry)
    for i = 1, #ENTITY_KINDS do
        local kind = ENTITY_KINDS[i]
        local list = _G[kind.native]()

        entityLabels.type = kind.label
        registry:set('fivem_entities', entityLabels, list and #list or 0)
    end
end

--- Resources: state by name.
function pass.resources(registry)
    local count = GetNumResources()
    if type(count) ~= 'number' or count <= 0 then return end

    -- Zero-based, measured. The one loop in this file that does not start at 1;
    -- getting it wrong drops a resource off one end silently.
    for i = 0, count - 1 do
        local name = GetResourceByFindIndex(i)

        if type(name) == 'string' and name ~= '' then
            resourceLabels.resource = name
            registry:set('fivem_resource_up', resourceLabels,
                Collectors.resourceUp(GetResourceState(name)) and 1 or 0)
        end
    end
end

--- The exporter's own numbers. Also called immediately before every render.
function pass.self(registry)
    -- GetGameTimer is ms since the *server process* started, measured, so uptime
    -- needs no stamp of its own and survives a restart of this resource.
    registry:set('fivem_server_uptime_seconds', nil, GetGameTimer() / 1000)

    -- Kbytes, and this resource's heap alone. Published raw: forcing a collection
    -- to smooth it would be a stall the exporter caused.
    registry:set('tickwatch_lua_memory_bytes', nil, collectgarbage('count') * 1024)
end

--------------------------------------------------------------------------------
-- Connection and session events
--------------------------------------------------------------------------------

-- source -> GetGameTimer() at join. Cleared on drop, so it cannot grow.
local joinedAt = {}

--- playerConnecting: the denominator, and deliberately not a join. It fires
--- before deferrals resolve, so a player counted here can still be rejected.
function Collectors.onConnecting(registry)
    registry:inc('fivem_player_connections_total', { result = 'attempted' })
end

--- playerJoining: the numerator. Join success rate is joined / attempted.
---
--- No 'rejected' series on purpose. Observing one means replacing a method on
--- the deferrals object other resources are also holding, which breaks joins if
--- the ordering is not what was assumed. Rejections are attempted minus joined.
function Collectors.onJoining(registry, source)
    registry:inc('fivem_player_connections_total', { result = 'joined' })

    if source ~= nil then
        joinedAt[tostring(source)] = GetGameTimer()
    end
end

--- playerDropped. Counts the drop and closes out the session.
function Collectors.onDropped(registry, source, reason)
    registry:inc('fivem_player_drops_total', { reason = Collectors.dropReason(reason) })

    if source == nil then return end

    local key = tostring(source)
    local start = joinedAt[key]
    joinedAt[key] = nil

    if start == nil then return end

    -- A player already connected when this resource started has no stamp, and a
    -- negative delta is not a session length. Both dropped, not observed.
    local elapsed = (GetGameTimer() - start) / 1000
    if elapsed >= 0 then
        registry:observe('fivem_player_session_duration_seconds', nil, elapsed)
    end
end

--- Sessions being tracked. For tests: the property worth asserting is that this
--- does not grow.
function Collectors.trackedSessions()
    local n = 0
    for _ in pairs(joinedAt) do n = n + 1 end
    return n
end

--------------------------------------------------------------------------------
-- Scheduling
--------------------------------------------------------------------------------

-- A pass that raises will raise again next interval, and an error on the main
-- thread every 10 s for the life of the process is worse than a missing metric.
-- The counter resets on success, so a transient failure costs nothing.
local MAX_CONSECUTIVE_FAILURES = 3

--- Run `fn` every `intervalMs`, first pass before the first wait so a scrape in
--- the opening interval finds values rather than an empty registry.
local function runScheduled(name, fn, registry, intervalMs)
    CreateThread(function()
        local failures = 0

        while true do
            local ok, err = pcall(fn, registry)

            if ok then
                failures = 0
            else
                failures = failures + 1
                print(('[tickwatch] %s collector failed (%d/%d): %s')
                    :format(name, failures, MAX_CONSECUTIVE_FAILURES, tostring(err)))

                if failures >= MAX_CONSECUTIVE_FAILURES then
                    print(('[tickwatch] %s collector retired after %d consecutive failures; its metrics are now stale')
                        :format(name, failures))
                    return
                end
            end

            Wait(intervalMs)
        end
    end)
end

-- Sampled, not per frame: measuring every one would double the work measured,
-- and the quantity is stationary so a subsample estimates it as well.
local OVERHEAD_SAMPLE_EVERY = 32

local function startTickCollector(registry)
    CreateThread(function()
        local last = GetGameTimer()
        local frame = 0

        while true do
            Wait(0)

            local now = GetGameTimer()
            local delta = now - last
            last = now

            -- A negative delta would be an enormous observation rather than a
            -- visibly wrong one, and a histogram cannot be un-poisoned.
            if delta >= 0 then
                registry:observe('fivem_server_tick_interval_seconds', nil, delta / 1000)
            end

            frame = frame + 1

            if frame >= OVERHEAD_SAMPLE_EVERY then
                frame = 0

                -- One observe() plus one timer read, through a 1 ms clock about
                -- a thousand times coarser than the quantity. Every sample is 0,
                -- or 1 when the work straddles a tick — meaningless per sample,
                -- but the boundary is crossed in proportion to time taken, so
                -- _sum / _count converges. Read the mean, never the buckets.
                local after = GetGameTimer()
                local cost = after - now

                if cost >= 0 then
                    registry:observe('tickwatch_collector_overhead_seconds', nil, cost / 1000)
                end
            end
        end
    end)
end

--- Set the constants: the up gauge, and the build labels.
--- @param info table|nil  { gamename } from /info.json, the only source for it —
---   GetConvar('gamename') returns empty on this build.
function Collectors.sampleConstants(registry, info)
    registry:set('fivem_server_up', nil, 1)

    local version = GetConvar('version', '')
    local gamename = info and info.gamename or GetConvar('gamename', '')

    registry:set('fivem_server_info', {
        version = version ~= '' and version or 'unknown',
        gamename = gamename ~= '' and gamename or 'unknown',
    }, 1)
end

--- Start every collector the configuration enables. Registration is the caller's
--- job: the startup sequence must be able to refuse to serve between the two.
function Collectors.start(registry, config, info)
    Collectors.sampleConstants(registry, info)

    startTickCollector(registry)

    runScheduled('self', pass.self, registry, config.renderIntervalMs)

    if config.playersIntervalMs > 0 then
        runScheduled('players', pass.players, registry, config.playersIntervalMs)
    end

    if config.entitiesIntervalMs > 0 then
        runScheduled('entities', pass.entities, registry, config.entitiesIntervalMs)
    end

    if config.resourcesIntervalMs > 0 then
        runScheduled('resources', pass.resources, registry, config.resourcesIntervalMs)
    end

    -- `source` is a global the runtime sets for the duration of a handler, not
    -- an argument — hence read inside the closure rather than captured outside.
    AddEventHandler('playerConnecting', function()
        Collectors.onConnecting(registry)
    end)

    AddEventHandler('playerJoining', function()
        Collectors.onJoining(registry, source)
    end)

    AddEventHandler('playerDropped', function(reason)
        Collectors.onDropped(registry, source, reason)
    end)
end

--------------------------------------------------------------------------------

_G.Collectors = Collectors
