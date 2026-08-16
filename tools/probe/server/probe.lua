-- tickwatch-probe — the measurement apparatus behind docs/platform-notes.md.
--
-- Every table in those notes was produced by a probe in this file. It ships so
-- that the claims can be checked rather than trusted: reproducibility is the
-- strongest available evidence that a measurement is real, and a reader who can
-- re-run a number is in a different position from one who has to believe it.
--
-- Drop this resource and tickwatch-probe-b into a server's `resources/`, ensure both,
-- and run a probe. Each maps to a section of the notes:
--
--   probe clock          Timing — GetGameTimer resolution and cost
--   probe osclock        Timing — os.clock semantics (wall vs CPU), then its
--                        resolution. Platform-dependent: see the note above it
--   probe memory         Memory — which lua_State collectgarbage reads (needs
--                        tickwatch-probe-b running as the control)
--   probe tvalue         Memory — value size and table growth
--   probe commands       Tick timing — enumerate the console command set
--   probe http           HTTP handlers — thread affinity (drive with curl first,
--                        see the route list below)
--   probe entities       Entities — cost at the current population
--   probe curve [type]   Entities — the population staircase, `vehicle` or `ped`
--   probe spawndiag      Entities — which creation natives work headless
--   probe convars        Configuration — set / sets / setr distinguishability
--   probe convartypes    Configuration — what the typed accessors do with a
--                        value they cannot parse (needs the server.cfg fixture)
--   probe series         Cardinality — bytes per series, against the real registry
--   probe sources        Collectors — return shapes of every native they read,
--                        and the cost of one full resource pass
--   probe collect        Collectors — run the real collectors.lua against the
--                        real server, and time every pass and the render
--   probe exports        Export API — cost and behaviour of a call from another
--                        resource, and whether a function survives the boundary
--   probe tickimpact [s] v0.1.0 — does running the exporter change the server's
--                        tick? control / treatment / control, in one session
--   probe load [n]       v0.1.0 — fill the registry to the cardinality cap so the
--                        request path can be timed against a full-sized one
--   probe spawn <n> [t]  populate by hand
--   probe despawn        remove what this probe spawned
--
-- Console: `probe <name>`. Or over HTTP, which is how a run gets read from
-- outside the process — console output cannot be scraped, and re-running a sweep
-- in order to transcribe it measures it twice under different conditions:
--
--   curl http://127.0.0.1:30130/tickwatch-probe/run/curve/ped   start a probe
--   curl http://127.0.0.1:30130/tickwatch-probe/log             read the output so far
--
-- Every line is also written to `probe-out.txt` in this resource's folder.
--
-- Findings are build-specific and vary by around 15% between server sessions, so
-- the build stamp is printed on start and figures are quoted to one significant
-- figure. Numbers from two different sessions are not comparable.

local probes = {}

-- --------------------------------------------------------------------------
-- output helpers
-- --------------------------------------------------------------------------

-- Every line is mirrored into a buffer and written to `probe-out.txt` beside this
-- file. The console is the natural place to watch a probe, but console output
-- cannot be read from outside the process, and a sweep that has to be re-run in
-- order to be copied is a sweep measured twice under different conditions.

local OUT_FILE = 'probe-out.txt'
local OUT_MAX = 4000
local outLines = {}

local function flushOutput()
    local text = table.concat(outLines, '\n')
    -- pcall rather than a type check: if the native is absent the probe should
    -- still print, and Q2 established that runtime objects do not always report
    -- the type their idiom implies.
    pcall(SaveResourceFile, GetCurrentResourceName(), OUT_FILE, text, #text)
end

--- Console plus buffer. Never called from inside a timed region, so the file
--- write cannot land in the middle of a measurement.
local function emit(line)
    print(line)
    outLines[#outLines + 1] = line
    if #outLines > OUT_MAX then
        table.remove(outLines, 1)
    end
    flushOutput()
end

--- One labelled result line, aligned for copy/paste into platform-notes.md.
local function report(label, value, unit)
    emit(('[probe] %-30s %s%s'):format(
        label,
        tostring(value),
        unit and (' ' .. unit) or ''
    ))
end

local function header(title)
    emit(('[probe] ---- %s ----'):format(title))
end

-- --------------------------------------------------------------------------
-- Q3 — clock resolution
-- --------------------------------------------------------------------------
-- YOU WRITE THIS. Four separate measurements, in this order:
--
--   a) existence sweep — which clock functions are non-nil on this build?
--                        (GetGameTimer, os.clock, os.time, anything else)
--   b) granularity     — tight read loop; collect deltas; discard zeros;
--                        report the MINIMUM non-zero delta per clock
--   c) call cost       — time N reads, divide by N (a single read is below
--                        the resolution you are trying to measure)
--   d) wall vs CPU     — read, Wait(100), read again. ~0.1 elapsed means wall
--                        clock; ~0 means CPU clock and it cannot time I/O
--
-- Report the sample count alongside every number — a minimum over 50 samples
-- and a minimum over 500k samples are not the same claim.

probes.clock = function()
    header('Q3 clock resolution')
    local N = 2000000
    local prev = GetGameTimer()
    local nonzero = 0
    local min = math.huge

    local t0 = GetGameTimer()
    for i = 1, N do
        local now = GetGameTimer()
        local delta = now - prev
        if delta > 0 then
            nonzero = nonzero + 1
            if delta < min then
                min = delta
            end
        end
        prev = now
    end
    local t1 = GetGameTimer()

    local elapsed = t1 - t0

    if nonzero > 0 then
        report('minimum non-zero delta', min/1000, 's')
    else
        report('minimum non-zero delta', 'none observed — clock never changed')
    end
    report('non-zero deltas', ('%d / %d'):format(nonzero, N))
    report('total elapsed', elapsed/1000, 's')
    report('per-call cost', elapsed / N / 1000, 's')
end

-- --------------------------------------------------------------------------
-- Q3b — os.clock semantics, then resolution
-- --------------------------------------------------------------------------
-- FXServer does not override os.clock: the scripting library imports C `clock`
-- and defines no replacement, and nothing under citizen/ touches the os table.
-- So os.clock is stock loslib — clock()/CLOCKS_PER_SEC — and what it *means* is
-- whatever the platform C library says. MSVC returns wall-clock time, deviating
-- from the C standard; POSIX libcs return process CPU time. The same Lua call is
-- therefore a different clock on Windows and on Linux.
--
-- Semantics is measured before resolution. The granularity of a clock that
-- cannot observe waiting is a precise answer to a question that no longer
-- matters, and ordering it second keeps that trap shut.
--
-- Discriminating wall from CPU needs more than "is the delta near zero". C
-- clock() is process-wide, and svMain/svSync/svNetwork keep burning CPU while
-- this thread waits, so a CPU clock still advances across an idle window. Both
-- hypotheses predict "some number between 0 and the wall interval". Two
-- references bracket the same window instead — GetGameTimer as known wall time,
-- and the process's own CPU accounting read from outside via /proc — and the
-- question becomes which of the two os.clock tracks, not whether it is small.

probes.osclock = function()
    header('Q3b os.clock semantics and resolution')

    -- (a) existence. A function present on one host can be absent on another,
    -- and this is the cheap half of a claim that a clock source is available.
    for _, name in ipairs({ 'clock', 'time', 'difftime' }) do
        report('os.' .. name, type(os[name]))
    end
    report('GetGameTimer', type(GetGameTimer))

    -- (b) semantics. Idle for a known wall interval; see which reference follows.
    local WAIT_MS = 5000
    local c0, g0 = os.clock(), GetGameTimer()
    Wait(WAIT_MS)
    local c1, g1 = os.clock(), GetGameTimer()

    local wall = (g1 - g0) / 1000
    local oc = c1 - c0
    local ratio = oc / wall

    report('idle wall elapsed', ('%.3f'):format(wall), 's  (GetGameTimer)')
    report('os.clock elapsed', ('%.6f'):format(oc), 's')
    report('os.clock / wall', ('%.4f'):format(ratio))
    report('reads as', ratio > 0.9 and 'WALL CLOCK' or 'NOT wall — CPU-like, cannot time waiting')

    -- (c) resolution. Interpret only in the light of (b): if this is a CPU clock,
    -- this number is the granularity of CPU accounting, not of elapsed time.
    local N = 1000000
    local prev = os.clock()
    local nonzero, min = 0, math.huge

    local t0 = os.clock()
    for i = 1, N do
        local now = os.clock()
        local delta = now - prev
        if delta > 0 then
            nonzero = nonzero + 1
            if delta < min then
                min = delta
            end
        end
        prev = now
    end
    local elapsed = os.clock() - t0

    if nonzero > 0 then
        report('minimum non-zero delta', ('%.9f'):format(min), 's')
        -- Same cross-check the GetGameTimer arm uses: if the minimum really is
        -- the tick size, tick count x tick size must reconstruct the elapsed
        -- time. A mismatch means ticks were missed or the minimum is noise.
        report('ticks x min delta', ('%.6f'):format(nonzero * min), 's')
    else
        report('minimum non-zero delta', 'none observed — clock never changed')
    end
    report('non-zero deltas', ('%d / %d'):format(nonzero, N))
    report('total elapsed', ('%.6f'):format(elapsed), 's')
    report('per-call cost', ('%.3e'):format(elapsed / N), 's')
end

-- --------------------------------------------------------------------------
-- Peer statistics — identifying an undocumented enum
-- --------------------------------------------------------------------------
-- `GetPlayerPeerStatistics(src, index)` exposes ENet's per-peer counters, which
-- would give packet loss and RTT variance where the spec collects only ping.
-- The index is an enum nobody documents server-side, so it has to be identified
-- rather than assumed.
--
-- A single sweep cannot do that. On a healthy link most counters rest at zero,
-- and "this index is packet loss" is indistinguishable from "this index is
-- always zero" — the same failure that made the two-arm setr test unsound. Two
-- things fix it, and both are needed:
--
--   1. sample repeatedly, so a counter that moves separates from a constant
--   2. impair the link by a KNOWN amount, so each index has a value predicted
--      before it is read rather than a number to rationalise afterwards
--
-- Run this against `tc qdisc ... netem delay 80ms loss 5%` on the server's
-- interface. Predictions to check against:
--
--   RTT          ~80, and tracks when the delay is changed
--   packet loss  ~3277 if ENet scales by 65536 (5% of it). If not, the ratio
--                between a 5% run and a 10% run still yields the scale.
--   anything flat under both impairments is not what its position suggests

probes.peers = function()
    header('peer statistics — index sweep')

    local players = GetPlayers()
    if not players or #players == 0 then
        report('verdict', 'CANNOT RUN — needs a connected client')
        return
    end

    local src = players[1]
    report('player src', src)
    report('name', GetPlayerName(src) or '?')

    local MAX_INDEX = 15
    local SAMPLES = 6
    local INTERVAL = 1000

    -- Collect first, report after. `report` writes a file, and doing that
    -- between samples would put a disk write inside the sampled interval.
    local series, pings, lastmsgs = {}, {}, {}
    for s = 1, SAMPLES do
        for idx = 0, MAX_INDEX do
            series[idx] = series[idx] or {}
            local ok, v = pcall(GetPlayerPeerStatistics, src, idx)
            series[idx][s] = ok and v or 'err'
        end
        pings[s] = GetPlayerPing(src)
        lastmsgs[s] = GetPlayerLastMsg(src)
        if s < SAMPLES then Wait(INTERVAL) end
    end

    report('samples', ('%d at %d ms'):format(SAMPLES, INTERVAL))
    report('GetPlayerPing', table.concat(pings, '  ') .. '  <- the reference')
    report('GetPlayerLastMsg', table.concat(lastmsgs, '  '))

    for idx = 0, MAX_INDEX do
        local vals = series[idx]
        local parts, moved, allZero = {}, false, true
        for s = 1, SAMPLES do
            parts[#parts + 1] = tostring(vals[s])
            if vals[s] ~= vals[1] then moved = true end
            if vals[s] ~= 0 then allZero = false end
        end

        local tag
        if moved then
            tag = '   <- VARIES'
        elseif allZero then
            tag = '   (flat zero — unidentifiable on this link)'
        else
            tag = '   (constant)'
        end

        report(('index %2d'):format(idx), table.concat(parts, '  ') .. tag)
    end

    emit('[probe] A constant here is not necessarily a constant. It may be a counter')
    emit('[probe] this link never exercises — which is what the impairment is for.')
end

-- --------------------------------------------------------------------------
-- Console command registry
-- --------------------------------------------------------------------------
-- Enumerates every command the server knows, rather than guessing at names like
-- `resmon` / `profiler` / `perf` and reading "Invalid command" as proof of absence.
-- Absence of evidence only counts if you enumerated the whole set.

probes.commands = function()
    header('registered console commands')

    local cmds = GetRegisteredCommands()
    if type(cmds) ~= 'table' then
        report('GetRegisteredCommands returned', type(cmds))
        return
    end

    report('total commands', #cmds)

    -- Record the entry schema — the native's return shape is undocumented.
    local first = cmds[1]
    if type(first) == 'table' then
        local keys = {}
        for k, v in pairs(first) do
            keys[#keys + 1] = ('%s=%s'):format(k, tostring(v))
        end
        table.sort(keys)
        report('entry shape', table.concat(keys, '  '))
    else
        report('entry shape', type(first) .. ' -> ' .. tostring(first))
    end

    local patterns = {
        'prof', 'resmon', 'perf', 'mem', 'tick',
        'cpu', 'stat', 'monitor', 'trace', 'time'
    }

    local hits = 0
    for i = 1, #cmds do
        local entry = cmds[i]
        local name = type(entry) == 'table' and tostring(entry.name) or tostring(entry)
        local lower = name:lower()

        for j = 1, #patterns do
            if lower:find(patterns[j], 1, true) then
                local owner = type(entry) == 'table' and entry.resource or '?'
                emit(('[probe]   %-28s %s'):format(name, tostring(owner)))
                hits = hits + 1
                break
            end
        end
    end

    report('profiling-related matches', hits)
end

-- --------------------------------------------------------------------------
-- Q4 — collectgarbage('count') scope
-- --------------------------------------------------------------------------
-- The question is not what the function does; it is which lua_State it reads.
-- Allocating here and watching this resource's count rise is consistent with
-- BOTH "one state per resource" and "one state shared by every Lua resource",
-- so a single-resource measurement proves nothing. The test only discriminates
-- if a second, independent state is read at the same moment:
--
--   per-resource state  ->  A rises, B flat
--   shared state        ->  A rises, B rises by the same amount
--
-- tickwatch-probe-b exists to be that B.

local BALLOON_N = 1000000

-- File scope on purpose. A function-local would go unreachable the moment the
-- probe returns, and the collect below would eat the evidence before it could
-- be read.
local balloon = nil

--- Two full cycles, not one. The first may resurrect objects through
--- finalizers; the second reclaims them.
local function fullCollect()
    collectgarbage('collect')
    collectgarbage('collect')
end

--- This state's heap in bytes. collectgarbage reports Kbytes as a float.
local function countBytes()
    return collectgarbage('count') * 1024
end

--- The other state's heap in bytes, over the export bridge. Wrapped in pcall
--- because a stopped tickwatch-probe-b throws here, and an error swallowed into a nil
--- would read as "B did not move" — indistinguishable from a genuine
--- per-resource result. The failure mode has to be loud.
local function otherBytes(collectFirst)
    local ok, kb = pcall(function()
        if collectFirst then
            return exports['tickwatch-probe-b']:collectAndCount()
        end
        return exports['tickwatch-probe-b']:count()
    end)

    if not ok or type(kb) ~= 'number' then
        return nil, tostring(kb)
    end
    return kb * 1024
end

local function peerBytes(collectFirst)
    local bytes, err = otherBytes(collectFirst)
    return assert(bytes, 'tickwatch-probe-b became unreachable mid-run: ' .. tostring(err))
end

--- Raw byte count is what gets checked against the TValue prediction; the MiB
--- figure is what is readable at a glance. Print both.
local function reportBytes(label, bytes)
    report(label, ('%d (%.3f MiB)'):format(
        math.floor(bytes + 0.5),
        bytes / 1048576
    ))
end

probes.memory = function()
    header('Q4 collectgarbage scope')

    -- (a) what is actually being called ------------------------------------
    -- Return arity is version-dependent, and the manifest asking for lua54 is
    -- not proof the runtime honoured it. Pin both rather than assume.
    report('lua version', _VERSION)
    report('count return arity', select('#', collectgarbage('count')))

    -- setpause / setstepmul are deliberately absent: called without an
    -- argument they set the parameter to 0 on the builds that still accept
    -- them, which would leave the GC misconfigured for the rest of the run.
    local options = { 'count', 'isrunning', 'step', 'collect', 'incremental', 'generational' }
    local allowed = {}
    for i = 1, #options do
        local ok = pcall(collectgarbage, options[i])
        allowed[#allowed + 1] = ('%s=%s'):format(options[i], ok and 'y' or 'n')
    end
    report('options accepted', table.concat(allowed, ' '))

    -- The sweep just switched GC modes. Put it back before measuring anything.
    pcall(collectgarbage, 'incremental')

    -- (b) is the control state reachable at all? ----------------------------
    local peer, err = otherBytes(false)
    if not peer then
        report('tickwatch-probe-b', 'unreachable — ' .. err)
        report('verdict', 'CANNOT RUN — ensure tickwatch-probe-b, then retry')
        return
    end

    -- (c) noise floor -------------------------------------------------------
    -- Every read across the export bridge serializes a call and allocates in
    -- both states. Quantify that before ballooning, so the real deltas are read
    -- against a measured floor instead of an assumed-clean one.
    balloon = nil
    local noiseB0 = peerBytes(true)
    fullCollect()
    local noiseA0 = countBytes()

    for _ = 1, 10 do peerBytes(false) end

    fullCollect()
    reportBytes('noise floor A / 10 reads', countBytes() - noiseA0)
    reportBytes('noise floor B / 10 reads', peerBytes(true) - noiseB0)

    -- (d) baseline ----------------------------------------------------------
    fullCollect()
    local baseA = countBytes()
    local baseB = peerBytes(true)
    reportBytes('baseline A (tickwatch-probe)', baseA)
    reportBytes('baseline B (tickwatch-probe-b)', baseB)

    -- (e) allocate ----------------------------------------------------------
    -- Numbers, not strings: strings intern and short ones are cached, which
    -- makes the expected size unpredictable. An array slot holds a TValue, so
    -- the prediction on Lua 5.4 is N * 16 bytes plus table overhead — and a
    -- delta that lands there confirms the count is real bytes for this state,
    -- not just a number that happened to move.
    balloon = {}
    for i = 1, BALLOON_N do
        balloon[i] = i
    end

    -- Growing the array rehashes repeatedly and leaves the discarded blocks
    -- behind. Collect so the delta reflects the live table rather than the cost
    -- of building it.
    fullCollect()

    local fullA = countBytes()
    local fullB = peerBytes(true)
    local dA = fullA - baseA
    local dB = fullB - baseB

    reportBytes('after balloon A', fullA)
    reportBytes('after balloon B', fullB)
    reportBytes('delta A', dA)
    reportBytes('delta B', dB)
    report('bytes per array slot', ('%.2f'):format(dA / BALLOON_N))

    -- (f) reversibility -----------------------------------------------------
    -- If dropping the reference does not return A to baseline, the rise was not
    -- the balloon and this run is not evidence of anything.
    balloon = nil
    fullCollect()
    local freeA = countBytes()
    reportBytes('after free A', freeA)
    reportBytes('residual vs baseline A', freeA - baseA)

    -- (g) verdict -----------------------------------------------------------
    -- Half of A's delta is a deliberately generous threshold: the two
    -- hypotheses predict ~100% and ~0%, so anything landing in between is not a
    -- close call, it is a result that needs explaining rather than classifying.
    local ratio = dA ~= 0 and (dB / dA * 100) or 0
    report('B moved as % of A', ('%.2f'):format(ratio))
    report('verdict', dB > (dA * 0.5)
        and 'SHARED — one state across resources'
        or  'per-resource — B did not move')
end

-- --------------------------------------------------------------------------
-- Q4b — TValue size and table growth
-- --------------------------------------------------------------------------
-- `probe memory` measured a 1,000,000-element array at 33,554,488 bytes, which
-- decomposes as 2^25 + 56 — an array block plus sizeof(Table). But 2^25 is
-- ambiguous: it is 2^20 slots of 32 bytes, and equally 2^21 slots of 16. The
-- two hypotheses differ by exactly 2x in BOTH capacity and slot size, so they
-- cancel in every power-of-two measurement and no amount of ballooning
-- separates them.
--
-- Breaking the tie needs an array whose capacity is NOT rounded to a power of
-- two, so that the divisor is known independently:
--
--   table.create(n)        presizes to exactly n, if this build has it
--   { 1, 1, 1, ... }       OP_NEWTABLE carries the literal item count, and
--                          luaH_resize applies it exactly — so a compiled
--                          constructor of n items gives capacity n
--
-- A long string anchors the whole thing: its size is length plus a header with
-- no rounding anywhere, so it independently confirms that collectgarbage
-- reports true bytes rather than some internal unit.

local STRING_LEN = 8 * 1024 * 1024
local EXACT_N = 100000

-- Second file-scope anchor, same reasoning as `balloon`.
local holder = nil

--- Delta in bytes across `build`, measured between full collections, with the
--- result held live at file scope so the second collect cannot reclaim it.
local function measure(build)
    holder = nil
    balloon = nil
    fullCollect()
    local before = countBytes()

    holder = build()

    fullCollect()
    local delta = countBytes() - before

    -- Reads the anchor as well as checking it. A build() that returned nil
    -- would leave a delta of roughly zero, which reads exactly like a
    -- successful measurement of something very small.
    assert(holder ~= nil, 'build() returned nil — nothing was held, delta is meaningless')

    holder = nil
    fullCollect()
    return delta
end

--- Exact-capacity table of n integers, and the name of the method used.
local function exactTable(n)
    if type(table.create) == 'function' then
        -- This build takes (narray, nhash) with BOTH required — calling it with
        -- one argument raises. Presizing maps straight through to luaH_resize,
        -- so the array part is exactly n with no rounding.
        return function()
            local t = table.create(n, 0)
            for i = 1, n do t[i] = i end
            return t
        end, 'table.create'
    end

    return function()
        -- The parts table and the source string are both transient; only the
        -- constructed table survives the collect in measure().
        local parts = {}
        for i = 1, n do parts[i] = '1' end
        return load('return {' .. table.concat(parts, ',') .. '}')()
    end, 'literal constructor'
end

probes.tvalue = function()
    header('Q4b TValue size and table growth')

    -- (a) byte anchor -------------------------------------------------------
    -- No power-of-two rounding applies to string contents, so this is a direct
    -- check that the reported unit really is bytes.
    local strDelta = measure(function()
        return string.rep('x', STRING_LEN)
    end)
    reportBytes(('string of %d bytes'):format(STRING_LEN), strDelta)
    report('string header overhead', strDelta - STRING_LEN, 'bytes')

    -- (b) growth staircase --------------------------------------------------
    -- Documents the rounding itself. Under Lua's rehash rule the optimal array
    -- size for all of 600000, 2^20 is 2^20, so those three should report an
    -- identical delta, and 2^20+1 should double.
    header('array growth (grown by assignment)')
    local sizes = { 524288, 600000, 1048576, 1048577 }
    for i = 1, #sizes do
        local n = sizes[i]
        local delta = measure(function()
            local t = {}
            for j = 1, n do t[j] = j end
            return t
        end)
        report(('N=%d'):format(n), ('%d bytes  = %.3f MiB'):format(
            math.floor(delta + 0.5),
            delta / 1048576
        ))
    end

    -- (c) the discriminator -------------------------------------------------
    header('exact-capacity array')
    local build, method = exactTable(EXACT_N)
    local exactDelta = measure(build)

    report('method', method)
    report('elements', EXACT_N)
    reportBytes('delta', exactDelta)

    -- sizeof(Table) is subtracted before dividing; the 1,000,000 run put it at
    -- 56 bytes, and it is a fixed header regardless of array length.
    local slot = (exactDelta - 56) / EXACT_N
    report('implied bytes per slot', ('%.3f'):format(slot))
    report('verdict', slot > 24
        and 'TValue = 32 bytes — widened union (LuaGLM vector types)'
        or  'TValue = 16 bytes — stock Lua layout, decomposition was wrong')
end

-- --------------------------------------------------------------------------
-- Q2 — SetHttpHandler thread affinity
-- --------------------------------------------------------------------------
-- Decides the shape of the Phase 1 serving path. Prometheus scrapes are pulls,
-- so the scrape rate is external input: if the handler holds the main thread,
-- render cost inside it is a server stall multiplied by a rate nobody controls,
-- and the metrics endpoint becomes a denial-of-service vector against the
-- server it exists to measure.
--
-- Two independent methods, on purpose:
--
--   tick counter   a thread increments `frames` every server frame. Read it
--                  either side of a block inside the handler. If the handler
--                  holds the main thread the counter CANNOT advance — it lives
--                  on that thread.
--   /perf/         the engine's own tickTime histogram, measured from outside.
--                  A ~200 ms block should put one observation in its 150-250 ms
--                  bucket against a baseline of 99.8% of ticks under 1 ms — the
--                  same technique that proved script execution runs inside
--                  svMain.
--
-- Drive from a second terminal, then read the results with `probe http`:
--
--   curl http://127.0.0.1:30130/tickwatch-probe/shape
--   curl http://127.0.0.1:30130/tickwatch-probe/block
--   curl http://127.0.0.1:30130/tickwatch-probe/wait
--   curl http://127.0.0.1:30130/tickwatch-probe/defer

local BLOCK_MS = 200
local DEFER_MS = 500

local frames = 0
local httpLog = {}
local httpSeq = 0
local httpActive = 0
local httpMaxActive = 0

Citizen.CreateThread(function()
    while true do
        frames = frames + 1
        Wait(0)
    end
end)

local function logLine(fmt, ...)
    httpLog[#httpLog + 1] = fmt:format(...)
end

--- Busy-wait. Deliberately does not call Wait: the entire point is to hold
--- whatever thread the handler was invoked on.
local function busyBlock(ms)
    local target = os.clock() + ms / 1000
    while os.clock() < target do end
end

--- Sorted `key:type` list, for recording the shape of req and res. Both are
--- undocumented, and calling the wrong method on res would look like the
--- feature being absent.
local function shapeOf(t)
    if type(t) ~= 'table' then
        return type(t)
    end

    local keys = {}
    local ok = pcall(function()
        for k, v in pairs(t) do
            keys[#keys + 1] = ('%s:%s'):format(tostring(k), type(v))
        end
    end)
    if not ok then
        return 'table (not enumerable)'
    end

    table.sort(keys)
    return #keys > 0 and table.concat(keys, ' ') or '(empty)'
end

--- Header and body support are themselves unknown, so both are attempted
--- inside pcall and the outcome recorded rather than assumed. Prometheus wants
--- a text/plain content type, which needs writeHead to exist.
local function respond(res, body)
    local okHead = pcall(function()
        res.writeHead(200, { ['Content-Type'] = 'text/plain; charset=utf-8' })
    end)
    local okSend = pcall(function()
        res.send(body)
    end)
    return okHead, okSend
end

local routes = {}

routes['/shape'] = function(req, res, id)
    logLine('[%d] req shape   %s', id, shapeOf(req))
    logLine('[%d] res shape   %s', id, shapeOf(res))
    logLine('[%d] method=%s path=%s address=%s',
        id,
        tostring(type(req) == 'table' and req.method or '?'),
        tostring(type(req) == 'table' and req.path or '?'),
        tostring(type(req) == 'table' and req.address or '?'))

    local okHead, okSend = respond(res, 'shape recorded\n')
    logLine('[%d] writeHead=%s send=%s', id, tostring(okHead), tostring(okSend))
end

-- Bearer auth reads exactly one header, and the case its key arrives in is not
-- documented. Guessing wrong is a 401 for every correctly-configured scrape,
-- with nothing in the log to say why — so the whole table is dumped verbatim,
-- keys quoted, and the query string is printed alongside `path` to settle
-- whether a route match has to strip one.
routes['/headers'] = function(req, res, id)
    local headers = type(req) == 'table' and req.headers or nil

    logLine('[%d] headers type   %s', id, type(headers))
    logLine('[%d] raw path       %q', id, tostring(type(req) == 'table' and req.path or '?'))
    logLine('[%d] method         %q', id, tostring(type(req) == 'table' and req.method or '?'))

    if type(headers) == 'table' then
        local keys = {}
        for k in pairs(headers) do keys[#keys + 1] = tostring(k) end
        table.sort(keys)

        for i = 1, #keys do
            logLine('[%d]   %q = %q', id, keys[i], tostring(headers[keys[i]]))
        end

        -- The two lookups a handler would actually write. Whichever of them is
        -- nil is the one that would have failed silently.
        logLine('[%d] ["Authorization"] = %s', id, tostring(headers['Authorization']))
        logLine('[%d] ["authorization"] = %s', id, tostring(headers['authorization']))
    end

    respond(res, 'headers recorded\n')
end

routes['/block'] = function(_req, res, id)
    local before = frames
    local t0 = os.clock()
    busyBlock(BLOCK_MS)
    local elapsed = os.clock() - t0
    local advanced = frames - before

    logLine('[%d] blocked %.3f s, frames advanced %d', id, elapsed, advanced)
    logLine('[%d] VERDICT %s', id, advanced == 0
        and 'MAIN THREAD — tick loop could not run'
        or  'off main thread — tick loop kept running')

    respond(res, ('blocked %.3f s, frames advanced %d\n'):format(elapsed, advanced))
end

routes['/wait'] = function(_req, res, id)
    -- If the handler body runs inside a coroutine, Wait yields and the frame
    -- counter advances across it. If it is a raw callback, this raises
    -- "attempt to yield from outside a coroutine" and the handler must be
    -- strictly synchronous — a hard constraint on Phase 1.
    local before = frames
    local ok, err = pcall(function()
        Wait(50)
    end)

    logLine('[%d] Wait(50) inside handler: ok=%s err=%s frames+%d',
        id, tostring(ok), tostring(err), frames - before)

    respond(res, ('wait ok=%s\n'):format(tostring(ok)))
end

routes['/defer'] = function(_req, res, id)
    -- Returns without sending. If the connection survives and the client gets
    -- a body DEFER_MS later, a slow render can complete off the request path
    -- and finish the response afterwards.
    logLine('[%d] deferring response by %d ms', id, DEFER_MS)

    Citizen.SetTimeout(DEFER_MS, function()
        local okHead, okSend = respond(res, 'deferred response\n')
        logLine('[%d] deferred send: writeHead=%s send=%s',
            id, tostring(okHead), tostring(okSend))
    end)
end

-- --------------------------------------------------------------------------
-- Driving a probe over HTTP
-- --------------------------------------------------------------------------
-- The console is the natural way to run a probe and a poor way to collect one:
-- its output cannot be read from outside the process, so a sweep has to be
-- re-run to be transcribed, and a re-run is a different measurement. `/run`
-- starts a probe, `/log` returns everything emitted so far.

--- Path segments, query string discarded.
local function segmentsOf(path)
    local segs = {}
    for s in path:gsub('%?.*$', ''):gmatch('[^/]+') do
        segs[#segs + 1] = s
    end
    return segs
end

--- Loopback only. This handler is served on the public game port and `/run`
--- spawns hundreds of entities, which is not something a stranger should be able
--- to do to a server — throwaway research resource or not.
local function isLoopback(req)
    local addr = type(req) == 'table' and tostring(req.address) or ''
    return addr:find('127.0.0.1', 1, true) ~= nil
        or addr:find('::1', 1, true) ~= nil
        or addr:find('localhost', 1, true) ~= nil
end

local function runRoute(req, res, segs)
    local name = segs[2]
    local fn = name and probes[name]

    if not isLoopback(req) then
        respond(res, 'refused — loopback only\n')
        return
    end
    if not fn then
        respond(res, ('no such probe: %s\n'):format(tostring(name)))
        return
    end

    -- Started on its own thread and answered immediately. Q2 established that
    -- handlers hold the main thread, so running a multi-second sweep inline would
    -- stall the server for its full duration — and time the sweep from inside its
    -- own stall.
    Citizen.CreateThread(function()
        local ok, err = pcall(fn, table.unpack(segs, 3, #segs))
        if not ok then
            emit(('[probe] ERROR in %s: %s'):format(name, tostring(err)))
        end
    end)

    respond(res, ('started %s — poll /tickwatch-probe/log\n'):format(name))
end

SetHttpHandler(function(req, res)
    httpSeq = httpSeq + 1
    local id = httpSeq

    httpActive = httpActive + 1
    if httpActive > httpMaxActive then
        httpMaxActive = httpActive
    end

    local path = type(req) == 'table' and tostring(req.path) or '?'
    local segs = segmentsOf(path)
    local route = routes[path]

    logLine('[%d] enter %s (active=%d)', id, path, httpActive)

    local ok, err = pcall(function()
        if segs[1] == 'log' then
            respond(res, table.concat(outLines, '\n') .. '\n')
        elseif segs[1] == 'run' then
            runRoute(req, res, segs)
        elseif route then
            route(req, res, id)
        else
            respond(res, 'routes: /shape /headers /block /wait /defer /log /run/<probe>[/<arg>]\n')
        end
    end)

    if not ok then
        logLine('[%d] handler error: %s', id, tostring(err))
        pcall(function() res.send('handler error\n') end)
    end

    logLine('[%d] exit  %s (active=%d)', id, path, httpActive)
    httpActive = httpActive - 1
end)

probes.http = function()
    header('Q2 SetHttpHandler thread affinity')

    report('endpoint', 'http://127.0.0.1:30130/tickwatch-probe/<route>')
    report('routes', 'shape, block, wait, defer')
    report('requests seen', httpSeq)

    -- Overlapping enter/exit pairs mean the handler is re-entered before the
    -- previous one finished. Only meaningful if requests were actually issued
    -- concurrently — /block holds for 200 ms, which is the window to do it in.
    report('max concurrent handlers', httpMaxActive)
    report('concurrency', httpMaxActive > 1
        and 'INTERLEAVED — registry is shared mutable state'
        or  'serialized — no interleaving observed')

    if #httpLog == 0 then
        report('log', 'empty — curl the endpoint first')
        return
    end

    header('handler log')
    for i = 1, #httpLog do
        emit(('[probe]   %s'):format(httpLog[i]))
    end
end

AddEventHandler('onResourceStart', function(resource)
    if resource ~= GetCurrentResourceName() then
        return
    end
    print('[probe] http endpoint — http://127.0.0.1:30130/tickwatch-probe/shape')
end)

-- --------------------------------------------------------------------------
-- Q5 — entity enumeration cost
-- --------------------------------------------------------------------------
-- `GetAllVehicles()` returns a fresh table of every vehicle handle on the
-- server. The exporter wants that as a gauge on an interval, so the question is
-- not "is it fast" but "what does one sample cost as a function of population",
-- because the answer sets the interval — and a wrong interval makes the exporter
-- into the kind of stall it exists to report.
--
-- Two costs, not one:
--
--   wall time    Q2 established that everything here runs on the main thread,
--                so this is simulation time not spent simulating.
--   allocation   a table of n handles, built and discarded every sample. Q4
--                established the GC is per-resource and Q4b that a value costs
--                32 bytes, so this garbage lands in our own memory gauge. The
--                prediction to check against is n * 32 + 56, rounded up to a
--                power-of-two capacity.
--
-- Three things the measurement has to get right:
--
--   a populated server   on an empty one the native returns an empty table and
--                        all that was measured is call overhead
--   several levels       one population gives a point and no shape; only the
--                        shape extrapolates to a server that can't be
--                        reproduced locally, and it separates the fixed floor
--                        from the per-entity term
--   N calls, not one     Q3 measured the clock at 1 ms. A single call here is
--                        far below that and reads as 0 or 1 — noise. Same fix
--                        as the clock probe: time many, divide.

local SPAWN_MODEL = 'blista'
local PED_MODEL = 'a_m_y_skater_01'

-- Airport apron: flat, open, and far from anywhere qb spawns players.
local SPAWN_X, SPAWN_Y, SPAWN_Z = -1336.0, -3044.0, 13.9
local SPAWN_STRIDE = 6.0
local SPAWN_ROW = 25

-- 250 ms of samples against a 1 ms clock is ~0.4% quantization error. Enough
-- precision without leaving the server stalled for a noticeable stretch.
local TIMING_TARGET = 0.25
local TIMING_MAX_CALLS = 2000000

-- Trials per measurement, reduced by median. One trial is not enough where it
-- matters most: an expensive call reaches the 250 ms target in few repetitions,
-- so a single server hitch or GC cycle landing inside it moves the whole figure.
-- That is not hypothetical — it produced a 33% outlier at the top of the vehicle
-- staircase, the one point in that sweep with the fewest repetitions behind it.
local TIMING_TRIALS = 5

local ENUMERATORS = { 'GetAllVehicles', 'GetAllPeds', 'GetAllObjects' }

local CURVE_STEPS = { 0, 50, 100, 200, 400 }

-- Crosses the native bridge and touches no entity pool. Q3 measured it at 115 ns
-- on an empty server, so it is a fixed point: if enumerator cost rises across the
-- staircase because the SERVER got busier rather than because a list got longer,
-- this rises with it. Flat here means the rise below is traversal.
local INERT_NATIVE = 'GetGameTimer'

-- Pre-registered from the vehicle staircase, so the ped run is compared against
-- a model chosen BEFORE its data rather than a curve fitted afterwards.
--
--   accepted entity   ~46.8 ns — walked, then written across the bridge
--   rejected entity   ~4.0 ns  — walked, type tag compared, skipped
--   fixed term        0.9 us with an array to allocate, 0.37 us returning empty
--
-- If the shared-traversal reading is right these are properties of the list and
-- must reproduce with peds in the slots. If they are really vehicle simulation
-- cost, there is no reason for them to.
local MODEL_PER_ACCEPTED = 46.8e-9
local MODEL_PER_REJECTED = 4.0e-9
local MODEL_FIXED_FULL = 0.9e-6
local MODEL_FIXED_EMPTY = 0.37e-6

--- What the cost model predicts for one enumerator returning `count` entities on
--- a server holding `total` of every type.
local function predictCost(count, total)
    local fixed = count > 0 and MODEL_FIXED_FULL or MODEL_FIXED_EMPTY
    return fixed
        + MODEL_PER_ACCEPTED * count
        + MODEL_PER_REJECTED * math.max(total - count, 0)
end

local spawned = {}
local spawnedKind = nil

--- Natives may be materialised lazily through a metatable on _G rather than
--- being present as plain keys, so index by name instead of trusting pairs().
local function nativeByName(name)
    local ok, fn = pcall(function() return _G[name] end)
    if not ok then
        return nil
    end
    return type(fn) == 'function' and fn or nil
end

--- True only if the handle names a live entity.
---
--- `DoesEntityExist` returns 1/0 on this build, not true/false — and 0 is
--- TRUTHY in Lua, so `if DoesEntityExist(h) then` is always taken. Normalise at
--- the edge rather than trusting the idiom. Same class of trap as Q2's callable
--- tables: the guard does not fail loudly, it just stops guarding.
local function entityExists(handle)
    if not handle or handle == 0 then
        return false
    end
    local r = DoesEntityExist(handle)
    return r == true or r == 1
end

--- Mean cost of one call, in seconds. Doubles the call count until the total
--- clears TIMING_TARGET, so the divisor adapts to whatever the call costs
--- instead of being guessed in advance.
---
--- The figure deliberately INCLUDES the GC's share of collecting the garbage
--- these calls create. That is the cost the sampling interval actually pays;
--- measuring the call with its allocation cost subtracted out would flatter it.
local function timeOnce(fn, calls)
    local t0 = os.clock()
    for _ = 1, calls do
        fn()
    end
    return os.clock() - t0
end

--- Returns median seconds per call, the call count used, and the spread across
--- trials as a percentage of the median.
---
--- The spread is returned rather than discarded because it is the reader's only
--- signal that a figure is soft. A 2% spread and a 30% spread carry the same
--- median and should not be quoted with the same confidence.
local function timeCall(fn)
    -- Calibrate: grow the call count until one trial clears the target, so the
    -- divisor adapts to whatever the call costs instead of being guessed.
    local calls = 64
    local elapsed = timeOnce(fn, calls)
    while elapsed < TIMING_TARGET and calls * 4 <= TIMING_MAX_CALLS do
        calls = calls * 4
        elapsed = timeOnce(fn, calls)
    end

    local samples = {}
    for i = 1, TIMING_TRIALS do
        samples[i] = timeOnce(fn, calls) / calls
    end
    table.sort(samples)

    local median = samples[(TIMING_TRIALS + 1) // 2]
    local spread = median > 0
        and (samples[TIMING_TRIALS] - samples[1]) / median * 100
        or 0

    return median, calls, spread
end

--- One enumerator, measured. Returns a row, or nil plus the reason it is void.
local function measureEnumerator(name)
    local fn = nativeByName(name)
    if not fn then
        return nil, 'absent on this build'
    end

    local ok, warm = pcall(fn)
    if not ok then
        return nil, 'raised: ' .. tostring(warm)
    end
    if type(warm) ~= 'table' then
        return nil, 'returned ' .. type(warm) .. ', not a table'
    end

    -- Other resources spawn and despawn things. Bracket the timed run with a
    -- count and throw the sample away if the population moved underneath it.
    local before = #fn()
    local perCall, calls, spread = timeCall(fn)
    local after = #fn()

    if before ~= after then
        return nil, ('population moved %d -> %d mid-run'):format(before, after)
    end

    -- measure() collects either side and holds the result live, so the delta is
    -- the retained table rather than the cost of building it.
    local bytes = measure(fn)

    return {
        name = name,
        count = before,
        perCall = perCall,
        calls = calls,
        spread = spread,
        bytes = bytes,
        element = type(warm[1]),
    }
end

--- `total` is the whole server population across every entity type. Under the
--- shared-traversal reading that, not `row.count`, is what sets the cost — which
--- is exactly the claim the ped staircase exists to test, so it is printed for
--- every row including the ones that returned nothing.
local function reportRow(row, total)
    report(row.name, ('%d entities  (server total %d)'):format(row.count, total or row.count))
    report('  per call', ('%.3f us  (median of %d x %d calls, spread %.1f%%)'):format(
        row.perCall * 1e6, TIMING_TRIALS, row.calls, row.spread))

    if row.count > 0 then
        report('  per entity', ('%.1f ns'):format(row.perCall * 1e9 / row.count))
    end

    if total and total > 0 then
        -- The falsifiable line. Deviation is against the vehicle-derived model,
        -- so a ped run landing within a few percent is the symmetry result and a
        -- run landing far off is not a noisy confirmation, it is a refutation.
        local predicted = predictCost(row.count, total)
        report('  vs model', ('%.3f us predicted, %+.1f%%'):format(
            predicted * 1e6,
            (row.perCall / predicted - 1) * 100))
    end

    report('  allocation', ('%d bytes'):format(math.floor(row.bytes + 0.5)))

    if row.count > 0 then
        -- Q4b's layout, applied forward. A delta near the prediction says the
        -- return really is a flat array of handles; far above it says the table
        -- holds something richer and the memory story changes.
        report('  vs 32B/slot + 56', ('%d predicted, element type %s'):format(
            row.count * 32 + 56, row.element))
    end
end

--- Total live entities across all three pools, and the per-type counts.
local function populationCounts()
    local counts, total = {}, 0
    for i = 1, #ENUMERATORS do
        local fn = nativeByName(ENUMERATORS[i])
        local n = fn and #fn() or 0
        counts[ENUMERATORS[i]] = n
        total = total + n
    end
    return counts, total
end

--- The inert control, measured with the same timing loop as everything else so
--- a change in the loop itself cannot show up as a change in only one row.
local function reportInert()
    local fn = nativeByName(INERT_NATIVE)
    if not fn then
        report(INERT_NATIVE .. ' (inert control)', 'absent')
        return
    end

    local perCall, calls, spread = timeCall(fn)
    report(INERT_NATIVE .. ' (inert control)',
        ('%.3f us  (median of %d x %d calls, spread %.1f%%)'):format(
            perCall * 1e6, TIMING_TRIALS, calls, spread))
end

probes.entities = function()
    header('Q5 entity enumeration cost')

    -- (a) existence sweep ---------------------------------------------------
    -- A count-only native would allocate nothing and dissolve this question for
    -- the gauges, so enumerate before concluding one does not exist. Report the
    -- global count too: if _G turns out not to be enumerable, an empty hit list
    -- means nothing and only the named checks below carry weight.
    local patterns = { 'getall', 'getnum', 'poolsize', 'pool', 'entitycount' }
    local hits, globals = {}, 0

    for k, v in pairs(_G) do
        globals = globals + 1
        if type(k) == 'string' and type(v) == 'function' then
            local lower = k:lower()
            for i = 1, #patterns do
                if lower:find(patterns[i], 1, true) then
                    hits[#hits + 1] = k
                    break
                end
            end
        end
    end
    table.sort(hits)

    report('globals enumerated', globals)
    report('candidate natives', #hits)
    for i = 1, #hits do
        emit(('[probe]   %s'):format(hits[i]))
    end

    -- Named checks, which work even if _G hides natives behind __index.
    local named = {}
    for i = 1, #ENUMERATORS do
        named[#named + 1] = ('%s=%s'):format(
            ENUMERATORS[i], nativeByName(ENUMERATORS[i]) and 'y' or 'n')
    end
    report('by name', table.concat(named, ' '))

    -- (b) cost at the current population ------------------------------------
    header('cost at current population')

    local _, total = populationCounts()
    reportInert()

    for i = 1, #ENUMERATORS do
        local row, why = measureEnumerator(ENUMERATORS[i])
        if row then
            reportRow(row, total)
        else
            report(ENUMERATORS[i], 'no result — ' .. why)
        end
    end

    report('spawned by probe', #spawned)
    if #spawned == 0 then
        report('note', 'empty server — run `probe curve`, or spawn first')
    end
end

-- --------------------------------------------------------------------------
-- population control
-- --------------------------------------------------------------------------

-- Q5a settled which creation path works headless for each type: plain
-- CreateVehicle returns 0 because it cannot resolve the vehicle type
-- server-side, the setter takes that type as an explicit argument and works;
-- CreatePed works unmodified; CreateObject is refused and stays undiagnosed.
--
-- Both entries below are known-good paths with no client connected. Keeping them
-- in one table means the vehicle and ped staircases run through identical timing,
-- measurement and cleanup code — if the two sweeps disagree, the difference is
-- the entity type and not the harness.
local SPAWN_TYPES = {
    vehicle = {
        enumerator = 'GetAllVehicles',
        native = 'CreateVehicleServerSetter',
        model = SPAWN_MODEL,
        make = function(fn, model, x, y, z)
            return fn(model, 'automobile', x, y, z, 0.0)
        end,
    },
    ped = {
        enumerator = 'GetAllPeds',
        native = 'CreatePed',
        model = PED_MODEL,
        make = function(fn, model, x, y, z)
            return fn(4, model, x, y, z, 0.0, true, true)
        end,
    },
}

local function spawnEntities(kind, n)
    local spec = SPAWN_TYPES[kind]
    if not spec then
        return 0, n, ('unknown spawn type %q'):format(tostring(kind))
    end

    local create = nativeByName(spec.native)
    if not create then
        return 0, n, spec.native .. ' absent server-side'
    end

    local model = GetHashKey(spec.model)
    local created, failed = 0, 0

    for _ = 1, n do
        local idx = #spawned
        local ok, handle = pcall(
            spec.make,
            create,
            model,
            SPAWN_X + (idx % SPAWN_ROW) * SPAWN_STRIDE,
            SPAWN_Y + math.floor(idx / SPAWN_ROW) * SPAWN_STRIDE,
            SPAWN_Z
        )

        -- A returned handle is not proof of existence: server-side creation can
        -- hand back a value for an entity that never materialises. Check.
        if ok and entityExists(handle) then
            spawned[#spawned + 1] = handle
            spawnedKind = kind
            created = created + 1
        else
            failed = failed + 1
        end
    end

    return created, failed
end

local function despawnAll()
    local removed = 0
    for i = #spawned, 1, -1 do
        if entityExists(spawned[i]) then
            DeleteEntity(spawned[i])
            removed = removed + 1
        end
        -- Left as a per-slot nil rather than `spawned = {}` on purpose. The
        -- vehicle sweep closed with a 20,096-byte residual, most of which is this
        -- table keeping its 512-slot array capacity after the elements are gone.
        -- The ped sweep should reproduce it to within a few hundred bytes,
        -- because the retention is a property of this Lua table and has nothing
        -- to do with what the handles pointed at. Changing the line here would
        -- discard that prediction rather than test it.
        spawned[i] = nil
    end
    spawnedKind = nil
    return removed
end

probes.spawn = function(arg, kind)
    kind = kind or 'vehicle'
    local n = tonumber(arg)
    local spec = SPAWN_TYPES[kind]

    if not n or n < 1 or not spec then
        report('usage', 'probe spawn <count> [vehicle|ped]')
        return
    end

    header(('spawning %d %s (%s)'):format(n, kind, spec.model))
    local created, failed, err = spawnEntities(kind, math.floor(n))

    report('created', created)
    report('failed', failed)
    if err then
        report('error', err)
    end

    local fn = nativeByName(spec.enumerator)
    if fn then
        -- The independent check: the spawner's own tally is not evidence that
        -- the enumerator can see them.
        report(spec.enumerator .. ' now reports', #fn())
    end
end

probes.despawn = function()
    header('despawning')
    local removed = despawnAll()
    report('deleted', removed)

    local counts = populationCounts()
    for i = 1, #ENUMERATORS do
        report(ENUMERATORS[i] .. ' now reports', counts[ENUMERATORS[i]])
    end
end

-- --------------------------------------------------------------------------
-- Q5a — why did spawning fail?
-- --------------------------------------------------------------------------
-- `probe curve` reported 400 failures and zero creations, but the spawner folds
-- every failure mode into one tally, so "it failed" is all that was measured.
-- These are not the same finding and they do not have the same fix:
--
--   handle 0/nil            the native refused — signature, model, or OneSync
--   handle, exists=false    nothing was ever made under that handle
--   exists, then gone       it WAS created and something reaped it, which is
--                           the ownerless-entity hypothesis
--
-- Hence two existence checks per attempt, one immediately and one a tick later.
-- Immediate-false and later-false read identically in a pass/fail count and mean
-- opposite things.
--
-- Three creation paths, because a vehicle-specific failure and a general one are
-- also different findings. CreateVehicleServerSetter takes the vehicle type as
-- an explicit argument, so if plain CreateVehicle fails and the setter succeeds,
-- the cause was type resolution and not ownership at all.

local DIAG_TYPES = { 'GetAllVehicles', 'GetAllPeds', 'GetAllObjects' }

--- Population across all three enumerators, as a compact string.
local function population()
    local parts = {}
    for i = 1, #DIAG_TYPES do
        local fn = nativeByName(DIAG_TYPES[i])
        parts[#parts + 1] = ('%s=%s'):format(
            DIAG_TYPES[i]:gsub('GetAll', ''),
            fn and #fn() or '?'
        )
    end
    return table.concat(parts, ' ')
end

probes.spawndiag = function()
    Citizen.CreateThread(function()
        header('Q5a spawn failure diagnosis')

        -- Context first. A wrong hash or a disabled OneSync would explain
        -- everything below and must be ruled out before anything else is read.
        report('onesync', GetConvar('onesync', '(empty)'))
        report('onesync_population', GetConvar('onesync_population', '(empty)'))
        report('players connected', GetNumPlayerIndices())
        report('model', ('%s -> %d'):format(SPAWN_MODEL, GetHashKey(SPAWN_MODEL)))
        report('population before', population())

        local model = GetHashKey(SPAWN_MODEL)

        local attempts = {
            {
                name = 'CreateVehicle',
                make = function(fn)
                    return fn(model, SPAWN_X, SPAWN_Y, SPAWN_Z, 0.0, true, true)
                end,
            },
            {
                name = 'CreateVehicleServerSetter',
                make = function(fn)
                    return fn(model, 'automobile', SPAWN_X + 10.0, SPAWN_Y, SPAWN_Z, 0.0)
                end,
            },
            {
                name = 'CreatePed',
                make = function(fn)
                    return fn(4, GetHashKey(PED_MODEL),
                        SPAWN_X + 20.0, SPAWN_Y, SPAWN_Z, 0.0, true, true)
                end,
            },
            {
                name = 'CreateObject',
                make = function(fn)
                    return fn(GetHashKey('prop_barrier_work05'),
                        SPAWN_X + 30.0, SPAWN_Y, SPAWN_Z, true, true, false)
                end,
            },
        }

        for i = 1, #attempts do
            local a = attempts[i]
            local fn = nativeByName(a.name)

            header(a.name)
            if not fn then
                report('native', 'absent server-side')
                goto continue
            end

            do
                local ok, handle = pcall(a.make, fn)
                if not ok then
                    report('raised', tostring(handle))
                    goto continue
                end

                report('returned', ('%s (%s)'):format(tostring(handle), type(handle)))

                local existsNow = entityExists(handle)
                report('exists immediately', tostring(existsNow))
                report('population immediately', population())

                Wait(500)

                local existsLater = entityExists(handle)
                report('exists after 500ms', tostring(existsLater))
                report('population after', population())

                report('verdict',
                    (not handle or handle == 0) and 'native refused — no handle'
                    or (not existsNow) and 'handle returned but nothing created'
                    or (not existsLater) and 'CREATED THEN REAPED — ownerless entity'
                    or 'alive — spawning works headless')

                if existsLater then
                    DeleteEntity(handle)
                end
            end

            ::continue::
        end

        report('population after cleanup', population())
    end)
end

-- --------------------------------------------------------------------------
-- Q5 — the staircase
-- --------------------------------------------------------------------------
-- Spawns incrementally to each level and measures all three enumerators there,
-- so one command produces the whole curve rather than a point.
--
-- The enumerators that return nothing are the control. Spawning vehicles, only
-- `GetAllVehicles` should have anything to walk — and yet ped and object cost
-- rose ~4 ns per vehicle anyway, which reads as one shared entity list walked
-- and filtered by type rather than three per-type pools.
--
-- Q5c: `probe curve ped` is the symmetry test of that reading, and the reason
-- this takes a type argument at all. The rival explanation for the same data is
-- that 400 vehicles simply make the server busier and inflate every timing. That
-- rival predicts nothing in particular; the shared-list reading predicts a
-- specific number, because the cost of stepping a list node and rejecting a type
-- tag is a property of the LIST and cannot depend on what occupies the slot. So:
--
--   shared list      GetAllVehicles (0 results) rises ~4 ns per PED, matching the
--                    4.05 and 4.00 ns/vehicle already measured, and GetAllPeds
--                    follows the same 0.9 us + 46.8 ns/entity model
--   general load     the rise is ped simulation cost, which has no reason to land
--                    on the same figure as vehicle physics
--
-- `GetAllObjects` returns zero in BOTH sweeps and is measured by identical code,
-- so it is the cleanest single comparison available.
--
-- Runs in a thread because it needs Wait() between levels, which a command
-- handler cannot do.

probes.curve = function(kind)
    kind = kind or 'vehicle'
    local spec = SPAWN_TYPES[kind]
    if not spec then
        report('usage', 'probe curve [vehicle|ped]')
        return
    end

    Citizen.CreateThread(function()
        header(('Q5 population staircase — %s'):format(kind))
        report('spawn type', ('%s via %s'):format(spec.model, spec.native))
        report('accepted enumerator', spec.enumerator)

        -- Leftovers from an earlier sweep would offset every level, and a
        -- non-zero baseline in a pool this run does not touch would break the
        -- "returned nothing" reading of the control rows. Both get cleared or
        -- stated rather than assumed.
        if #spawned > 0 then
            report('pre-existing probe entities', #spawned)
            report('cleared', despawnAll())
            Wait(500)
        end

        local baseline, baseTotal = populationCounts()
        for i = 1, #ENUMERATORS do
            report('baseline ' .. ENUMERATORS[i], baseline[ENUMERATORS[i]])
        end
        if baseTotal > 0 then
            report('WARNING', 'server not empty — levels are offset by the above')
        end

        -- Taken so the reading after cleanup has something to be compared
        -- against. Without it the closing number is a value, not a control.
        fullCollect()
        local heapBefore = countBytes()
        report('resource heap before', ('%d bytes'):format(
            math.floor(heapBefore + 0.5)))

        for i = 1, #CURVE_STEPS do
            local target = CURVE_STEPS[i]
            local deficit = target - #spawned

            if deficit > 0 then
                local created, failed, err = spawnEntities(kind, deficit)
                if created < deficit then
                    report('spawn shortfall', ('%d of %d created, %d failed%s'):format(
                        created, deficit, failed, err and (' — ' .. err) or ''))
                end
            end

            -- Let the server settle: creation may need a tick to register, and
            -- measuring inside that window would undercount.
            Wait(500)

            local _, total = populationCounts()
            header(('level: %d spawned, %d entities on server'):format(#spawned, total))

            -- First, because it is the within-sweep discriminator. If this rises
            -- alongside the enumerators then the server got slower generally and
            -- nothing below is evidence of traversal.
            reportInert()

            for j = 1, #ENUMERATORS do
                local row, why = measureEnumerator(ENUMERATORS[j])
                if row then
                    reportRow(row, total)
                else
                    report(ENUMERATORS[j], 'no result — ' .. why)
                end
            end
        end

        header('cleanup')
        report('deleted', despawnAll())

        -- Closing control: the heap must come back. A residual means the sweep
        -- leaked, and any allocation figure above it is suspect.
        Wait(500)
        fullCollect()
        local heapAfter = countBytes()
        report('resource heap after', ('%d bytes'):format(
            math.floor(heapAfter + 0.5)))
        report('residual vs before', ('%d bytes'):format(
            math.floor(heapAfter - heapBefore + 0.5)))
    end)
end

-- --------------------------------------------------------------------------
-- Q6 — is a publicly-readable convar detectable from a script?
-- --------------------------------------------------------------------------
-- Exporter config comes from convars, including the scrape auth token. An
-- operator who writes `setr` where they meant `set` broadcasts that token to
-- every connecting client and publishes it in the server's own unauthenticated
-- /info.json. The exporter should catch that at startup and refuse to serve —
-- which it can only do if the condition is observable from a server script.
--
-- The obvious experiment is `set` against `setr`, and it is under-specified.
-- There are THREE verbs:
--
--   set    server only
--   sets   server info — published in /info.json, NOT pushed to clients
--   setr   replicated — pushed to clients
--
-- With two arms, a hit in /info.json gets attributed to replication when `sets`
-- produces the same hit for an entirely different reason. The write-up would be
-- confidently wrong. Hence three.
--
-- It also reframes the question. What the exporter needs to know is not "is this
-- convar replicated" but "is this convar's value publicly readable", and `setr`
-- is only one of two routes there — a check that catches only `setr` still leaks
-- a `sets` token.
--
-- Convars cannot be removed once created, so the arm names survive until the
-- server restarts. A second run in the same session is therefore void, and the
-- probe checks for its own leftovers before trusting anything.

-- First attempt drove all three through `ExecuteCommand('set name value')`. Every
-- call returned success and not one convar existed afterwards — GetConvar read
-- `(absent)` for all three and none reached /info.json. A silent no-op, and it
-- would have read as "no verb is detectable" if the read-back control had not
-- been there to catch it.
--
-- The native sweep in the same run supplied the fix: SetConvar,
-- SetConvarServerInfo and SetConvarReplicated all exist, and map exactly onto
-- set / sets / setr. The console path is kept as a fourth arm so the failure is
-- recorded rather than discarded — a Phase 1 resource that needs to write a
-- convar has to know which route actually works.
--
-- Fresh names: the first arms are believed clean, but anything that lands late
-- would silently poison a rerun, and names are free.
-- Names are deliberately opaque and equal-shaped. The previous attempt named them
-- after their verb — `tickwatch_probe_b_set`, `tickwatch_probe_b_sets` — and `..._set` is a
-- PREFIX of `..._sets`, so a plain substring search for the first matched the
-- second's key and reported it present when it was not. Cost: one run, and it
-- inverted the headline result. Keys are now searched quoted (`"name"`) as well,
-- which is exact against JSON, but names that cannot collide are the real fix.
local CONVAR_ARMS = {
    { label = 'SetConvar', setter = 'SetConvar',
      name = 'tickwatch_probe_c_alpha', value = 'twv_alpha_c31' },
    { label = 'SetConvarServerInfo', setter = 'SetConvarServerInfo',
      name = 'tickwatch_probe_c_bravo', value = 'twv_bravo_c31' },
    { label = 'SetConvarReplicated', setter = 'SetConvarReplicated',
      name = 'tickwatch_probe_c_delta', value = 'twv_delta_c31' },
    { label = 'ExecuteCommand set', setter = false,
      name = 'tickwatch_probe_c_echo', value = 'twv_echo_c31' },
}

-- Declared in server.cfg, never written from here — and they are the arms that
-- actually answer Q6.
--
-- The natives above are not evidence about the console verbs. `SetConvarReplicated`
-- is a native whose relationship to the `setr` COMMAND is an assumption, and the
-- question Q6 asks is what happens when an operator types `setr` in their config.
-- Substituting the native for the verb because ExecuteCommand refused to work
-- would answer a question nobody asked. These require a full server restart to
-- take effect, not a resource restart.
local CFG_ARMS = {
    { label = 'cfg set', name = 'tickwatch_cfg_foxtrot', value = 'twv_foxtrot_c31' },
    { label = 'cfg sets', name = 'tickwatch_cfg_golf', value = 'twv_golf_c31' },
    { label = 'cfg setr', name = 'tickwatch_cfg_hotel', value = 'twv_hotel_c31' },
}

--- Every arm, for the read-only checks. Only CONVAR_ARMS are written or blanked.
local ALL_ARMS = {}
for i = 1, #CONVAR_ARMS do ALL_ARMS[#ALL_ARMS + 1] = CONVAR_ARMS[i] end
for i = 1, #CFG_ARMS do ALL_ARMS[#ALL_ARMS + 1] = CFG_ARMS[i] end

local CONVAR_POLL_ATTEMPTS = 10
local CONVAR_POLL_INTERVAL = 500

--- Base URL of this server's own HTTP endpoint.
local function selfBase()
    local ep = GetConvar('endpoint_add_tcp', '')
    local port = ep:match(':(%d+)')
    return ('http://127.0.0.1:%s'):format(port or '30130'), ep
end

--- Blocking GET. PerformHttpRequest is callback-based, so the caller must be on
--- a thread that can Wait. This is an OUTBOUND request and does not go through
--- SetHttpHandler, but it does target our own process, so a timeout here would
--- itself be the finding — hence a bounded wait rather than an open one.
local function httpGet(url, timeoutMs)
    local done, code, body = false, nil, nil

    local ok, err = pcall(function()
        PerformHttpRequest(url, function(c, d)
            code, body, done = c, d, true
        end, 'GET', '', {})
    end)
    if not ok then
        return nil, 'PerformHttpRequest raised: ' .. tostring(err)
    end

    local deadline = GetGameTimer() + (timeoutMs or 5000)
    while not done and GetGameTimer() < deadline do
        Wait(25)
    end

    if not done then
        return nil, 'timeout'
    end
    return body, code
end

--- Which arm names, and which arm values, occur in a response body. Name and
--- value are checked separately: a key present with an empty value is a
--- different result from the key being absent, and the cleanup step below turns
--- on exactly that distinction.
local function findArms(body)
    local found = {}
    for i = 1, #ALL_ARMS do
        local a = ALL_ARMS[i]
        -- Quoted on both sides. An unquoted search for `foo` also matches the key
        -- `foos`, which is how the previous run produced a false positive.
        found[a.name] = {
            name = body and body:find('"' .. a.name .. '"', 1, true) ~= nil or false,
            value = body and body:find('"' .. a.value .. '"', 1, true) ~= nil or false,
        }
    end
    return found
end

probes.convars = function()
    Citizen.CreateThread(function()
        header('Q6 publicly-readable convar detection')

        local base, ep = selfBase()
        report('endpoint_add_tcp', ep ~= '' and ep or '(empty — port assumed)')
        report('self endpoint', base)

        -- (a) baseline, and the leftover check ------------------------------
        local info0, err0 = httpGet(base .. '/info.json')
        if not info0 then
            report('/info.json', 'unreachable — ' .. tostring(err0))
            report('verdict', 'CANNOT RUN')
            return
        end
        report('/info.json bytes', #info0)

        local pre = findArms(info0)
        for i = 1, #CONVAR_ARMS do
            local a = CONVAR_ARMS[i]
            if pre[a.name].name then
                report('WARNING', a.name .. ' already present — leftovers from an')
                report('', 'earlier run in this session. Restart before trusting this.')
            end
        end

        -- Closes a separate gap while the payload is in hand: GetConvar returns
        -- empty for `gamename` on this build, and /info.json publishes it. If the
        -- self-HTTP route works, it is also the source for that metric label.
        header('values GetConvar cannot supply')
        report('GetConvar gamename', GetConvar('gamename', '(empty)'))
        report('/info.json gamename', info0:match('"gamename"%s*:%s*"([^"]*)"') or '(not found)')

        -- (b) one convar per verb -------------------------------------------
        header('setting one convar per verb')
        for i = 1, #CONVAR_ARMS do
            local a = CONVAR_ARMS[i]
            local ok

            if a.setter then
                local fn = nativeByName(a.setter)
                ok = fn and select(1, pcall(fn, a.name, a.value)) or false
            else
                ok = select(1, pcall(ExecuteCommand,
                    ('set %s %s'):format(a.name, a.value)))
            end

            report(a.label, ('%s = %s  (call ok=%s)'):format(a.name, a.value, tostring(ok)))
        end

        -- ExecuteCommand is queued rather than applied inline, so give the
        -- console arm room to land before reading anything back. A short wait
        -- would make a slow path look like a broken one.
        Wait(1000)

        -- (c) can the script tell them apart at the point of use? ------------
        header('GetConvar read-back')
        local allRead = true
        for i = 1, #ALL_ARMS do
            local a = ALL_ARMS[i]
            local v = GetConvar(a.name, '(absent)')
            report(a.label .. ' -> GetConvar', v)
            if v ~= a.value then
                allRead = false
            end
        end
        report('never-set control', GetConvar('tickwatch_probe_b_missing', '(absent)'))
        report('reading', allRead
            and 'all arms read back their value — GetConvar gives NO signal'
            or  'some arm did not take — inspect above before concluding')

        -- (d) /info.json, polled ---------------------------------------------
        -- Polled rather than read once: if the payload is cached, a single early
        -- read returns "absent", which is indistinguishable from the interesting
        -- result. The delay at which each arm appears is itself the answer to
        -- whether a startup check can trust one fetch.
        header('/info.json — polled')
        local firstSeen = {}
        local t0 = GetGameTimer()

        local lastFound = {}

        for _ = 1, CONVAR_POLL_ATTEMPTS do
            local body = httpGet(base .. '/info.json')
            lastFound = findArms(body or '')
            for i = 1, #ALL_ARMS do
                local a = ALL_ARMS[i]
                if lastFound[a.name].name and not firstSeen[a.name] then
                    firstSeen[a.name] = GetGameTimer() - t0
                end
            end
            Wait(CONVAR_POLL_INTERVAL)
        end

        -- Key and value reported separately. The key appearing is what makes a
        -- convar enumerable; the VALUE appearing is the leak, and after a blanking
        -- the two come apart.
        for i = 1, #ALL_ARMS do
            local a = ALL_ARMS[i]
            report(a.label .. ' in /info.json', firstSeen[a.name]
                and ('KEY yes +%d ms, VALUE %s'):format(
                    firstSeen[a.name], lastFound[a.name].value and 'yes' or 'no')
                or ('no — absent after %d ms'):format(
                    CONVAR_POLL_ATTEMPTS * CONVAR_POLL_INTERVAL))
        end

        -- (e) the other public endpoint ---------------------------------------
        local dyn = httpGet(base .. '/dynamic.json')
        local dynFound = findArms(dyn or '')
        for i = 1, #ALL_ARMS do
            local a = ALL_ARMS[i]
            report(a.label .. ' in /dynamic.json', tostring(dynFound[a.name].name))
        end

        -- (f) command registry -------------------------------------------------
        -- Q1 found convars appear here, with duplicated entries for convar-backed
        -- `internal` commands. If the entry differs by verb it is a detection
        -- path that costs no HTTP request at all.
        header('command registry')
        local cmds = GetRegisteredCommands()
        if type(cmds) ~= 'table' then
            report('GetRegisteredCommands', type(cmds))
        else
            for i = 1, #ALL_ARMS do
                local a = ALL_ARMS[i]
                local seen = 0
                for j = 1, #cmds do
                    local e = cmds[j]
                    local n = type(e) == 'table' and tostring(e.name) or tostring(e)
                    if n == a.name then
                        seen = seen + 1
                        local keys = {}
                        for k, v in pairs(type(e) == 'table' and e or {}) do
                            keys[#keys + 1] = ('%s=%s'):format(k, tostring(v))
                        end
                        table.sort(keys)
                        emit(('[probe]   %-15s %s'):format(a.label, table.concat(keys, '  ')))
                    end
                end
                report(a.label .. ' registry entries', seen)
            end
        end

        -- (g) named-candidate native sweep -------------------------------------
        -- Named, not enumerated: natives materialise lazily through __index, so
        -- pairs(_G) cannot show that one is missing. A negative here means "not
        -- under these names" and nothing stronger.
        header('candidate natives')
        local candidates = {
            'IsConvarReplicated', 'GetConvarReplicated', 'IsConvarServerInfo',
            'SetConvarReplicated', 'SetConvarServerInfo', 'SetConvar',
            'GetConvarServerInfo', 'GetAllConvars', 'GetConvars',
            'GetConvarInt', 'GetConvarBool', 'GetConvarFloat', 'GetConvar',
            'GetServerInfo', 'GetHostServerInfo', 'GetServerInfoVars',
        }
        local present = {}
        for i = 1, #candidates do
            if nativeByName(candidates[i]) then
                present[#present + 1] = candidates[i]
            end
        end
        report('present', table.concat(present, ' '))
        report('absent under these names', #candidates - #present)

        -- (h) cleanup -----------------------------------------------------------
        -- There is no `unset`. Blanking is the closest available, and whether the
        -- key then disappears from /info.json or lingers with an empty value is
        -- worth recording — it decides whether a mistake is recoverable without a
        -- restart.
        header('cleanup')
        for i = 1, #CONVAR_ARMS do
            local a = CONVAR_ARMS[i]
            local fn = a.setter and nativeByName(a.setter) or nil
            if fn then
                pcall(fn, a.name, '')
            else
                pcall(ExecuteCommand, ('set %s ""'):format(a.name))
            end
        end
        Wait(1000)

        local after = httpGet(base .. '/info.json')
        local post = findArms(after or '')
        for i = 1, #CONVAR_ARMS do
            local a = CONVAR_ARMS[i]
            report(a.label .. ' after blanking', ('key=%s  value=%s'):format(
                tostring(post[a.name].name), tostring(post[a.name].value)))
        end
        report('note', 'convars persist until restart — rerun only after one')
    end)
end

-- --------------------------------------------------------------------------
-- Phase 1 — typed convar accessor behaviour
-- --------------------------------------------------------------------------
-- config.lua reads every setting through GetConvarInt / GetConvarBool /
-- GetConvarFloat rather than parsing strings. What those return for a value that
-- is *not* of the requested type is undocumented, and it decides an interface
-- question: config.lua wants "0 disables this collector". If a typo returns 0
-- instead of the default, a typo silently disables a collector, and a silently
-- disabled collector is a metric that is simply absent from the dashboard with
-- nothing anywhere saying why.

-- To reproduce, paste into server.cfg and restart. Convars cannot be set from a
-- script and cannot be deleted at runtime, so this is a restart either way.
-- Convar NAMES are case-insensitive: tw_probe_ct_true and tw_probe_ct_TRUE are
-- one convar, and the later cfg line wins.
--
--   set tw_probe_ct_empty ""
--   set tw_probe_ct_garbage "abc"
--   set tw_probe_ct_int "12"
--   set tw_probe_ct_float "12.9"
--   set tw_probe_ct_negative "-3"
--   set tw_probe_ct_spaced " 12 "
--   set tw_probe_ct_true "true"
--   set tw_probe_ct_yes "yes"
--   set tw_probe_ct_one "1"
--   set tw_probe_ct_zero "0"
--   set tw_probe_ct_false "false"
--   set tw_probe_ct_no "no"
--   set tw_probe_ct_on "on"
--   set tw_probe_ct_off "off"
local CT_PREFIX = 'tw_probe_ct_'

local CT_CASES = {
    { key = 'unset',    value = nil,       note = 'never set' },
    { key = 'empty',    value = '',        note = 'set to empty string' },
    { key = 'garbage',  value = 'abc',     note = 'non-numeric text' },
    { key = 'int',      value = '12',      note = 'plain integer' },
    { key = 'float',    value = '12.9',    note = 'fractional' },
    { key = 'negative', value = '-3',      note = 'negative integer' },
    { key = 'spaced',   value = ' 12 ',    note = 'integer with whitespace' },
    { key = 'true',     value = 'true',    note = 'boolean word' },
    { key = 'yes',      value = 'yes',     note = 'boolean synonym' },
    { key = 'one',      value = '1',       note = 'boolean as number' },
    { key = 'zero',     value = '0',       note = 'boolean as number' },
    { key = 'false',    value = 'false',   note = 'boolean word' },

    -- The words an operator reaches for that are not `true` or `false`. If these
    -- fall back to the default, then `set tickwatch_enabled no` leaves the
    -- exporter running and nothing anywhere says so.
    { key = 'no',       value = 'no',      note = 'boolean synonym' },
    { key = 'on',       value = 'on',      note = 'boolean synonym' },
    { key = 'off',      value = 'off',     note = 'boolean synonym' },
    { key = 'TRUE',     value = 'TRUE',    note = 'case sensitivity' },
    { key = 'FALSE',    value = 'FALSE',   note = 'case sensitivity' },
}

probes.convartypes = function()
    Citizen.CreateThread(function()
        header('Phase 1 typed convar accessors')

        -- Distinctive sentinels. If an accessor returns its default, that is
        -- visible at a glance rather than confusable with a parsed value.
        local INT_DEFAULT = 4242
        local FLOAT_DEFAULT = 42.42

        -- Fixtures come from server.cfg, because ExecuteCommand('set name value')
        -- returns successfully and does nothing — already recorded in Q6.
        --
        -- Presence is checked through a normal global lookup, never rawget:
        -- natives materialise lazily through __index, so rawget reports absent
        -- for every native that has not been touched yet. (Q6 already
        -- established SetConvar works; this line exists to keep the wrong check
        -- from being reintroduced.)
        report('SetConvar present', tostring(nativeByName('SetConvar') ~= nil))
        report('fixtures from', 'server.cfg — see the block below')

        report('legend', 'int/float default=4242/42.42 — seeing it means "fell back"')
        report('legend', 'values shown as type:value — number 0 is TRUTHY in Lua')
        emit(('[probe] %-10s %-24s %-10s %-22s %-14s %s'):format(
            'case', 'raw GetConvar', 'Int', 'Float', 'Bool(F)', 'Bool(T)'))

        for i = 1, #CT_CASES do
            local case = CT_CASES[i]
            local name = CT_PREFIX .. case.key

            local raw = GetConvar(name, '(default)')

            -- pcall each: an accessor that raises on a value it cannot convert
            -- is a third possible behaviour, and it would be a much louder one.
            local okI, vi = pcall(GetConvarInt, name, INT_DEFAULT)
            local okF, vf = pcall(GetConvarFloat, name, FLOAT_DEFAULT)

            -- Both defaults, because an accessor that ignores the value and
            -- returns the default is indistinguishable from one that parsed it,
            -- unless the two runs disagree.
            local okBF, vbf = pcall(GetConvarBool, name, false)
            local okBT, vbt = pcall(GetConvarBool, name, true)

            -- type:value, because the difference between boolean false and the
            -- number 0 is the whole question for the boolean accessor: `0` is
            -- truthy in Lua, so a config read that trusts `if` on it inverts.
            local function show(ok, v)
                if not ok then return 'RAISED' end
                return ('%s:%s'):format(type(v), tostring(v))
            end

            emit(('[probe] %-10s %-24s %-10s %-22s %-14s %s'):format(
                case.key,
                ('%q'):format(raw),
                okI and tostring(vi) or 'RAISED',
                okF and tostring(vf) or 'RAISED',
                show(okBF, vbf),
                show(okBT, vbt)))
        end

        header('what this decides')
        report('if garbage -> 0', 'config.lua must NOT use 0 as "disabled"')
        report('if garbage -> default', '0-means-disabled is safe')
        report('note', 'convars persist until restart — rerun only after one')
    end)
end

-- --------------------------------------------------------------------------
-- Phase 1 — per-series byte cost
-- --------------------------------------------------------------------------
-- The cardinality cap's default has to come from a measurement rather than from
-- a round number, because values on this runtime are 32 bytes and a table never
-- gives array capacity back once it has grown.
--
-- The registry is loaded from the tickwatch resource with LoadResourceFile and
-- executed here, so this measures the file that ships rather than a copy of it
-- that can drift.
--
-- Fixed overhead is cancelled rather than estimated: each shape is built at two
-- sizes and the marginal cost is the difference divided by the difference in
-- series. Whatever a registry costs to exist appears in both terms and
-- subtracts out.

local SERIES_SMALL = 500
local SERIES_LARGE = 2500
local SERIES_TRIALS = 5

local function median(t)
    local copy = {}
    for i = 1, #t do copy[i] = t[i] end
    table.sort(copy)
    local n = #copy
    if n % 2 == 1 then return copy[(n + 1) // 2] end
    return (copy[n // 2] + copy[n // 2 + 1]) / 2
end

--- Build a registry holding `count` series of one shape and return its heap cost.
local function seriesFootprint(Registry, shape, count)
    fullCollect()
    local before = countBytes()

    local reg = Registry.new({ defaultCap = count + 16 })
    reg:register(shape.def)

    for i = 1, count do
        shape.write(reg, i)
    end

    fullCollect()
    local after = countBytes()

    -- Read something off the registry after the measurement so it is
    -- unambiguously still reachable at the collect above. Without this the
    -- collector is within its rights to have freed the whole thing.
    local held = reg.metrics[shape.def.name].seriesCount
    if held ~= count then
        error(('shape %s built %d series, expected %d — cap or dedup bug')
            :format(shape.label, held, count))
    end

    return after - before
end

local function measureShape(Registry, shape)
    local marginals, smalls, larges = {}, {}, {}

    for _ = 1, SERIES_TRIALS do
        local small = seriesFootprint(Registry, shape, SERIES_SMALL)
        local large = seriesFootprint(Registry, shape, SERIES_LARGE)

        smalls[#smalls + 1] = small
        larges[#larges + 1] = large
        marginals[#marginals + 1] = (large - small) / (SERIES_LARGE - SERIES_SMALL)
    end

    local lo, hi = math.huge, -math.huge
    for i = 1, #marginals do
        lo = math.min(lo, marginals[i])
        hi = math.max(hi, marginals[i])
    end

    local mid = median(marginals)

    report(shape.label, ('%.1f B/series   (spread %.1f–%.1f, n=%d)')
        :format(mid, lo, hi, SERIES_TRIALS))
    report('  ' .. shape.label .. ' at ' .. SERIES_LARGE, ('%.0f B total (%.2f MiB)')
        :format(median(larges), median(larges) / 1048576))

    return mid
end

probes.series = function()
    header('Phase 1 per-series byte cost')

    local path = 'server/registry.lua'
    local src = LoadResourceFile('tickwatch', path)

    if not src or src == '' then
        report('verdict', 'CANNOT RUN — tickwatch/' .. path .. ' not readable')
        report('fix', 'junction the tickwatch repo into resources/tickwatch and restart')
        return
    end

    report('registry source bytes', #src)

    local chunk, err = load(src, '@tickwatch/' .. path)
    if not chunk then
        report('verdict', 'CANNOT RUN — ' .. tostring(err))
        return
    end

    chunk()

    local Registry = _G.Registry
    if type(Registry) ~= 'table' or type(Registry.new) ~= 'function' then
        report('verdict', 'CANNOT RUN — registry.lua did not export Registry')
        return
    end

    report('table.create present', tostring(table.create ~= nil))
    report('trials per shape', SERIES_TRIALS)
    report('sizes', ('%d and %d series'):format(SERIES_SMALL, SERIES_LARGE))

    -- Label values are fixed width so the interned string is the same size for
    -- every series and does not itself vary with the series count.
    local function value(i) return ('v%06d'):format(i) end

    local shapes = {
        {
            label = 'gauge, 1 label',
            def = { name = 'm_g1', type = 'gauge', help = 'x', labels = { 'a' } },
            write = function(reg, i) reg:set('m_g1', { a = value(i) }, i) end,
        },
        {
            label = 'gauge, 2 labels',
            def = { name = 'm_g2', type = 'gauge', help = 'x', labels = { 'a', 'b' } },
            write = function(reg, i) reg:set('m_g2', { a = value(i), b = 'const' }, i) end,
        },
        {
            label = 'counter, 1 label',
            def = { name = 'm_c1', type = 'counter', help = 'x', labels = { 'a' } },
            write = function(reg, i) reg:inc('m_c1', { a = value(i) }, 1) end,
        },
        {
            -- The expensive shape, and the one the default has to survive: a
            -- histogram series carries a counts array of bucketCount + 1 slots
            -- on top of everything a gauge series holds.
            label = 'histogram, 1 label, 10 buckets',
            def = { name = 'm_h1', type = 'histogram', help = 'x', labels = { 'a' } },
            write = function(reg, i) reg:observe('m_h1', { a = value(i) }, 0.003) end,
        },
    }

    header('marginal cost per series')

    local worst, worstLabel = 0, '?'
    for i = 1, #shapes do
        local cost = measureShape(Registry, shapes[i])
        if cost > worst then
            worst, worstLabel = cost, shapes[i].label
        end
    end

    header('what this sets')
    report('worst shape', worstLabel)
    report('worst cost', ('%.1f B/series'):format(worst))

    -- A budget is a number an operator can hold in their head. State the cap
    -- that lands under each of these and let the README quote one.
    for _, budgetMiB in ipairs({ 1, 4, 16 }) do
        local cap = math.floor((budgetMiB * 1048576) / worst)
        report(('cap for %d MiB'):format(budgetMiB), ('%d series (worst shape)'):format(cap))
    end

    report('note', 'per-metric cap — total is this times the number of capped metrics')
end

-- --------------------------------------------------------------------------
-- Phase 1 — the natives the collectors read
-- --------------------------------------------------------------------------
-- Every gauge in the catalog is a native call, and a collector is exactly as
-- correct as its assumptions about what that call hands back. Three of those
-- assumptions have already been wrong on this runtime — 1/0 where a boolean was
-- expected, a callable table where a function was, the word `false` read as the
-- number 0 — and none of the three raised an error. So the remaining ones are
-- read off the running server rather than off the documentation.
--
-- Two questions:
--
--   what does each native return, by type and by value, including for input it
--   should refuse; and
--
--   what does one full pass over the resource list cost? It is the only
--   collector whose cost grows with something the operator controls, and the
--   design already asserts that growth without a number behind it.
--
-- What cannot be measured headless is printed as unmeasured rather than
-- guessed. The player natives need a connected client; with none, only their
-- existence, their empty-server values and their behaviour on a source that is
-- not there are visible from here.

local BOGUS_RESOURCE = 'tickwatch-no-such-resource'
local BOGUS_SOURCE = 65535
local RESOURCE_PASS_REPEATS = 200

--- type:value for a call, or the reason there is no value.
local function callShape(name, ...)
    local fn = nativeByName(name)
    if not fn then
        return 'ABSENT on this build'
    end

    local ok, v = pcall(fn, ...)
    if not ok then
        return 'RAISED: ' .. tostring(v)
    end

    return ('%s:%s'):format(type(v), tostring(v))
end

--- Which index the resource list starts at. Asked rather than assumed: the
--- native is 0-based like an array in the engine's own language and 1-based like
--- everything else in Lua, and only one of those loops reads the whole list. A
--- wrong base silently drops one resource off either end.
local function resourceIndexBase()
    local zero = GetResourceByFindIndex(0)
    if type(zero) == 'string' and zero ~= '' then
        return 0
    end
    return 1
end

--- One full resources collector pass: every name, every state. Nothing is
--- retained, so this is what the collector itself will do, garbage included.
local function resourcePass(base, count)
    local n = 0
    for i = base, base + count - 1 do
        local name = GetResourceByFindIndex(i)
        if name and name ~= '' then
            local state = GetResourceState(name)
            if state then n = n + 1 end
        end
    end
    return n
end

probes.sources = function()
    header('Phase 1 — collector input natives')

    report('note', 'run this on a server with a realistic resource count')

    header('server identity — fivem_server_info')
    report('GetConvar version', callShape('GetConvar', 'version', '(unset)'))
    report('GetConvar gamename', callShape('GetConvar', 'gamename', '(unset)'))
    report('GetConvar sv_projectName', callShape('GetConvar', 'sv_projectName', '(unset)'))
    report('GetGameTimer', callShape('GetGameTimer'))
    report('  note', 'ms since process start — uptime is measured against a start stamp, not this')

    header('players — needs a connected client for the rest')
    report('GetNumPlayerIndices', callShape('GetNumPlayerIndices'))
    report('GetPlayers', callShape('GetPlayers'))

    local players = nil
    do
        local fn = nativeByName('GetPlayers')
        if fn then
            local ok, v = pcall(fn)
            players = ok and type(v) == 'table' and v or nil
        end
    end

    if players then
        report('  #GetPlayers()', #players)
        report('  element type', #players > 0 and type(players[1]) or 'UNMEASURED — no client connected')
    end

    report('GetPlayerFromIndex(0)', callShape('GetPlayerFromIndex', 0))
    report('sv_maxclients (GetConvar)', callShape('GetConvar', 'sv_maxclients', '(unset)'))
    report('sv_maxclients (GetConvarInt)', callShape('GetConvarInt', 'sv_maxclients', -1))

    -- The collector reads a ping for each source it enumerated, and a player can
    -- leave between the two calls. Whether that raises or returns a number
    -- decides whether the ping loop needs a pcall around every iteration or
    -- whether one implausible value can simply be skipped.
    report(('GetPlayerPing(%d) number'):format(BOGUS_SOURCE), callShape('GetPlayerPing', BOGUS_SOURCE))
    report(('GetPlayerPing("%d") string'):format(BOGUS_SOURCE), callShape('GetPlayerPing', tostring(BOGUS_SOURCE)))
    report('GetPlayerName(stale)', callShape('GetPlayerName', BOGUS_SOURCE))

    -- A floor, not the cost. A source that names nobody may return before doing
    -- the lookup a real one forces, so this measures the bridge crossing and
    -- whatever the miss path costs — the true per-player figure can only be
    -- higher. It is still worth having: if even the floor were expensive the
    -- ping loop would need a different shape, and it decides that question
    -- without a client.
    local pingFn = nativeByName('GetPlayerPing')
    if pingFn then
        local perCall, calls, spread = timeCall(function() pingFn(BOGUS_SOURCE) end)
        report('GetPlayerPing floor', ('%.3f us  (median of %d x %d calls, spread %.1f%%)')
            :format(perCall * 1e6, TIMING_TRIALS, calls, spread))
        report('  modelled 64-player pass', ('>= %.1f us'):format(perCall * 64 * 1e6))
    end

    local playersFn = nativeByName('GetPlayers')
    if playersFn then
        local perCall, calls, spread = timeCall(playersFn)
        report('GetPlayers on empty server', ('%.3f us  (median of %d x %d calls, spread %.1f%%)')
            :format(perCall * 1e6, TIMING_TRIALS, calls, spread))
        report('  note', 'empty-server floor — the entity sweep found this term rises with population')
    end

    header('resources — fivem_resource_up')
    report('GetNumResources', callShape('GetNumResources'))

    local count = GetNumResources()
    if type(count) ~= 'number' or count <= 0 then
        report('verdict', 'CANNOT RUN — GetNumResources gave nothing to walk')
        return
    end

    local base = resourceIndexBase()
    report('index base', base)
    report(('GetResourceByFindIndex(%d)'):format(base - 1), callShape('GetResourceByFindIndex', base - 1))
    report(('GetResourceByFindIndex(%d)'):format(base), callShape('GetResourceByFindIndex', base))
    report(('GetResourceByFindIndex(%d) last'):format(base + count - 1),
        callShape('GetResourceByFindIndex', base + count - 1))
    report(('GetResourceByFindIndex(%d) past end'):format(base + count),
        callShape('GetResourceByFindIndex', base + count))

    -- `fivem_resource_up` is 1 or 0, so every state string the server can
    -- produce has to map onto one of the two. Enumerating what actually appears
    -- beats mapping the list a wiki gives.
    local states, order = {}, {}
    local named = 0

    for i = base, base + count - 1 do
        local name = GetResourceByFindIndex(i)
        if type(name) == 'string' and name ~= '' then
            named = named + 1
            local ok, state = pcall(GetResourceState, name)
            local key = ok and tostring(state) or ('RAISED: ' .. tostring(state))
            if states[key] == nil then
                states[key] = 0
                order[#order + 1] = key
            end
            states[key] = states[key] + 1
        end
    end

    report('names returned', ('%d of %d'):format(named, count))
    table.sort(order)
    for i = 1, #order do
        report(('  state %s'):format(order[i]), states[order[i]])
    end

    report('GetResourceState(absent)', callShape('GetResourceState', BOGUS_RESOURCE))
    report('  why it matters', 'decides whether a stopped-and-removed resource can be told from a typo')

    header('resource pass cost — the one that grows with the server')

    local passed = resourcePass(base, count)
    if passed ~= named then
        report('verdict', ('pass saw %d, enumeration saw %d — list moved mid-run'):format(passed, named))
    end

    local perPass, calls, spread = timeCall(function() resourcePass(base, count) end)

    report('resources walked', named)
    report('per pass', ('%.1f us  (median of %d x %d passes, spread %.1f%%)')
        :format(perPass * 1e6, TIMING_TRIALS, calls, spread))
    report('per resource', ('%.0f ns'):format(perPass * 1e9 / math.max(named, 1)))

    -- The number the interval has to be justified against. A collector is
    -- affordable or not against the interval it runs on, never in isolation.
    for _, intervalS in ipairs({ 10, 30, 60 }) do
        report(('at a %d s interval'):format(intervalS),
            ('%.5f%% of one core'):format(perPass / intervalS * 100))
    end

    -- Names and states are short strings, so Lua interns them and a repeat pass
    -- should retain nothing at all. Worth confirming rather than asserting: this
    -- pass runs every 30 s for the life of the process, and a few bytes retained
    -- per resource per pass is a leak that would take days to become visible.
    fullCollect()
    local before = countBytes()
    for _ = 1, RESOURCE_PASS_REPEATS do
        resourcePass(base, count)
    end
    fullCollect()
    local retained = countBytes() - before

    report(('retained over %d passes'):format(RESOURCE_PASS_REPEATS), ('%.0f B'):format(retained))
    report('  per pass', ('%.1f B'):format(retained / RESOURCE_PASS_REPEATS))
end

-- --------------------------------------------------------------------------
-- Phase 1 — the collectors, against the real server
-- --------------------------------------------------------------------------
-- The suite runs collectors.lua against stub natives in a stock Lua VM, which
-- proves the logic and proves nothing about the runtime. This runs the same file
-- against the real ones: real players, real entity lists, a real resource list,
-- and the registry it writes through.
--
-- Three things come out of it. Whether a pass works at all outside the harness,
-- what a pass costs on this server, and what the exposition it produces actually
-- looks like — including the histogram invariant that no linter checks.

local COLLECT_FILES = { 'server/registry.lua', 'server/collectors.lua' }
local EXPOSITION_PREVIEW = 24

--- Load a tickwatch source file into this state. Reads the shipping file rather
--- than a copy, so what is measured cannot drift from what is deployed.
local function loadTickwatch(path)
    local src = LoadResourceFile('tickwatch', path)
    if not src or src == '' then
        return nil, 'tickwatch/' .. path .. ' not readable'
    end

    local chunk, err = load(src, '@tickwatch/' .. path)
    if not chunk then
        return nil, tostring(err)
    end

    chunk()
    return #src
end

--- Every histogram must satisfy +Inf == _count. A histogram that does not is
--- valid exposition text that no linter rejects and that returns wrong
--- percentiles at query time, which makes this the one invariant worth checking
--- on the wire rather than only in the suite.
local function checkHistograms(text)
    local inf, counts = {}, {}

    for line in text:gmatch('[^\n]+') do
        local name, value = line:match('^([%w_]+)_bucket{le="%+Inf"}%s+(%S+)$')
        if name then inf[name] = value end

        local cname, cvalue = line:match('^([%w_]+)_count%s+(%S+)$')
        if cname then counts[cname] = cvalue end
    end

    local checked, bad = 0, 0

    for name, value in pairs(inf) do
        checked = checked + 1
        if counts[name] ~= value then
            bad = bad + 1
            report('  MISMATCH ' .. name, ('+Inf=%s _count=%s'):format(value, tostring(counts[name])))
        end
    end

    return checked, bad
end

--- Bytes allocated by one call, with the collector held off so nothing is
--- reclaimed underneath the measurement.
---
--- This is the figure that decides whether a write path allocates, and it is
--- worth more than the wall-clock one: a few microseconds of difference sits
--- inside the ~15% variation between server sessions, while an allocation either
--- happens or does not.
local function allocPerCall(fn, n)
    fullCollect()

    local stopped = pcall(collectgarbage, 'stop')
    local before = countBytes()

    for _ = 1, n do fn() end

    local after = countBytes()
    if stopped then pcall(collectgarbage, 'restart') end

    return (after - before) / n, stopped
end

probes.collect = function()
    header('Phase 1 — collectors against the real server')

    for i = 1, #COLLECT_FILES do
        local bytes, err = loadTickwatch(COLLECT_FILES[i])
        if not bytes then
            report('verdict', 'CANNOT RUN — ' .. err)
            report('fix', 'junction the tickwatch repo into resources/tickwatch and restart')
            return
        end
        report(COLLECT_FILES[i], bytes .. ' bytes')
    end

    local Registry, Collectors = _G.Registry, _G.Collectors
    if type(Registry) ~= 'table' or type(Collectors) ~= 'table' then
        report('verdict', 'CANNOT RUN — the files did not export what they should')
        return
    end

    local reg = Registry.new()
    Collectors.register(reg)
    Collectors.sampleConstants(reg, nil)

    report('metrics registered', #reg.order)

    header('one pass each, on this server')

    -- Order matters only for reading: self first so uptime is set before
    -- anything slower runs.
    local passes = { 'self', 'players', 'entities', 'resources' }

    for i = 1, #passes do
        local name = passes[i]
        local fn = Collectors.pass[name]

        local ok, err = pcall(fn, reg)
        if not ok then
            report(name .. ' pass', 'RAISED: ' .. tostring(err))
        else
            local perCall, calls, spread = timeCall(function() fn(reg) end)
            report(name .. ' pass', ('%.1f us  (median of %d x %d, spread %.1f%%)')
                :format(perCall * 1e6, TIMING_TRIALS, calls, spread))

            local bytes, stopped = allocPerCall(function() fn(reg) end, 1000)
            report('  allocates', ('%.0f B/pass%s'):format(bytes, stopped and '' or '  (GC could not be paused — soft)'))
        end
    end

    -- The resources pass writes one series per resource, and the obvious way to
    -- write it builds a label table per write. Whether that matters is a
    -- question about allocation, not about time: at 100 writes the wall-clock
    -- difference is inside the ~15% variation between server sessions, so the
    -- two shapes are compared here in the same session and by bytes.
    header('a label table per write, against one reused')

    local ab = Registry.new({ defaultCap = 200 })
    ab:register({ name = 'ab_gauge', type = 'gauge', help = 'x', labels = { 'resource' } })

    local AB_WRITES = 100
    local names = {}
    for i = 1, AB_WRITES do names[i] = ('resource-%03d'):format(i) end

    local shared = { resource = '' }

    local function writeFresh()
        for i = 1, AB_WRITES do ab:set('ab_gauge', { resource = names[i] }, i) end
    end

    local function writeShared()
        for i = 1, AB_WRITES do
            shared.resource = names[i]
            ab:set('ab_gauge', shared, i)
        end
    end

    -- Create the series first. First sight of a label set builds its serialized
    -- text and is the expensive path by design; the steady state is what the
    -- comparison is about.
    writeFresh()

    for _, variant in ipairs({ { 'table per write', writeFresh }, { 'one reused table', writeShared } }) do
        local perCall, calls, spread = timeCall(variant[2])
        local bytes = allocPerCall(variant[2], 1000)

        report(variant[1], ('%.1f us / %d writes  (median of %d x %d, spread %.1f%%)')
            :format(perCall * 1e6, AB_WRITES, TIMING_TRIALS, calls, spread))
        report('  allocates', ('%.0f B  (%.1f B/write)'):format(bytes, bytes / AB_WRITES))
    end

    -- With no player connected every histogram is empty, and an invariant check
    -- over nothing passes without checking anything. Feed each one a spread of
    -- observations so the +Inf == _count check below has something to be wrong
    -- about. These are synthetic and are not measurements of anything.
    local SYNTHETIC = 50
    for i = 1, SYNTHETIC do
        reg:observe('fivem_server_tick_interval_seconds', nil, (i % 40) / 1000)
        reg:observe('fivem_player_ping_seconds', nil, (i % 300) / 1000)
        reg:observe('fivem_player_session_duration_seconds', nil, i * 37)
        reg:observe('tickwatch_collector_overhead_seconds', nil, (i % 2) / 1000)
    end
    report('synthetic observations', ('%d per histogram, for the invariant check'):format(SYNTHETIC))

    header('series produced')

    local total = 0
    for i = 1, #reg.order do
        local metric = reg.order[i]
        total = total + metric.seriesCount
        report('  ' .. metric.name, ('%d series (%s)'):format(metric.seriesCount, metric.kind))
    end
    report('total series', total)

    header('render')

    local text = reg:render()
    local lines = select(2, text:gsub('\n', '\n'))

    report('bytes', #text)
    report('lines', lines)
    report('ends with newline', tostring(text:sub(-1) == '\n'))

    local perRender, renders, spread = timeCall(function() reg:render() end)
    report('render cost', ('%.1f us  (median of %d x %d, spread %.1f%%)')
        :format(perRender * 1e6, TIMING_TRIALS, renders, spread))

    local checked, bad = checkHistograms(text)
    report('histograms checked', ('%d, %d with +Inf ~= _count'):format(checked, bad))

    header('first lines on the wire')

    local shown = 0
    for line in text:gmatch('[^\n]+') do
        emit('[probe] | ' .. line)
        shown = shown + 1
        if shown >= EXPOSITION_PREVIEW then break end
    end
    report('...', ('%d more lines'):format(math.max(lines - shown, 0)))
end

-- --------------------------------------------------------------------------
-- Phase 1 — the export API, called the way a real caller calls it
-- --------------------------------------------------------------------------
-- Everything else in Phase 1 was measured from inside tickwatch's own Lua state.
-- The export API is the one surface that is not: a caller is a different
-- resource, a different lua_State, and arguments cross a serialization boundary
-- to get here. Nothing measured inside the resource says what that costs or what
-- survives the trip.
--
-- Four questions, and the last one changed the API before it shipped:
--
--   what does one export call cost, against the ~1 us a local registry write
--   costs and the ~500 us database query it is meant to instrument;
--
--   do the registry's own errors reach the caller, or does the boundary swallow
--   them — because "rejected loudly" is not a claim that survives being wrong;
--
--   do table arguments arrive as tables, with their string keys intact;
--
--   and does a returned closure work at all? The design specified
--   StartTimer returning a stop() function. A function cannot be serialized, so
--   either the runtime wraps it in a reference — which makes calling it a round
--   trip rather than a local call — or it does not survive.

local EXPORT_TRIALS = 3

--- Call an export, reporting what came back and whether it raised.
local function callExport(name, ...)
    local ok, result = pcall(function(...)
        return exports['tickwatch'][name](exports['tickwatch'], ...)
    end, ...)

    if not ok then
        return nil, tostring(result)
    end
    return result, nil
end

local function reportCall(label, value, err)
    if err then
        report(label, 'RAISED: ' .. err)
    else
        report(label, ('%s:%s'):format(type(value), tostring(value)))
    end
end

probes.exports = function()
    header('Phase 1 — the export API across a resource boundary')

    if GetResourceState('tickwatch') ~= 'started' then
        report('verdict', 'CANNOT RUN — tickwatch is not started')
        return
    end

    -- Register a metric this probe owns, so the measurement never depends on the
    -- catalog and never writes into a series a dashboard might read.
    local PROBE_COUNTER = 'tickwatch_probe_calls_total'
    local PROBE_HISTOGRAM = 'tickwatch_probe_duration_seconds'

    header('does a definition survive the boundary')

    local registered, err = callExport('Register', {
        name = PROBE_COUNTER,
        type = 'counter',
        help = 'Probe calls. Registered from another resource.',
        labels = { 'kind' },
    })
    reportCall('Register (labelled counter)', registered, err)

    local registeredHist, histErr = callExport('Register', {
        name = PROBE_HISTOGRAM,
        type = 'histogram',
        help = 'Probe durations. Registered from another resource.',
        buckets = { 0.001, 0.01, 0.1, 1 },
    })
    reportCall('Register (custom buckets)', registeredHist, histErr)

    -- A labels table with string keys is the argument shape every write uses. If
    -- the boundary turned it into an array, or dropped it, every labelled write
    -- from every caller would fail and this is where that shows.
    reportCall('Inc with a labels table', callExport('Inc', PROBE_COUNTER, { kind = 'probe' }, 1))
    reportCall('IsRegistered', callExport('IsRegistered', PROBE_COUNTER))

    header('are mistakes rejected, and does the caller survive them')

    -- The design says a typo fails loudly and never creates a series. The other
    -- half of that claim is that failing does not take the caller down, which is
    -- only observable from out here.
    reportCall('Inc on an unknown metric', callExport('Inc', 'tickwatch_probe_no_such_metric', nil, 1))
    reportCall('Inc with a wrong type', callExport('Set', PROBE_COUNTER, { kind = 'probe' }, 1))
    reportCall('Inc with a negative value', callExport('Inc', PROBE_COUNTER, { kind = 'probe' }, -5))
    reportCall('Inc with a nil name', callExport('Inc', nil, nil, 1))
    reportCall('Observe with a string value', callExport('Observe', PROBE_HISTOGRAM, nil, 'soon'))
    report('caller still running', 'yes — every rejection above returned rather than raised')

    header('the stopwatch')

    -- The caller reads its own clock; the API only converts the units. See the
    -- closure measurement below for why there is no StartTimer to call.
    local started = GetGameTimer()
    Wait(50)

    reportCall('ObserveSince after ~50 ms',
        callExport('ObserveSince', PROBE_HISTOGRAM, nil, started))
    reportCall('ObserveSince with an os.time() value',
        callExport('ObserveSince', PROBE_HISTOGRAM, nil, os.time()))

    -- A counter, not a gauge. The first version of this registered a gauge and
    -- then timed Inc against it, which measures the REJECTION path — and did so
    -- convincingly enough to look like a result: 11.7 us, above the labelled
    -- write it was supposed to be cheaper than. A refusal formats a message and
    -- writes an error counter, so it costs more than the success it replaces.
    callExport('Register', {
        name = 'tickwatch_probe_plain_total',
        type = 'counter',
        help = 'Probe counter. Unlabelled, for the unlabelled-write timing below.',
    })

    header('can a function cross the boundary at all')

    -- The question the design was originally wrong about. tickwatch no longer
    -- returns a closure from StartTimer, and this is the measurement that
    -- justifies not doing so — asked against the control resource, because it is
    -- a property of the runtime rather than of the exporter.
    local ok, made = pcall(function() return exports['tickwatch-probe-b']:makeCounter() end)
    report('a returned closure arrives as', ok and type(made) or ('RAISED: ' .. tostring(made)))

    if ok and made ~= nil then
        local calledOk, first = pcall(made)
        report('  calling it', calledOk and ('returned ' .. tostring(first)) or ('RAISED: ' .. tostring(first)))

        if calledOk then
            local perCall, calls, spread = timeCall(function() pcall(made) end)
            report('  cost per call', ('%.3f us  (median of %d x %d, spread %.1f%%)')
                :format(perCall * 1e6, TIMING_TRIALS, calls, spread))
            report('  compare', 'a local closure call is single-digit nanoseconds')
        end
    end

    local okH, handle = pcall(function() return exports['tickwatch-probe-b']:makeHandle() end)
    report('a table containing a function', okH and type(handle) or ('RAISED: ' .. tostring(handle)))

    if okH and type(handle) == 'table' then
        report('  .label survived', tostring(handle.label))
        report('  .bump arrives as', type(handle.bump))
    end

    header('what a call costs')

    -- Against the numbers this has to be compared with: a local registry write
    -- is ~0.26 us, and the 500 us database query the API exists to instrument.
    local shapes = {
        {
            label = 'Inc, no labels, via export',
            fn = function()
                exports['tickwatch']:Inc('tickwatch_probe_plain_total', nil, 1)
            end,
        },
        {
            -- The rejection path, measured on purpose rather than by accident.
            -- A caller with a typo pays this on every call forever, so it is
            -- worth knowing whether refusing costs more than succeeding.
            label = 'Inc on an unknown metric (rejected)',
            fn = function()
                exports['tickwatch']:Inc('tickwatch_probe_no_such_metric', nil, 1)
            end,
        },
        {
            label = 'Inc, labelled, via export',
            fn = function()
                exports['tickwatch']:Inc(PROBE_COUNTER, { kind = 'probe' }, 1)
            end,
        },
        {
            label = 'Observe, no labels, via export',
            fn = function()
                exports['tickwatch']:Observe(PROBE_HISTOGRAM, nil, 0.003)
            end,
        },
        {
            label = 'ObserveSince, via export',
            fn = function()
                exports['tickwatch']:ObserveSince(PROBE_HISTOGRAM, nil, GetGameTimer())
            end,
        },
        {
            -- The comparison that killed StartTimer. Whatever an export call
            -- costs, this is what the caller pays to read the same clock in its
            -- own state — and a StartTimer export would have done nothing else.
            label = '(control) GetGameTimer, no export',
            fn = function() GetGameTimer() end,
        },
        {
            -- And the floor for anything the API could offer: a local registry
            -- write, measured inside tickwatch by `probe collect`, is ~0.26 us.
            label = '(control) an empty function call',
            fn = function() end,
        },
    }

    for i = 1, #shapes do
        local shape = shapes[i]
        local perCall, calls, spread = timeCall(shape.fn)

        report(shape.label, ('%.3f us  (median of %d x %d, spread %.1f%%)')
            :format(perCall * 1e6, TIMING_TRIALS, calls, spread))
    end

    -- Allocation matters as much as time here: this runs inside a caller's hot
    -- path, and garbage it creates lands in the caller's own heap.
    local bytes = allocPerCall(function()
        exports['tickwatch']:Inc(PROBE_COUNTER, { kind = 'probe' }, 1)
    end, 1000)
    report('labelled Inc allocates', ('%.0f B/call  (in the CALLER heap)'):format(bytes))

    header('what this sets')
    report('note', 'compare against a 500 us query — the overhead of timing one is the ratio')
    report('trials', EXPORT_TRIALS)
end

-- --------------------------------------------------------------------------
-- v0.1.0 — does running the exporter change the server's tick?
-- --------------------------------------------------------------------------
-- The exporter's central claim is that it measures a server without altering
-- it, and it runs one permanent per-frame thread in a design that forbids
-- per-frame work everywhere else. That thread is the obvious place for the claim
-- to be false, so it gets tested rather than asserted.
--
-- The measurement is taken from THIS resource's own Wait(0) thread, which is
-- independent of tickwatch and present in every condition, so whatever it costs
-- cancels out.
--
-- Three phases, control-treatment-control, all in one server session:
--
--   tickwatch stopped, tickwatch started, tickwatch stopped again.
--
-- The second control is what makes the result readable. A server drifts over
-- minutes — other resources do work, the heap grows, the host does something
-- else — and a two-phase test cannot tell drift from effect. If the two controls
-- agree with each other and the treatment differs from both, that is an effect.
-- If the two controls differ from each other by as much as the treatment does,
-- the run measured the weather.
--
-- Session-to-session variation on this platform is around 15%, larger than any
-- effect worth finding here, so comparing across server restarts would not have
-- worked at all.

local TICK_PHASE_MS = 30000
local TICK_SETTLE_MS = 3000

-- registry.lua keeps its own copy of this as a local, so it is not in scope here
-- even in the probes that load that file. Declared rather than probed for with
-- `tableCreate and ...`, which would silently stop presizing if it were ever nil.
local presize = table.create or function() return {} end

--- Collect frame intervals for a fixed wall-clock window.
---
--- The sample buffer is preallocated, and nothing inside the loop allocates or
--- formats anything. A collector that produces garbage while measuring the cost
--- of a collector that produces garbage measures itself.
local function collectIntervals(windowMs)
    local capacity = math.floor(windowMs / 40) + 256
    local samples = presize(capacity, 0)
    local n = 0

    local deadline = GetGameTimer() + windowMs
    local last = GetGameTimer()

    while true do
        Wait(0)

        local now = GetGameTimer()
        local delta = now - last
        last = now

        if delta >= 0 then
            n = n + 1
            samples[n] = delta
        end

        if now >= deadline then break end
    end

    return samples, n
end

--- Mean, sample standard deviation, and the standard error of the mean.
---
--- The standard error is the point of this. A difference between two means is
--- only a finding if it is large against the uncertainty in each of them, and
--- with ~600 samples per phase that uncertainty is small enough to resolve a
--- fraction of a millisecond — well below the 1 ms the clock reports in.
local function summarise(samples, n)
    if n == 0 then return nil end

    local total = 0
    for i = 1, n do total = total + samples[i] end
    local mean = total / n

    local sq = 0
    for i = 1, n do
        local d = samples[i] - mean
        sq = sq + d * d
    end

    local sd = n > 1 and math.sqrt(sq / (n - 1)) or 0

    local sorted = presize(n, 0)
    for i = 1, n do sorted[i] = samples[i] end
    table.sort(sorted)

    local function at(q)
        local idx = math.max(1, math.min(n, math.ceil(q * n)))
        return sorted[idx]
    end

    return {
        n = n,
        mean = mean,
        sd = sd,
        sem = n > 1 and sd / math.sqrt(n) or 0,
        median = at(0.5),
        p95 = at(0.95),
        p99 = at(0.99),
        max = sorted[n],
    }
end

local function reportPhase(label, s)
    if not s then
        report(label, 'no samples')
        return
    end

    report(label, ('mean %.2f +/- %.2f ms   (n=%d, sd %.2f)')
        :format(s.mean, s.sem, s.n, s.sd))
    report('  ' .. label .. ' tail', ('median %d, p95 %d, p99 %d, max %d ms')
        :format(s.median, s.p95, s.p99, s.max))
end

probes.tickimpact = function(seconds)
    header('v0.1.0 — tick distribution with and without the exporter')

    local windowMs = (tonumber(seconds) or 0) > 0 and (tonumber(seconds) * 1000) or TICK_PHASE_MS

    if GetResourceState('tickwatch') == 'missing' then
        report('verdict', 'CANNOT RUN — the tickwatch resource is not present')
        return
    end

    report('phase length', ('%d ms each, three phases'):format(windowMs))
    report('settle', ('%d ms after each state change'):format(TICK_SETTLE_MS))
    report('note', 'measured from this resource, which is present in every phase')

    local phases = {
        { label = 'control A (stopped)', want = 'stopped' },
        { label = 'treatment (running)', want = 'started' },
        { label = 'control B (stopped)', want = 'stopped' },
    }

    local results = {}

    for i = 1, #phases do
        local phase = phases[i]

        if phase.want == 'started' then
            StartResource('tickwatch')
        else
            StopResource('tickwatch')
        end

        -- Startup does an HTTP fetch of /info.json and a first render. Measuring
        -- across that would time the boot, not the steady state the claim is
        -- about.
        Wait(TICK_SETTLE_MS)

        local state = GetResourceState('tickwatch')
        if (phase.want == 'started') ~= (state == 'started') then
            report('verdict', ('CANNOT RUN — tickwatch is %s, wanted %s'):format(state, phase.want))
            return
        end

        local samples, n = collectIntervals(windowMs)
        results[i] = summarise(samples, n)
        reportPhase(phase.label, results[i])
    end

    -- Leave the server as the run found it, running.
    StartResource('tickwatch')

    header('the comparison')

    local a, t, b = results[1], results[2], results[3]
    if not (a and t and b) then
        report('verdict', 'INCOMPLETE — a phase produced no samples')
        return
    end

    local controlMean = (a.mean + b.mean) / 2
    local controlDrift = math.abs(a.mean - b.mean)
    local effect = t.mean - controlMean

    -- Uncertainty in the difference of two means is the two standard errors
    -- added in quadrature, not one of them.
    local uncertainty = math.sqrt(t.sem * t.sem + ((a.sem + b.sem) / 2) ^ 2)

    report('control mean', ('%.2f ms'):format(controlMean))
    report('drift between controls', ('%.2f ms'):format(controlDrift))
    report('effect (treatment - control)', ('%+.2f +/- %.2f ms'):format(effect, uncertainty))
    report('as a share of a frame', ('%+.2f%%'):format(effect / controlMean * 100))

    -- The drift between the two controls is the floor on what this run can
    -- resolve. An effect smaller than the noise the apparatus itself produced is
    -- not a measurement of anything.
    if controlDrift > math.abs(effect) then
        report('verdict', 'UNCHANGED — the effect is smaller than the drift between the two controls')
    elseif math.abs(effect) < 2 * uncertainty then
        report('verdict', 'UNCHANGED — the effect is inside two standard errors')
    else
        report('verdict', ('CHANGED — %+.2f ms, outside both the drift and the error'):format(effect))
    end
end

-- --------------------------------------------------------------------------
-- v0.1.0 — the request path at the cardinality cap
-- --------------------------------------------------------------------------
-- The milestone puts the request path under 2 ms at 500 series, and the live
-- registry holds about 113. This inflates it past the cap through the public
-- export API — the same path a caller with too many labels would take — so the
-- scrape being timed is a scrape of a full-sized registry.

local LOAD_METRIC = 'tickwatch_probe_load_total'

probes.load = function(count)
    header('v0.1.0 — filling the registry to the cardinality cap')

    if GetResourceState('tickwatch') ~= 'started' then
        report('verdict', 'CANNOT RUN — tickwatch is not started')
        return
    end

    local target = tonumber(count) or 450

    local ok = exports['tickwatch']:IsRegistered(LOAD_METRIC)
    if not ok then
        exports['tickwatch']:Register({
            name = LOAD_METRIC,
            type = 'counter',
            help = 'Probe load generator. Not a measurement of anything.',
            labels = { 'slot' },
        })
    end

    local t0 = GetGameTimer()
    local written = 0
    for i = 1, target do
        if exports['tickwatch']:Inc(LOAD_METRIC, { slot = ('slot-%04d'):format(i) }, 1) then
            written = written + 1
        end
    end
    local elapsed = GetGameTimer() - t0

    report('series requested', target)
    report('writes accepted', written)
    report('time to write them', ('%d ms  (%.1f us each)'):format(elapsed, elapsed * 1000 / target))
    report('next', 'scrape /tickwatch/metrics now and time it from outside')
end

-- --------------------------------------------------------------------------
-- dispatch
-- --------------------------------------------------------------------------

local function probeNames()
    local names = {}
    for name in pairs(probes) do
        names[#names + 1] = name
    end
    table.sort(names)
    return names
end

RegisterCommand('probe', function(source, args)
    if source ~= 0 then
        return -- server console only
    end

    local name = args[1]
    local fn = name and probes[name]

    if not fn then
        if name then
            print(('[probe] no such probe: %s'):format(name))
        end
        print(('[probe] available: %s'):format(table.concat(probeNames(), ', ')))
        return
    end

    local ok, err = pcall(fn, table.unpack(args, 2, #args))
    if not ok then
        emit(('[probe] ERROR in %s: %s'):format(name, tostring(err)))
    end
end, true)

AddEventHandler('onResourceStart', function(resource)
    if resource ~= GetCurrentResourceName() then
        return
    end

    -- A fresh buffer per resource start, so `/log` returns this run's output and
    -- not a mix of runs taken under different code.
    outLines = {}

    header('build stamp — record this with every finding')
    report('version', GetConvar('version', '?'))
    report('gamename', GetConvar('gamename', '?'))
    report('onesync', GetConvar('onesync', '?'))
    report('ready', table.concat(probeNames(), ', '))
    report('drive over http', 'curl http://127.0.0.1:30130/tickwatch-probe/run/<probe>')
    report('read output', 'curl http://127.0.0.1:30130/tickwatch-probe/log  (or probe-out.txt)')
end)
