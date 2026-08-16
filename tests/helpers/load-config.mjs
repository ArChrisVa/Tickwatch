import { readFileSync } from 'node:fs'
import { fileURLToPath } from 'node:url'
import path from 'node:path'
import { LuaFactory } from 'wasmoon'
import { toLua } from './load-registry.mjs'

const root = path.join(path.dirname(fileURLToPath(import.meta.url)), '..', '..')

// Boots the real config.lua against stub convar natives.
//
// The stubs below are not guesses about how GetConvar* behaves — they reproduce
// `probe convartypes`, run against FXServer-master v1.0.0.32561. That matters,
// because a config test is only ever as good as its model of the runtime: if the
// stub is wrong in the same direction as the code, the suite agrees with itself
// and says nothing. The probe is the source of truth and lives in
// tickwatch-probe; this is a transcription of its output.
//
// Reproduce it with:
//   set tw_probe_ct_garbage "abc"   (and the rest — see the probe's case table)
//   curl http://127.0.0.1:30130/tickwatch-probe/run/convartypes
const NATIVES = `
    local store = {}

    -- Convar names are case-insensitive. Measured: a server.cfg declaring both
    -- tw_probe_ct_true and tw_probe_ct_TRUE ended up with one convar.
    function T_setConvars(t)
        store = {}
        for k, v in pairs(t) do store[k:lower()] = v end
    end

    local function raw(name)
        return store[name:lower()]
    end

    -- The only spellings any accessor recognises as boolean, case-insensitive.
    local BOOLS = { ['true'] = true, ['false'] = false, ['1'] = true, ['0'] = false }

    function GetConvar(name, default)
        local v = raw(name)
        if v == nil then return default end
        return v
    end

    -- Measured: unset, empty and unparseable text all fall back to the default.
    -- The words true and false are read as 1 and 0. A fractional value is
    -- truncated. Surrounding whitespace is tolerated.
    function GetConvarInt(name, default)
        local v = raw(name)
        if v == nil or v == '' then return default end

        local b = BOOLS[v:lower()]
        if b ~= nil then return b and 1 or 0 end

        local n = tonumber(v)
        if n == nil then return default end

        if n >= 0 then return math.floor(n) end
        return -math.floor(-n)
    end

    -- Measured: as the integer accessor, except the words true and false are NOT
    -- recognised and fall back. Returns float32 precision — 12.9 reads back as
    -- 12.89999961853 — which is why nothing in config.lua uses it.
    function GetConvarFloat(name, default)
        local v = raw(name)
        if v == nil or v == '' then return default end

        local n = tonumber(v)
        if n == nil then return default end
        return n
    end

    -- Measured, and the surprising one: returns the NUMBER 1 for true and the
    -- BOOLEAN false for false. It never returns boolean true and never returns
    -- the number 0. An unrecognised word falls back to the default, which is
    -- then passed through the same shaping.
    function GetConvarBool(name, default)
        local v = raw(name)
        local b = nil

        if v ~= nil then b = BOOLS[v:lower()] end
        if b == nil then b = default end

        if b then return 1 end
        return false
    end
`

export async function loadConfig(convars = {}) {
    const lua = await new LuaFactory().createEngine()

    await lua.doString(NATIVES)
    await lua.doString(readFileSync(path.join(root, 'config.lua'), 'utf8'))

    // Same synchronous seam as the registry harness: a function fetched with
    // global.get calls synchronously and propagates Lua errors as JS throws.
    await lua.doString(`
        function T_eval(src)
            local fn, err = load(src, 'harness')
            if not fn then error(err, 0) end
            return fn()
        end
    `)

    const run = lua.global.get('T_eval')

    run(`T_setConvars(${toLua(convars)})`)
    run('C = Config.load()')

    return {
        lua,
        run,

        // Scalar fields cross the bridge cleanly. The whole table does not — it
        // holds closures — so fields are read one at a time.
        get: field => run(`return C[${toLua(field)}]`),

        // Joined and split rather than returned as a table, so the value that
        // crosses is a plain string. No problem message contains a newline.
        problems: () => {
            const joined = run("return table.concat(C.problems, '\\n')")
            return joined === '' ? [] : joined.split('\n')
        },

        tokenMatches: candidate => run(`return C.tokenMatches(${toLua(candidate)})`),
        tokenLeaksInto: body => run(`return C.tokenLeaksInto(${toLua(body)})`),

        tokenConvar: run('return Config.TOKEN_CONVAR')
    }
}

// A token long enough not to trip the length advisory, for tests that are about
// something else.
export const GOOD_TOKEN = 'a-token-long-enough-to-pass'
