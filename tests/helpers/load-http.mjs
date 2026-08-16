import { readFileSync } from 'node:fs'
import { fileURLToPath } from 'node:url'
import path from 'node:path'
import { LuaFactory } from 'wasmoon'
import { toLua } from './load-registry.mjs'
import { WORLD } from './load-collectors.mjs'

const root = path.join(path.dirname(fileURLToPath(import.meta.url)), '..', '..')

// Boots the whole server side — config, registry, collectors, http — against a
// stub runtime, and drives real requests through the real handler.
//
// The request and response objects are modelled from `probe http`, and one
// detail of that model is doing work rather than decorating: **res.send,
// res.write and res.writeHead are callable tables on this runtime, not
// functions**. `type(res.send)` reports 'table'. Building the stubs the obvious
// way, as plain functions, would let a `type(x) == 'function'` guard pass here
// and fail on the server — which is the exact bug the note exists to prevent. So
// every method on both objects is a table with a __call metamethod, and the
// suite is strictly harder to satisfy than the runtime.
//
// Header keys are passed through verbatim by this runtime — measured with
// `authorization`, `Authorization` and `AUTHORIZATION`, all of which arrived
// unchanged — so the stub stores whatever the test wrote and never normalises.
const HTTP_WORLD = `
    -- config.lua reads this one and the collectors' world does not define it.
    -- Modelled from probe convartypes, quirks included: it returns the NUMBER 1
    -- for true and the BOOLEAN false for false, never boolean true, and it
    -- recognises only true / false / 1 / 0.
    local BOOLS = { ['true'] = true, ['false'] = false, ['1'] = true, ['0'] = false }

    function GetConvarBool(name, default)
        local v = GetConvar(name, '')
        local b = nil

        if v ~= '' then b = BOOLS[v:lower()] end
        if b == nil then b = default end

        if b then return 1 end
        return false
    end

    local function callable(fn)
        return setmetatable({}, { __call = function(_, ...) return fn(...) end })
    end

    T_responses = {}
    T_handlers = {}

    function SetHttpHandler(fn)
        T_handlers[#T_handlers + 1] = fn
    end

    function T_handlerCount() return #T_handlers end

    --- Drive one request through the registered handler. Returns its index.
    function T_request(spec)
        local rec = {
            status = nil,
            body = nil,
            headers = {},
            sends = 0,
            heads = 0,
            cancel = nil,
        }

        T_responses[#T_responses + 1] = rec

        local res = {
            writeHead = callable(function(status, headers)
                rec.status = status
                rec.heads = rec.heads + 1
                if type(headers) == 'table' then
                    for k, v in pairs(headers) do rec.headers[k] = v end
                end
            end),
            send = callable(function(body)
                rec.body = body
                rec.sends = rec.sends + 1
            end),
            write = callable(function() end),
        }

        local req = {
            path = spec.path,
            method = spec.method or 'GET',
            headers = spec.headers or {},
            address = '127.0.0.1:54321',
            setCancelHandler = callable(function(fn) rec.cancel = fn end),
            setDataHandler = callable(function() end),
        }

        local handler = T_handlers[#T_handlers]
        if handler == nil then error('no handler registered', 0) end

        handler(req, res)
        return #T_responses
    end

    function T_res(i, field) return T_responses[i][field] end
    function T_resHeader(i, name) return T_responses[i].headers[name] end
    function T_responseCount() return #T_responses end

    --- Simulate the client going away, the way setCancelHandler reports it.
    function T_cancel(i)
        local rec = T_responses[i]
        if rec.cancel then rec.cancel() end
        return rec.cancel ~= nil
    end
`

export async function loadHttp(options = {}) {
    const {
        token = 'a-token-long-enough-to-pass',
        convars = {},
        world = {},
    } = options

    const lua = await new LuaFactory().createEngine()

    await lua.doString(WORLD)
    await lua.doString(HTTP_WORLD)

    for (const file of [
        'config.lua',
        'server/registry.lua',
        'server/collectors.lua',
        'server/http.lua'
    ]) {
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

    const allConvars = { tickwatch_token: token, ...convars }
    const lowered = {}
    for (const [k, v] of Object.entries(allConvars)) lowered[k.toLowerCase()] = v

    run(`T_world(${toLua({ ...world, convars: lowered })})`)

    // The real config, not a stand-in. The token comparison under test is the
    // one config.lua ships, including its length-independent compare.
    run('C = Config.load()')
    run('R = Registry.new({ defaultCap = C.seriesCap })')
    run('Collectors.register(R)')

    // The handler, built but not started: Http.start would also spawn the render
    // loop, and a test that wants a render wants to say when.
    run('SetHttpHandler(Http.handler(R, C, Collectors))')

    return {
        lua,
        run,

        request: spec => run(`return T_request(${toLua(spec)})`),
        status: i => run(`return T_res(${toLua(i)}, 'status')`),
        body: i => run(`return T_res(${toLua(i)}, 'body')`),
        sends: i => run(`return T_res(${toLua(i)}, 'sends')`),
        header: (i, name) => run(`return T_resHeader(${toLua(i)}, ${toLua(name)})`),
        cancel: i => run(`return T_cancel(${toLua(i)})`),

        render: () => run('Http.render(R, Collectors)'),
        start: () => run('Http.start(R, C, Collectors)'),
        state: field => run(`return Http.state()[${toLua(field)}]`),

        route: p => run(`return Http.route(${toLua(p)})`),
        authorised: headers => run(`return Http.authorised(C, { headers = ${toLua(headers)} })`),

        setTimer: ms => run(`T_setTimer(${toLua(ms)})`),
        world: patch => run(`T_world(${toLua(patch)})`),
        handlerCount: () => run('return T_handlerCount()'),
        threadCount: () => run('return T_threadCount()'),
        printed: () => {
            const joined = run("return table.concat(T_printed, '\\n')")
            return joined === '' ? [] : joined.split('\n')
        },

        seriesValue: (name, labels) =>
            run(`local s = R:seriesFor(R.metrics[${toLua(name)}], ${toLua(labels)}); return s and s.value or nil`),

        config: field => run(`return C[${toLua(field)}]`)
    }
}

export const TOKEN = 'a-token-long-enough-to-pass'
