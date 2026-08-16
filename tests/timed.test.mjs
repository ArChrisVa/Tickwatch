// shared/timed.lua — the wrapper a consuming resource loads to instrument itself.
//
// The whole reason this file exists is that hand-written timing silently skips
// the calls that error or return early, and those are disproportionately the slow
// ones. So the tests that matter here are the failure paths, not the happy one:
// if the wrapper only observed successful calls it would be a more convenient way
// of producing the same wrong histogram.

import test from 'node:test'
import assert from 'node:assert/strict'
import { loadTimed } from './helpers/load-exports.mjs'

const HISTOGRAM = {
    name: 'myjob_duration_seconds',
    type: 'histogram',
    help: 'How long the job took.'
}

async function withHistogram(def = HISTOGRAM) {
    const t = await loadTimed()
    t.register(def)
    return t
}

// Observation count for the histogram, or 0 when it has never been written. The
// registry deliberately renders HELP and TYPE with no samples for a histogram
// that has not been observed, so absence of the line means zero observations.
function observations(t, name = HISTOGRAM.name) {
    const line = t.render()
        .split('\n')
        .find(l => l.startsWith(`${name}_count`))

    return line ? Number(line.split(' ')[1]) : 0
}

function sum(t, name = HISTOGRAM.name) {
    const line = t.render()
        .split('\n')
        .find(l => l.startsWith(`${name}_sum`))

    return line ? Number(line.split(' ')[1]) : 0
}

//------------------------------------------------------------------------------
// The point of the thing
//------------------------------------------------------------------------------

test('a call that raises is still observed, and the error still reaches the caller', async () => {
    const t = await withHistogram()

    const fn = t.wrap(HISTOGRAM.name, `function() error('database is gone', 0) end`)

    t.setTimer(1000)
    const outcome = fn.pcall()

    // Both halves matter. Observing but swallowing the error would be a wrapper
    // that breaks the caller's control flow; re-raising without observing would
    // be the bug this file exists to fix.
    assert.equal(outcome.ok, false)
    assert.equal(outcome.message, 'database is gone')
    assert.equal(observations(t), 1, 'the failing call was not counted')
})

test('an early return is observed', async () => {
    const t = await withHistogram()

    // The shape that loses observations when written by hand: the guard clause
    // returns before the line that would have recorded the timing.
    const fn = t.wrap(HISTOGRAM.name, `function(player) if not player then return end return 'paid' end`)

    fn.call(false)
    fn.call(false)

    assert.equal(observations(t), 2)
})

test('the duration of a failing call is recorded, not discarded', async () => {
    const t = await withHistogram()

    // 250 ms of work before it blows up. A histogram that drops this is exactly
    // how a p99 comes back looking healthy.
    const fn = t.wrap(HISTOGRAM.name, `function() T_setTimer(1250) error('timeout', 0) end`)

    t.setTimer(1000)
    fn.pcall()

    assert.equal(observations(t), 1)
    assert.ok(Math.abs(sum(t) - 0.25) < 1e-9, `expected 0.25 s observed, got ${sum(t)}`)
})

//------------------------------------------------------------------------------
// Being a drop-in replacement
//------------------------------------------------------------------------------

test('arguments pass through untouched', async () => {
    const t = await withHistogram()

    const fn = t.wrap(HISTOGRAM.name, `function(a, b, c) return a .. '-' .. b .. '-' .. tostring(c) end`)

    assert.equal(fn.call('one', 'two', 3), 'one-two-3')
})

test('every return value survives, including a nil in the middle', async () => {
    const t = await withHistogram()

    // table.pack rather than `local ok, a, b = pcall(...)` is what makes this
    // pass. A fixed-arity unpack would silently truncate the third value, and an
    // ipairs-based one would stop at the embedded nil — an instrument that
    // changes what the wrapped function returns is worse than no instrument.
    const fn = t.wrap(HISTOGRAM.name, `function() return 'a', nil, 'c' end`)

    assert.equal(fn.callAll(), '3|a,nil,c')
})

test('a function returning nothing still returns nothing', async () => {
    const t = await withHistogram()

    const fn = t.wrap(HISTOGRAM.name, `function() return end`)

    assert.equal(fn.callAll(), '0|')
    assert.equal(observations(t), 1)
})

test('a single false return is not mistaken for no return', async () => {
    const t = await withHistogram()

    const fn = t.wrap(HISTOGRAM.name, `function() return false end`)

    assert.equal(fn.callAll(), '1|false')
})

//------------------------------------------------------------------------------
// Timing
//------------------------------------------------------------------------------

test('the observation is the elapsed time in seconds', async () => {
    const t = await withHistogram()

    const fn = t.wrap(HISTOGRAM.name, `function() T_setTimer(1120) end`)

    t.setTimer(1000)
    fn.call()

    // 120 ms of wall clock, reported in seconds because that is the base unit
    // the metric name promises.
    assert.ok(Math.abs(sum(t) - 0.12) < 1e-9, `expected 0.12, got ${sum(t)}`)
})

test('each call is observed separately', async () => {
    const t = await withHistogram()

    const fn = t.wrap(HISTOGRAM.name, `function() T_setTimer(GetGameTimer() + 50) end`)

    t.setTimer(0)
    fn.call()
    fn.call()
    fn.call()

    assert.equal(observations(t), 3)
    assert.ok(Math.abs(sum(t) - 0.15) < 1e-9, `expected 0.15 across three calls, got ${sum(t)}`)
})

//------------------------------------------------------------------------------
// Labels, and refusing to be used wrongly
//------------------------------------------------------------------------------

test('labels are passed through to the observation', async () => {
    const t = await loadTimed()
    t.register({
        name: 'myjob_duration_seconds',
        type: 'histogram',
        help: 'How long the job took.',
        labels: ['job']
    })

    const fn = t.wrap('myjob_duration_seconds', `function() T_setTimer(1030) end`, { job: 'trucker' })

    t.setTimer(1000)
    fn.call()

    assert.match(t.render(), /myjob_duration_seconds_count\{job="trucker"\} 1/)
})

test('wrapping something that is not a function fails at wrap time', async () => {
    const t = await withHistogram()

    // Loudly, and immediately. This is a mistake a developer is looking at when
    // they make it, unlike a write on a hot path — so unlike the write API, which
    // returns false and never raises, this one raises.
    for (const source of ['nil', "'a string'", '42', '{}']) {
        const outcome = t.tryWrap(HISTOGRAM.name, source)
        assert.equal(outcome.ok, false, `wrapping ${source} should have raised`)
        assert.match(outcome.message, /expects a function to wrap/)
    }
})

test('an unregistered metric name does not break the wrapped function', async () => {
    const t = await loadTimed()

    // Nothing registered. The write is refused and counted, but the wrapped
    // function must still run and still return — a metrics helper that takes a
    // resource down because a metric name was wrong is worse than a flat graph.
    const fn = t.wrap('never_registered_seconds', `function() return 'still ran' end`)

    assert.equal(fn.call(), 'still ran')
    assert.match(t.render(), /tickwatch_export_errors_total\{reason="[^"]+"\} 1/)
})
