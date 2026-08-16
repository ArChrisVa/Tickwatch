import test from 'node:test'
import assert from 'node:assert/strict'
import { loadExports } from './helpers/load-exports.mjs'
import { parseExposition } from './helpers/load-registry.mjs'

//------------------------------------------------------------------------------
// The surface
//------------------------------------------------------------------------------

test('the export surface is exactly what is documented', async () => {
    const c = await loadExports()

    assert.deepEqual(c.exportNames(), [
        'Event', 'Inc', 'IsRegistered', 'Observe', 'ObserveSince', 'Query', 'Register', 'Set'
    ])
})

test('there is no StartTimer', async () => {
    // The design specified one twice and measurement removed it twice. A closure
    // returned across the boundary becomes a proxy that costs 6.2 µs to call,
    // against single-digit nanoseconds for a local one; a plain number version
    // still cost a ~7 µs boundary crossing to return what GetGameTimer gives the
    // caller locally for 0.093 µs. The clock reading is the caller's.
    const c = await loadExports()

    assert.ok(!c.exportNames().includes('StartTimer'))
    assert.ok(!c.exportNames().includes('StopTimer'))
})

//------------------------------------------------------------------------------
// Writes
//------------------------------------------------------------------------------

test('a write through the API lands in the exposition', async () => {
    const c = await loadExports()

    c.event('playerRevive', 0.012)

    const p = parseExposition(c.render())
    assert.equal(p.one('fivem_events_total', { event: 'playerRevive' }).value, 1)
    assert.equal(p.one('fivem_event_duration_seconds_count', { event: 'playerRevive' }).value, 1)
    assert.equal(p.one('fivem_event_duration_seconds_sum', { event: 'playerRevive' }).value, 0.012)
})

test('a caller can declare and write its own metric', async () => {
    const c = await loadExports()

    assert.equal(c.register({
        name: 'jobs_completed_total',
        type: 'counter',
        help: 'Jobs finished.',
        labels: ['job']
    }), true)

    assert.equal(c.isRegistered('jobs_completed_total'), true)
    assert.equal(c.inc('jobs_completed_total', { job: 'trucker' }), true)
    assert.equal(c.inc('jobs_completed_total', { job: 'trucker' }, 4), true)

    assert.equal(
        parseExposition(c.render()).one('jobs_completed_total', { job: 'trucker' }).value, 5)
})

test('custom bucket bounds survive registration', async () => {
    const c = await loadExports()

    c.register({
        name: 'heist_duration_seconds',
        type: 'histogram',
        help: 'Heists.',
        buckets: [60, 300, 900]
    })

    c.observe('heist_duration_seconds', null, 120)

    const buckets = parseExposition(c.render()).of('heist_duration_seconds_bucket')
    assert.deepEqual(buckets.map(b => b.labels.le), ['60', '300', '900', '+Inf'])
    assert.deepEqual(buckets.map(b => b.value), [0, 1, 1, 1])
})

test('Query counts and times in one call', async () => {
    // Two registry writes behind one boundary crossing. That is the whole reason
    // the wrapper exists: a caller doing Inc then Observe pays ~7 µs twice.
    const c = await loadExports()

    c.query('select', 'ok', 0.0005)
    c.query('select', 'ok', 0.0007)
    c.query('insert', 'error', 0.02)

    const p = parseExposition(c.render())
    assert.equal(p.one('fivem_db_queries_total', { op: 'select', status: 'ok' }).value, 2)
    assert.equal(p.one('fivem_db_queries_total', { op: 'insert', status: 'error' }).value, 1)
    assert.equal(p.one('fivem_db_query_duration_seconds_count', { op: 'select' }).value, 2)
})

test('a query status is normalised to a two-value enum', async () => {
    // A failing query is exactly when a caller is most likely to pass the
    // driver's error message straight through, and that message is unbounded.
    const c = await loadExports()

    c.query('select', 'ER_NO_SUCH_TABLE: Table qb_test.foo does not exist', 0.001)
    c.query('select', 'error', 0.001)
    c.query('select', null, 0.001)

    const statuses = parseExposition(c.render())
        .of('fivem_db_queries_total')
        .map(s => s.labels.status)
        .sort()

    assert.deepEqual(statuses, ['error', 'ok'])
})

test('ObserveSince converts milliseconds to seconds', async () => {
    // The trap it exists to close: Prometheus base units are seconds, and a
    // caller passing a millisecond figure to Observe gets a histogram wrong by a
    // factor of a thousand that looks entirely plausible.
    const c = await loadExports()

    c.setTimer(10_000)
    const started = 10_000

    c.setTimer(10_250)
    assert.equal(c.observeSince('fivem_event_duration_seconds', { event: 'x' }, started), true)

    assert.equal(
        parseExposition(c.render()).one('fivem_event_duration_seconds_sum', { event: 'x' }).value,
        0.25)
})

test('ObserveSince rejects a reading that is not a game timer value', async () => {
    const c = await loadExports()

    c.setTimer(5000)

    // os.time() is seconds since 1970; the game timer is milliseconds since the
    // process started. The subtraction goes hugely negative, which is the shape
    // of the mistake rather than a duration.
    assert.equal(c.observeSince('fivem_event_duration_seconds', { event: 'x' }, 1_755_000_000), false)
    assert.equal(c.observeSince('fivem_event_duration_seconds', { event: 'x' }, 'soon'), false)
    assert.equal(c.observeSince('fivem_event_duration_seconds', { event: 'x' }, null), false)
})

//------------------------------------------------------------------------------
// Mistakes never reach the caller
//------------------------------------------------------------------------------

test('a write never raises, whatever the caller does to it', async () => {
    // The principle the whole file is built on. An export call runs inside
    // somebody else's function, on the main thread, in production. A tool that
    // can take down the resource it observes is worse than one whose graph stays
    // flat. Each of these raises inside the registry and returns false here.
    const c = await loadExports()

    assert.equal(c.inc('no_such_metric_total', null, 1), false)
    assert.equal(c.inc('fivem_events_total', { event: 'x' }, -5), false)
    assert.equal(c.set('fivem_events_total', { event: 'x' }, 1), false)
    assert.equal(c.observe('fivem_events_total', { event: 'x' }, 1), false)
    assert.equal(c.inc(null, null, 1), false)
    assert.equal(c.inc('fivem_events_total', 'not a table', 1), false)
    assert.equal(c.inc('fivem_events_total', { wrong_label: 'x' }, 1), false)
    assert.equal(c.set('fivem_players_connected', null, 'not a number'), false)
    assert.equal(c.observe('fivem_event_duration_seconds', { event: 'x' }, null), false)
})

test('an unknown metric is never created on demand', async () => {
    // A metric that appears because somebody mistyped a name is a series that
    // looks almost right, is never graphed, and consumes a slot under the cap.
    const c = await loadExports()

    c.inc('fivem_evnets_total', { event: 'x' }, 1)

    assert.equal(c.hasMetric('fivem_evnets_total'), false)
    assert.equal(c.isRegistered('fivem_evnets_total'), false)
})

test('a rejected write is counted', async () => {
    const c = await loadExports()

    c.inc('no_such_metric_total', null, 1)
    c.inc('fivem_events_total', { event: 'x' }, -5)

    const p = parseExposition(c.render())
    assert.equal(p.one('tickwatch_export_errors_total', { reason: 'unknown_metric' }).value, 1)
    assert.equal(p.one('tickwatch_export_errors_total', { reason: 'bad_write' }).value, 1)
})

test('a repeated mistake is reported once, not once per call', async () => {
    // A caller in a hot path makes the same mistake at the rate of that hot
    // path. Printing all of them on the main thread would be a bigger problem
    // than the mistake.
    const c = await loadExports()

    for (let i = 0; i < 500; i++) c.inc('no_such_metric_total', null, 1)

    const complaints = c.printed().filter(l => l.includes('no_such_metric_total'))
    assert.equal(complaints.length, 1)

    // Counted every time, though. The console says what is wrong; the metric
    // says how often.
    assert.equal(
        parseExposition(c.render()).one('tickwatch_export_errors_total', { reason: 'unknown_metric' }).value,
        500)
})

test('distinct mistakes are each reported, up to a bound', async () => {
    const c = await loadExports()

    for (let i = 0; i < 200; i++) c.inc(`no_such_metric_${i}_total`, null, 1)

    const complaints = c.printed().filter(l => l.includes('export rejected'))

    assert.ok(complaints.length > 1, 'distinct mistakes must not collapse into one')
    assert.ok(complaints.length <= 64, 'the report cap must hold')
    assert.ok(c.printed().some(l => l.includes('will be counted but not printed')))
})

test('the error message names the metric and the problem', async () => {
    const c = await loadExports()

    c.inc('fivem_events_total', { event: 'x' }, -5)

    const line = c.printed().find(l => l.includes('export rejected'))

    assert.match(line, /fivem_events_total/)
    assert.match(line, /counter/)

    // The chunk:line prefix Lua prepends points into exports.lua and tells the
    // caller nothing about their own mistake.
    assert.ok(!/\.lua:\d+/.test(line), `internal source location leaked: ${line}`)
})

//------------------------------------------------------------------------------
// Register is the exception
//------------------------------------------------------------------------------

test('Register raises, because a declaration is a startup-time mistake', async () => {
    // The one place failing hard is right: a declaration is made once, by a
    // developer who is looking at it, and it is in nobody's hot path.
    const c = await loadExports()

    assert.throws(() => c.register({ name: 'no spaces allowed', type: 'counter', help: 'x' }))
    assert.throws(() => c.register({ name: 'ok_total', type: 'sundial', help: 'x' }))
    assert.throws(() => c.register({ name: 'ok_total', type: 'counter', help: '' }))
    assert.throws(() => c.register('not a table'))
    assert.throws(() => c.register({ name: 'fivem_events_total', type: 'counter', help: 'dup' }))
})

//------------------------------------------------------------------------------
// Before and after the exporter is running
//------------------------------------------------------------------------------

test('writes are refused while the exporter is not serving', async () => {
    // main.lua binds only on the path where every startup check passed, so a
    // resource writing into a tickwatch that is not serving gets false rather
    // than a write into a registry nothing will ever render.
    //
    // Register is the exception and queues instead, because a declaration made
    // during startup is early rather than wrong. A write cannot be queued: there
    // is nothing to write to, and the value would be stale by the time there was.
    const c = await loadExports({ bind: false })

    assert.equal(c.inc('fivem_events_total', { event: 'x' }, 1), false)
    assert.equal(c.event('x'), false)
    assert.equal(c.isRegistered('fivem_events_total'), false)

    assert.ok(c.printed().some(l => l.includes('not serving')))
})

test('the exports exist before the exporter starts', async () => {
    // Registered at load rather than at bind. "No such export" reads like a
    // missing dependency; a refusal reads like what it is.
    const c = await loadExports({ bind: false })

    assert.ok(c.exportNames().includes('Inc'))
})

test('unbinding stops writes without breaking callers', async () => {
    const c = await loadExports()

    assert.equal(c.event('x'), true)
    c.unbind()
    assert.equal(c.event('x'), false)
})

//------------------------------------------------------------------------------
// Cardinality
//------------------------------------------------------------------------------

test('caller-supplied labels are still bounded by the cap', async () => {
    // The event label is the one place in the catalog where cardinality is not
    // bounded by construction — it is whatever a caller passes. The cap is what
    // stands between a loop over player names and a dead Prometheus.
    const c = await loadExports()

    for (let i = 0; i < 800; i++) c.event(`event_${i}`)

    const cap = c.run("return R.metrics['fivem_events_total'].cap")

    assert.equal(c.seriesCount('fivem_events_total'), cap)
    assert.ok(
        parseExposition(c.render()).one('tickwatch_series_dropped_total',
            { metric: 'fivem_events_total' }).value > 0)
})

test('a write refused by the cap is not an error the caller sees', async () => {
    // The cap dropping a write is the registry working as designed, not the
    // caller doing something wrong, so it is not counted as an export error.
    const c = await loadExports()

    for (let i = 0; i < 800; i++) c.event(`event_${i}`)

    const errors = parseExposition(c.render()).of('tickwatch_export_errors_total')
    assert.equal(errors.length, 0)
})

//------------------------------------------------------------------------------
// Registering before tickwatch has finished starting
//------------------------------------------------------------------------------
// The startup sequence yields on an HTTP round trip to /info.json before it
// binds, so a resource that declares its metrics at load time ALWAYS gets here
// first, whatever order the server starts resources in. That is the documented
// usage, so it has to work rather than depend on luck.

test('a metric declared before bind is registered at bind', async () => {
    const c = await loadExports({ bind: false })

    assert.equal(c.register({
        name: 'myjob_payouts_total', type: 'counter',
        help: 'Payouts made.', labels: ['job']
    }), true)

    assert.equal(c.pending(), 1)
    assert.equal(c.hasMetric('myjob_payouts_total'), false)

    c.bind()

    assert.equal(c.pending(), 0)
    assert.equal(c.hasMetric('myjob_payouts_total'), true)
})

test('a write to a metric declared before bind lands once bound', async () => {
    const c = await loadExports({ bind: false })

    c.register({ name: 'myjob_payouts_total', type: 'counter', help: 'Payouts.', labels: ['job'] })
    c.bind()
    c.inc('myjob_payouts_total', { job: 'trucker' })

    assert.equal(
        parseExposition(c.render()).one('myjob_payouts_total', { job: 'trucker' }).value, 1)
})

test('IsRegistered answers the same before and after bind', async () => {
    // Otherwise the defensive-registration idiom in the README registers twice.
    const c = await loadExports({ bind: false })

    assert.equal(c.isRegistered('myjob_payouts_total'), false)
    c.register({ name: 'myjob_payouts_total', type: 'counter', help: 'Payouts.' })
    assert.equal(c.isRegistered('myjob_payouts_total'), true)

    c.bind()
    assert.equal(c.isRegistered('myjob_payouts_total'), true)
})

test('the same name declared twice before bind still raises', async () => {
    const c = await loadExports({ bind: false })

    c.register({ name: 'myjob_payouts_total', type: 'counter', help: 'Payouts.' })
    const second = c.tryRegister({ name: 'myjob_payouts_total', type: 'counter', help: 'Again.' })

    assert.equal(second.ok, false)
    assert.match(second.message, /already registered/)
})

test('a definition table is still required before bind', async () => {
    // Queuing must not defer the shape check to a stack that no longer exists.
    const c = await loadExports({ bind: false })

    assert.equal(c.tryRegister('myjob_payouts_total').ok, false)
    assert.equal(c.pending(), 0)
})

test('a bad definition queued before bind is reported, not raised, at bind', async () => {
    // By bind the caller's stack is gone, so the only honest options are to print
    // and count it or to swallow it. It is printed and counted.
    const c = await loadExports({ bind: false })

    c.register({ name: 'has_no_type_or_help' })
    c.bind()

    assert.equal(c.hasMetric('has_no_type_or_help'), false)
    assert.ok(c.printed().some(l => /has_no_type_or_help/.test(l)))
    assert.ok(
        parseExposition(c.render()).of('tickwatch_export_errors_total')
            .some(s => s.labels.reason === 'bad_registration'))
})

test('unbind clears the queue', async () => {
    const c = await loadExports({ bind: false })

    c.register({ name: 'myjob_payouts_total', type: 'counter', help: 'Payouts.' })
    assert.equal(c.pending(), 1)

    c.unbind()
    assert.equal(c.pending(), 0)
})

test('after startup refuses, Register raises instead of queueing', async () => {
    // The difference between a caller being early and a caller being wrong. A
    // queued declaration after a refusal would never be replayed, so holding one
    // would tell the caller it succeeded when nothing will ever come of it.
    const c = await loadExports({ bind: false })

    c.run('Exports.refuseToStart()')

    const r = c.tryRegister({ name: 'myjob_payouts_total', type: 'counter', help: 'Payouts.' })
    assert.equal(r.ok, false)
    assert.match(r.message, /startup refused/)
    assert.equal(c.pending(), 0)
})

test('a refusal names the metrics it is dropping', async () => {
    // Otherwise a resource that registered during startup simply never appears
    // and nothing anywhere explains why.
    const c = await loadExports({ bind: false })

    c.register({ name: 'myjob_payouts_total', type: 'counter', help: 'Payouts.' })
    c.run('Exports.refuseToStart()')

    assert.ok(c.printed().some(l => l.includes('myjob_payouts_total')))
    assert.equal(c.pending(), 0)
})
