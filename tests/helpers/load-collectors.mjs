import { readFileSync } from 'node:fs'
import { fileURLToPath } from 'node:url'
import path from 'node:path'
import { LuaFactory } from 'wasmoon'
import { toLua } from './load-registry.mjs'

const root = path.join(path.dirname(fileURLToPath(import.meta.url)), '..', '..')

// Boots the real server/collectors.lua on top of the real server/registry.lua,
// against a stub server.
//
// The stubs reproduce `probe sources`, run against FXServer-master v1.0.0.32561
// on a framework server holding 100 resources. Everything below that could have
// been assumed instead was measured, and the ones that matter are:
//
//   GetPlayerPing returns 0 for a source that is not connected, and does not
//   raise — for a number or a string argument alike.
//   GetResourceByFindIndex is 0-based; index -1 and index n both return nil.
//   GetResourceState returns 'missing' for a name that is not a resource.
//   GetConvar('gamename') returns empty on this build, so the label has to come
//   from somewhere else.
//   GetGameTimer is milliseconds since the server process started.
//
// Reproduce with:
//   curl http://127.0.0.1:30130/tickwatch-probe/run/sources
export const WORLD = `
    local world = {
        convars = {},
        players = {},
        pings = {},
        entities = { ped = 0, vehicle = 0, object = 0 },
        resources = {},
        timer = 0,
    }

    T_calls = {}

    local function count(name)
        T_calls[name] = (T_calls[name] or 0) + 1
    end

    function T_world(t)
        for k, v in pairs(t) do world[k] = v end
    end

    function T_setTimer(ms) world.timer = ms end
    function T_callCount(name) return T_calls[name] or 0 end
    function T_resetCalls() T_calls = {} end

    -- Captured rather than printed: a retirement message is something the suite
    -- asserts on, and a test run should not be noisy to be correct.
    T_printed = {}
    function print(line) T_printed[#T_printed + 1] = tostring(line) end

    function GetGameTimer()
        count('GetGameTimer')
        return world.timer
    end

    function GetConvar(name, default)
        local v = world.convars[name:lower()]
        if v == nil then return default end
        return v
    end

    function GetConvarInt(name, default)
        local v = world.convars[name:lower()]
        if v == nil or v == '' then return default end
        local n = tonumber(v)
        if n == nil then return default end
        return math.floor(n)
    end

    -- Returns a fresh array of source ids. They are strings on this runtime,
    -- which could not be confirmed with no client connected — so the stub hands
    -- back whatever the test set, and one test sets numbers to prove the pass
    -- does not care.
    function GetPlayers()
        count('GetPlayers')
        local out = {}
        for i = 1, #world.players do out[i] = world.players[i] end
        return out
    end

    -- Measured: 0 for an unknown source, never an error.
    function GetPlayerPing(src)
        count('GetPlayerPing')
        return world.pings[tostring(src)] or 0
    end

    local function entityList(native, kind)
        return function()
            count(native)
            local out = {}
            for i = 1, (world.entities[kind] or 0) do out[i] = i end
            return out
        end
    end

    GetAllPeds = entityList('GetAllPeds', 'ped')
    GetAllVehicles = entityList('GetAllVehicles', 'vehicle')
    GetAllObjects = entityList('GetAllObjects', 'object')

    function GetNumResources()
        count('GetNumResources')
        return #world.resources
    end

    -- Zero-based, measured. The stub is deliberately strict about it: an
    -- off-by-one in the collector has to produce a wrong answer here, not a
    -- forgiving one.
    function GetResourceByFindIndex(i)
        count('GetResourceByFindIndex')
        if type(i) ~= 'number' or i < 0 or i >= #world.resources then return nil end
        return world.resources[i + 1].name
    end

    function GetResourceState(name)
        count('GetResourceState')
        for i = 1, #world.resources do
            if world.resources[i].name == name then return world.resources[i].state end
        end
        return 'missing'
    end

    -- Threads are recorded, not run. A collector thread loops forever, so the
    -- suite drives one by hand with a wait budget instead.
    local threads = {}
    local waitBudget = 0
    local lastWait = -1

    function CreateThread(fn)
        threads[#threads + 1] = fn
    end

    function Wait(ms)
        count('Wait')
        lastWait = ms
        waitBudget = waitBudget - 1
        if waitBudget <= 0 then error('T_STOP', 0) end
    end

    function T_threadCount() return #threads end

    --- Run thread i until it has waited that many times, or until it returns.
    --- Reports which of the two happened, because a collector that retires
    --- returns and one that is healthy does not.
    function T_runThread(i, waits)
        waitBudget = waits or 1
        lastWait = -1

        local ok, err = pcall(threads[i])
        if not ok and err ~= 'T_STOP' then error(err, 0) end

        return ('%s:%d'):format(ok and 'returned' or 'waiting', lastWait)
    end

    T_events = {}
    function AddEventHandler(name, fn)
        T_events[name] = fn
        return name
    end
`

export async function loadCollectors(world = {}) {
    const lua = await new LuaFactory().createEngine()

    await lua.doString(WORLD)
    await lua.doString(readFileSync(path.join(root, 'server', 'registry.lua'), 'utf8'))
    await lua.doString(readFileSync(path.join(root, 'server', 'collectors.lua'), 'utf8'))

    await lua.doString(`
        function T_eval(src)
            local fn, err = load(src, 'harness')
            if not fn then error(err, 0) end
            return fn()
        end

        -- In registration order, which is the order they render in.
        function T_metricNames()
            local names = {}
            for i = 1, #R.order do names[i] = R.order[i].name end
            return names
        end
    `)

    const run = lua.global.get('T_eval')

    // A registry of its own rather than the _G.Metrics registry.lua creates, so
    // a test starts from a known empty state.
    run('R = Registry.new()')
    run(`T_world(${toLua(normalise(world))})`)

    return {
        lua,
        run,

        register: () => run('Collectors.register(R)'),
        pass: name => run(`Collectors.pass[${toLua(name)}](R)`),
        render: () => run('return R:render()'),

        world: patch => run(`T_world(${toLua(normalise(patch))})`),
        setTimer: ms => run(`T_setTimer(${toLua(ms)})`),

        calls: name => run(`return T_callCount(${toLua(name)})`),
        resetCalls: () => run('T_resetCalls()'),

        printed: () => {
            const joined = run("return table.concat(T_printed, '\\n')")
            return joined === '' ? [] : joined.split('\n')
        },

        dropReason: text => run(`return Collectors.dropReason(${toLua(text)})`),
        resourceUp: state => run(`return Collectors.resourceUp(${toLua(state)})`),

        onConnecting: () => run('Collectors.onConnecting(R)'),
        onJoining: source => run(`Collectors.onJoining(R, ${toLua(source)})`),
        onDropped: (source, reason) => run(`Collectors.onDropped(R, ${toLua(source)}, ${toLua(reason)})`),
        trackedSessions: () => run('return Collectors.trackedSessions()'),

        sampleConstants: info => run(`Collectors.sampleConstants(R, ${toLua(info)})`),
        start: (config, info) => run(`Collectors.start(R, ${toLua(config)}, ${toLua(info)})`),

        threadCount: () => run('return T_threadCount()'),
        runThread: (index, waits = 1) => run(`return T_runThread(${toLua(index)}, ${toLua(waits)})`),
        hasEvent: name => run(`return T_events[${toLua(name)}] ~= nil`),

        // Read a metric definition off the registry, so a test asserts against
        // what was actually registered rather than against the catalog table.
        metric: (name, field) => run(`return R.metrics[${toLua(name)}][${toLua(field)}]`),
        seriesCount: name => run(`return R.metrics[${toLua(name)}].seriesCount`),
        metricNames: () => run("return table.concat(T_metricNames(), '\\n')")
    }
}

// Convar names are matched case-insensitively by the runtime, and the stub
// lowercases its store, so the fixtures have to be lowercased on the way in.
function normalise(world) {
    if (!world || !world.convars) return world

    const convars = {}
    for (const [k, v] of Object.entries(world.convars)) convars[k.toLowerCase()] = v

    return { ...world, convars }
}

// A default configuration shaped like the one Config.load() returns, for tests
// about scheduling rather than about configuration.
export const CONFIG = {
    renderIntervalMs: 5000,
    playersIntervalMs: 10000,
    entitiesIntervalMs: 10000,
    resourcesIntervalMs: 30000
}

export function resourceList(spec) {
    return Object.entries(spec).map(([name, state]) => ({ name, state }))
}
