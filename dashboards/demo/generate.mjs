// Generates a day of synthetic metrics in OpenMetrics text format, for
// backfilling into Prometheus so the dashboards can be screenshotted with
// something on them. See README.md in this directory.
//
// This produces FAKE data. Nothing here is a measurement, and nothing here is
// loaded by the exporter.
//
//   node generate.mjs demo.openmetrics
//
// Writes the file itself rather than using stdout, because shell redirection on
// Windows prepends a UTF-8 BOM and the OpenMetrics parser rejects it.
//
// The day is built around four incidents rather than around noise, because the
// point of the screenshot is to show what can be READ off these panels. Each
// one is visible in several places at once, and the panels have to agree — a
// mass disconnect that does not also move the entity count and the drop-reason
// breakdown is a picture of nothing.

import { writeFileSync } from 'node:fs';

const OUTPUT = process.argv[2] || 'demo.openmetrics';

const HOURS = 24;
const STEP = 30;                      // seconds between samples
const END = Math.floor(Date.now() / 1000 / STEP) * STEP;
const START = END - HOURS * 3600;
const STEPS = (END - START) / STEP;

const INSTANCE = 'primary';
const JOB = 'tickwatch';

// Deterministic noise, so regenerating gives the same picture.
let seed = 0x2f6e2b1;
function rnd() {
    seed = (seed * 1103515245 + 12345) & 0x7fffffff;
    return seed / 0x7fffffff;
}
const jitter = (amount) => (rnd() - 0.5) * 2 * amount;

//------------------------------------------------------------------------------
// The incidents
//------------------------------------------------------------------------------
// Hours from the start of the window. The window begins at the current time of
// day, so hour 0 is roughly "yesterday evening" and hour 21 is "this afternoon".

const INCIDENTS = {
    // A database that degrades for 40 minutes. Query p95 crosses the alert
    // threshold, errors rise, and it pushes into frame time and join success —
    // which is the point: the cause is visible one dashboard over.
    dbSlow: { from: 1.0, to: 1.7 },

    // The main thread starts missing its budget, then stalls hard.
    hitch: { from: 2.60, to: 3.00 },
    stall: { from: 2.94, to: 2.97 },

    // 22 players lost at once. Not 'quit' — 'crashed' and 'timeout', which is
    // how the drop-reason breakdown earns its place on the dashboard.
    massDisconnect: { at: 2.95, crashed: 18, timeout: 4 },

    // A resource stopped and restarted overnight.
    resourceRestart: { from: 5.20, to: 5.31, resource: 'qb-houses' },

    // Somebody probing the metrics endpoint with a bad token.
    badScrapes: { from: 15.5, to: 16.1 },

    // A milder rough patch as the server refills the next afternoon.
    roughPatch: { from: 21.0, to: 21.7 },
};

const H = 3600;
const hourOf = (t) => (t - START) / H;
const during = (t, w) => hourOf(t) >= w.from && hourOf(t) < w.to;
// How far through a window, 0..1 — for ramping an effect in and out.
const through = (t, w) => Math.min(1, Math.max(0, (hourOf(t) - w.from) / (w.to - w.from)));
// A hump: 0 at the edges, 1 in the middle.
const hump = (t, w) => (during(t, w) ? Math.sin(Math.PI * through(t, w)) : 0);

//------------------------------------------------------------------------------
// Population
//------------------------------------------------------------------------------

// Trough at 09:00, peak at 21:00, with a plateau rather than a spike.
function baseline(t) {
    const hour = ((t % 86400) / 3600 + 2) % 24;
    const wave = 0.5 * (1 - Math.cos((2 * Math.PI * (hour - 9)) / 24));
    return 3 + 46 * Math.pow(Math.max(wave, 0), 1.5);
}

const CHURN = 0.006;      // per player per step — about 33 joins/hour at peak
const RECOVERY = 0.045;   // how fast the population returns to baseline

// One forward walk producing the gauge and the counters together, so they
// cannot disagree. A player count that falls without matching drops is the
// single most misleading thing a fabricated dataset can contain.
const players = [];
const joinsPer = [];
const dropsPer = [];        // { quit, timeout, crashed, kicked, banned }
const REASONS = ['quit', 'timeout', 'crashed', 'kicked', 'banned'];

let pop = baseline(START);

for (let i = 0; i < STEPS; i++) {
    const t = START + i * STEP;
    const base = baseline(t);

    // Steady churn: people leaving and arriving at roughly equal rates.
    const churn = pop * CHURN;
    let joins = churn;
    const drops = { quit: churn * 0.80, timeout: churn * 0.12, crashed: churn * 0.05, kicked: churn * 0.02, banned: churn * 0.01 };

    // Drift toward the baseline, rate limited so a recovery takes ~30 minutes
    // rather than one sample.
    const gap = base - pop;
    if (gap > 0) joins += gap * RECOVERY;
    else drops.quit += -gap * RECOVERY;

    // The mass disconnect, in the single step it happens.
    const md = INCIDENTS.massDisconnect;
    if (hourOf(t) >= md.at && hourOf(t - STEP) < md.at) {
        drops.crashed += md.crashed;
        drops.timeout += md.timeout;
    }

    // A degraded server sheds a few extra players, and fewer arrive.
    const hitching = hump(t, INCIDENTS.hitch);
    drops.timeout += hitching * 0.6;
    joins *= 1 - 0.45 * hitching;

    const totalDrops = REASONS.reduce((a, r) => a + drops[r], 0);
    pop = Math.max(0, pop + joins - totalDrops);

    players.push(Math.max(0, Math.round(pop + jitter(1.4))));
    joinsPer.push(joins);
    dropsPer.push(drops);
}

// 0 when empty, 1 at a full server. Drives every load-dependent distribution.
const loadAt = (i) => Math.min(1, players[i] / 48);

//------------------------------------------------------------------------------
// Emitting
//------------------------------------------------------------------------------

const out = [];

// Every family is declared a gauge. The backfiller only needs the samples to be
// well formed, and declaring counters under OpenMetrics' `_total` convention
// would mean renaming series the dashboards query by their real names.
function family(name, help, series) {
    out.push(`# HELP ${name} ${help}`);
    out.push(`# TYPE ${name} gauge`);
    for (const { labels, values } of series) {
        const l = { instance: INSTANCE, job: JOB, ...labels };
        const tag = '{' + Object.entries(l).map(([k, v]) => `${k}="${v}"`).join(',') + '}';
        for (let i = 0; i < values.length; i++) {
            out.push(`${name}${tag} ${values[i]} ${START + i * STEP}`);
        }
    }
}

function series(fn) {
    const values = [];
    for (let i = 0; i < STEPS; i++) values.push(fn(START + i * STEP, i));
    return values;
}

// A counter: takes a per-step increment and accumulates it.
function counter(fn, from = 0) {
    let total = from;
    return series((t, i) => {
        total += fn(t, i);
        return Math.round(total * 1000) / 1000;
    });
}

// Spread n observations over weights by drawing each one, rather than by
// proportion. Proportional rounding puts every observation in the first bucket
// when n is small, which silently made session length read as 57 seconds.
function spread(n, weights) {
    const counts = new Array(weights.length).fill(0);
    const total = weights.reduce((a, b) => a + b, 0);
    if (total <= 0) return counts;

    for (let i = 0; i < n; i++) {
        let r = rnd() * total;
        for (let b = 0; b < weights.length; b++) {
            r -= weights[b];
            if (r <= 0) { counts[b]++; break; }
        }
    }
    return counts;
}

// Turns a fractional per-step rate into whole observations, carrying the
// remainder forward. A histogram fed Math.round() of a rate below 1 observes
// either nothing or one thing, and never the right number on average.
function accumulator() {
    let carry = 0;
    return (rate) => {
        carry += rate;
        const whole = Math.floor(carry);
        carry -= whole;
        return whole;
    };
}

// A histogram: takes a per-step { counts[], sum } and emits cumulative buckets.
function histogram(name, help, bounds, fn, labels = {}) {
    const running = new Array(bounds.length + 1).fill(0);
    let sum = 0, count = 0;
    const buckets = bounds.map(() => []);
    const inf = [], sums = [], counts = [];

    for (let i = 0; i < STEPS; i++) {
        const step = fn(START + i * STEP, i);
        for (let b = 0; b < running.length; b++) running[b] += step.counts[b] || 0;
        sum += step.sum;
        count += step.counts.reduce((a, b) => a + b, 0);

        let cum = 0;
        for (let b = 0; b < bounds.length; b++) {
            cum += running[b];
            buckets[b].push(cum);
        }
        inf.push(cum + running[bounds.length]);
        sums.push(Math.round(sum * 1000) / 1000);
        counts.push(count);
    }

    family(`${name}_bucket`, help, [
        ...bounds.map((b, i) => ({ labels: { ...labels, le: String(b) }, values: buckets[i] })),
        { labels: { ...labels, le: '+Inf' }, values: inf },
    ]);
    family(`${name}_sum`, help, [{ labels, values: sums }]);
    family(`${name}_count`, help, [{ labels, values: counts }]);
}

const weighted = (counts, mids) => counts.reduce((a, c, b) => a + c * mids[b], 0);

//------------------------------------------------------------------------------
// Server state
//------------------------------------------------------------------------------

family('up', 'Scrape succeeded.', [{ labels: {}, values: series(() => 1) }]);
family('fivem_server_up', 'Always 1 while the exporter is running.',
    [{ labels: {}, values: series(() => 1) }]);
family('fivem_server_uptime_seconds', 'Seconds since the server process started.',
    [{ labels: {}, values: series((t) => t - START + 412_000) }]);
family('fivem_server_info', 'Server build and game, as labels on a constant 1.',
    [{ labels: { version: 'FXServer-master v1.0.0.13598 win32', gamename: 'gta5' }, values: series(() => 1) }]);

family('fivem_players_connected', 'Players currently connected.',
    [{ labels: {}, values: players }]);
family('fivem_players_max', 'Player slots configured, from sv_maxclients.',
    [{ labels: {}, values: series(() => 64) }]);

//------------------------------------------------------------------------------
// Frame timing
//------------------------------------------------------------------------------

const TICK_BUCKETS = [0.033, 0.045, 0.055, 0.07, 0.09, 0.12, 0.15, 0.25, 0.5, 1, 2.5, 5];
const TICK_MIDS = [0.028, 0.040, 0.050, 0.062, 0.080, 0.105, 0.135, 0.20, 0.375, 0.75, 1.75, 3.75, 6.0];

histogram('fivem_server_tick_interval_seconds',
    'Interval between successive frames, observed by the exporter\'s own thread.',
    TICK_BUCKETS,
    (t, i) => {
        const load = loadAt(i);

        // Healthy: nearly everything in the bucket bracketing the 20 Hz
        // baseline, with a thin tail that thickens under load.
        const w = [0, 6, 9400 - 900 * load, 380 + 260 * load, 90 + 120 * load,
                   26 + 60 * load, 8 + 22 * load, 4 + 12 * load, 1 + 3 * load, 0, 0, 0, 0];

        // The hitch drags mass into the 90-250 ms range.
        const h = hump(t, INCIDENTS.hitch);
        if (h > 0) {
            w[3] += 900 * h; w[4] += 700 * h; w[5] += 520 * h;
            w[6] += 300 * h; w[7] += 260 * h; w[8] += 90 * h; w[9] += 14 * h;
        }

        // The stall itself: frames measured in whole seconds.
        const s = hump(t, INCIDENTS.stall);
        if (s > 0) {
            w[8] += 200 * s; w[9] += 260 * s; w[10] += 150 * s; w[11] += 40 * s; w[12] += 6 * s;
        }

        const r = hump(t, INCIDENTS.roughPatch);
        if (r > 0) { w[3] += 420 * r; w[4] += 260 * r; w[5] += 130 * r; w[6] += 60 * r; w[7] += 26 * r; }

        // Fewer frames happen when frames take longer.
        const frames = Math.round(600 * (1 - 0.06 * load - 0.42 * h - 0.75 * s) + jitter(6));
        const counts = spread(Math.max(40, frames), w);
        return { counts, sum: weighted(counts, TICK_MIDS) };
    });

// The engine's own tick histogram, from /perf/ as a second scrape job. Work done
// INSIDE a frame, not the gap between frames — a different quantity.
const perfLabels = { name: 'svMain', job: 'fxserver-perf' };
family('fxserver_tick_time_seconds_count', 'Engine tick count.',
    [{ labels: perfLabels, values: counter((t, i) => 600 * (1 - 0.06 * loadAt(i) - 0.42 * hump(t, INCIDENTS.hitch))) }]);
family('fxserver_tick_time_seconds_sum', 'Engine tick work.',
    [{ labels: perfLabels, values: counter((t, i) => 600 * (0.00018 + 0.0009 * loadAt(i) + 0.004 * hump(t, INCIDENTS.hitch))) }]);

//------------------------------------------------------------------------------
// Players
//------------------------------------------------------------------------------

const PING_BUCKETS = [0.01, 0.02, 0.03, 0.05, 0.075, 0.1, 0.15, 0.2, 0.3, 0.5, 1];
const PING_MIDS = [0.008, 0.015, 0.025, 0.04, 0.062, 0.087, 0.125, 0.175, 0.25, 0.4, 0.75, 1.4];

histogram('fivem_player_ping_seconds', 'Distribution of connected players\' ping.',
    PING_BUCKETS,
    (t, i) => {
        const load = loadAt(i);
        const h = hump(t, INCIDENTS.hitch);
        // A stalled server cannot answer promptly either, so the tail moves.
        const w = [2, 30, 90, 300, 240, 120 + 90 * h, 55 + 110 * h, 22 + 90 * h,
                   10 + 20 * load + 70 * h, 4 + 40 * h, 1 + 14 * h, 1];
        const counts = spread(players[i] * 3, w);   // one players pass per 10 s
        return { counts, sum: weighted(counts, PING_MIDS) };
    });

// Join success falls with load, and collapses while the server is hitching —
// deferrals time out before they resolve.
const failureRate = series((t, i) =>
    Math.min(0.85, 0.02 + 0.07 * Math.pow(loadAt(i), 2) + 0.55 * hump(t, INCIDENTS.hitch) + jitter(0.006)));

family('fivem_player_connections_total', 'Connection attempts by outcome.', [
    { labels: { result: 'attempted' }, values: counter((t, i) => joinsPer[i] / (1 - failureRate[i])) },
    { labels: { result: 'joined' }, values: counter((t, i) => joinsPer[i]) },
]);

family('fivem_player_drops_total', 'Players dropped, by normalised reason.',
    REASONS.map((reason) => ({ labels: { reason }, values: counter((t, i) => dropsPer[i][reason]) })));

const SESSION_BUCKETS = [60, 300, 900, 1800, 3600, 7200, 14400, 28800];
const SESSION_MIDS = [30, 180, 600, 1350, 2700, 5400, 10800, 21600, 40000];
const sessionObs = accumulator();

histogram('fivem_player_session_duration_seconds', 'How long a session lasted.',
    SESSION_BUCKETS,
    (t, i) => {
        const total = REASONS.reduce((a, r) => a + dropsPer[i][r], 0);
        // A mass crash truncates whatever was in progress, so the distribution
        // shifts down for exactly one sample. That dip is the evidence.
        const md = INCIDENTS.massDisconnect;
        const crashed = hourOf(t) >= md.at && hourOf(t - STEP) < md.at;
        const w = crashed
            ? [1, 6, 16, 26, 30, 15, 4, 1, 1]
            : [2, 5, 10, 17, 27, 24, 11, 3, 1];
        const counts = spread(sessionObs(total), w);
        return { counts, sum: weighted(counts, SESSION_MIDS) };
    });

//------------------------------------------------------------------------------
// Entities and resources
//------------------------------------------------------------------------------

// Entities follow the population. If 22 players vanish and the entity count does
// not move, the dashboard is lying about something.
family('fivem_entities', 'Server-side entities by type.', [
    { labels: { type: 'ped' }, values: series((t, i) => Math.round(players[i] * 1.9 + jitter(4))) },
    { labels: { type: 'vehicle' }, values: series((t, i) => Math.round(players[i] * 2.4 + jitter(5))) },
    { labels: { type: 'object' }, values: series((t, i) => Math.round(players[i] * 0.6 + 12 + jitter(3))) },
]);

const RESOURCES = [
    'chat', 'spawnmanager', 'sessionmanager', 'mapmanager', 'basic-gamemode', 'hardcap',
    'rconlog', 'scoreboard', 'playernames', 'oxmysql', 'ox_lib', 'qb-core', 'qb-spawn',
    'qb-multicharacter', 'qb-inventory', 'qb-target', 'qb-menu', 'qb-input', 'qb-clothing',
    'qb-weathersync', 'qb-vehiclekeys', 'qb-garages', 'qb-fuel', 'qb-hud', 'qb-phone',
    'qb-banking', 'qb-shops', 'qb-policejob', 'qb-ambulancejob', 'qb-mechanicjob',
    'qb-taxijob', 'qb-houses', 'qb-apartments', 'qb-doorlock', 'qb-radialmenu',
    'screenshot-basic', 'pma-voice', 'interact-sound', 'tickwatch',
];

family('fivem_resource_up', 'Resource state: 1 while started, 0 otherwise.',
    RESOURCES.map((resource) => ({
        labels: { resource },
        values: series((t) =>
            resource === INCIDENTS.resourceRestart.resource && during(t, INCIDENTS.resourceRestart) ? 0 : 1),
    })));

//------------------------------------------------------------------------------
// Pushed through the export API
//------------------------------------------------------------------------------

const DB_BUCKETS = [0.001, 0.002, 0.005, 0.01, 0.02, 0.05, 0.1, 0.25, 0.5, 1];
const DB_MIDS = [0.0007, 0.0015, 0.0035, 0.0075, 0.015, 0.035, 0.075, 0.175, 0.375, 0.75, 1.4];

const DB_FAST = [300, 420, 220, 40, 12, 4, 2, 1, 0, 0, 0];   // p95 ~6 ms
const DB_SLOW = [150, 330, 330, 120, 45, 15, 6, 3, 1, 0, 0]; // p95 ~14 ms

const DB_OPS = [
    { op: 'select', rate: 5.4, shape: DB_FAST },
    { op: 'update', rate: 1.8, shape: DB_SLOW },
    { op: 'insert', rate: 0.6, shape: DB_SLOW },
    { op: 'delete', rate: 0.08, shape: DB_FAST },
];

// The database incident: p95 crosses the 50 ms alert and the error ratio rises
// with it, half an hour before anything shows up in frame time.
const dbTrouble = series((t) => hump(t, INCIDENTS.dbSlow));

family('fivem_db_queries_total', 'Database queries by operation and outcome.',
    DB_OPS.flatMap(({ op, rate }) => {
        const volume = (t, i) => rate * STEP * (0.3 + loadAt(i));
        const errRate = (t, i) => 0.003 + 0.13 * dbTrouble[i];
        return [
            { labels: { op, status: 'ok' }, values: counter((t, i) => volume(t, i) * (1 - errRate(t, i))) },
            { labels: { op, status: 'error' }, values: counter((t, i) => volume(t, i) * errRate(t, i)) },
        ];
    }));

for (const { op, rate, shape } of DB_OPS) {
    const obs = accumulator();
    histogram('fivem_db_query_duration_seconds', `Query duration for ${op}.`, DB_BUCKETS,
        (t, i) => {
            const load = loadAt(i);
            const d = dbTrouble[i];
            const w = shape.map((v, b) => v + (b >= 3 && b <= 6 ? v * 0.6 * load : 0));
            if (d > 0) {
                w[4] += 120 * d; w[5] += 400 * d; w[6] += 320 * d; w[7] += 140 * d; w[8] += 30 * d;
            }
            const counts = spread(obs(rate * STEP * (0.3 + load)), w);
            return { counts, sum: weighted(counts, DB_MIDS) };
        }, { op });
}

const EVENTS = [
    { event: 'playerRevive', rate: 0.02 },
    { event: 'vehicleSpawn', rate: 0.35 },
    { event: 'inventoryOpen', rate: 1.1 },
    { event: 'jobPayout', rate: 0.14 },
];

family('fivem_events_total', 'Events pushed by other resources, by event name.',
    EVENTS.map(({ event, rate }) => ({
        labels: { event },
        values: counter((t, i) => rate * STEP * (0.2 + loadAt(i))),
    })));

for (const { event, rate } of EVENTS) {
    const obs = accumulator();
    histogram('fivem_event_duration_seconds', `Duration of ${event}.`, DB_BUCKETS,
        (t, i) => {
            const load = loadAt(i);
            const d = dbTrouble[i];
            const w = [30, 80, 200, 160, 60, 20 + 25 * load + 90 * d, 5 + 60 * d, 2 + 24 * d, 0, 0, 0];
            const counts = spread(obs(rate * STEP * (0.2 + load)), w);
            return { counts, sum: weighted(counts, DB_MIDS) };
        }, { event });
}

//------------------------------------------------------------------------------
// The exporter measuring itself
//------------------------------------------------------------------------------

const seriesCount = series((t, i) => 118 + RESOURCES.length + Math.round(players[i] * 0.4));

// A scrape is deferred when a render has not landed yet, which is exactly what
// happens while the main thread is stalling. The exporter's own dashboard shows
// the incident too, from the other side.
family('tickwatch_scrapes_total', 'Scrape requests by outcome.', [
    { labels: { result: 'served' }, values: counter((t) => (STEP / 15) * (1 - 0.8 * hump(t, INCIDENTS.stall))) },
    { labels: { result: 'deferred' }, values: counter((t) => (rnd() < 0.02 ? 1 : 0) + (STEP / 15) * 0.8 * hump(t, INCIDENTS.hitch)) },
    { labels: { result: 'dropped' }, values: counter((t) => (STEP / 15) * 0.5 * hump(t, INCIDENTS.stall)) },
    { labels: { result: 'unauthorized' }, values: counter((t) => (during(t, INCIDENTS.badScrapes) ? 3 + Math.round(rnd() * 4) : 0)) },
]);

family('tickwatch_render_duration_seconds_count', 'Renders.',
    [{ labels: {}, values: counter(() => STEP / 5) }]);
family('tickwatch_render_duration_seconds_sum', 'Render time.',
    [{ labels: {}, values: counter((t, i) => (STEP / 5) * (0.000069 + seriesCount[i] * 3e-7)) }]);

family('tickwatch_collector_overhead_seconds_count', 'Overhead samples.',
    [{ labels: {}, values: counter((t) => (STEP * 20 / 32) * (1 - 0.4 * hump(t, INCIDENTS.hitch))) }]);
family('tickwatch_collector_overhead_seconds_sum', 'Overhead time.',
    [{ labels: {}, values: counter((t) => (STEP * 20 / 32) * 0.0000042) }]);

family('tickwatch_cache_age_seconds', 'Age of the payload the previous scrape was served.',
    [{ labels: {}, values: series((t) => Math.round((1.4 + rnd() * 3.4 + 9 * hump(t, INCIDENTS.hitch)) * 100) / 100) }]);

family('tickwatch_lua_memory_bytes', 'This resource\'s own Lua heap.',
    // Sawtooth: allocation between collections, then a GC drop.
    [{ labels: {}, values: series((t, i) => Math.round(1_180_000 + (i % 90) * 5400 + players[i] * 900)) }]);

family('tickwatch_series_dropped_total', 'Writes refused by the cardinality guard.',
    [{ labels: { metric: 'fivem_events_total' }, values: series(() => 0) }]);

family('tickwatch_export_errors_total', 'Rejected calls to the export API.',
    [{ labels: { reason: 'unknown_metric' }, values: counter(() => (rnd() < 0.0015 ? 1 : 0)) }]);

//------------------------------------------------------------------------------

out.push('# EOF');
writeFileSync(OUTPUT, out.join('\n') + '\n', { encoding: 'utf8' });

const peak = Math.max(...players);
const trough = Math.min(...players);
process.stderr.write(
    `${OUTPUT}: ${out.length} lines, ${STEPS} steps over ${HOURS} h, players ${trough}-${peak}\n`);
