# Design

What tickwatch is, how it is built, and why each part is shaped the way it is.

Every constraint below is a measured property of the runtime rather than a preference. The
measurements are in [`platform-notes.md`](platform-notes.md) and can be re-run from
[`tools/probe`](../tools/probe); this document states what follows from them.

---

## Goals

Expose the health of a running game server as Prometheus metrics, without becoming part of
the problem being measured.

A game server tick is a deadline. Instrumentation that misses it stops being instrumentation
and becomes load — which is the reason general-purpose exporters fit this class of server
badly. Three properties follow, and they order every decision in this document:

1. **Bounded cost.** Metric writes are O(1) and allocation-free. Collection runs on a fixed
   schedule. Nothing expensive happens on a caller-controlled path.
2. **Bounded cardinality.** Series count is limited by construction, not by convention.
3. **Honest reporting.** The exporter publishes its own overhead, and the documentation states
   what each metric cannot tell you.

### Non-goals

- **Per-resource CPU attribution.** Not implementable on this platform; see the limits below.
- **Replacing the engine's `/perf/` endpoint.** That is used as a reference, not superseded.
- **Log aggregation, tracing, or alerting delivery.** Metrics only; alerting is Grafana's job.
- **Being a framework resource.** No qb-core or ESX dependency, and no third-party code.

---

## Architecture

```
   game server                          collector                monitoring
 ┌──────────────┐                    ┌──────────────┐        ┌──────────────┐
 │  tickwatch   │  GET /metrics      │              │        │              │
 │  (Lua)       │◄───────────────────│  scrape +    │◄───────│  Prometheus  │
 │              │   bearer token     │  fan-in      │        │              │
 │  registry    │                    │              │        └──────┬───────┘
 │  collectors  │                    │  host/PID    │               │
 │  http        │                    │  MySQL       │        ┌──────▼───────┐
 └──────────────┘                    └──────────────┘        │   Grafana    │
        ▲                                                    └──────────────┘
        │ exports API
 ┌──────┴───────┐
 │ any resource │   Observe('db_query', {op='select'}, seconds)
 └──────────────┘
```

The Lua resource is useful on its own and is the first shippable milestone. The collector
exists to gather what a Lua resource **cannot see** — the host process, the database, and
more than one server — not to proxy what it can.

---

## What the platform allows

Six measured limits shape the design. Each links to its measurement.

| Limit | Consequence |
|---|---|
| No interface reports per-resource tick time ([notes](platform-notes.md#tick-timing-and-resource-attribution)) | Event-loop lag is used as a proxy for server load. It cannot name the resource that stalled. |
| HTTP handlers run on the main thread, serialized ([notes](platform-notes.md#http-handlers)) | Rendering never happens inside a request. |
| A handler stall is invisible to `/perf/` ([notes](platform-notes.md#http-handlers)) | The lag proxy observes a class of stall the engine's own histogram cannot. |
| `os.clock` is stock Lua — CPU time on POSIX ([notes](platform-notes.md#timing)) | `GetGameTimer()` is the only portable clock. Histograms floor at 1 ms. |
| `collectgarbage('count')` is per-resource ([notes](platform-notes.md#memory)) | The memory gauge is the exporter's own heap and is named to say so. |
| Enumerator cost follows total entity population ([notes](platform-notes.md#entities)) | The three enumerators are batched into one pass on the normal schedule. |

---

## The Lua exporter

```
fxmanifest.lua
config.lua              convar reading and validation
server/
  registry.lua          metric primitives + exposition renderer
  collectors.lua        built-in collectors
  http.lua              /metrics, /health, auth, serving model
  exports.lua           public API for other resources
tests/                  wasmoon suite, run under Node
```

### Registry

Counter, Gauge and Histogram implemented from scratch. No dependencies.

- Prometheus text exposition v0.0.4, served as
  `text/plain; version=0.0.4; charset=utf-8`.
- Every metric emits `# HELP` and `# TYPE`.
- Label values escaped for `\`, `"` and newline.
- Label sets keyed by a sorted, serialized string built **once per unique set** and cached.
  The key is never rebuilt on a write.

**Histograms are cumulative.** Each `_bucket{le="X"}` counts every observation where
`value <= X`, not the observations falling between this bound and the previous one. Buckets
ascend and end with `le="+Inf"`, which equals `_count`. `_sum` and `_count` are both emitted.

> This is the most common defect in a hand-written histogram and no exposition linter
> catches it — a non-cumulative histogram is *valid* text. It fails silently at query time,
> when `histogram_quantile()` returns wrong percentiles. It is a required test case.

That claim is now checked rather than asserted. Fed to `promtool check metrics` v3.13.2:

```
h_bucket{le="1"} 5      # buckets going BACKWARDS
h_bucket{le="2"} 3
h_bucket{le="+Inf"} 8
```

`exit 0`, no output. The same tool exits 3 on a counter missing a `_total` suffix, so it is
looking — it simply has no opinion about whether buckets are cumulative. Nothing between a
hand-written histogram and a wrong percentile except a test, which is why the suite asserts
monotonicity and `+Inf == _count` and why `probe collect` re-checks it on the wire.

**Bucket bounds are constants.** The default ladder is floored at 1 ms:

```
0.001, 0.002, 0.005, 0.01, 0.02, 0.05, 0.1, 0.25, 0.5, 1
```

The floor is a property of the timing interface rather than of the host — `GetGameTimer`
returns integer milliseconds everywhere — so no per-host configuration or runtime
measurement is needed. Confirmed on Windows and Linux against the same build.

**That default is for code durations, and three metrics do not measure one.** A ladder is only
useful where the data is, so each of these declares its own:

| metric | ladder | why the default is wrong for it |
|---|---|---|
| `fivem_server_tick_interval_seconds` | 0.033 → 5, bracketing 50 ms | a `Wait(0)` thread wakes once per frame and the runtime frames at **20 Hz**, so the floor is ~50 ms, not 1 ms ([notes](platform-notes.md#a-wait0-thread-wakes-at-20-hz-so-the-tick-metric-floors-at-50-ms)) |
| `fivem_player_ping_seconds` | 0.01 → 1 | a network round trip: three default buckets sit below what the source can report |
| `fivem_player_session_duration_seconds` | 60 → 28800 | minutes to hours; every session would land in the overflow slot |

The tick ladder is the one that was wrong first, and it was wrong twice. Under the default
bounds a live server put 1,951 of 2,699 samples under `le="0.05"` and all the rest in the one
bucket above, with the bottom five bounds uncrossable — a percentile of the bucket boundary
rather than of the server. The replacement spread the upper bounds across nameable frame rates
and, because 20 Hz is itself a nameable frame rate, kept `0.05` as a bound. The healthy
distribution went on pressing against a bucket edge, and `histogram_quantile` went on
interpolating downward out of it: **p50 read 45.3 ms for a metric that cannot go below 50.**

That is not a rounding complaint. It is the failure mode this project exists to describe,
sitting in the project's own flagship metric, past a comment that had already diagnosed it and
a note that had explicitly rationalised it as acceptable coarseness. The rule now is that **no
bound sits on the value the mass is expected to occupy**; `0.045` and `0.055` bracket the
baseline, and `0.15`/`0.5` stay exact because alerts should fire at the numbers they state.
Re-measured over 4,897 frames, p50 is 50.0 ms against a 50.3 ms mean.

The regression is pinned in two places — `tests/collectors.test.mjs` asserts no bound falls on
the frame period, and `tickwatch.test.yml` asserts the p50 the rules return. Both were checked
against the old ladder first and both fail on it, which is the only thing that makes them worth
having.

**Table allocation.** Values on this runtime are 32 bytes, twice what stock-Lua reasoning
predicts, and a table never releases array capacity once grown. Registry tables are presized
with `table.create(narray, nhash)` (both arguments required), and memory is budgeted against
the **peak** series count ever observed rather than the live count.

### Collectors

One scheduled pass, not several. Collection is a bounded unit of work on a fixed interval.

Anything that moves at scrape resolution is sampled *below* the default 15 s Prometheus scrape,
deliberately. A collector running at the scrape interval drifts against it — some scrapes see a
repeated sample, others skip one — and collecting faster costs a handful of native calls while
removing the aliasing entirely. Nothing is lost by oversampling: gauges keep the last value and
histogram buckets are cumulative counters.

Resource state is the exception at 30 s. It changes when an operator starts or stops something,
not continuously, so sampling it faster than the scrape would buy nothing for a pass whose cost
grows with the resource count. All intervals are convars, so an operator scraping on a different
schedule can move them.

| Collector | Interval | Measured cost | Notes |
|---|---|---|---|
| Tick interval | every frame | — | Event-loop lag. The one permanent per-frame thread in the project. |
| Players | 10 s | 1.1 µs, 56 B | count, max, and a ping histogram |
| Entities | 10 s | 2.2 µs, 456 B | all three enumerators in **one** pass — the ~1 µs fixed term is per call |
| Resources | 30 s | 67.9 µs, 0 B | state by name, at 100 resources |
| Exporter's own | render interval | 0.5 µs, 0 B | uptime and own heap |
| Server info | once at start | — | version and gamename, the latter from `/info.json` |

Costs are on an idle server, so the players and entities figures are floors — both grow with
population, and the entity term is the one that grows fastest. The resource pass is the only
one whose cost is set by something the operator controls; it extrapolates to ~0.34 ms on a
500-resource server, still under what the timing source can resolve.
([notes](platform-notes.md#what-a-collector-pass-costs))

**The tick collector is the project's one deliberate contradiction** — a per-frame thread
inside a design that forbids per-frame work everywhere else. It is owned rather than hidden:
`tickwatch_collector_overhead_seconds` measures its cost and the README publishes it.

Boolean-shaped natives are normalised at the call site. `DoesEntityExist` returns `1` or `0`,
and `0` is truthy in Lua, so `if DoesEntityExist(h) then` is always taken and guards nothing.
The failure is silent — the check does not error, it stops being a check.

### HTTP endpoint and serving model

`SetHttpHandler` serves under `/tickwatch/` on the game port.

| Route | Auth | Behaviour |
|---|---|---|
| `GET /metrics` | bearer token | exposition text |
| `GET /health` | none | `200 ok` |
| anything else | — | `404`; non-GET on `/metrics` is `405`; bad token is `401` |

Two things about a request on this runtime that a handler has to be written around, both
measured. **Header keys arrive verbatim** — `authorization`, `Authorization` and
`AUTHORIZATION` all reach the handler exactly as sent — so the auth header is found by a
case-insensitive scan rather than by indexing, or a correctly configured scrape gets a 401
depending on which client sent it. And **`req.path` carries the query string**, so routes match
on the path with it stripped.
([notes](platform-notes.md#request-header-keys-arrive-verbatim-with-no-normalisation))

Measured end to end against a running server, 113 series and a 9,630-byte payload: 20
sequential scrapes took **1.32–1.58 ms** each, and 8 concurrent ones **1.32–1.89 ms**. The
comparison is the 200 ms handler in the same notes, where four concurrent requests took 836 ms
and the server stopped ticking.

**The handler never renders.** Handlers run on the main thread and are serialized — four
concurrent requests against a 200 ms handler took 836 ms — so any work inside one is a server
stall at a rate chosen by whoever is scraping. Instead:

1. Compare the cached payload against a freshness threshold.
2. If current, send it immediately.
3. If stale, **defer the response** and let the next scheduled render complete it.

Deferred completion is confirmed working, and `req.setCancelHandler` makes client disconnects
observable so a response is never written to a socket that has gone away. Pending responses
are **bounded with an explicit drop policy**: when the queue is full the *oldest* waiting
response is answered `503` and removed. The oldest has waited longest and is nearest its own
client's timeout, so the responses kept are the ones most likely to still have somebody
listening. Every drop increments `tickwatch_scrapes_total{result="dropped"}` — a loss the
exporter causes has to be visible in the exporter's own output.

**Deferral is the stalled-server path, not the normal one.** The configuration holds the
freshness threshold at or above twice the render interval, so a cached payload can only exceed
it when the render loop is late by more than a whole interval. On a healthy server every
scrape is served from cache and the queue stays empty.

Cache age is exposed so staleness is visible rather than silent. It is written when a scrape is
served rather than when a payload is rendered — at render time it is zero by construction — so
the value in any payload describes the previous scrape. A payload cannot contain a measurement
of its own age, and the same is true of the render duration beside it.

> `res.send`, `res.write` and `res.writeHead` report a `type()` of `table`, not `function` —
> they are callable tables. A defensive `type(res.send) == 'function'` check concludes the
> method is missing when it is present.

### Startup sequence

Serving does not begin until these complete, in order:

1. Read and validate configuration from convars, using the typed accessors
   (`GetConvarInt` / `GetConvarBool` / `GetConvarFloat`) rather than parsing strings.
2. Refuse to start if the auth token is unset.
3. Fetch the server's own `/info.json` **once**. It serves two purposes: it supplies
   `gamename`, which `GetConvar` returns empty for on this build, and it is where a token set
   with `sets` would be publicly visible. If the token appears there, refuse to serve.

   Retried five times at 2 s before it is believed. **If it still cannot be read, refuse.**
   That has a cost — an operator whose own endpoint is briefly unreachable at boot gets no
   exporter — and it is the right way round anyway: a security check that fails open is not a
   check.
4. Register metrics and start collectors.

### Public API

```lua
exports['tickwatch']:Register({ name, type, help, labels, buckets })
exports['tickwatch']:IsRegistered(name)
exports['tickwatch']:Inc(name, labels, value)
exports['tickwatch']:Set(name, labels, value)
exports['tickwatch']:Observe(name, labels, seconds)
exports['tickwatch']:ObserveSince(name, labels, gameTimerReading)
exports['tickwatch']:Event(name, seconds)
exports['tickwatch']:Query(op, status, seconds)
```

Unregistered names are rejected, never silently created — a typo must fail rather than create
a near-duplicate series that is never graphed and consumes a slot under the cap.

**And one thing that is deliberately not an export.** `shared/timed.lua` wraps a function so
every call to it is observed, and it is loaded into the *calling* resource through
`server_scripts { '@tickwatch/shared/timed.lua' }` rather than reached across the boundary.

It exists because hand-written timing is wrong by default: every early return and every error
between the clock read and the `ObserveSince` skips the observation, and the error path is
usually the slow path. A histogram that drops its slow cases reports a healthy p99 for a broken
system, which is the exact failure this project is about.

It is not an export because the boundary measurements rule it out. A crossing costs ~8 µs and
1,651 B in the caller's heap; a function returned across it arrives as a callable-table proxy
costing 6.3 µs per call; and **errors do not cross at all**, so an exported wrapper could not
re-raise the caller's exception and would swallow it instead. Roughly 14 µs of overhead per call
and broken error propagation, against a local `pcall` that costs nothing extra and crosses the
boundary exactly once per observation — the same as writing the timing by hand, which is the
version it replaces. This is the third API decision the export-boundary measurement has made,
after the removal of `StartTimer`/`StopTimer` and the choice to count rejected writes rather
than raise on them.

**A rejected write returns `false`; it does not raise.** An export call runs inside somebody
else's function, on the main thread, in production. A tool that can take down the resource it
observes is worse than one whose graph stays flat, so a refusal is made loud in the two places
that cannot hurt the caller: the console, once per distinct mistake, and
`tickwatch_export_errors_total`. `Register` is the exception and raises — a declaration is a
startup-time statement made once by a developer who is looking at it.

**There is no `StartTimer`, and this spec called for one twice.** Both versions were removed by
measurement.

A closure returned across the export boundary *does* survive — the runtime proxies it by
reference, and it arrives as a callable table, the same shape `res.send` has. Calling that
proxy costs **6.3 µs** against single-digit nanoseconds for a local closure. A stopwatch whose
stop button is a round trip is not a stopwatch.

Returning a plain number instead fixed that and left something worse: an export call costs
~8 µs, and `StartTimer` would have spent it calling `GetGameTimer()`, which the caller can do
in its own state for **0.10 µs**. So the clock reading is the caller's, and `ObserveSince` does
the part that is worth a boundary crossing — converting to seconds, which is the unit mistake
that otherwise produces a histogram wrong by a factor of a thousand and entirely plausible.

**What instrumentation costs, measured across the boundary from another resource:**

| | |
|---|---|
| any export call | **~8 µs**, differences between call shapes inside the run-to-run spread |
| allocation per labelled call | **1,651 B**, in the *caller's* heap |
| the same write inside tickwatch | ~0.26 µs |
| `GetGameTimer()` locally, for comparison | 0.10 µs |

Against a 500 µs database query that is under 2%, so timing queries and event handlers is
affordable. It is forty times what the write costs internally, though, and the allocation lands
in the caller's own heap — so anything running thousands of times a second should be counted,
not timed. `Event` and `Query` exist for exactly this reason: each does two registry writes
behind one boundary crossing.
([notes](platform-notes.md#what-an-export-call-costs))

---

## Metric catalog

Namespaced `fivem_` for the server being measured, `tickwatch_` for the exporter itself. Base
units only — seconds and bytes. Counters end `_total`.

### The server

| Metric | Type | Labels | Source |
|---|---|---|---|
| `fivem_server_up` | gauge | — | constant 1 |
| `fivem_server_uptime_seconds` | gauge | — | `GetGameTimer()`, which is process uptime |
| `fivem_server_info` | gauge | `version`, `gamename` | value 1, info pattern |
| `fivem_server_tick_interval_seconds` | histogram | — | event-loop lag |
| `fivem_players_connected` | gauge | — | player count |
| `fivem_players_max` | gauge | — | `sv_maxclients` |
| `fivem_player_ping_seconds` | histogram | — | sampled in the players pass |
| `fivem_player_connections_total` | counter | `result` | see below |
| `fivem_player_drops_total` | counter | `reason` | normalised enum |
| `fivem_player_session_duration_seconds` | histogram | — | on drop |
| `fivem_entities` | gauge | `type` | `ped` / `vehicle` / `object` |
| `fivem_resource_up` | gauge | `resource` | `GetResourceState` |
| `fivem_events_total` | counter | `event` | push API |
| `fivem_event_duration_seconds` | histogram | `event` | push API |
| `fivem_db_queries_total` | counter | `op`, `status` | push API |
| `fivem_db_query_duration_seconds` | histogram | `op` | push API |

### The exporter

Kept visually separate because it describes the tool, not the server.

| Metric | Type | Labels | Source |
|---|---|---|---|
| `tickwatch_render_duration_seconds` | histogram | — | exposition render wall-time |
| `tickwatch_cache_age_seconds` | gauge | — | staleness of the payload the previous scrape got |
| `tickwatch_scrapes_total` | counter | `result` | `served` / `deferred` / `dropped` / `unauthorized` |
| `tickwatch_series_dropped_total` | counter | `metric` | cardinality guard |
| `tickwatch_lua_memory_bytes` | gauge | — | `collectgarbage('count') * 1024` |
| `tickwatch_collector_overhead_seconds` | histogram | — | cost of the tick collector |

`tickwatch_render_duration_seconds` is a histogram rather than a gauge because a gauge of a
sub-millisecond quantity read through a 1 ms clock reports 0 almost always and 1 ms
occasionally, which is noise. It dithers the same way the overhead metric below does, and
unlike that one its buckets earn their place on a large registry: render cost grows with the
series count and crosses the clock floor well before the cap.

`tickwatch_collector_overhead_seconds` is the one metric in the catalog whose **buckets carry
nothing**, and the help text says so. It measures the tick collector's own work with a clock
that resolves to 1 ms against a quantity around a microsecond, so every individual sample is 0
and occasionally 1 ms — whenever the work happens to straddle a tick boundary. That makes the
distribution meaningless and the mean correct: a boundary is crossed in proportion to the time
taken, so `_sum / _count` converges on the real figure over a long window. It is read as a
ratio, never per sample.

The cost is also sampled rather than measured every frame — one frame in 32. Measuring each
one would double the work being measured, and the quantity is stationary, so a subsample
estimates it just as well.

`tickwatch_lua_memory_bytes` is **this resource's heap**, not the server's. No interface
exposes another resource's memory. It is published raw rather than smoothed: a forced
collection at scrape time would be a stall the exporter itself causes, and the sawtooth
carries information — the trough is live-set size, so a rising trough is a leak while a rising
peak alone is not.

### Connection counting

`playerConnecting` fires *before* deferrals resolve, so counting a join there is wrong — a
player can be deferred then rejected, or drop during loading.

- `playerConnecting` → `result="attempted"` (the denominator)
- `playerJoining` → `result="joined"`

Join success rate is `joined / attempted`, and rejections are the difference.

**There is deliberately no `rejected` series.** A deferral is owned by the resource that
registered it, and the only way to observe its rejection from outside would be to replace a
method on the `deferrals` object that other resources are also holding — which changes whether
players can join somebody's server if the handler ordering is not what was assumed. An
exporter is not entitled to that risk. The number is recoverable by subtraction, and the
exporter does not claim to have watched the event happen.

### Drop reasons

`DropPlayer(src, reason)` takes free text, so reasons are unbounded and cannot be a label raw.
Normalised to a fixed enum before use:

`timeout` | `kicked` | `banned` | `quit` | `crashed` | `server_shutdown` | `other`

Anything unmatched becomes `other`. The raw string is never passed through.

### Deliberately excluded

**`GetPlayerPeerStatistics`.** Measured; the enum has eight members and index 3 is RTT — but
it equals `GetPlayerPing` exactly at every sample, so it adds nothing. Its only new
information is packet loss, whose scale could not be verified: every attempt to establish a
dose-response against a known impairment dropped the client. The counters are also lagged
smoothed estimates, roughly one 5-second throttle interval behind. Revisit when there is a rig
that can impair a link without ending the session.

---

## Cardinality

Series count is bounded by construction.

- Never labelled by player id, citizen id, license, IP address, or any other unbounded string.
- Free text is normalised to a fixed enum before becoming a label.
- Each metric caps unique series. Past the cap the write is dropped and
  `tickwatch_series_dropped_total` increments, so the loss is visible rather than silent.

The cap default is set from a **measured** per-series byte cost rather than a round number.

**The cap is order-dependent and is a memory guard, not a sampling strategy.** The first N
label sets observed win, and which ones those are can differ between restarts. A capped metric
shows the first N series seen, not a representative sample. Documented in the README so a
partial series set is never read as complete.

---

## Security model

The endpoint sits on the public game port. That is the starting condition, not a choice.

- **Bearer token auth**, token from a convar. Refuse to serve if unset.
- **Set it with `set`.** `sets` publishes it in the unauthenticated `/info.json`; `setr`
  broadcasts it to every connecting client.
- **Only one of those two mistakes is detectable.** A `sets` token is caught by the startup
  `/info.json` fetch. A `setr` token is undetectable from a server script — no native under
  sixteen candidate names exposes the flag, and the command registry entries are identical
  across all three verbs. The README says this plainly rather than implying the check is
  complete.
- **Plaintext HTTP.** Put it behind a reverse proxy or firewall rule for anything real.

Worth stating as context rather than excuse: a stock server of this build already publishes
its Cfx license token and its engine tick timings unauthenticated on the same port. A metrics
endpoint is not the first thing that port exposes.

---

## Collector sidecar

A separate Node/TypeScript service. It collects what Lua cannot see.

- Scrapes N game servers with auth, timeouts and retries, and re-exposes a unified endpoint
  with a `server` label — one Prometheus target for a whole fleet.
- **Host and process metrics** per FXServer PID: CPU%, RSS, thread count, file descriptors.
- **MySQL metrics** over its own connection: pool saturation, `SHOW GLOBAL STATUS`, slow
  queries, table sizes.
- Optionally scrapes each server's `/perf/`, respecting `rateLimiter_http_perf_rate`, so the
  engine's own tick histogram sits beside the exporter's proxy on one dashboard.
- Per-target `up`, `scrape_duration_seconds`, `scrape_error_total`.

Stack: TypeScript, `prom-client`, `mysql2`, `pidusage`, `zod` for config validated at boot,
`vitest`, multi-stage Dockerfile. Configuration from environment, failing fast with a readable
error.

---

## Dashboards

Provisioned as JSON, never clicked in by hand.

1. **Server health** — tick interval p50/p95/p99, players, uptime, resource states.
2. **Performance** — event-loop lag heatmap, DB latency, entity counts, memory.
3. **Player flow** — connections, join success rate, drops by reason, session duration, ping.

Recording rules for the percentiles, and at least three alert rules: sustained high tick-lag
p99, high DB p95, and a player drop-rate spike. `docker compose up` must produce working
dashboards with no manual setup.

---

## Load harness

A dev-only resource generating synthetic in-server load: entity spawn/despawn, N events/sec,
N queries/sec, all configurable. Its purpose is to prove the metrics respond under stress and
to capture dashboard screenshots at load.

`CreateVehicleServerSetter` and `CreatePed` work with no client connected; `CreateVehicle` and
`CreateObject` do not. Distinguishing "no handle", "handle but nothing created" and "created
then reaped" needs two existence checks per attempt.

**This is synthetic in-server load, not N real connected clients**, and the README says so.
An inflated claim is worse than a modest true one.

---

## Testing

`tests/` runs the real `server/*.lua` under a wasmoon VM in Node.

Required cases:

- Exposition output parses and matches golden files
- **Histogram buckets are cumulative** — bounds monotonically non-decreasing, `le="+Inf"`
  equals `_count`
- Label escaping for `\`, `"`, newline
- Label-set key caching — the same labels in a different order produce one series, not two
- Cardinality cap trips at the limit and increments the drop counter
- Drop-reason normalisation maps unknown text to `other`
- `Register` / `Inc` / `Observe` reject unregistered names

Harness notes: stubs return `undefined`, never `null`, which crashes crossing into Lua; the
loader rewrites `?.` before loading; test files are run directly, because `node --test <dir>`
glob-expands bracket paths and resolves wrong.

### Benchmarking rule

Two acceptance criteria are comparisons — request-path time at 500 series, and the tick
distribution with the exporter running versus without. **Session-to-session variance on this
platform is ~15%, larger than either effect.** Both halves of both comparisons must come from
one server session, as a median of N trials with the spread reported. This rule already
invalidated a finding once.

---

## Milestones

| | Deliverable | Done when |
|---|---|---|
| **v0.1.0** | Lua exporter | Valid exposition; passes `promtool check metrics`; Prometheus scrapes with zero parse errors; `histogram_quantile()` returns plausible percentiles; request path under 2 ms at 500 series; tick distribution statistically unchanged; test suite green — **all met, see below** |
| **v0.2.0** | Dashboards | `docker compose up` yields working dashboards against a live server |
| **v0.3.0** | Collector | Fleet scraping, host and MySQL metrics, alerting |
| **v0.4.0** | Load harness | Benchmark table and screenshots under load in the README |

Order is deliberate: dashboards come before the collector, because dashboards prove the
metrics are useful while the collector only makes them scale. If time runs short, the
collector is what gets cut — the exporter and dashboards are already a complete piece.

### v0.1.0 acceptance, measured

Against the qb framework test server, FXServer v1.0.0.32561, Prometheus and promtool 3.13.2.

| criterion | result |
|---|---|
| valid exposition | parses; `+Inf == _count` re-checked on the wire by `probe collect` |
| `promtool check metrics` | **exit 0, no output**, at both 113 and 563 series |
| Prometheus scrapes, zero parse errors | target `up`, `lastError` empty, 601 samples per scrape, 1.01 ms scrape duration |
| `histogram_quantile()` plausible | tick p50 **50.0 ms** against a 50.3 ms mean and a 50 ms floor, over 4,897 frames |
| request path under 2 ms at 500 series | 563 series, 31.6 KB payload: 20 sequential scrapes **1.28–2.02 ms**, median 1.40; 8 concurrent 1.22–1.70 ms |
| tick distribution unchanged | **−0.01 ± 0.04 ms**, or −0.02% of a frame. Control/treatment/control below |
| test suite green | 176 tests, 0 failures |

**The request-path criterion is met with one qualification worth stating**: 19 of 20 sequential
scrapes came in under 2 ms and one landed at 2.02 ms. The number to hold onto is the median of
1.40 ms, and that the payload nearly tripling from 9.6 KB to 31.6 KB barely moved it — the
handler sends a string somebody else built, so the cost is connection setup rather than
content.

**The tick comparison, in one session, control–treatment–control:**

| phase | mean | n | tail |
|---|---|---|---|
| control A, exporter stopped | 50.30 ± 0.03 ms | 597 | p99 52, max 57 |
| treatment, exporter running | 50.29 ± 0.02 ms | 597 | p99 52, max 52 |
| control B, exporter stopped | 50.31 ± 0.03 ms | 597 | p99 52, max 52 |

Measured from the probe's own `Wait(0)` thread, which is present in all three phases so its own
cost cancels. The second control is what makes this readable: a server drifts over minutes, and
a two-phase test cannot separate drift from effect. Here the two controls agree to 0.00 ms
while the treatment sits 0.01 ms below both — an order of magnitude inside the uncertainty.
Reproduce with `probe tickimpact`.

---

## Open questions

- **Validate the lag proxy against `/perf/`** — *half answered.* `/perf/` already serves
  Prometheus text exposition, so it needs no sidecar and no JSON datasource: it is a second
  scrape job, now in `prometheus.yml`, with `tickTime` renamed on the way in because it is
  camelCase and unsuffixed. Measured at 30 back-to-back requests all returning 200, so the
  rate limiter has ample headroom for one scrape per 15 s.

  What is established: the two measure **different quantities** — work inside a frame
  (0.176 ms mean) versus the gap between frames (50.26 ms) — and the proxy catches a class of
  stall the reference is blind to. Ten 200 ms handler blocks produced ten observations in the
  proxy's `(0.15, 0.25]` bucket and *zero* anywhere above 10 ms in `tickTime`, with the engine
  verified live across the same window ([notes](platform-notes.md#both-instruments-read-at-once)).

  What is **not** established, and is the half that remains: that the two **track each other
  on stalls the reference can see**. That needs a stall originating inside a tick rather than
  inside a handler, sustained long enough to move both histograms, and it needs the load
  harness. Until then the honest claim is "observes a superset", not "agrees with".
- **Does the `1`/`0` boolean return generalise** to every `BOOL`-returning server native, or
  is it specific to `DoesEntityExist`? A convention either way; it does not block.
- **Windows-only findings.** Only timing has been re-measured on Linux. Memory scope
  reproduced there incidentally but is not yet claimed in the notes.
