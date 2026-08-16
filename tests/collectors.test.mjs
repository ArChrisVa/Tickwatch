import test from 'node:test'
import assert from 'node:assert/strict'
import { loadCollectors, CONFIG, resourceList } from './helpers/load-collectors.mjs'
import { parseExposition } from './helpers/load-registry.mjs'

//------------------------------------------------------------------------------
// The catalog
//------------------------------------------------------------------------------

test('every metric in the catalog registers', async () => {
    const c = await loadCollectors()
    c.register()

    const names = c.metricNames().split('\n')

    // The registry declares its own drop counter, so the rendered set is the
    // catalog plus that one.
    assert.ok(names.includes('tickwatch_series_dropped_total'))
    assert.ok(names.includes('fivem_server_up'))
    assert.ok(names.includes('fivem_resource_up'))
    assert.equal(new Set(names).size, names.length, 'a metric was registered twice')
})

test('the catalog renders as valid exposition', async () => {
    const c = await loadCollectors()
    c.register()

    const text = c.render()
    const parsed = parseExposition(text)

    for (const name of c.metricNames().split('\n')) {
        assert.ok(parsed.help[name], `${name} has no HELP`)
        assert.ok(parsed.type[name], `${name} has no TYPE`)
    }
})

test('naming follows the Prometheus conventions', async () => {
    const c = await loadCollectors()
    c.register()

    for (const name of c.metricNames().split('\n')) {
        assert.match(name, /^(fivem|tickwatch)_/, `${name} is outside both namespaces`)

        const kind = c.metric(name, 'kind')

        if (kind === 'counter') {
            assert.ok(name.endsWith('_total'), `${name} is a counter and must end _total`)
        } else {
            assert.ok(!name.endsWith('_total'), `${name} ends _total but is a ${kind}`)
        }
    }
})

test('the resource gauge carries a cap of its own, above the default', async () => {
    const c = await loadCollectors()
    c.register()

    const cap = c.metric('fivem_resource_up', 'cap')

    // The server sets this label's cardinality, not the exporter. Measured at
    // 100 on a framework server; the cap has to clear a large deployment.
    assert.equal(cap, 1000)
    assert.ok(cap > c.metric('fivem_players_connected', 'cap'))
})

test('each histogram gets a ladder for what it measures', async () => {
    const c = await loadCollectors()
    c.register()

    const bounds = name => c.run(`return table.concat(R.metrics[${JSON.stringify(name)}].bounds, ',')`)
        .split(',').map(Number)

    // The default tops out at 1 s, which is every session ever recorded landing
    // in the overflow slot.
    assert.ok(bounds('fivem_player_session_duration_seconds')[0] >= 60)

    // A ping is a network round trip: nothing below the millisecond the source
    // reports in, and resolution where players actually sit.
    assert.ok(bounds('fivem_player_ping_seconds')[0] >= 0.01)

    // The one the whole project is built around, and the one the default ladder
    // was worst for. A Wait(0) thread wakes once per server frame and this
    // runtime frames at 20 Hz, so the floor is ~50 ms rather than the 1 ms the
    // clock resolves. Under the default bounds the five below 0.02 could never
    // be crossed and a single bucket covered everything between a healthy tick
    // and a stall — measured live at 1,951 of 2,699 samples under 0.05 and the
    // rest immediately above it.
    const tick = bounds('fivem_server_tick_interval_seconds')

    assert.ok(tick.filter(b => b >= 0.02 && b <= 0.15).length >= 4,
        'needs resolution around the 50 ms baseline, not below it')
    assert.ok(tick.at(-1) >= 1, 'needs headroom for a stall, which is what it exists to catch')
})

test('no tick bound sits on the frame period the mass occupies', async () => {
    // The assertion above passed against a ladder that returned a wrong number,
    // which is why this one exists. The first replacement ladder kept 0.05 as a
    // bound while every healthy observation lands at 50-51 ms, so the bulk of
    // the distribution piled against a bucket's upper edge and
    // histogram_quantile interpolated downward out of it: p50 reported 45.3 ms
    // for a metric that cannot physically go below 50. A percentile below the
    // floor of its own metric is the failure this project exists to talk about,
    // so the rule is pinned here rather than left in a comment.
    //
    // Stated generally: the expected mass must fall strictly inside a bucket,
    // never on the seam between two.
    const NOMINAL = 0.05 // 20 Hz, measured — see TICK_BUCKETS in collectors.lua

    const c = await loadCollectors()
    c.register()

    const tick = c.run('return table.concat(R.metrics["fivem_server_tick_interval_seconds"].bounds, ",")')
        .split(',').map(Number)

    assert.ok(!tick.some(b => Math.abs(b - NOMINAL) < 1e-9),
        `${NOMINAL} is a bucket bound, so every percentile below the mode interpolates beneath the metric's floor`)

    const below = tick.filter(b => b < NOMINAL).at(-1)
    const above = tick.find(b => b > NOMINAL)

    assert.ok(below !== undefined && above !== undefined,
        'the nominal frame period must be bracketed, not off the end of the ladder')

    // Bracketing it loosely would satisfy the letter and not the point: a
    // bucket spanning 33-75 ms still interpolates p50 far below 50. The bucket
    // holding the mass has to be tight enough that interpolating inside it
    // cannot leave the range the server can actually produce.
    assert.ok(above - below <= 0.02,
        `the bucket holding the baseline spans ${((above - below) * 1000).toFixed(0)} ms, wide enough to interpolate outside the achievable range`)
})

//------------------------------------------------------------------------------
// Players
//------------------------------------------------------------------------------

test('the players pass reports count and configured maximum', async () => {
    const c = await loadCollectors({
        players: ['1', '2', '3'],
        pings: { 1: 24, 2: 180, 3: 60 },
        convars: { sv_maxclients: '48' }
    })

    c.register()
    c.pass('players')

    const p = parseExposition(c.render())
    assert.equal(p.one('fivem_players_connected').value, 3)
    assert.equal(p.one('fivem_players_max').value, 48)
})

test('a ping is observed in seconds, and the histogram is cumulative', async () => {
    const c = await loadCollectors({
        players: ['1', '2', '3'],
        pings: { 1: 24, 2: 180, 3: 60 }
    })

    c.register()
    c.pass('players')

    const p = parseExposition(c.render())
    const buckets = p.of('fivem_player_ping_seconds_bucket')

    assert.equal(p.one('fivem_player_ping_seconds_count').value, 3)

    // 0.024 + 0.18 + 0.06, in seconds rather than milliseconds.
    assert.ok(Math.abs(p.one('fivem_player_ping_seconds_sum').value - 0.264) < 1e-9)

    let previous = 0
    for (const b of buckets) {
        assert.ok(b.value >= previous, `bucket ${b.labels.le} went backwards`)
        previous = b.value
    }

    assert.equal(buckets.at(-1).labels.le, '+Inf')
    assert.equal(buckets.at(-1).value, p.one('fivem_player_ping_seconds_count').value)

    // 24 ms is at or below 30 ms and above 20 ms.
    assert.equal(buckets.find(b => b.labels.le === '0.03').value, 1)
    assert.equal(buckets.find(b => b.labels.le === '0.02').value, 0)
})

test('a ping of zero is not observed', async () => {
    // Measured: GetPlayerPing returns 0 for a source that is not connected, and
    // does not raise. A player who left between the enumeration and the ping
    // read is therefore indistinguishable from a genuine zero, and counting it
    // would drag every percentile toward the floor.
    const c = await loadCollectors({
        players: ['1', '2'],
        pings: { 1: 40 }
    })

    c.register()
    c.pass('players')

    const p = parseExposition(c.render())
    assert.equal(p.one('fivem_players_connected').value, 2)
    assert.equal(p.one('fivem_player_ping_seconds_count').value, 1)
})

test('an empty server sets the gauges and observes nothing', async () => {
    const c = await loadCollectors({ players: [], convars: { sv_maxclients: '8' } })

    c.register()
    c.pass('players')

    const p = parseExposition(c.render())
    assert.equal(p.one('fivem_players_connected').value, 0)
    assert.equal(p.one('fivem_players_max').value, 8)
    assert.equal(c.calls('GetPlayerPing'), 0)

    // A histogram nobody has observed into has no series, so it renders its
    // HELP and TYPE and no samples. That is the registry's deliberate
    // behaviour and it is the right answer here: "no ping data on an empty
    // server" and "every ping was zero" are different claims.
    assert.equal(p.type.fivem_player_ping_seconds, 'histogram')
    assert.equal(p.of('fivem_player_ping_seconds_count').length, 0)
})

test('the players pass does not care whether a source is a string or a number', async () => {
    // Which of the two GetPlayers returns could not be established with no
    // client connected, so the pass must not depend on it. It passes the value
    // straight back to GetPlayerPing, which was measured accepting both.
    const c = await loadCollectors({ players: [1, 2], pings: { 1: 30, 2: 30 } })

    c.register()
    c.pass('players')

    assert.equal(parseExposition(c.render()).one('fivem_player_ping_seconds_count').value, 2)
})

test('the players count comes from the same call the pings do', async () => {
    const c = await loadCollectors({ players: ['1', '2'], pings: { 1: 10, 2: 10 } })

    c.register()
    c.pass('players')

    // One enumeration per pass. A second source for the count could disagree
    // with the histogram it is printed beside.
    assert.equal(c.calls('GetPlayers'), 1)
})

//------------------------------------------------------------------------------
// Entities
//------------------------------------------------------------------------------

test('entities are reported by type', async () => {
    const c = await loadCollectors({ entities: { ped: 12, vehicle: 5, object: 0 } })

    c.register()
    c.pass('entities')

    const p = parseExposition(c.render())
    assert.equal(p.one('fivem_entities', { type: 'ped' }).value, 12)
    assert.equal(p.one('fivem_entities', { type: 'vehicle' }).value, 5)
    assert.equal(p.one('fivem_entities', { type: 'object' }).value, 0)
})

test('each enumerator is called exactly once per pass', async () => {
    // The three natives walk one shared entity list and filter by type, so each
    // pays the whole server population whatever it returns. Calling one twice
    // costs a full traversal for nothing.
    const c = await loadCollectors({ entities: { ped: 3, vehicle: 3, object: 3 } })

    c.register()
    c.pass('entities')

    assert.equal(c.calls('GetAllPeds'), 1)
    assert.equal(c.calls('GetAllVehicles'), 1)
    assert.equal(c.calls('GetAllObjects'), 1)
})

test('entity gauges hold three series however many passes run', async () => {
    const c = await loadCollectors({ entities: { ped: 1, vehicle: 1, object: 1 } })

    c.register()
    c.pass('entities')
    c.pass('entities')
    c.pass('entities')

    assert.equal(c.seriesCount('fivem_entities'), 3)
})

//------------------------------------------------------------------------------
// Resources
//------------------------------------------------------------------------------

test('resource state maps onto one gauge per resource', async () => {
    const c = await loadCollectors({
        resources: resourceList({ 'qb-core': 'started', 'qb-policejob': 'stopped', chat: 'started' })
    })

    c.register()
    c.pass('resources')

    const p = parseExposition(c.render())
    assert.equal(p.one('fivem_resource_up', { resource: 'qb-core' }).value, 1)
    assert.equal(p.one('fivem_resource_up', { resource: 'qb-policejob' }).value, 0)
    assert.equal(p.one('fivem_resource_up', { resource: 'chat' }).value, 1)
})

test('the resource walk is zero-based and reads every entry', async () => {
    // Measured: GetResourceByFindIndex(0) returns the first resource and
    // index -1 returns nil. A 1-based loop drops the first resource and reads
    // one past the end, and both failures are silent.
    const c = await loadCollectors({
        resources: resourceList({ first: 'started', middle: 'started', last: 'started' })
    })

    c.register()
    c.pass('resources')

    assert.equal(c.seriesCount('fivem_resource_up'), 3)

    const p = parseExposition(c.render())
    assert.equal(p.one('fivem_resource_up', { resource: 'first' }).value, 1)
    assert.equal(p.one('fivem_resource_up', { resource: 'last' }).value, 1)
})

test('only started counts as up', async () => {
    const c = await loadCollectors()

    assert.equal(c.resourceUp('started'), true)

    // Testing for the one up state rather than listing the down ones means a
    // state this build has never produced reads as down, which is the safe
    // direction for an up gauge.
    for (const state of ['stopped', 'starting', 'stopping', 'uninitialized', 'missing', 'unknown'])
        assert.equal(c.resourceUp(state), false, `${state} must not count as up`)

    assert.equal(c.resourceUp(null), false)
})

test('a resource list that shrinks leaves the old series behind', async () => {
    // Worth pinning down rather than discovering in a dashboard: a stopped and
    // removed resource keeps its last value, because nothing deletes a series.
    // The gauge is 0 by then, so it reads as down rather than as up forever.
    const c = await loadCollectors({
        resources: resourceList({ a: 'started', b: 'started' })
    })

    c.register()
    c.pass('resources')

    c.world({ resources: resourceList({ a: 'started' }) })
    c.pass('resources')

    const p = parseExposition(c.render())
    assert.equal(c.seriesCount('fivem_resource_up'), 2)
    assert.equal(p.one('fivem_resource_up', { resource: 'a' }).value, 1)
    assert.equal(p.one('fivem_resource_up', { resource: 'b' }).value, 1)
})

test('the resource pass is one index read and one state read per resource', async () => {
    const c = await loadCollectors({
        resources: resourceList({ a: 'started', b: 'stopped', c: 'started' })
    })

    c.register()
    c.pass('resources')

    assert.equal(c.calls('GetNumResources'), 1)
    assert.equal(c.calls('GetResourceByFindIndex'), 3)
    assert.equal(c.calls('GetResourceState'), 3)
})

test('an empty resource list is not an error', async () => {
    const c = await loadCollectors({ resources: [] })

    c.register()
    c.pass('resources')

    assert.equal(c.seriesCount('fivem_resource_up'), 0)
})

//------------------------------------------------------------------------------
// Drop reasons
//------------------------------------------------------------------------------

test('drop reasons normalise to the enum', async () => {
    const c = await loadCollectors()

    const cases = {
        'Disconnected.': 'quit',
        'Exiting': 'quit',
        'Quit: bye': 'quit',
        'Connection timed out.': 'timeout',
        'timeout': 'timeout',
        'Kicked: go away': 'kicked',
        'You have been banned from this server': 'banned',
        'Client crashed': 'crashed',
        'Server shutting down: restart': 'server_shutdown',
        'something nobody has seen before': 'other'
    }

    for (const [text, expected] of Object.entries(cases))
        assert.equal(c.dropReason(text), expected, `${text} should be ${expected}`)
})

test('the more specific rule wins when phrases co-occur', async () => {
    const c = await loadCollectors()

    // These are the collisions the ordering exists for. A ban message says the
    // player was kicked; a shutdown message says everybody disconnected. First
    // rule wins, so the specific causes are listed above the generic ones.
    assert.equal(c.dropReason('You were kicked: banned until 2030'), 'banned')
    assert.equal(c.dropReason('Server shutting down, all players disconnected'), 'server_shutdown')
})

test('a drop reason is matched literally, not as a pattern', async () => {
    // Operator-written text can contain any of Lua's pattern characters, and a
    // '-' or '%' in a needle would change what the search means.
    const c = await loadCollectors()

    assert.equal(c.dropReason('100%% of the time this is not a match'), 'other')
    assert.equal(c.dropReason('[banned]'), 'banned')
})

test('a missing or empty reason is other, not a crash', async () => {
    const c = await loadCollectors()

    assert.equal(c.dropReason(null), 'other')
    assert.equal(c.dropReason(''), 'other')
    assert.equal(c.dropReason(42), 'other')
})

test('the reason label is the enum value, never the raw text', async () => {
    const c = await loadCollectors()
    c.register()

    c.onDropped(1, 'Kicked: you were being extremely rude, case #418')

    const p = parseExposition(c.render())
    assert.equal(p.one('fivem_player_drops_total', { reason: 'kicked' }).value, 1)
    assert.ok(!c.render().includes('#418'), 'raw drop text reached the exposition')
})

test('unbounded reason text cannot grow the series count', async () => {
    const c = await loadCollectors()
    c.register()

    for (let i = 0; i < 200; i++) c.onDropped(i, `Kicked: reason number ${i}`)

    assert.equal(c.seriesCount('fivem_player_drops_total'), 1)
})

//------------------------------------------------------------------------------
// Connections and sessions
//------------------------------------------------------------------------------

test('connections count attempts and joins separately', async () => {
    const c = await loadCollectors()
    c.register()

    c.onConnecting()
    c.onConnecting()
    c.onJoining(1)

    const p = parseExposition(c.render())
    assert.equal(p.one('fivem_player_connections_total', { result: 'attempted' }).value, 2)
    assert.equal(p.one('fivem_player_connections_total', { result: 'joined' }).value, 1)
})

test('there is no rejected series', async () => {
    // A deferral is rejected by the resource that owns it, and observing that
    // from here would mean replacing a method on an object other resources hold.
    // Rejections are attempted minus joined, computed at query time. Emitting a
    // rejected series that only ever reads 0 would be worse than not having one.
    const c = await loadCollectors()
    c.register()

    c.onConnecting()
    c.onJoining(1)

    const results = parseExposition(c.render())
        .of('fivem_player_connections_total')
        .map(s => s.labels.result)

    assert.deepEqual(results.sort(), ['attempted', 'joined'])
})

test('a session is observed when the player drops', async () => {
    const c = await loadCollectors()
    c.register()

    c.setTimer(10_000)
    c.onJoining(7)

    c.setTimer(1_810_000) // half an hour later
    c.onDropped(7, 'Disconnected.')

    const p = parseExposition(c.render())
    assert.equal(p.one('fivem_player_session_duration_seconds_count').value, 1)
    assert.equal(p.one('fivem_player_session_duration_seconds_sum').value, 1800)
})

test('a drop with no matching join observes nothing', async () => {
    // A player already connected when the resource started has no join stamp.
    // The alternative is an observation measured from resource start, which
    // reads as a real session and is not one.
    const c = await loadCollectors()
    c.register()

    c.setTimer(500_000)
    c.onDropped(7, 'Disconnected.')

    const p = parseExposition(c.render())
    assert.equal(p.one('fivem_player_drops_total', { reason: 'quit' }).value, 1)
    assert.equal(p.of('fivem_player_session_duration_seconds_count').length, 0)
})

test('session tracking does not grow', async () => {
    const c = await loadCollectors()
    c.register()

    for (let i = 1; i <= 50; i++) {
        c.setTimer(i * 1000)
        c.onJoining(i)
    }

    assert.equal(c.trackedSessions(), 50)

    for (let i = 1; i <= 50; i++) {
        c.setTimer(100_000 + i * 1000)
        c.onDropped(i, 'Disconnected.')
    }

    assert.equal(c.trackedSessions(), 0)
})

test('a clock that moved backwards produces no session observation', async () => {
    const c = await loadCollectors()
    c.register()

    c.setTimer(900_000)
    c.onJoining(1)

    c.setTimer(1000)
    c.onDropped(1, 'Disconnected.')

    const p = parseExposition(c.render())
    assert.equal(p.of('fivem_player_session_duration_seconds_count').length, 0)
    assert.equal(c.trackedSessions(), 0, 'the tracking entry must be cleared either way')
})

//------------------------------------------------------------------------------
// The exporter's own numbers
//------------------------------------------------------------------------------

test('uptime comes from the game timer, not from a start stamp', async () => {
    // Measured twice against a known launch time: GetGameTimer is milliseconds
    // since the server process started. Reading it directly means uptime is the
    // server's rather than this resource's, and survives a resource restart.
    const c = await loadCollectors()
    c.register()

    c.setTimer(3_600_000)
    c.pass('self')

    assert.equal(parseExposition(c.render()).one('fivem_server_uptime_seconds').value, 3600)
})

test('the memory gauge reports bytes', async () => {
    const c = await loadCollectors()
    c.register()
    c.pass('self')

    const bytes = parseExposition(c.render()).one('tickwatch_lua_memory_bytes').value

    // collectgarbage counts in Kbytes. A gauge reporting single-digit thousands
    // would be the unit mistake this converts away.
    assert.ok(bytes > 50_000, `expected a byte figure, got ${bytes}`)
})

test('server_up is a constant 1 and the build is a label', async () => {
    const c = await loadCollectors({
        convars: { version: 'FXServer-master SERVER v1.0.0.32561 win32' }
    })

    c.register()
    c.sampleConstants({ gamename: 'gta5' })

    const p = parseExposition(c.render())
    assert.equal(p.one('fivem_server_up').value, 1)

    const info = p.of('fivem_server_info')
    assert.equal(info.length, 1)
    assert.equal(info[0].value, 1)
    assert.equal(info[0].labels.gamename, 'gta5')
    assert.match(info[0].labels.version, /^FXServer-master/)
})

test('gamename falls back rather than becoming an empty label', async () => {
    // Measured: GetConvar('gamename') returns empty on this build, which is why
    // the value comes from /info.json. When that fetch produced nothing either,
    // the label says unknown — an empty label value is a different series from
    // an absent one and reads as a bug in the exporter.
    const c = await loadCollectors()

    c.register()
    c.sampleConstants(null)

    const info = parseExposition(c.render()).of('fivem_server_info')[0]
    assert.equal(info.labels.gamename, 'unknown')
    assert.equal(info.labels.version, 'unknown')
})

//------------------------------------------------------------------------------
// Scheduling
//------------------------------------------------------------------------------

test('start wires one thread per enabled collector, plus the tick thread', async () => {
    const c = await loadCollectors()
    c.register()
    c.start(CONFIG, { gamename: 'gta5' })

    // tick, self, players, entities, resources
    assert.equal(c.threadCount(), 5)
    assert.ok(c.hasEvent('playerConnecting'))
    assert.ok(c.hasEvent('playerJoining'))
    assert.ok(c.hasEvent('playerDropped'))
})

test('an interval of zero leaves that collector unstarted', async () => {
    const c = await loadCollectors()
    c.register()
    c.start({ ...CONFIG, entitiesIntervalMs: 0, resourcesIntervalMs: 0 }, null)

    assert.equal(c.threadCount(), 3)
})

test('a scheduled collector runs a pass before its first wait', async () => {
    // A scrape arriving inside the first interval has to find values rather than
    // an empty registry.
    const c = await loadCollectors({ players: ['1'], pings: { 1: 50 } })
    c.register()
    c.start({ ...CONFIG, entitiesIntervalMs: 0, resourcesIntervalMs: 0 }, null)

    // 1 tick, 2 self, 3 players.
    assert.equal(c.runThread(3, 1), 'waiting:10000')
    assert.equal(parseExposition(c.render()).one('fivem_players_connected').value, 1)
})

test('a collector that keeps failing retires instead of logging forever', async () => {
    const c = await loadCollectors()
    c.register()

    // GetPlayers gone is the shape of a native disappearing under a runtime
    // update: the pass raises every interval, and an error printed on the main
    // thread every 10 s for the life of the process is worse than a stale gauge.
    c.run('GetPlayers = nil')
    c.start({ ...CONFIG, entitiesIntervalMs: 0, resourcesIntervalMs: 0 }, null)

    assert.equal(c.runThread(3, 10), 'returned:10000')

    const printed = c.printed()
    assert.equal(printed.filter(l => l.includes('players collector failed')).length, 3)
    assert.ok(printed.some(l => l.includes('retired')))
})

test('a transient failure does not retire a collector', async () => {
    const c = await loadCollectors({ players: [], resources: [] })
    c.register()
    c.start({ ...CONFIG, entitiesIntervalMs: 0, resourcesIntervalMs: 0 }, null)

    // Fail once, then recover. The failure counter has to reset on success or a
    // long-running server retires every collector eventually.
    c.run('T_realGetPlayers = GetPlayers; GetPlayers = function() error("transient") end')
    assert.equal(c.runThread(3, 1), 'waiting:10000')

    c.run('GetPlayers = T_realGetPlayers')
    assert.equal(c.runThread(3, 5), 'waiting:10000')

    assert.ok(!c.printed().some(l => l.includes('retired')))
})

test('the tick collector observes an interval and samples its own cost', async () => {
    const c = await loadCollectors()
    c.register()
    c.start(CONFIG, null)

    // 40 frames at 20 ms, so the overhead sample fires once at frame 32.
    c.run(`
        local n = 0
        local base = 0
        GetGameTimer = function()
            n = n + 1
            if n % 2 == 1 then base = base + 20 end
            return base
        end
    `)

    c.runThread(1, 40)

    const p = parseExposition(c.render())
    assert.ok(p.one('fivem_server_tick_interval_seconds_count').value >= 39)
    assert.equal(p.one('tickwatch_collector_overhead_seconds_count').value, 1)
})
