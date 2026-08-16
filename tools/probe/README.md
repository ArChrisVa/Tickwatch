# tickwatch-probe

The measurement apparatus behind [`docs/platform-notes.md`](../../docs/platform-notes.md).

Every table in those notes was produced by a probe in here. It is checked in so that the
claims can be re-run rather than trusted — a reader who can reproduce a number is in a
different position from one who has to believe it.

It is not part of the exporter. Nothing in `tools/` is loaded by, or required by, tickwatch
at runtime.

## Running it

Copy both resources into a test server's `resources/` and ensure them:

```cfg
ensure tickwatch-probe
ensure tickwatch-probe-b
```

`tickwatch-probe-b` is a second Lua state and exists only to be a control. The memory-scope probe
cannot produce a result without it, and says so rather than reporting a number.

Then, from the server console:

```
probe                 list the probes
probe curve ped       run one
```

Or over HTTP, which is how a run gets read from outside the process — console output cannot be
scraped, and re-running a sweep in order to transcribe it measures it twice under different
conditions:

```sh
curl http://127.0.0.1:30130/tickwatch-probe/run/curve/ped   # start a probe
curl http://127.0.0.1:30130/tickwatch-probe/log             # read the output so far
```

Every line is also written to `probe-out.txt` inside the resource folder. `/run` is restricted
to loopback: the game port is public and some probes spawn hundreds of entities.

## What reproduces what

| probe | notes section |
|---|---|
| `clock` | Timing — `GetGameTimer` resolution and call cost |
| `osclock` | Timing — `os.clock` semantics (wall vs CPU), then its resolution |
| `memory` | Memory — which `lua_State` `collectgarbage` reads (**needs `tickwatch-probe-b`**) |
| `tvalue` | Memory — value size and table growth |
| `commands` | Tick timing — enumerating the console command set |
| `http` | HTTP handlers — thread affinity (drive with `curl` first, see below) |
| `entities` | Entities — cost at the current population |
| `curve [vehicle\|ped]` | Entities — the population staircase |
| `spawndiag` | Entities — which creation natives work with no client connected |
| `convars` | Configuration — `set` / `sets` / `setr` distinguishability |
| `spawn <n> [type]`, `despawn` | populate and clean up by hand |

`probe http` reports results that four `curl` calls have to generate first:

```sh
curl http://127.0.0.1:30130/tickwatch-probe/shape    # what req and res actually expose
curl http://127.0.0.1:30130/tickwatch-probe/block    # 200 ms busy-block inside the handler
curl http://127.0.0.1:30130/tickwatch-probe/wait     # is the handler a coroutine?
curl http://127.0.0.1:30130/tickwatch-probe/defer    # can a response be completed later?
```

Run several `/block` calls concurrently to measure whether handlers interleave.

## Reading the output honestly

**Figures are not comparable across server sessions.** Measurements of the same operation in
two different sessions of the same server on the same machine differ by more than the effects
being measured — around 15% was observed. Two numbers being compared must come from one
session. This is not a footnote; it invalidated a finding that was already written up, and
`probe curve` therefore measures both entity types in a single sweep for exactly this reason.

**Every timing is a median of five trials, and the spread is printed beside it.** A 2% spread
and a 30% spread carry the same median and should not be quoted with the same confidence. If a
number matters, look at its spread before using it.

**The probe perturbs what it measures.** A full sweep stalls the main thread for long enough
to trigger the engine's own hitch warning. That is expected — the probes run timing loops and
forced garbage collections on the server's main thread deliberately — but it means a probe
should not be run against anything you care about.

**The tick cross-check only closes on one side of a crossover.** Both clock probes check
their own result by asserting that tick count × tick size reconstructs the elapsed time. That
identity holds when the clock is coarse relative to the cost of reading it, which is the case
for `GetGameTimer` — most reads return the same value, and the non-zero deltas are the ticks.
It cannot hold for `os.clock` on Linux, where a 1.4 µs call reads a 1 µs clock: every read
differs from the last, so no read is ever discarded and the reconstruction falls short of the
elapsed time. `probe osclock` prints both figures rather than hiding the gap. A mismatch there
is the expected result, not a failed measurement.

**Convars cannot be unset.** `probe convars` creates convars that persist until the server
restarts, so a second run in the same session is void. It checks for its own leftovers and
says so.

**Absence is hard to prove here.** Natives materialise lazily through an `__index` metatable,
so `pairs(_G)` cannot show that one is missing. Where a probe reports a native as absent it
checked a named list, and the claim is "not under these names" — nothing stronger.

## Environment these numbers came from

| | Windows | Linux |
|---|---|---|
| FXServer build | `FXServer-master SERVER v1.0.0.32561 win32` | `FXServer-master v1.0.0.32561 linux` |
| Lua runtime | LuaGLM 5.4 | LuaGLM 5.4 |
| C library | MSVC CRT | musl |
| Host OS | Windows 11 (build 26200) | kernel 6.18.33.1, clocksource `tsc` |
| Server | QBCore, 8 slots | bare server, this resource only |

Findings are build-specific and host-specific. The build stamp is printed every time the
resource starts, and belongs with any number taken from it.

Only the timing probes have been run on both platforms, against the same build number so
that a difference between the columns is the platform rather than a version change. Every
other table in the notes is Windows-only.
