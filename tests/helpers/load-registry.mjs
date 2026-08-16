import { readFileSync } from 'node:fs'
import { fileURLToPath } from 'node:url'
import path from 'node:path'
import { LuaFactory } from 'wasmoon'

const root = path.join(path.dirname(fileURLToPath(import.meta.url)), '..', '..')

// Boots the real server/registry.lua in a wasmoon Lua VM. There is no local
// FiveM interpreter, and the registry is the one file in the resource that
// touches no native at all, so it runs unmodified — the code under test is the
// code that ships, not a port of it.
//
// table.create is absent from stock Lua and the registry falls back to a plain
// table when it is missing. That changes allocation behaviour, never semantics,
// so every assertion here holds on both runtimes.
//
// Calls cross the bridge as generated Lua source rather than as JS values.
// wasmoon hands a JS object to Lua as *userdata* with an __index metamethod, not
// as a table: type() reports 'userdata' and pairs() does not work on it. The
// registry validates that it was given a real table, and that check is worth
// keeping, so the harness builds real tables instead of the registry loosening.
export async function loadRegistry(opts = {}) {
    const lua = await new LuaFactory().createEngine()

    await lua.doString(readFileSync(path.join(root, 'server', 'registry.lua'), 'utf8'))

    // The seam. Calling a Lua function fetched with global.get is synchronous,
    // unlike doString, which keeps the tests free of await on every line and
    // lets assert.throws see the errors the registry raises.
    await lua.doString(`
        function T_eval(src)
            local fn, err = load(src, 'harness')
            if not fn then error(err, 0) end
            return fn()
        end
    `)

    const run = lua.global.get('T_eval')

    run(`R = Registry.new(${toLua({ defaultCap: opts.defaultCap })})`)

    return {
        lua,
        run,

        register: def => run(`R:register(${toLua(def)})`),
        inc: (name, labels, value) => run(`R:inc(${toLua(name)}, ${toLua(labels)}, ${toLua(value)})`),
        set: (name, labels, value) => run(`R:set(${toLua(name)}, ${toLua(labels)}, ${toLua(value)})`),
        observe: (name, labels, value) => run(`R:observe(${toLua(name)}, ${toLua(labels)}, ${toLua(value)})`),
        render: () => run('return R:render()'),

        seriesCount: name => run(`return R.metrics[${toLua(name)}].seriesCount`),

        // Sends a string into Lua and straight back out. Used by the suite to
        // prove the bridge is lossless before any test trusts it to carry a
        // string full of backslashes and quotes.
        echo: value => run(`return ${toLua(value)}`)
    }
}

//------------------------------------------------------------------------------
// JS values as Lua source
//------------------------------------------------------------------------------

export function toLua(value) {
    if (value === undefined || value === null) return 'nil'
    if (typeof value === 'boolean') return value ? 'true' : 'false'
    if (typeof value === 'number') return luaNumber(value)
    if (typeof value === 'string') return luaString(value)

    if (Array.isArray(value))
        return `{${value.map(toLua).join(',')}}`

    if (typeof value === 'object')
        return `{${Object.entries(value).map(([k, v]) => `[${luaString(k)}]=${toLua(v)}`).join(',')}}`

    throw new Error(`cannot express ${typeof value} as Lua`)
}

function luaNumber(n) {
    if (Number.isNaN(n)) return '(0/0)'
    if (n === Infinity) return 'math.huge'
    if (n === -Infinity) return '-math.huge'

    // Lua 5.4 distinguishes integers from floats by how the literal is written,
    // and String() preserves that: 1 stays an integer, 0.001 is a float.
    return String(n)
}

function luaString(s) {
    let out = '"'

    for (const ch of s) {
        const code = ch.codePointAt(0)

        if (ch === '\\') out += '\\\\'
        else if (ch === '"') out += '\\"'
        else if (ch === '\n') out += '\\n'
        else if (ch === '\r') out += '\\r'
        else if (ch === '\t') out += '\\t'
        else if (code < 0x20 || code === 0x7f) out += '\\' + String(code).padStart(3, '0')
        else out += ch
    }

    return out + '"'
}

//------------------------------------------------------------------------------
// Exposition parsing
//------------------------------------------------------------------------------

// Parse exposition text into something assertable.
//
// The tests parse rather than string-match on purpose. A test that asserts on a
// substring passes for the wrong reasons — it cannot tell a bucket line from a
// sum line, and it silently ignores everything it did not look at. Parsing also
// means the tests fail if the output stops being parseable at all, which is the
// property the exporter actually needs.
export function parseExposition(text) {
    const help = {}
    const type = {}
    const samples = []

    for (const line of text.split('\n')) {
        if (line === '') continue

        if (line.startsWith('# HELP ')) {
            const rest = line.slice('# HELP '.length)
            const space = rest.indexOf(' ')
            help[rest.slice(0, space)] = rest.slice(space + 1)
            continue
        }

        if (line.startsWith('# TYPE ')) {
            const [name, kind] = line.slice('# TYPE '.length).split(' ')
            type[name] = kind
            continue
        }

        if (line.startsWith('#')) continue

        samples.push(parseSample(line))
    }

    return {
        help,
        type,
        samples,

        // Every sample of one series name, in emission order.
        of: name => samples.filter(s => s.name === name),

        // The single sample matching a name and an exact label set.
        one(name, labels = {}) {
            const wanted = JSON.stringify(sortedEntries(labels))
            const hits = samples.filter(s =>
                s.name === name && JSON.stringify(sortedEntries(s.labels)) === wanted)

            if (hits.length !== 1)
                throw new Error(`expected exactly one ${name}${JSON.stringify(labels)}, got ${hits.length}`)

            return hits[0]
        }
    }
}

function sortedEntries(labels) {
    return Object.entries(labels).sort(([a], [b]) => a < b ? -1 : a > b ? 1 : 0)
}

// `name{a="1",b="2"} 3` or `name 3`. Label values may contain escaped quotes and
// backslashes, so the label set is walked rather than split on commas.
function parseSample(line) {
    const brace = line.indexOf('{')

    if (brace === -1) {
        const space = line.lastIndexOf(' ')
        return { name: line.slice(0, space), labels: {}, value: Number(line.slice(space + 1)), raw: line }
    }

    const name = line.slice(0, brace)
    const close = findClosingBrace(line, brace)

    return {
        name,
        labels: parseLabels(line.slice(brace + 1, close)),
        value: Number(line.slice(close + 2)),
        raw: line
    }
}

function findClosingBrace(line, from) {
    let inQuotes = false

    for (let i = from + 1; i < line.length; i++) {
        const c = line[i]

        if (inQuotes && c === '\\') { i++; continue }
        if (c === '"') { inQuotes = !inQuotes; continue }
        if (c === '}' && !inQuotes) return i
    }

    throw new Error(`unterminated label set: ${line}`)
}

function parseLabels(body) {
    const labels = {}
    let i = 0

    while (i < body.length) {
        const eq = body.indexOf('=', i)
        const name = body.slice(i, eq)

        i = eq + 2 // skip ="
        let value = ''

        while (body[i] !== '"') {
            if (body[i] === '\\') {
                const next = body[i + 1]
                value += next === 'n' ? '\n' : next
                i += 2
                continue
            }

            value += body[i]
            i++
        }

        labels[name] = value
        i += 2 // skip ",
    }

    return labels
}
