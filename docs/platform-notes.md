# Platform notes

Observed behaviour of the FXServer runtime, and the design decisions that follow from it.

Several of the platform's characteristics are undocumented, and at least one contradicts
the reference documentation for the language it exposes. Each note below records what was
measured, how, and what changed in the exporter as a result. Findings are build-specific;
the build they were taken against is recorded below.

**Every table here can be re-run.** The measurement apparatus is checked in at
[`tools/probe`](../tools/probe), along with which probe reproduces which section and the
caveats that apply to reading its output — chief among them that figures from two different
server sessions are not comparable, which is a larger effect than most of what is measured
below.

## Environment

Most findings below were taken on Windows. Where a result could plausibly be a property
of the host rather than of FXServer, it was re-measured on Linux against **the same build
number**, so that a difference between the two columns is the platform and not a version
change.

| | Windows | Linux |
|---|---|---|
| FXServer build | `FXServer-master SERVER v1.0.0.32561 win32` | `FXServer-master v1.0.0.32561 linux` |
| Lua runtime | LuaGLM 5.4 (`_VERSION`) | LuaGLM 5.4 |
| C library | MSVC CRT | musl (`libc.musl-x86_64.so.1`) |
| Game build | 2944 | — |
| OneSync | enabled | off |
| Host OS | Windows 11 (build 26200) | kernel 6.18.33.1, clocksource `tsc` |
| Server | QBCore, 8 slots, MariaDB via oxmysql | bare server, probe resource only |
| Measured | 2026-08-14 | 2026-08-14 |

The Linux column is the official `build_proot_linux` artifact of build 32561 running in a
container on a WSL2 kernel. That is a real kernel rather than an emulation layer, so the
`clock_gettime` path the measurements depend on is genuine. Only the timing section has
been re-measured there so far; everything else is Windows-only and says so.

---

## Timing

Three clock sources are available to a server-side script:

| source | type | unit | epoch |
|---|---|---|---|
| `GetGameTimer()` | integer | milliseconds | server start |
| `os.clock()` | float | seconds | process start |
| `os.time()` | integer | seconds | unix |

`os.time()` has one-second resolution and cannot express any duration this exporter
measures. It is unused.

### `os.clock()` is stock Lua, so it measures something different on each platform

Standard C defines `clock()` as processor time. Microsoft's C runtime does not follow that
— it returns wall-clock time elapsed since process start. Standard Lua's `os.clock()` is a
thin wrapper over `clock()`, and **FXServer does not replace it**:

- `libcitizen-scripting-lua.so` imports `clock` as an undefined symbol and defines no
  replacement of its own
- the `os` library registration table inside that binary is stock loslib, unmodified —
  `clock, date, difftime, exit, getenv, remove, rename, setlocale, time, tmpname`
- nothing under `citizen/` assigns to the `os` table from Lua

So the meaning of `os.clock()` is inherited from the platform C library, and the same call
is a different clock on each host:

| | Windows | Linux |
|---|---|---|
| what it reports | wall-clock since process start | **process CPU time** |
| resolution | 1 ms | 1 µs |
| cost per call | 55 ns | **1,444 ns** |

On Windows, over a window in which the process consumed 267.9 s of CPU against 5072.2 s of
wall time, `os.clock()` read 5006.686 — tracking wall, not CPU. Had it been CPU time it
would have reported roughly 268. `GetGameTimer() / 1000` read 5005.687 at the same moment,
a constant ~1 s offset consistent with the gap between process start and Lua state
initialisation.

On Linux the same question needs a third observer. C `clock()` is process-*wide*, and
FXServer's other engine threads keep consuming CPU while a script thread waits, so a CPU
clock still advances across an idle window. Both answers predict some number between zero
and the interval, and "is it near zero" has no principled threshold. Two references bracket
the same 5-second idle wait instead:

| observer | reading |
|---|---|
| `GetGameTimer` — known wall time | 5.002 s |
| `os.clock` | 0.114 s |
| `/proc/<pid>/stat` utime+stime — the process's own CPU accounting | 0.110 s |

`os.clock` tracks the CPU counter to within 4% and is wrong about wall time by a factor of
44. The server was genuinely 2.2% busy during the wait, which is exactly why the weaker
test would not have settled it.

**Why this matters.** A CPU clock cannot observe time spent *waiting*. A database query
blocked on a socket consumes almost no CPU, so on a Linux host `os.clock()` reports
near-zero latency for precisely the operations this exporter exists to measure. Nearly
every metric of interest here — query latency, HTTP round-trips, event handler duration —
is dominated by waiting rather than computation.

**Consequence.** `os.clock()` is not used. It is not a portable clock, and on Linux it is
also 16× more expensive than the alternative, because `CLOCK_PROCESS_CPUTIME_ID` is a real
system call rather than a vDSO read.

The reverse of this finding is worth stating too: on Linux `os.clock()` is a genuine
process-CPU-time source, which is what conventional exporters publish as
`process_cpu_seconds_total`. It is not that on Windows, so that metric is not implementable
portably from Lua either.

### `GetGameTimer()` resolves to 1 ms, on both platforms

Resolution — the smallest interval a clock can express — was measured by reading the clock
in a tight loop, discarding zero deltas, and taking the minimum of the remainder. The count
of non-zero deltas cross-checks the result: if the minimum really is the tick size, the
number of ticks observed must equal the elapsed time divided by it.

| host | min non-zero delta | ticks observed | elapsed | cost per call |
|---|---|---|---|---|
| Windows | 0.001 s | 229 | 0.229 s | 115 ns |
| Linux, trial 1 | 0.001 s | 196 | 0.196 s | 98 ns |
| Linux, trial 2 | 0.001 s | 180 | 0.180 s | 90 ns |
| Linux, trial 3 | 0.001 s | 174 | 0.174 s | 87 ns |

Every cross-check holds exactly — 229 ticks across 229 ms, 196 across 196, 180 across 180,
174 across 174. One tick per millisecond, none missed or double-counted. The three Linux
trials ran back to back inside one server session, because figures from two sessions are not
comparable; the per-call costs across the two *platforms* are for that reason indicative
only, while the resolution is an exact quantization boundary rather than an average.

The Windows figure is notably *not* that platform's default timer granularity of ~15.6 ms,
so the process runs with a raised timer resolution — which left open whether the 1 ms floor
was FXServer truncating in its own code or an artifact of a Windows timer API. The Linux run
settles it, and the host's clocksource is what makes it a control rather than a coincidence:
it is `tsc`, so nanosecond-class resolution was available to the operating system, and
FXServer quantized to exactly 1 ms anyway.

The simpler statement is stronger still. `GetGameTimer()` returns integer milliseconds, so
the 1 ms floor is a property of the interface rather than of any host. The measurements add
that it is not *coarser* than its own unit on either platform, which was the open question.

`GetGameTimer()` is **not** frame-latched: it advances every millisecond independently of
the server tick, rather than updating once per frame.

### `GetGameTimer()` is the timing source used

It is the only one of the three that measures elapsed time everywhere the exporter might
run. `os.time()` cannot express the durations involved, and `os.clock()` is a CPU clock on
Linux, as recorded above.

**Per-operation instrumentation is affordable.** Timing an operation costs two clock reads,
roughly 180–230 ns depending on host. Against a 500 µs database query that is under 0.05%
overhead, so the exported timer API can wrap individual queries and event handlers without
measurably perturbing them.

**Histogram buckets are floored at 1 ms, on every platform.** Bucket bounds of 1, 2 and 5 ms
correspond to one, two and five ticks and are all resolvable. Nothing below 1 ms is
meaningful and no bucket is defined there. Because that floor follows from the timing source
being an integer-millisecond interface rather than from a property of the host, bucket bounds
are fixed constants and need no per-host configuration or runtime measurement.

**Durations under 1 ms are indistinguishable from one another.** A 0.1 ms and a 0.9 ms
operation both record as 0 or 1 ms, depending only on where the operation fell relative to a
tick boundary. Quantization cancels in the mean, so `_sum / _count` remains approximately
correct for sub-millisecond work, but low-end percentiles derived from it do not. Fast local
queries should be read as an average, not a distribution.

**The clock a script gets is not the same on every host, even where the resolution is.**
The 1 ms floor holds on both platforms measured, but the section above shows `os.clock()`
changing meaning, resolution and cost between them while `GetGameTimer()` did not. A timing
claim on this platform is only as portable as the source it was taken from, and the two
available sources differ on exactly that point.

### A `Wait(0)` thread wakes at 20 Hz, so the tick metric floors at 50 ms

The 1 ms floor above applies to *durations* — a query, an event handler, a render. It does not
apply to the interval between frames, which has a much higher floor, and the difference was
not obvious until the exporter ran.

A thread that calls `Wait(0)` resumes once per server frame, and this runtime frames at 20 Hz:
2,299 successive intervals summing to 115.498 s, a mean of **50.2 ms**. A second run agreed to
three digits — 999 intervals, 50.181 s, 50.2 ms.

The distribution is tight rather than merely centred there. Of 999 samples, 725 fell at or
below 50 ms and the remaining 274 at or below 75 ms, with nothing above on an idle server.

**Consequence, and it corrected a design decision.** `fivem_server_tick_interval_seconds` was
originally given the same bucket ladder as every other histogram — `0.001` through `1`,
floored at the clock resolution. Against a 50 ms baseline that ladder can never cross its
bottom five bounds, and it leaves a single bucket spanning everything between a healthy frame
and a stall: the first live run put 1,951 of 2,699 samples under `le="0.05"` and all 748
others in the one bucket above it, which makes `histogram_quantile` a percentile of the bucket
boundary rather than of the server.

The first replacement ladder was placed on frame rates rather than powers of ten —
`0.02, 0.033, 0.05, 0.075, 0.1, 0.15, 0.25, 0.5, 1, 2.5, 5`, for 50 Hz, 30 Hz, 20 Hz, 13 Hz,
10 Hz and then the stall scale. It fixed the single-bucket problem and reproduced the other
one, because **20 Hz is both a nameable frame rate and the baseline**, so `0.05` stayed a
bound with the entire healthy distribution pressed against it.

This paragraph previously described that as "percentiles *inside* the baseline are coarse on
purpose: this metric exists to measure the tail." That was a rationalisation, and measuring it
showed the difference. `histogram_quantile` interpolates linearly inside whichever bucket the
target observation lands in; when the median observation sits in the bucket *below* the bound,
the answer comes back below the bound. Live, p50 read **45.3 ms for a metric whose floor is
one frame period, 50 ms**. Not coarse — outside the range the server can physically produce.

The rule the ladder follows now is that **no bound sits on the value the mass is expected to
occupy**:

`0.033, 0.045, 0.055, 0.07, 0.09, 0.12, 0.15, 0.25, 0.5, 1, 2.5, 5`

`0.045` and `0.055` bracket the 20 Hz baseline instead of landing on it. `0.15` and `0.5` are
kept exactly because they are alerting thresholds and an alert should fire at the number it
states. `0.033` remains as a single sentinel: if it ever fills, the 20 Hz assumption underneath
all of this has changed.

Re-measured on the same idle server, 4,897 frames: 99.7% of observations land inside the
45–55 ms bucket, and Prometheus returns **p50 50.0 ms against a mean of 50.3 ms** — 0.3 ms
apart, and above the floor rather than 4.7 ms beneath it. The same figure computed by hand
from the raw cumulative buckets gives 50.009 ms, agreeing with Prometheus to 0.03 ms.

One caveat, stated because the numbers invite the wrong reading: p99 also moved, from 74.2 ms
to 54.9 ms. Part of that is resolution — the old ladder lumped a 51 ms frame and a 74 ms frame
into one bucket, so the tail interpolated upward through nominal mass — and part is that this
run's server was genuinely quieter, with only 11 of 4,897 frames above 55 ms. **Those two
causes are not separated here**, because the two measurements come from different sessions.
The p50 claim does not depend on it: a median below the metric's own floor is wrong
arithmetically, not statistically.

It also puts the collector's cost in proportion. 20 observations a second, at roughly a
microsecond each, is 0.002% of one core — not the 200 Hz the phrase "per-frame thread"
suggests.

**The thread does not miss frames.** Measured directly over a 30 s window on the exporter's own
counters: 600 observations, 19.91 per second, and the intervals summed to 30.143 s against
30.143 s of elapsed uptime — **100.0% of the window accounted for**. So `Wait(0)` resumes on
every frame rather than on some of them, which is what makes the interval a measure of
scheduler delay rather than of how often this particular thread happened to be picked.

That check exists because a Prometheus query said otherwise. `rate(..._count[5m])` returned
13.7 frames per second against a mean interval implying 19.9, which reads exactly like a thread
missing a third of its wakeups. It was an artefact: the counter had not existed for the whole
five-minute window, so the rate was averaged over more time than the series covers. Over
`[1m]`, a window the series fully spans, the same query returns **20.0** and
`rate(..._sum[1m])` returns 1.005 seconds of tick per second. **A rate window longer than the
age of the series under-reports, silently and plausibly.**

---

## Tick timing and resource attribution

### No server-side interface reports per-resource tick time

Established by enumeration rather than by trial:

- The server native table (`citizen/scripting/v8/natives_server.d.ts`) contains no native
  returning per-resource timing. The resource natives — `GetResourceState`,
  `GetResourceMetadata`, `GetResourcePath`, `GetResourceCommands`, `GetNumResources`,
  `GetResourceByFindIndex` — expose state and metadata only. `ScheduleResourceTick`
  schedules a tick; it does not report on one.
- All 410 registered console commands were enumerated via `GetRegisteredCommands()`. No
  `resmon`, no `profiler`, nothing reporting resource cost. Trying a few likely command
  names and reading "invalid command" would not have been evidence; enumerating the set is.

Profiler natives do exist — `ProfilerEnterScope`, `ProfilerExitScope`,
`ProfilerIsRecording` — but they are write-only. They emit scopes into a profiler
recording, and no counterpart native reads results back. That is a debugging facility, not
a metrics source: profiling must be explicitly started, and continuous profiling is far too
expensive to leave running.

**Checked against the complete shipped native list, not by sampling names.** The artifacts
ship both `citizen/scripting/v8/natives_server.d.ts` and
`citizen/scripting/lua/natives_server.lua`; extracting names from each independently gives 393
and 366 declarations. Filtering both for `cpu|profil|monitor|usage|perf|msec|elapsed|tick|time`
returns only `GetGameTimer` (process uptime), `GetPlayerTimeOnline` and
`GetPlayerTimeInPursuit` (gameplay, not performance), `ScheduleResourceTick` (schedules a tick,
does not measure one), and the three write-only profiler natives above. Every `Resource` native
is KVP storage, metadata, enumeration, state, lifecycle or file access. There is no
`GetResourceCpuTime` and nothing equivalent.

### `resmon` is a client-side measurement of a different process

The client has a Resource Monitor overlay — `resmon 1` in the F8 console — that shows exactly
the per-resource CPU table this section says is unavailable. It is not a counter-example, for
two reasons.

It measures **client scripts inside the player's game process**. A resource's server half
contributes nothing to that table, so a server stalling for 200 ms appears nowhere in it. And
it is **not collectable even in principle**: it is an overlay drawn in the game client, so
gathering it would mean every player reporting their own, describing their machines rather than
the server.

Client performance is a real thing to measure and this is the tool for it. It is a different
measurement of a different process, and it does not close the attribution gap on the server.

**Consequence.** Per-resource CPU attribution is not implementable on this platform. This
exporter measures **event-loop lag** — scheduler delay observed by its own thread — as a
proxy for overall server load. It reports that the server stalled; it cannot report which
resource caused the stall. That limitation is inherent to the platform, not to this
implementation, and is stated in the README.

### The server exposes its own Prometheus endpoint

FXServer serves Prometheus text exposition at `/perf/` on the game port:

```
# HELP tickTime Time spent on server ticks
# TYPE tickTime histogram
tickTime_bucket{name="svMain",le="0.001"} 159532
```

| property | observed |
|---|---|
| Content | a single `tickTime` histogram, labelled by engine thread |
| Series | `svMain`, `svSync`, `svNetwork` — engine threads, **not** resources |
| Buckets | 1, 2, 4, 6, 8, 10, 15, 20, 30, 50, 70, 100, 150, 250 ms, `+Inf` |
| Authentication | none |
| Rate limiting | governed by `rateLimiter_http_perf_rate` / `_burst` |
| Routing | prefix handler — any subpath returns the identical payload |

**`tickTime{name="svMain"}` includes resource script execution.** Verified directly:
blocking the main thread from a script for approximately 230 ms twice produced exactly two
observations in the 150–250 ms range of that histogram, against a baseline where 99.8% of
ticks complete under 1 ms.

Its bucket floor of 1 ms independently matches the floor derived from clock resolution
above.

**Consequence.** `/perf/` is treated as a **reference measurement, not a replacement**. The
engine's own tick histogram is ground truth measured from the inside at no cost, so it is
used to validate that this exporter's event-loop-lag proxy tracks reality — a proxy checked
against a reference is a stronger claim than either number alone. That validation holds for
stalls originating on the script thread; it does not cover every stall the server can
suffer, as the HTTP section below records.

It also bounds what this project adds. `/perf/` publishes engine thread tick time and
nothing else: no players, entities, resources, database, events, connection outcomes,
drops, sessions or network quality, no authentication, and no server label for multi-server
deployments. Two smaller points: `tickTime` follows neither Prometheus snake_case naming
nor the base-unit suffix convention despite reporting seconds; and because the endpoint is
unauthenticated on the public game port, every server running this build publishes its tick
timings to anyone who asks.

---

## Memory

### `collectgarbage('count')` reports one resource's heap, not the server's

`collectgarbage('count')` returns the memory tracked by a single `lua_State`. For an
exporter the question is which state that is — its own, or one shared by every Lua resource
on the server. The difference decides whether the resulting metric is a footnote about the
exporter or a genuine measure of server health.

It cannot be answered from inside one resource. Allocating there and watching that
resource's own count rise is equally consistent with both answers. A second resource was
added purely as a control, so that one heap could be grown while both were read:

| | resource A | resource B (control) |
|---|---|---|
| baseline | 230,093 B | 211,330 B |
| after a 1,000,000-element table in A | 33,784,581 B | 211,330 B |
| delta | +33,554,488 B | **0 B** |

Exactly zero, and three controls support it. Dropping the reference returned A to baseline
to the byte, so the rise was the allocation rather than unrelated drift. Ten cross-resource
reads moved either heap by under 300 bytes, so the measurement apparatus is not the signal.
And reading B's heap from inside B agreed with reading it across the resource boundary to
within 9 bytes, so the boundary crossing does not distort the number.

**Consequence.** `fivem_exporter_lua_memory_bytes` is the exporter's own heap, and is named
to say so. No interface exposes another resource's memory, so server-wide Lua memory is not
implementable on this platform — the same boundary that blocks per-resource tick time
above. FXServer gives a resource no observability into any other resource, in either
dimension.

### The gauge is published raw, not smoothed

A Lua heap gauge sawtooths: it climbs as garbage accumulates and drops on each collection.
Forcing a full collection at scrape time would flatten it, and the exporter deliberately
does not.

- A full collection is a stall the exporter itself causes. It would be manufacturing
  exactly the pauses it exists to report.
- Scrapes are pull-based and the caller is not under the exporter's control. Work done per
  scrape is an amplification vector, not a fixed cost.
- The sawtooth carries information that flattening destroys. Peak-to-trough amplitude is
  the allocation rate per collection cycle, and the trough is live-set size. A rising trough
  is a leak; a rising peak alone is not. `min_over_time(...[10m])` reads the trough.

A corollary for anyone reading the raw series: because the scrape interval and the
collection cycle are unrelated, a single sample lands at an arbitrary point on the tooth.
The series is meaningful in aggregate, not point by point.

### The runtime is LuaGLM, and its values are twice the size of stock Lua's

`_VERSION` reports `LuaGLM 5.4`, not `Lua 5.4`. The fork is not cosmetic — it is visible in
the size of every value the language stores.

Measuring that is less direct than it looks, because Lua rounds a table's array capacity up
to a power of two. A 1,000,000-element array costs 33,554,488 bytes, which decomposes as
2^25 plus 56 bytes of table header — but 2^25 is both 2^20 slots of 32 bytes and 2^21 slots
of 16. The two candidates differ by a factor of two in capacity *and* in slot size, so they
cancel in every power-of-two measurement and no amount of allocation separates them.

`table.create(narray, nhash)` is available on this build, with both arguments required. It
presizes to an exact capacity, which removes the rounding and the ambiguity with it:

```
100,000 elements at exact capacity     3,200,056 bytes
                                     = 100,000 x 32  +  56 (table header)
```

**32 bytes per value, against 16 for stock Lua 5.4 on a 64-bit host.** This is consistent
with a value union widened to hold vector and quaternion types inline — a four-component
vector needs 16 bytes by itself — and applies to every value, whether or not a script uses
vectors. The exact field layout is not observable from script; the size is.

Growth follows the documented rehash rule exactly. Each measurement below is a power-of-two
block plus the same 56-byte header, and two different element counts that round to the same
capacity report byte-identical totals:

| elements | measured | decomposes as |
|---|---|---|
| 524,288 | 16,777,272 B | 2^24 + 56 |
| 600,000 | 33,554,488 B | 2^25 + 56 |
| 1,048,576 | 33,554,488 B | 2^25 + 56 |
| 1,048,577 | 67,108,920 B | 2^26 + 56 |

The byte accounting itself was anchored against a long string, whose size is its length
plus a header and is subject to no rounding: 8 MiB requested reported 8,388,976 bytes. The
counter reports real bytes rather than an internal unit.

**Consequence.** Table memory on this platform costs twice what stock-Lua reasoning
predicts, which lands directly on the exporter's series registry — every stored label set
and sample. The cardinality cap is therefore set from a measured per-series byte cost rather
than a round number. It also means the exporter's own memory gauge steps at power-of-two
boundaries rather than climbing smoothly, so a doubling in that series is table growth and
not necessarily a leak.

This is the second finding, after `os.clock()`, where the runtime departs from the language
it presents. Stock Lua documentation is a starting point for this platform, not an
authority on it.

### What one series actually costs

The paragraph above says the cardinality cap should come from a measurement. This is that
measurement, taken against the finished registry rather than against a model of it: the
probe loads `server/registry.lua` out of the tickwatch resource with `LoadResourceFile` and
runs it, so the file measured is the file that ships.

Fixed overhead is cancelled rather than estimated. Each shape is built at 500 and at 2,500
series and the marginal cost is the difference divided by 2,000, so whatever a registry costs
to exist appears in both terms and subtracts out. Median of 5 trials, one session.

| series shape | marginal cost | spread over 5 | 2,500 series |
|---|---|---|---|
| counter, 1 label | 583.5 B | 583.5–583.5 | 1.34 MiB |
| gauge, 1 label | 583.5 B | 575.4–583.5 | 1.34 MiB |
| gauge, 2 labels | 861.5 B | 861.5–861.5 | 2.01 MiB |
| histogram, 1 label, 10 buckets | **1,183.5 B** | 1,183.5–1,183.5 | 2.77 MiB |

The shape of the numbers is what the value size predicts. A second label adds 278 B — the
extra index level, the longer serialized label text, and the interned value. A ten-bucket
histogram adds 600 B over the gauge, which is the eleven-slot counts array at 32 bytes a slot
plus its header and the `_sum` and `_count` fields.

**Consequence.** The default cap is **500 series per metric**, which is ~578 KiB for the worst
shape and comfortably above any legitimate label set in the catalog. It is a per-metric figure:
total worst-case memory is that times the number of metrics that reach their cap. Collectors
whose legitimate label set is larger — resource state on a server running hundreds of
resources — declare their own cap rather than raising the default for everything.

Reproduce with `probe series`. It needs the tickwatch resource present on the server.

### A label table per write is the collectors' only allocation

A collector that writes one series per resource has to hand the registry a label set, and the
obvious way to write it builds a table per write. Whether that matters is a question about
allocation rather than about time — a few microseconds sits inside the between-session
variation recorded under Entities — so both shapes were run in the same session and measured
by bytes as well as by clock. 100 writes per call, against series that already exist:

| write shape | 100 writes | allocated | per write |
|---|---|---|---|
| a fresh table per write | 30.3 µs (spread 4.8%) | 10,400 B | 104 B |
| one table reused | 25.7 µs (spread 1.0%) | **0 B** | 0 B |

The registry reads a label table and never retains it — the series it resolves holds the
serialized label text, built once at first sight — so reuse is safe, and it takes the write
path to zero allocation. The 15% of wall clock is real, both spreads being well under the
difference, but it is not what decides this: 10 KB of garbage per pass, in the resource whose
own heap the exporter publishes as a metric, is.

The reused table is per metric shape rather than one shared across metrics. The registry
checks that a label set has exactly the declared number of keys, so a shared table carrying a
stale key from another metric would raise on first sight of a series.

Measured with the garbage collector paused across the run, so nothing is reclaimed underneath
the count. Reproduce with `probe collect`.

---

## Entities

`GetAllVehicles()`, `GetAllPeds()` and `GetAllObjects()` each return a fresh table of entity
handles, and are the only route to server-wide entity counts. The exporter samples them as
gauges on a fixed interval, so the question is not whether they are fast but what one sample
costs as a function of population. Handlers and scripts both run on the main thread, so that
answer sets the sampling interval — and a wrong interval turns the exporter into the kind of
stall it exists to report.

Cost was measured by spawning entities in steps and timing all three enumerators at every
level. Each figure is the **median of five trials**, each trial being enough repeated calls to
clear the 1 ms clock resolution by a wide margin. Median rather than a single trial because a
trial that catches a server hitch or a garbage collection is inflated by an amount unrelated
to the call, and the more expensive the call, the fewer repetitions stand behind it.

### Enumeration cost follows total entity count, not the count returned

Two sweeps, identical except for what was spawned. Microseconds per call.

**400 peds spawned**

| population | `GetAllPeds` — returns them | `GetAllVehicles` — returns 0 | `GetAllObjects` — returns 0 |
|---|---|---|---|
| 0 | 0.413 | 0.410 | 0.404 |
| 50 | 3.662 | 0.576 | 0.559 |
| 100 | 6.454 | 0.812 | 0.801 |
| 200 | 11.978 | 1.278 | 1.362 |
| 400 | 23.132 | 2.171 | 2.071 |

**400 vehicles spawned**

| population | `GetAllVehicles` — returns them | `GetAllPeds` — returns 0 | `GetAllObjects` — returns 0 |
|---|---|---|---|
| 0 | 0.395 | 0.400 | 0.401 |
| 50 | 3.841 | 0.560 | 0.562 |
| 100 | 6.454 | 0.773 | 0.781 |
| 200 | 12.894 | 1.526 | 1.419 |
| 400 | 23.743 | 2.205 | 2.178 |

**Enumerating zero entities costs over five times more on a populated server than on an empty
one.** In each sweep the two enumerators that returned nothing throughout still rose linearly
with a population composed entirely of a type they never return.

The second sweep is what makes that readable. One sweep alone is equally consistent with a
duller explanation — several hundred spawned entities make the server busier, inflating every
measurement taken on it. That explanation predicts nothing in particular. A single entity list
walked and filtered by type predicts something specific: the cost of skipping an entity is a
property of the list, so it cannot depend on what occupies the slot, and spawning the other
type must reproduce the same figure.

It does. Fitted across all five levels:

| | per skipped entity | per returned entity | ratio |
|---|---|---|---|
| peds spawned | 4.47 / 4.29 ns | 55.6 ns | 12.7× |
| vehicles spawned | 4.73 / 4.60 ns | 57.2 ns | 12.3× |

The two zero-result enumerators agree with each other to within 4% in both sweeps, and across
entity type the skipped and returned terms agree to within 6% and 3% respectively. **These
natives walk one shared entity list and filter by type rather than indexing a per-type pool.**
A skipped entity costs roughly 4.5 ns and a returned one roughly 56 ns; the ~12× gap is the
cost of writing a handle across the native bridge into the returned table, and that ratio
holds in both sweeps.

Cost is linear in population across the whole range measured, with no sign of superlinearity —
the returned-entity fits reproduce every level to within 4%, and the ped sweep to within 0.4%.
The per-entity figure declining down each table (77 → 59 ns) is the fixed term amortising, not
a scaling effect.

### Two controls, and one correction they forced

A native that crosses the same bridge but touches no entity pool should be unaffected if the
reading above is right. `GetGameTimer()` was timed at every level of both sweeps:

| population | 0 | 50 | 100 | 200 | 400 |
|---|---|---|---|---|---|
| vehicles spawned | 0.075 | 0.082 | 0.081 | 0.082 | 0.080 |
| peds spawned | 0.084 | 0.081 | 0.080 | 0.096 | 0.085 |

Flat to within ±13% of ~0.083 µs with no trend, while enumerator cost rose more than fivefold
over the same range. The server did not become generally slower — the rise is specific to the
enumerators.

The second control corrected the write-up rather than confirming it. An initial vehicle sweep
taken in an *earlier server session* put its per-entity figures around 15% below the ped
sweep, consistently across both the skipped and returned terms — a difference clean enough to
read as a real property of ped records. Repeating the vehicle sweep in the same session as the
ped one reversed the sign of that difference, and the tables above, measured back to back,
show the two types agreeing within a few percent. **Variation between server sessions is
larger than the effect it would have been attributed to.** Figures here are therefore quoted
to one significant figure, comparisons between entity types are only made within a single
session, and the probe reports the spread across its own trials so that a soft number is
visible as one.

### Allocation is exactly what the value size predicts

Every level of both sweeps, to the byte:

| entities returned | allocated | `n × 32 + 56` |
|---|---|---|
| 0 | 56 B | — |
| 50 | 1,656 B | 1,656 |
| 100 | 3,256 B | 3,256 |
| 200 | 6,456 B | 6,456 |
| 400 | 12,856 B | 12,856 |

Eight measurements across the two sweeps, eight exact matches. Two things follow. The element
type is `number`, so the return is a flat array of integer handles with nothing per-entity
behind it. And the capacity is *exactly* n, with none of the power-of-two rounding a table
grown by assignment shows — the native presizes to the count it already knows.

That makes this the cleanest confirmation of the 32-byte value size recorded above, which
needed `table.create` to escape the rounding ambiguity; here the rounding is simply not
present. The 56-byte table header arrives independently too: an enumerator returning nothing
allocates exactly 56 bytes, the same figure the 100,000-element measurement produced by
subtraction.

### Consequences

**Sampling all three is affordable at the default interval, and needs no special handling.**
One full sample of all three enumerators costs ~28 µs at 400 entities. Extrapolating the cost
model to a busy 2,000-entity server gives ~0.14 ms, which against a 10-second interval is
0.0014% of one core. Entity gauges are collected on the normal schedule — no spreading across
ticks, no opt-in flag, no separate interval.

**The three calls are batched into one collector pass.** The fixed term of roughly 1 µs is
paid per call, not per sample, so collecting the three on separate schedules pays it three
times for nothing.

**Cost is budgeted from total population, not from any one gauge.** A server holding 2,000
entities pays the walk over all of them on each of the three calls, however the population
divides between types. A deployment reasoning about "we only have 50 vehicles" is reasoning
about the wrong number.

**Allocation, not time, is the term worth watching.** At 2,000 entities each sample discards
~64 KB, about 6.4 KB/s at a 10-second interval, landing in the exporter's own per-resource
heap. It is modest, but it is the term that grows with server population, and it is part of
the sawtooth described under Memory rather than a leak.

**The empty-server floor understates the real cost.** An enumerator on an empty server costs
~0.40 µs and allocates no array part at all. The fixed term of a real enumeration is ~1 µs,
roughly 2.4× higher. Measuring this on an idle test server and extrapolating would have
produced a figure wrong in the safe-looking direction.

### The instrument demonstrated the effect it was built to measure

The first entity sweep triggered the engine's own
`server thread hitch warning: timer interval of 1512 milliseconds` — three timing runs and
repeated full garbage collections, all on the main thread. A measurement apparatus stalling
the server for 1.5 seconds is the same failure mode the HTTP section describes, and it is why
the exporter's own collection is a single bounded pass on a fixed schedule rather than work
performed on demand.

### Server-side entity creation, for reproducibility

The populations above were created with no client connected. Which natives work headless is
not documented and is not uniform:

| native | result with 0 players connected |
|---|---|
| `CreateVehicle` | returns `0` — refused |
| `CreateVehicleServerSetter` | creates a vehicle that survives and is enumerable |
| `CreatePed` | creates a ped that survives and is enumerable |
| `CreateObject` | returns `0` — refused |

Same model hash, same position, same moment. The difference is not entity ownership:
`CreateVehicle` cannot resolve the vehicle *type* server-side, and the setter takes that type
as an explicit argument. The `CreateObject` refusal is undiagnosed and may be a property of the
model rather than of server-side object creation.

Distinguishing these requires two existence checks per attempt, one immediately and one a tick
later. "No handle returned", "handle returned but nothing created" and "created, then reaped"
are indistinguishable in a pass/fail count and mean opposite things.

### `DoesEntityExist` returns 1 or 0, not true or false

And `0` is truthy in Lua, so `if DoesEntityExist(handle) then` is always taken and guards
nothing. The failure is silent: the check does not error, it simply stops being a check.

This is the same class as the callable tables recorded under HTTP handlers below: the runtime
does not return what the Lua idiom assumes, and the mismatch produces no error. Every
boolean-shaped native result is normalised at the point of the call rather than being used
directly in a condition.

---

## Players and resources

The remaining collector inputs. Each of these was read off a running server before anything
was written against it, because three of this runtime's return shapes have already turned out
to be different from what the Lua idiom assumes, and none of the three raised an error.

### What each one returns

Measured on an idle server holding 100 resources. `type:value`, as the probe prints it.

| call | returns | note |
|---|---|---|
| `GetConvar('version', ...)` | `string` — `FXServer-master SERVER v1.0.0.32561 win32` | the whole build string |
| `GetConvar('gamename', ...)` | the default | empty on this build; `/info.json` has it |
| `GetGameTimer()` | `number` — 11128 | milliseconds since the process started |
| `GetNumPlayerIndices()` | `number` — 0 | |
| `GetPlayers()` | `table`, `#` 0 | element type unmeasurable with no client |
| `GetPlayerFromIndex(0)` | `nil` | with no player connected, so the base is undetermined |
| `GetConvarInt('sv_maxclients', -1)` | `number` — 8 | reads correctly through the typed accessor |
| `GetPlayerPing(65535)` | `number` — **0** | no such player, and no error |
| `GetPlayerName(65535)` | `nil` | |
| `GetNumResources()` | `number` — 100 | |
| `GetResourceByFindIndex(-1)` | `nil` | |
| `GetResourceByFindIndex(0)` | `string` — the first resource | **zero-based** |
| `GetResourceByFindIndex(100)` | `nil` | one past the end |
| `GetResourceState(name)` | `string` — `started` / `stopped` | 84 and 16 of the 100 |
| `GetResourceState('nonexistent')` | `string` — `missing` | |

### `GetGameTimer()` is uptime, so the exporter does not keep a start stamp

Read 11.1 s and 33.8 s into two server sessions whose launch times were known. That makes
`fivem_server_uptime_seconds` a direct division rather than a delta against a stamp taken when
the resource started, which means it reports the *server's* uptime and survives a restart of
the exporter.

Its behaviour past 24.8 days is unverified — that is where a signed 32-bit millisecond counter
would wrap — so every difference taken from it in the exporter is guarded against going
negative, and a negative delta is dropped rather than observed.

### `GetPlayerPing` answers for a player who is not there

It returns `0` for a source that names nobody, for a number and a string argument alike, and
does not raise. Two consequences, and only one of them is convenient.

The ping loop needs no `pcall` around each iteration: a player who disconnects between the
enumeration and the read cannot take the pass down.

But `0` is the runtime's "no answer" and is indistinguishable from a genuine zero ping. Left
in, every departing player and every player who has not completed a round trip yet piles into
the lowest bucket and drags every percentile toward the floor. **The exporter observes a ping
only when it is above zero**, and the only real value that costs is a loopback client.

### The resource list is zero-based

`GetResourceByFindIndex(0)` returns the first resource and index `-1` returns nil, so the walk
runs `0` to `n-1`. It is the only loop in the exporter that does not start at 1. A 1-based
loop drops the first resource and reads one past the end, and both failures are silent — the
metric is simply short by one series that nobody was looking for.

`fivem_resource_up` therefore tests for the one state that means up rather than listing the
states that mean down. `started` and `stopped` are what a real list produces and `missing` is
what a name that is not a resource returns; the transitional states are documented but were
not observed. A state this build has never produced reads as down, which is the safe direction
for an up gauge.

### What a collector pass costs

Every pass, run against the shipping `server/collectors.lua` loaded out of the tickwatch
resource, on an idle server with 100 resources. Median of 5, and bytes measured with the
collector paused so nothing is reclaimed underneath the count.

| pass | cost | allocates | what it does |
|---|---|---|---|
| self | 0.5 µs | 0 B | uptime and own heap |
| players | 1.1 µs | 56 B | one `GetPlayers()` table header, empty server |
| entities | 2.2 µs | 456 B | three enumerators, empty server |
| resources | 67.9 µs | 0 B | 100 index reads, 100 state reads, 100 series writes |
| render | 69.3 µs | — | 113 series, 194 lines, 9,795 bytes |

The resource pass is the only one whose cost grows with something an operator controls. Its
native reads alone were ~0.3 µs per resource in a separate session, and 100 reused-table
writes cost 25.7 µs in this one, which puts the split at roughly half native reads and half
registry writes. Quoted to one significant figure, and the two halves are not from the same
session — see the between-session caveat under Entities.

At the default 30-second interval, 67.9 µs is 0.0002% of one core. A server with 500 resources
extrapolates to ~0.34 ms per pass, which is still under the 1 ms the timing source can even
resolve.

The pass allocates nothing, which is not obvious: it builds 100 resource names and 100 state
strings per pass. Both are short strings the runtime interns, so a repeat pass produces no new
objects. 200 passes retained −64 B, which is zero plus measurement noise.

Reproduce with `probe sources` and `probe collect`. Both need the tickwatch resource present.

---

## HTTP handlers

`SetHttpHandler` registers a handler served under `/<resource>/` on the game port. It is the
only route by which a script can serve HTTP, and so the only way to expose a scrape endpoint
from inside the server.

### Handlers run on the main thread

Three independent measurements agree, taken across a 200 ms busy-block inside the handler
and compared against an idle window of comparable length:

| measurement | idle | during the block |
|---|---|---|
| script frame counter | advances every tick | **0 frames** |
| `svMain` ticks recorded | 6 | **1** |
| `svSync` / `svNetwork` ticks | 39 / 32 | 29 / 24 |

Only `svMain` starves. The other two engine threads tick at their normal rate throughout,
which rules out a general server-wide pause and localises the stall to the main thread.
Four concurrent requests against the same blocking handler completed in 836 ms — serialized,
and confirmed from inside by an entry/exit counter that never exceeded one.

**Consequence.** Work done inside a handler is a server stall, at a rate chosen by whoever
is making the requests. For a metrics endpoint that is an unusual exposure: scrapes are
pulls, so the scrape rate is external input rather than a property of the exporter.

### A stall inside a handler is invisible to `/perf/`

Across that same 200 ms stall, `tickTime_sum{name="svMain"}` increased by **zero**. Not a
long observation in a high bucket — no observation at all.

The contrast with script execution is the finding. Blocking for a comparable 230 ms from a
script produced exactly two observations in the 150–250 ms range of that same histogram, as
recorded above. Same thread, same duration, recorded in one case and absent in the other:
the engine stops ticking rather than recording a long tick, so time spent in a handler falls
outside the region `tickTime` brackets.

**Consequence.** `/perf/` is a reference for script-thread stalls specifically, and an
exporter's own serving path sits in its blind spot. A slow handler degrades the server in a
way the engine's own instrumentation does not show.

It also inverts the relationship between the two measurements. During that stall the script
scheduler was frozen, so an event-loop-lag metric registers the full 200 ms. The proxy is
not a degraded substitute for the reference — it observes a class of stall the reference
cannot see.

#### Both instruments, read at once

The above was measured one instrument at a time. Repeated as a paired experiment, with
Prometheus scraping both `/tickwatch/metrics` and `/perf/`, and ten 200 ms handler blocks
fired between two snapshots:

| | delta across the window |
|---|---|
| `fivem_server_tick_interval_seconds`, bucket `(0.15, 0.25]` | **+10 observations** |
| `tickTime{name="svMain"}`, every bucket above 10 ms | **+0 observations** |

Ten stalls, ten observations, none of them seen by the reference.

**The control matters more than the result.** "Nothing above 10 ms" is also what a cached or
static endpoint returns, so `/perf/` was checked for liveness across the same window:
`tickTime_count{name="svMain"}` advanced by **172** and `tickTime_sum{name="svMain"}` by
**0.033 s**. The endpoint was awake and counting. Had it seen the blocks, that sum would have
risen by roughly 2.0 s — sixty times what it recorded. The engine was ticking, measuring, and
reporting 33 ms of work while the server was frozen for two seconds.

This is the clearest statement of what the exporter adds over the endpoint the engine already
publishes, and it is worth stating precisely: **it is not a better measurement of the same
thing.** `tickTime` measures work inside a frame — 0.176 ms mean, p99 0.99 ms on an idle
server. The lag proxy measures the gap between frames — 50.26 ms mean, p99 54.9 ms. On a
healthy server they differ by ~285x, because the server works briefly and then sleeps to hold
20 Hz. They are answers to different questions, and only one of them noticed the freeze.

### What a handler can do

| | |
|---|---|
| `req` | `path`, `method`, `headers`, `address`, `setDataHandler`, `setCancelHandler` |
| `res` | `send`, `write`, `writeHead` |
| yielding | `Wait()` inside the handler succeeds, and the frame counter advances across it |
| deferred response | `res` may be captured, returned from, and completed later — a 500 ms deferred send reached the client at 545 ms |

Two details that matter to anyone writing against this interface. `res.send`, `res.write` and
`res.writeHead` report a `type()` of **`table`**, not `function` — they are callable tables,
so a defensive `type(res.send) == 'function'` check concludes the method is missing when it
is present. And `setCancelHandler` makes client disconnects observable, which any design
that completes a response after the handler returns needs in order to avoid writing to a
socket that has gone away.

**The serving model this produces.** The handler never renders. It compares a cached
exposition payload against a freshness threshold, sends it immediately if current, and
otherwise defers the response to be completed by the next scheduled render. Render cost is
paid once per interval regardless of scrape rate, no scrape renders inline, and the content
type is set through `writeHead`.

### Request header keys arrive verbatim, with no normalisation

Sent three spellings of the same header and read back what the handler received:

| sent | arrived as | `headers['Authorization']` | `headers['authorization']` |
|---|---|---|---|
| `Authorization: …` | `Authorization` | the value | nil |
| `authorization: …` | `authorization` | nil | the value |
| `AUTHORIZATION: …` | `AUTHORIZATION` | nil | nil |

`x-weird-CASE` came back with its mixed case intact too. The runtime hands the table through
exactly as the client wrote it.

HTTP header names are case-insensitive by specification, so every one of those spellings is a
correct request. A handler that indexes the table by one of them therefore works against one
client and returns 401 to another, on a scrape that is configured correctly — and nothing in
the failure points at the cause. **The exporter scans the header table case-insensitively**
rather than indexing it, which costs a loop over a handful of keys on a request that already
costs orders of magnitude more.

### `req.path` carries the query string

`/metrics?collect[]=foo` arrives as exactly that, so `path == '/metrics'` is false and the
request 404s. Prometheus does not normally add parameters to a scrape URL, which is what makes
this a bug that survives a test suite and appears once, on somebody else's setup. Routes are
matched on the path with the query stripped.

### A `Content-Length` is discarded

Set one through `writeHead` and the response still went out as `Transfer-Encoding: chunked`.
The header simply does not appear on the wire. `WWW-Authenticate` set the same way does, so
this is specific to the length rather than a general refusal of custom headers. The exporter
does not set it: a line implying a framing guarantee the transport does not keep is worse than
no line.

### What a scrape costs on a live server

The serving model above, measured end to end with curl against a running server. 113 series,
a 9,630-byte payload.

| | |
|---|---|
| 20 sequential scrapes | 1.32–1.58 ms each |
| 8 concurrent scrapes | 1.32–1.89 ms each |

The comparison that matters is against the 200 ms handler measured above, where four
concurrent requests took 836 ms and the server stopped ticking. Here eight overlap inside two
milliseconds and the tick histogram registers nothing, because the handler does a string
comparison and a table lookup and sends a payload somebody else built.

Deferral is deliberately not the normal path. The configuration holds the freshness threshold
at or above twice the render interval, so a payload can only exceed it if the render loop is
late by more than a whole interval — which is to say, when the server is already stalled. On a
healthy server every scrape is served from cache.

---

## The export boundary

Every other measurement in these notes was taken from inside one resource's Lua state. The
export API is the one surface that is not: a caller is a different resource, a different
`lua_State`, and its arguments are serialized to get here. Nothing measurable from inside says
what that costs or what survives it — and the answer removed a function from the public API
before it shipped.

### A function does cross, as a proxy, and calling it is a round trip

An export returning a closure was expected to fail. It does not:

| | |
|---|---|
| a returned closure arrives as | `table` — a callable table, the same shape `res.send` has |
| calling it | works, and the upvalue persists between calls |
| **cost per call** | **6.3 µs** (spread 4.4%) |
| a table containing a function | survives; the string field arrives intact and the function field arrives as a callable table |

So the runtime wraps the function in a reference and proxies the call back into the owning
resource. It works, and it costs roughly a thousand times what calling a local closure costs.

**Consequence.** `StartTimer()` returning a `stop()` closure — which the design specified — is
a stopwatch whose stop button is a round trip. It was removed. The replacement takes a
`GetGameTimer()` reading the caller took in its own state.

### What an export call costs

Measured from `tickwatch-probe` calling into `tickwatch`, three runs, medians of five.

| call | cost | spread |
|---|---|---|
| `Inc`, no labels | 7.8–8.0 µs | 3–4% |
| `Inc`, labelled | 8.2–9.1 µs | 6–21% |
| `Observe` | 7.7–9.8 µs | 3–23% |
| `ObserveSince` | 9.0 µs | 18% |
| `Inc` on an unknown metric, refused | 8.2–10.3 µs | 5–15% |
| *(control)* `GetGameTimer()` locally | 0.093–0.100 µs | 1–16% |
| *(control)* an empty function call | 0.012 µs | 8% |

**About 8 µs, and the differences between call shapes are inside the variation between runs.**
The boundary dominates: an unlabelled counter increment and a labelled histogram observation
cost the same to within the noise, and so does a call that is refused outright — refusing is
not meaningfully more expensive than succeeding, which matters because a caller with a typo
pays that path on every call forever.

**A labelled call allocates 1,651 B, and it allocates them in the caller's heap.** That figure
was identical to the byte across all three runs. It is the term that limits where this API
belongs: at a thousand calls a second it is 1.6 MB/s of garbage in somebody else's resource.

**Consequences.**

Timing a database query is affordable — 8 µs against ~500 µs is under 2%. Timing something
that runs thousands of times a second is not; count it instead.

The convenience wrappers are not sugar. `Query(op, status, seconds)` does two registry writes
behind one boundary crossing, which is half the cost of a caller making the two calls itself.

And an earlier claim in the design was wrong by a factor of forty. It read "timing an operation
costs two clock reads, roughly 180–230 ns … under 0.05%", which is the cost *inside* the
resource. Through the export API the same instrumentation costs ~8 µs and ~1.6 KB. Corrected
there.

### Errors do not cross

Every rejection the exporter makes — unknown metric, wrong type, a counter given a negative
increment, a label set that does not match the declaration — returned `false` to the caller and
raised nothing. Confirmed from the calling resource, which continued running in every case.

That is a property of the exporter rather than of the runtime: `exports.lua` wraps every
registry write in `pcall` deliberately, because the registry's own guards are worth keeping and
the caller's stack is not the place to enforce them.

Reproduce with `probe exports`. It needs `tickwatch` started and `tickwatch-probe-b` present.

---

## Configuration and convars

Exporter configuration is read from convars, including the token that authenticates scrapes.
FXServer offers three verbs for setting one, and they differ in who can read the result.

### Only one of the three verbs is observable from a server script

Each verb was tested twice — declared in `server.cfg`, and set through its corresponding
native — against a server whose own `/info.json` was polled for five seconds afterwards.

| verb | native | `GetConvar` | in `/info.json` `vars` | pushed to clients |
|---|---|---|---|---|
| `set` | `SetConvar` | reads the value | no | no |
| `sets` | `SetConvarServerInfo` | reads the value | **yes** | no |
| `setr` | `SetConvarReplicated` | reads the value | no | **yes** |

The cfg-declared and native-set arms agree on every observable, so the three natives are
equivalent to the three console verbs for these purposes.

**A replicated convar is indistinguishable from a private one, from inside the server.**
`GetConvar` returns the value identically for all three and reports nothing about how it was
set. No native exposes the flag — sixteen candidate names were checked individually, since
natives materialise lazily through `__index` and cannot be enumerated, so this is "absent
under these names" rather than a proof of absence. And the command registry, which does list
convars, registers exactly two entries per convar — arity 0 and arity 1, resource `internal` —
identically for all three verbs.

`/info.json` was the promising route and it does not work: **`setr` is precisely the verb that
does not appear there.** The endpoint reflects server-info convars, which is `sets`, not
replication. A check built on it would catch the wrong mistake.

### What that means for a scrape token

The two failure modes are not equally defensible:

- **`sets` puts the value in `/info.json`**, unauthenticated on the game port, readable by
  anyone including server-list crawlers. This *is* detectable: the exporter can fetch its own
  `/info.json` at startup and refuse to serve if its token convar appears there. The value
  showed up 53 ms after being set and the payload is regenerated per request, so a single
  fetch is sufficient — no polling, no cache allowance.
- **`setr` pushes the value to every connecting client** and is not detectable server-side at
  all. It is equally a leak and nothing in the runtime reports it.

So the exporter can defend against one of the two and not the other, and the README says so
rather than implying the check is complete. The token convar is named to make the wrong verb
look wrong, and the documentation states `set` explicitly rather than leaving it to be
inferred from an example.

A partial remedy exists for the detectable case. Blanking a server-info convar with
`SetConvarServerInfo(name, '')` removes the value from `/info.json` while leaving the key
present and empty. Convars cannot be deleted at runtime, so an operator can scrub an exposed
value without a restart, but not the fact that the name exists.

### `ExecuteCommand` cannot set a convar

`ExecuteCommand('set name value')` from a server script returns successfully and does nothing.
The convar does not exist afterwards: `GetConvar` returns the default, no entry appears in the
command registry, and nothing reaches `/info.json`. There is no error and no return value to
check.

The three natives work. Any resource that needs to write a convar uses them.

### The typed accessors, and what they do with a value they cannot parse

`GetConvarInt`, `GetConvarFloat` and `GetConvarBool` avoid parsing strings by hand. What they
return for a value that is not of the requested type is undocumented, and it decides whether a
configuration typo is loud or silent. Each convar below was declared in `server.cfg` — a script
cannot set one — and read through all three accessors, with distinctive defaults so a fallback
is visible rather than confusable with a parsed value.

| value in cfg | `GetConvarInt` | `GetConvarFloat` | `GetConvarBool` |
|---|---|---|---|
| *(unset)* | default | default | default |
| `""` | default | default | default |
| `"abc"` | default | default | default |
| `"12"` | `12` | `12.0` | `1` |
| `"12.9"` | `12` | `12.89999961853` | `1` |
| `"-3"` | `-3` | `-3.0` | `1` |
| `" 12 "` | `12` | `12.0` | `1` |
| `"1"` | `1` | `1.0` | `1` |
| `"0"` | `0` | `0.0` | `false` |
| `"true"` | **`1`** | default | `1` |
| `"false"` | **`0`** | default | `false` |
| `"yes"` `"no"` `"on"` `"off"` | default | default | default |

Four things follow, and three of them are traps.

**Unparseable text falls back to the default rather than to zero.** This is the safe direction
and it is what makes `0` usable as a "disabled" sentinel for a collector interval: a typo
cannot produce it.

**Except that the integer accessor reads `true` and `false` as `1` and `0`.** So
`set tickwatch_players_interval_ms false` arrives as a deliberate-looking `0`. That is the one
hole in the paragraph above, and the exporter screens the raw string for a number before
trusting the accessor.

**`GetConvarBool` returns the number `1` for true and the boolean `false` for false.** It never
returns boolean `true` and never returns the number `0`. `if GetConvarBool(x, true) then` works
by luck, because `1` is truthy — but `GetConvarBool(x, true) == true` is false for a convar
explicitly set to `true`. This is the same 1/0 convention seen on `DoesEntityExist`, and the
result is normalised at the call site for the same reason.

**Only `true`, `false`, `1` and `0` are recognised, case-insensitively.** `yes`, `no`, `on` and
`off` fall back to the default and report nothing. `set tickwatch_enabled no` therefore leaves
the exporter running. Nothing in the runtime catches this, so the exporter validates the raw
string itself and prints what it did not understand.

Two smaller notes. `GetConvarFloat` returns float32 precision — `12.9` reads back as
`12.89999961853` — so it is unsuitable for anything where the exact value matters; nothing in
the exporter uses it. And convar **names** are case-insensitive: a `server.cfg` declaring both
`tw_probe_ct_true` and `tw_probe_ct_TRUE` ends up with one convar, the later line winning.

Reproduce with `probe convartypes`; the cfg block it needs is in the probe's source.

### `/info.json` supplies values `GetConvar` will not

`GetConvar('gamename')` returns empty on this build, while the server's own `/info.json`
reports `"gamename": "gta5"` in the same moment. The endpoint is not merely a place where
convars leak — it is the only script-reachable source for some of them.

The exporter therefore reads its own `/info.json` once at startup, which it is already doing
for the token check above, and uses it to populate labels that no native supplies. One
outbound request at startup, cached for the process lifetime.

### What a server publishes without being asked

Worth knowing for anyone deploying this. `/info.json` is unauthenticated on the game port and
already carries `sv_licenseKeyToken`, the server's own Cfx license token, with no operator
action. Combined with the `/perf/` endpoint recorded above, a stock server of this build
publishes its license token and its tick timings to anyone who asks.

This is the platform's behaviour, not something this exporter introduces, and it is stated
here because it sets the baseline: a metrics endpoint on the same port is not the first thing
that server exposes, and any argument about authenticating scrapes should start from what is
already public.
