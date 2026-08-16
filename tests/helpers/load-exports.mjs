import { readFileSync } from 'node:fs'
import { fileURLToPath } from 'node:url'
import path from 'node:path'
import { LuaFactory } from 'wasmoon'
import { toLua } from './load-registry.mjs'
import { WORLD } from './load-collectors.mjs'

const root = path.join(path.dirname(fileURLToPath(import.meta.url)), '..', '..')

// Boots the export API on top of the real registry and the real catalog.
//
// `exports(name, fn)` is the registration call FXServer provides. Here it only
// records, because what a test drives is the function itself — the boundary
// those calls are reached across is measured by `probe exports` on a live
// server, not modelled here. What that probe found and this suite therefore
// takes as given: arguments and tables cross intact, a returned function becomes
// a callable-table proxy, and nothing raised inside the callee reaches the
// caller as an error.
const EXPORT_WORLD = `
    T_exported = {}

    function exports(name, fn)
        T_exported[name] = fn
    end

    function T_exportNames()
        local names = {}
        for k in pairs(T_exported) do names[#names + 1] = k end
        table.sort(names)
        return table.concat(names, ',')
    end
`

export async function loadExports({ bind = true, world = {} } = {}) {
    const lua = await new LuaFactory().createEngine()

    await lua.doString(WORLD)
    await lua.doString(EXPORT_WORLD)

    for (const file of ['server/registry.lua', 'server/collectors.lua', 'server/exports.lua']) {
        await lua.doString(readFileSync(path.join(root, ...file.split('/')), 'utf8'))
    }

    await lua.doString(`
        function T_eval(src)
            local fn, err = load(src, 'harness')
            if not fn then error(err, 0) end
            return fn()
        end
    `)

    const run = lua.global.get('T_eval')

    run(`T_world(${toLua(world)})`)
    run('R = Registry.new()')
    run('Collectors.register(R)')

    if (bind) run('Exports.bind(R)')

    // Every call goes through the recorded export entry rather than the module
    // table, so the suite exercises what a caller reaches rather than what the
    // file happens to expose.
    const call = (name, args) =>
        run(`return T_exported[${toLua(name)}](${args.map(toLua).join(', ')})`)

    return {
        lua,
        run,
        call,

        register: def => call('Register', [def]),
        isRegistered: name => call('IsRegistered', [name]),
        inc: (name, labels, value) => call('Inc', [name, labels, value]),
        set: (name, labels, value) => call('Set', [name, labels, value]),
        observe: (name, labels, value) => call('Observe', [name, labels, value]),
        observeSince: (name, labels, at) => call('ObserveSince', [name, labels, at]),
        event: (name, seconds) => call('Event', [name, seconds]),
        query: (op, status, seconds) => call('Query', [op, status, seconds]),

        exportNames: () => run('return T_exportNames()').split(','),
        render: () => run('return R:render()'),
        seriesCount: name => run(`return R.metrics[${toLua(name)}] and R.metrics[${toLua(name)}].seriesCount or nil`),
        hasMetric: name => run(`return R.metrics[${toLua(name)}] ~= nil`),

        setTimer: ms => run(`T_setTimer(${toLua(ms)})`),
        unbind: () => run('Exports.unbind()'),
        bind: () => run('Exports.bind(R)'),
        pending: () => run('return Exports.pending()'),

        // Register raises rather than returning false, so a test that wants the
        // message has to catch it on the Lua side.
        tryRegister: def => {
            const out = run(`
                local ok, err = pcall(function() return T_exported['Register'](${toLua(def)}) end)
                return (ok and 'ok' or 'err') .. '\\1' .. tostring(err)
            `)
            const [status, message] = out.split('')
            return { ok: status === 'ok', message }
        },

        printed: () => {
            const joined = run("return table.concat(T_printed, '\\n')")
            return joined === '' ? [] : joined.split('\n')
        }
    }
}

// Boots shared/timed.lua the way a consuming resource actually reaches it.
//
// That file is loaded into somebody else's resource through
// `server_scripts { '@tickwatch/shared/timed.lua' }`, so it calls
// `exports['tickwatch']:ObserveSince(...)` rather than touching the module table.
// `exports` in FXServer is both callable — `exports(name, fn)` to register — and
// indexable — `exports['res']:Method()` to consume. The harness above models only
// the callable half, because nothing before this needed the other one, so the
// metatable is installed here rather than changed underneath 21 passing tests.
//
// The dispatch is deliberately direct. What these tests are about is the
// wrapper's behaviour around pcall, return values and errors; routing them
// through a simulated boundary would only re-test the boundary that
// `probe exports` already measured on a live server.
export async function loadTimed(options = {}) {
    const api = await loadExports(options)

    api.run(`
        local register = exports

        exports = setmetatable({}, {
            __call = function(_, name, fn) register(name, fn) end,

            __index = function(_, resource)
                if resource ~= 'tickwatch' then return nil end

                return setmetatable({}, {
                    __index = function(_, method)
                        return function(_self, ...)
                            local fn = T_exported[method]
                            if not fn then
                                error('no such export: ' .. tostring(method), 0)
                            end
                            return fn(...)
                        end
                    end
                })
            end
        })
    `)

    await api.lua.doString(
        readFileSync(path.join(root, 'shared', 'timed.lua'), 'utf8')
    )

    return {
        ...api,

        // Wraps a function written as Lua source. The wrapped value is kept in a
        // Lua-side slot and never crosses into JS, so what the tests observe is
        // Lua calling Lua rather than wasmoon marshalling a callback.
        wrap: (name, luaSource, labels) => {
            api.run(`T_target = ${luaSource}`)
            api.run(`T_wrapped = TickwatchTimed(${toLua(name)}, T_target, ${toLua(labels)})`)

            const argList = args => args.map(toLua).join(', ')

            return {
                call: (...args) => api.run(`return T_wrapped(${argList(args)})`),

                // Returns the outcome instead of raising, so a test can assert on
                // the message the calling resource would actually have seen.
                pcall: (...args) => {
                    const out = api.run(`
                        local r = table.pack(pcall(T_wrapped${args.length ? ', ' + argList(args) : ''}))
                        return (r[1] and 'ok' or 'err') .. '\\1' .. tostring(r[2])
                    `)
                    const [status, message] = out.split('')
                    return { ok: status === 'ok', message }
                },

                // Arity and every value, so multi-return and embedded nil can be
                // asserted rather than assumed.
                callAll: (...args) => api.run(`
                    local r = table.pack(T_wrapped(${argList(args)}))
                    local parts = {}
                    for i = 1, r.n do parts[i] = tostring(r[i]) end
                    return tostring(r.n) .. '|' .. table.concat(parts, ',')
                `)
            }
        },

        // Wrapping something that is not a function should fail at wrap time.
        tryWrap: (name, luaSource) => {
            const out = api.run(`
                local ok, err = pcall(function()
                    return TickwatchTimed(${toLua(name)}, ${luaSource})
                end)
                return (ok and 'ok' or 'err') .. '\\1' .. tostring(err)
            `)
            const [status, message] = out.split('')
            return { ok: status === 'ok', message }
        }
    }
}
