import { test } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { fileURLToPath } from 'node:url'
import path from 'node:path'
import { loadRegistry, parseExposition } from './helpers/load-registry.mjs'

const root = path.join(path.dirname(fileURLToPath(import.meta.url)), '..')

// The registry registers its own drop counter, so a fresh registry is never
// empty. Tests that count metric families account for it by name.
const DROPPED = 'tickwatch_series_dropped_total'

//------------------------------------------------------------------------------
// The harness itself
//------------------------------------------------------------------------------

test('the bridge carries strings into Lua unchanged', async () => {
    // Calls reach Lua as generated source, so every string is escaped twice on
    // the way in — once for the Lua literal, then by the registry for the
    // exposition. If the first of those were wrong, the escaping tests below
    // would be measuring the harness rather than the registry. This checks the
    // harness first so those tests mean what they say.
    const reg = await loadRegistry()

    for (const value of ['plain', 'a\\b', 'a"b', 'a\nb', 'a\tb', '\\\\', '"', '', 'ünïcødé', 'a\\"b'])
        assert.equal(reg.echo(value), value, `bridge mangled ${JSON.stringify(value)}`)
})

//------------------------------------------------------------------------------
// Exposition shape
//------------------------------------------------------------------------------

test('every metric emits HELP and TYPE', async () => {
    const reg = await loadRegistry()

    reg.register({ name: 'demo_requests_total', type: 'counter', help: 'Requests served.' })
    reg.register({ name: 'demo_players', type: 'gauge', help: 'Players connected.' })
    reg.register({ name: 'demo_latency_seconds', type: 'histogram', help: 'Latency.' })

    const out = parseExposition(reg.render())

    for (const name of ['demo_requests_total', 'demo_players', 'demo_latency_seconds', DROPPED]) {
        assert.ok(out.help[name], `${name} is missing HELP`)
        assert.ok(out.type[name], `${name} is missing TYPE`)
    }

    assert.equal(out.type.demo_requests_total, 'counter')
    assert.equal(out.type.demo_players, 'gauge')
    assert.equal(out.type.demo_latency_seconds, 'histogram')
})

test('a metric with no labels renders with no braces at all', async () => {
    const reg = await loadRegistry()

    reg.register({ name: 'demo_up', type: 'gauge', help: 'Up.' })
    reg.set('demo_up', undefined, 1)

    assert.ok(reg.render().includes('\ndemo_up 1\n'))
})

test('the exposition ends with a newline', async () => {
    const reg = await loadRegistry()

    reg.register({ name: 'demo_up', type: 'gauge', help: 'Up.' })
    reg.set('demo_up', undefined, 1)

    assert.ok(reg.render().endsWith('\n'))
})

test('a registered metric with no writes still announces itself', async () => {
    // HELP and TYPE with no samples is valid exposition, and it means a metric
    // that has not fired yet is still discoverable by whoever is querying.
    const reg = await loadRegistry()

    reg.register({ name: 'demo_never_written_total', type: 'counter', help: 'Nothing yet.' })

    const out = parseExposition(reg.render())

    assert.equal(out.type.demo_never_written_total, 'counter')
    assert.equal(out.of('demo_never_written_total').length, 0)
})

//------------------------------------------------------------------------------
// Counters and gauges
//------------------------------------------------------------------------------

test('inc defaults to 1 and accumulates', async () => {
    const reg = await loadRegistry()

    reg.register({ name: 'demo_events_total', type: 'counter', help: 'Events.' })

    reg.inc('demo_events_total')
    reg.inc('demo_events_total')
    reg.inc('demo_events_total', undefined, 5)

    assert.equal(parseExposition(reg.render()).one('demo_events_total').value, 7)
})

test('a gauge takes an absolute value and can fall', async () => {
    const reg = await loadRegistry()

    reg.register({ name: 'demo_players', type: 'gauge', help: 'Players.' })

    reg.set('demo_players', undefined, 14)
    reg.set('demo_players', undefined, 3)

    assert.equal(parseExposition(reg.render()).one('demo_players').value, 3)
})

test('a counter cannot decrease', async () => {
    const reg = await loadRegistry()

    reg.register({ name: 'demo_events_total', type: 'counter', help: 'Events.' })

    assert.throws(() => reg.inc('demo_events_total', undefined, -1), /cannot decrease/)
})

//------------------------------------------------------------------------------
// Series identity
//------------------------------------------------------------------------------

test('the same labels in a different order are one series, not two', async () => {
    // This is the whole reason label names are sorted at registration and read
    // in that fixed order on write. Lua's pairs() order is unspecified, so a
    // registry that serialized in iteration order would split one logical series
    // in two — each holding part of the count, and neither raising an error.
    const reg = await loadRegistry()

    reg.register({
        name: 'demo_db_queries_total',
        type: 'counter',
        help: 'Queries.',
        labels: ['op', 'status']
    })

    reg.inc('demo_db_queries_total', { op: 'select', status: 'ok' })
    reg.inc('demo_db_queries_total', { status: 'ok', op: 'select' })

    assert.equal(reg.seriesCount('demo_db_queries_total'), 1)

    const out = parseExposition(reg.render())

    assert.equal(out.of('demo_db_queries_total').length, 1)
    assert.equal(out.one('demo_db_queries_total', { op: 'select', status: 'ok' }).value, 2)
})

test('labels are emitted in sorted order regardless of how they were passed', async () => {
    const reg = await loadRegistry()

    reg.register({
        name: 'demo_db_queries_total',
        type: 'counter',
        help: 'Queries.',
        labels: ['status', 'op']
    })

    reg.inc('demo_db_queries_total', { status: 'ok', op: 'select' })

    assert.ok(reg.render().includes('demo_db_queries_total{op="select",status="ok"} 1'))
})

test('different label sets are different series', async () => {
    const reg = await loadRegistry()

    reg.register({ name: 'demo_entities', type: 'gauge', help: 'Entities.', labels: ['type'] })

    reg.set('demo_entities', { type: 'ped' }, 42)
    reg.set('demo_entities', { type: 'vehicle' }, 17)

    const out = parseExposition(reg.render())

    assert.equal(out.of('demo_entities').length, 2)
    assert.equal(out.one('demo_entities', { type: 'ped' }).value, 42)
    assert.equal(out.one('demo_entities', { type: 'vehicle' }).value, 17)
})

test('a label the metric does not declare is rejected', async () => {
    const reg = await loadRegistry()

    reg.register({ name: 'demo_entities', type: 'gauge', help: 'Entities.', labels: ['type'] })

    assert.throws(() => reg.set('demo_entities', { type: 'ped', extra: 'x' }, 1), /declares 1/)
})

test('a misspelled label is rejected rather than creating a near-duplicate series', async () => {
    const reg = await loadRegistry()

    reg.register({ name: 'demo_entities', type: 'gauge', help: 'Entities.', labels: ['type'] })

    assert.throws(() => reg.set('demo_entities', { tpye: 'ped' }, 1), /must be a string/)
})

test('a non-string label value is rejected', async () => {
    // Coercing would let 1 and "1" index different series that render identical
    // lines, which is a duplicate series that looks like a single one.
    const reg = await loadRegistry()

    reg.register({ name: 'demo_entities', type: 'gauge', help: 'Entities.', labels: ['type'] })

    assert.throws(() => reg.set('demo_entities', { type: 3 }, 1), /must be a string/)
})

test('passing labels to a metric that declares none is rejected', async () => {
    const reg = await loadRegistry()

    reg.register({ name: 'demo_up', type: 'gauge', help: 'Up.' })

    assert.throws(() => reg.set('demo_up', { any: 'thing' }, 1), /takes no labels/)
})

//------------------------------------------------------------------------------
// Escaping
//------------------------------------------------------------------------------

test('label values escape backslash, quote and newline', async () => {
    const reg = await loadRegistry()

    reg.register({ name: 'demo_events_total', type: 'counter', help: 'Events.', labels: ['name'] })

    reg.inc('demo_events_total', { name: 'a\\b"c\nd' })

    const rendered = reg.render()

    // The escaped form on the wire...
    assert.ok(rendered.includes('demo_events_total{name="a\\\\b\\"c\\nd"} 1'))

    // ...and it survives a round trip, which is the property that matters.
    assert.equal(parseExposition(rendered).of('demo_events_total')[0].labels.name, 'a\\b"c\nd')
})

test('the backslash is escaped before the characters whose escapes introduce one', async () => {
    // Escaping in the wrong order turns a single backslash into a double, or
    // double-escapes the backslash that \" just introduced.
    const reg = await loadRegistry()

    reg.register({ name: 'demo_events_total', type: 'counter', help: 'Events.', labels: ['name'] })

    reg.inc('demo_events_total', { name: '\\' })

    assert.ok(reg.render().includes('{name="\\\\"}'))
})

test('help text escapes backslash and newline but not the quote', async () => {
    // HELP is the remainder of the line rather than a quoted string, so a double
    // quote in it needs no escape and escaping it would change the text.
    const reg = await loadRegistry()

    reg.register({ name: 'demo_up', type: 'gauge', help: 'A "quoted" word, a \\ and a\nbreak.' })

    const line = reg.render().split('\n').find(l => l.startsWith('# HELP demo_up'))

    assert.equal(line, '# HELP demo_up A "quoted" word, a \\\\ and a\\nbreak.')
})

//------------------------------------------------------------------------------
// Histograms — the case no exposition linter can catch
//------------------------------------------------------------------------------

const BUCKETS = [0.001, 0.002, 0.005, 0.01, 0.02, 0.05, 0.1, 0.25, 0.5, 1]

async function histogramWith(observations, buckets = BUCKETS) {
    const reg = await loadRegistry()

    reg.register({ name: 'demo_latency_seconds', type: 'histogram', help: 'Latency.', buckets })

    for (const v of observations) reg.observe('demo_latency_seconds', undefined, v)

    return parseExposition(reg.render())
}

test('buckets are cumulative, not per-bucket counts', async () => {
    // One observation in each of the first three buckets. Cumulative means
    // le="0.005" reports all three, not the one that fell between 2 and 5 ms.
    // A per-bucket implementation renders 1/1/1 here — valid text, wrong data,
    // and histogram_quantile() reports plausible nonsense from it forever.
    const out = await histogramWith([0.001, 0.002, 0.005])
    const buckets = out.of('demo_latency_seconds_bucket')

    assert.equal(buckets.find(b => b.labels.le === '0.001').value, 1)
    assert.equal(buckets.find(b => b.labels.le === '0.002').value, 2)
    assert.equal(buckets.find(b => b.labels.le === '0.005').value, 3)
    assert.equal(buckets.find(b => b.labels.le === '0.01').value, 3)
})

test('bucket counts never decrease as the bound rises', async () => {
    const out = await histogramWith([0.0005, 0.003, 0.003, 0.4, 2, 90])
    const buckets = out.of('demo_latency_seconds_bucket')

    let previous = -1

    for (const bucket of buckets) {
        assert.ok(bucket.value >= previous,
            `le="${bucket.labels.le}" fell to ${bucket.value} from ${previous}`)
        previous = bucket.value
    }
})

test('the last bucket is +Inf and equals _count', async () => {
    // The renderer carries its running sum through the overflow slot to produce
    // +Inf rather than copying _count into it. So this holds only if every
    // observation was filed into exactly one slot — if any were double-counted
    // or lost, the two numbers disagree here.
    const observations = [0.0005, 0.003, 0.003, 0.4, 2, 90]
    const out = await histogramWith(observations)

    const buckets = out.of('demo_latency_seconds_bucket')
    const last = buckets[buckets.length - 1]

    assert.equal(last.labels.le, '+Inf')
    assert.equal(last.value, observations.length)
    assert.equal(out.one('demo_latency_seconds_count').value, observations.length)
    assert.equal(last.value, out.one('demo_latency_seconds_count').value)
})

test('an observation on a bucket bound falls inside it', async () => {
    // le means less than or equal. Getting this wrong by one bucket is invisible
    // in aggregate and shifts every percentile.
    const out = await histogramWith([0.01])
    const buckets = out.of('demo_latency_seconds_bucket')

    assert.equal(buckets.find(b => b.labels.le === '0.005').value, 0)
    assert.equal(buckets.find(b => b.labels.le === '0.01').value, 1)
})

test('an observation above the last finite bound reaches only +Inf', async () => {
    const out = await histogramWith([5])
    const buckets = out.of('demo_latency_seconds_bucket')

    assert.equal(buckets.find(b => b.labels.le === '1').value, 0)
    assert.equal(buckets[buckets.length - 1].value, 1)
    assert.equal(out.one('demo_latency_seconds_count').value, 1)
})

test('_sum totals the observations and _count counts them', async () => {
    const out = await histogramWith([0.001, 0.002, 0.005])

    assert.ok(Math.abs(out.one('demo_latency_seconds_sum').value - 0.008) < 1e-12)
    assert.equal(out.one('demo_latency_seconds_count').value, 3)
})

test('a histogram carries its labels onto every bucket, sum and count line', async () => {
    const reg = await loadRegistry()

    reg.register({
        name: 'demo_query_seconds',
        type: 'histogram',
        help: 'Query duration.',
        labels: ['op'],
        buckets: [0.01, 0.1]
    })

    reg.observe('demo_query_seconds', { op: 'select' }, 0.05)
    reg.observe('demo_query_seconds', { op: 'insert' }, 0.5)

    const out = parseExposition(reg.render())

    assert.equal(out.one('demo_query_seconds_bucket', { op: 'select', le: '0.01' }).value, 0)
    assert.equal(out.one('demo_query_seconds_bucket', { op: 'select', le: '0.1' }).value, 1)
    assert.equal(out.one('demo_query_seconds_bucket', { op: 'select', le: '+Inf' }).value, 1)
    assert.equal(out.one('demo_query_seconds_count', { op: 'select' }).value, 1)

    assert.equal(out.one('demo_query_seconds_bucket', { op: 'insert', le: '0.1' }).value, 0)
    assert.equal(out.one('demo_query_seconds_bucket', { op: 'insert', le: '+Inf' }).value, 1)
})

test('bucket bounds must strictly ascend', async () => {
    const reg = await loadRegistry()

    assert.throws(() => reg.register({
        name: 'demo_bad_seconds', type: 'histogram', help: 'Bad.', buckets: [0.01, 0.005]
    }), /ascend/)

    assert.throws(() => reg.register({
        name: 'demo_bad2_seconds', type: 'histogram', help: 'Bad.', buckets: [0.01, 0.01]
    }), /ascend/)
})

test('a histogram cannot declare the reserved le label', async () => {
    const reg = await loadRegistry()

    assert.throws(() => reg.register({
        name: 'demo_bad_seconds', type: 'histogram', help: 'Bad.', labels: ['le']
    }), /reserved label le/)
})

//------------------------------------------------------------------------------
// Cardinality guard
//------------------------------------------------------------------------------

test('the cap stops new series and records the drop', async () => {
    const reg = await loadRegistry()

    reg.register({ name: 'demo_events_total', type: 'counter', help: 'Events.', labels: ['event'], cap: 3 })

    for (let i = 0; i < 5; i++) reg.inc('demo_events_total', { event: `e${i}` })

    assert.equal(reg.seriesCount('demo_events_total'), 3)

    const out = parseExposition(reg.render())

    assert.equal(out.of('demo_events_total').length, 3)
    assert.equal(out.one(DROPPED, { metric: 'demo_events_total' }).value, 2)
})

test('the first N label sets win, and they stay writable after the cap trips', async () => {
    // The cap is a memory guard, not a sampling strategy: series already in the
    // registry keep counting normally.
    const reg = await loadRegistry()

    reg.register({ name: 'demo_events_total', type: 'counter', help: 'Events.', labels: ['event'], cap: 2 })

    reg.inc('demo_events_total', { event: 'first' })
    reg.inc('demo_events_total', { event: 'second' })
    reg.inc('demo_events_total', { event: 'third' })
    reg.inc('demo_events_total', { event: 'first' })

    const out = parseExposition(reg.render())

    assert.equal(out.one('demo_events_total', { event: 'first' }).value, 2)
    assert.equal(out.one('demo_events_total', { event: 'second' }).value, 1)
    assert.equal(out.of('demo_events_total').length, 2)
})

test('a refused write does not grow the registry', async () => {
    // The index tree is only extended once the cap has agreed to the series. If
    // it were built during the lookup, an unbounded stream of new label sets
    // would grow memory without ever growing the series count — the cap would
    // bound the number it reports and not the thing it exists to protect.
    const reg = await loadRegistry()

    reg.register({ name: 'demo_events_total', type: 'counter', help: 'Events.', labels: ['event'], cap: 2 })

    for (let i = 0; i < 500; i++) reg.inc('demo_events_total', { event: `e${i}` })

    assert.equal(reg.seriesCount('demo_events_total'), 2)
    assert.equal(parseExposition(reg.render()).one(DROPPED, { metric: 'demo_events_total' }).value, 498)
})

test('drops are counted per metric', async () => {
    const reg = await loadRegistry()

    reg.register({ name: 'demo_a_total', type: 'counter', help: 'A.', labels: ['k'], cap: 1 })
    reg.register({ name: 'demo_b_total', type: 'counter', help: 'B.', labels: ['k'], cap: 1 })

    reg.inc('demo_a_total', { k: '1' })
    reg.inc('demo_a_total', { k: '2' })
    reg.inc('demo_b_total', { k: '1' })
    reg.inc('demo_b_total', { k: '2' })
    reg.inc('demo_b_total', { k: '3' })

    const out = parseExposition(reg.render())

    assert.equal(out.one(DROPPED, { metric: 'demo_a_total' }).value, 1)
    assert.equal(out.one(DROPPED, { metric: 'demo_b_total' }).value, 2)
})

//------------------------------------------------------------------------------
// Rejecting bad calls
//------------------------------------------------------------------------------

test('writing to an unregistered metric raises', async () => {
    // Never created on demand. A typo that silently opened a new series would
    // produce a metric nobody is graphing and no error to notice.
    const reg = await loadRegistry()

    assert.throws(() => reg.inc('demo_missing_total'), /not a registered metric/)
    assert.throws(() => reg.set('demo_missing', undefined, 1), /not a registered metric/)
    assert.throws(() => reg.observe('demo_missing_seconds', undefined, 1), /not a registered metric/)
})

test('a write has to match the metric type', async () => {
    const reg = await loadRegistry()

    reg.register({ name: 'demo_events_total', type: 'counter', help: 'Events.' })
    reg.register({ name: 'demo_players', type: 'gauge', help: 'Players.' })
    reg.register({ name: 'demo_latency_seconds', type: 'histogram', help: 'Latency.' })

    assert.throws(() => reg.set('demo_events_total', undefined, 1), /is a counter, not a gauge/)
    assert.throws(() => reg.inc('demo_players'), /is a gauge, not a counter/)
    assert.throws(() => reg.observe('demo_players', undefined, 1), /is a gauge, not a histogram/)
    assert.throws(() => reg.inc('demo_latency_seconds'), /is a histogram, not a counter/)
})

test('registering the same name twice raises', async () => {
    const reg = await loadRegistry()

    reg.register({ name: 'demo_events_total', type: 'counter', help: 'Events.' })

    assert.throws(() => reg.register({ name: 'demo_events_total', type: 'counter', help: 'Again.' }),
        /already registered/)
})

test('a metric needs a valid name, a known type and a help string', async () => {
    const reg = await loadRegistry()

    assert.throws(() => reg.register({ name: '9bad', type: 'counter', help: 'x' }), /invalid metric name/)
    assert.throws(() => reg.register({ name: 'bad-name', type: 'counter', help: 'x' }), /invalid metric name/)
    assert.throws(() => reg.register({ name: 'demo_x', type: 'summary', help: 'x' }), /invalid type/)
    assert.throws(() => reg.register({ name: 'demo_x', type: 'counter' }), /help/)
    assert.throws(() => reg.register({ name: 'demo_x', type: 'counter', help: '' }), /help/)
})

test('label names are validated and cannot repeat', async () => {
    const reg = await loadRegistry()

    assert.throws(() => reg.register({
        name: 'demo_x', type: 'counter', help: 'x', labels: ['bad-label']
    }), /invalid label name/)

    assert.throws(() => reg.register({
        name: 'demo_y', type: 'counter', help: 'x', labels: ['op', 'op']
    }), /twice/)
})

//------------------------------------------------------------------------------
// Golden file
//------------------------------------------------------------------------------

// A golden file pins the exact bytes on the wire. The assertions above each
// check one property; this checks that the whole document did not change in some
// way nobody wrote an assertion for — ordering, spacing, a stray line. When it
// fails, the diff is read and either the code or the golden is wrong; it is
// never updated without looking.
test('a fixed registry renders byte for byte as the golden file', async () => {
    const reg = await loadRegistry()

    reg.register({ name: 'demo_server_up', type: 'gauge', help: 'Always 1 while the exporter is running.' })
    reg.register({ name: 'demo_entities', type: 'gauge', help: 'Entities by type.', labels: ['type'] })
    reg.register({ name: 'demo_connections_total', type: 'counter', help: 'Connection attempts by result.', labels: ['result'] })
    reg.register({
        name: 'demo_query_seconds',
        type: 'histogram',
        help: 'Database query duration.',
        labels: ['op'],
        buckets: [0.001, 0.01, 0.1]
    })

    reg.set('demo_server_up', undefined, 1)
    reg.set('demo_entities', { type: 'ped' }, 42)
    reg.set('demo_entities', { type: 'vehicle' }, 17)

    reg.inc('demo_connections_total', { result: 'attempted' }, 10)
    reg.inc('demo_connections_total', { result: 'joined' }, 8)

    reg.observe('demo_query_seconds', { op: 'select' }, 0.0005)
    reg.observe('demo_query_seconds', { op: 'select' }, 0.05)
    reg.observe('demo_query_seconds', { op: 'select' }, 3)

    const expected = readFileSync(path.join(root, 'tests', 'golden', 'exposition.txt'), 'utf8')

    assert.equal(reg.render(), expected)
})
