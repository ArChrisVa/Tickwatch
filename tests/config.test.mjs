import { test } from 'node:test'
import assert from 'node:assert/strict'
import { loadConfig, GOOD_TOKEN } from './helpers/load-config.mjs'

const TOKEN = 'tickwatch_token'

// Most tests are about something other than the token, and an unset token makes
// the config refuse to serve. Supplying a valid one keeps each test's failure
// attributable to the thing it is testing.
const withToken = extra => ({ [TOKEN]: GOOD_TOKEN, ...extra })

// A problem line matching a substring. The exact wording is not the contract —
// that a misconfiguration is *reported at all* is.
const reports = (problems, fragment) =>
    problems.some(p => p.toLowerCase().includes(fragment.toLowerCase()))

//------------------------------------------------------------------------------
// Defaults
//------------------------------------------------------------------------------

test('an unconfigured server gets the documented defaults', async () => {
    const c = await loadConfig(withToken())

    assert.equal(c.get('enabled'), true)
    assert.equal(c.get('renderIntervalMs'), 5000)
    assert.equal(c.get('maxAgeMs'), 15000)
    assert.equal(c.get('maxPending'), 8)
    assert.equal(c.get('playersIntervalMs'), 10000)
    assert.equal(c.get('entitiesIntervalMs'), 10000)
    assert.equal(c.get('resourcesIntervalMs'), 30000)
})

test('the series cap default is the measured one, not a round number', async () => {
    const c = await loadConfig(withToken())

    // 500 series of the worst measured shape — a labelled histogram at
    // 1183.5 B/series — is ~578 KiB for one metric. If this number changes, the
    // README's stated memory budget has to change with it.
    assert.equal(c.get('seriesCap'), 500)
})

test('a clean configuration reports no problems', async () => {
    const c = await loadConfig(withToken())

    assert.deepEqual(c.problems(), [])
    assert.equal(c.get('ok'), true)
})

//------------------------------------------------------------------------------
// The token
//------------------------------------------------------------------------------

test('an unset token refuses to serve', async () => {
    const c = await loadConfig({})

    assert.equal(c.get('ok'), false)
    assert.ok(reports(c.problems(), 'is not set'))
})

test('the refusal names the right convar verb', async () => {
    const c = await loadConfig({})

    // The three verbs are not interchangeable and two of them leak the token.
    // An operator reading this line should not have to go and look it up.
    const [problem] = c.problems()
    assert.ok(problem.includes('sets'), 'should warn about sets')
    assert.ok(problem.includes('setr'), 'should warn about setr')
})

test('a correct token matches and a wrong one does not', async () => {
    const c = await loadConfig(withToken())

    assert.equal(c.tokenMatches(GOOD_TOKEN), true)
    assert.equal(c.tokenMatches('wrong'), false)

    // Same length as the real token, differing in one byte. The comparison is
    // length-independent, so this is the case that actually exercises it.
    const nearMiss = GOOD_TOKEN.slice(0, -1) + 'X'
    assert.equal(c.tokenMatches(nearMiss), false)
})

test('a prefix of the token does not match', async () => {
    const c = await loadConfig(withToken())

    assert.equal(c.tokenMatches(GOOD_TOKEN.slice(0, 5)), false)
    assert.equal(c.tokenMatches(GOOD_TOKEN + 'extra'), false)
    assert.equal(c.tokenMatches(''), false)
})

test('a non-string credential is rejected rather than raising', async () => {
    const c = await loadConfig(withToken())

    // A missing Authorization header arrives as nil. The handler should get
    // false back, not an error thrown inside a request.
    assert.equal(c.tokenMatches(null), false)
    assert.equal(c.tokenMatches(42), false)
    assert.equal(c.tokenMatches(true), false)
})

test('nothing matches when no token is configured', async () => {
    const c = await loadConfig({})

    // The empty string is the internal "unset" value, so this is the case where
    // a naive comparison would let an empty Authorization header through.
    assert.equal(c.tokenMatches(''), false)
    assert.equal(c.tokenMatches('anything'), false)
})

test('surrounding whitespace is trimmed and reported', async () => {
    const c = await loadConfig({ [TOKEN]: `  ${GOOD_TOKEN}  ` })

    assert.equal(c.get('ok'), true)
    assert.equal(c.tokenMatches(GOOD_TOKEN), true)
    assert.ok(reports(c.problems(), 'whitespace'))
})

test('a short token serves but is advised against', async () => {
    const c = await loadConfig({ [TOKEN]: 'short' })

    assert.equal(c.get('ok'), true, 'the operator decides, not the exporter')
    assert.ok(reports(c.problems(), 'characters'))
})

test('the token is not a readable field on the config', async () => {
    const c = await loadConfig(withToken())

    // Hygiene rather than a boundary — everything in a resource's Lua state is
    // reachable from that state. But no accidental print of the config table
    // should print the secret.
    // Lua nil arrives as JS null, not undefined.
    assert.equal(c.get('token'), null)
    assert.equal(c.get('raw'), null)
})

test('a leaked token is detected in an /info.json body', async () => {
    const c = await loadConfig(withToken())

    // What a `sets` token looks like in the unauthenticated document. The check
    // searches for the value, not the key, because `sets` publishes it under
    // whatever name the operator chose.
    assert.equal(c.tokenLeaksInto(`{"vars":{"tickwatch_token":"${GOOD_TOKEN}"}}`), true)
    assert.equal(c.tokenLeaksInto('{"vars":{"sv_projectName":"test"}}'), false)
})

test('the leak check is inert when there is no token', async () => {
    const c = await loadConfig({})

    // Otherwise an empty token would be "found" in every body ever fetched and
    // the startup gate would refuse to serve for the wrong reason.
    assert.equal(c.tokenLeaksInto('{"vars":{}}'), false)
    assert.equal(c.tokenLeaksInto(''), false)
})

test('the leak check does not treat the token as a pattern', async () => {
    const token = 'aaa.bbb-%d+ccc'
    const c = await loadConfig({ [TOKEN]: token })

    assert.equal(c.tokenLeaksInto(`prefix ${token} suffix`), true)

    // A Lua pattern match would find this. A plain find must not.
    assert.equal(c.tokenLeaksInto('aaaxbbb-123ccc'), false)
})

test('the token convar name is exported for the startup gate', async () => {
    const c = await loadConfig(withToken())

    assert.equal(c.tokenConvar, TOKEN)
})

//------------------------------------------------------------------------------
// Booleans — the measured trap
//------------------------------------------------------------------------------

test('true and false are understood in either case', async () => {
    for (const [value, expected] of [['true', true], ['false', false], ['TRUE', true], ['FALSE', false], ['1', true], ['0', false]]) {
        const c = await loadConfig(withToken({ tickwatch_enabled: value }))

        assert.equal(c.get('enabled'), expected, `tickwatch_enabled=${value}`)
        assert.deepEqual(c.problems(), [], `tickwatch_enabled=${value} should be clean`)
    }
})

test('a boolean word the runtime does not understand is reported', async () => {
    // This is the whole reason boolConvar exists. GetConvarBool recognises only
    // true / false / 1 / 0; yes, no, on and off silently fall back to the
    // default. `set tickwatch_enabled no` would otherwise leave the exporter
    // running with nothing anywhere saying why.
    for (const value of ['no', 'yes', 'on', 'off', 'nope', 'disabled']) {
        const c = await loadConfig(withToken({ tickwatch_enabled: value }))

        assert.ok(reports(c.problems(), 'not a boolean'), `${value} should be reported`)
        assert.equal(c.get('enabled'), true, `${value} should fall back to the default`)
    }
})

test('disabling the exporter refuses to serve', async () => {
    const c = await loadConfig(withToken({ tickwatch_enabled: 'false' }))

    assert.equal(c.get('enabled'), false)
    assert.equal(c.get('ok'), false)
})

test('enabled is a real boolean, not the number the native returns', async () => {
    const c = await loadConfig(withToken({ tickwatch_enabled: 'true' }))

    // GetConvarBool returns the number 1 for true. Left unnormalised, every
    // `== true` comparison downstream would be false for a server that is
    // explicitly enabled.
    assert.equal(c.get('enabled'), true)
    assert.notEqual(c.get('enabled'), 1)
})

//------------------------------------------------------------------------------
// Numbers
//------------------------------------------------------------------------------

test('a valid interval is taken as given', async () => {
    const c = await loadConfig(withToken({ tickwatch_render_interval_ms: '2000', tickwatch_max_age_ms: '30000' }))

    assert.equal(c.get('renderIntervalMs'), 2000)
    assert.equal(c.get('maxAgeMs'), 30000)
    assert.deepEqual(c.problems(), [])
})

test('a non-numeric interval falls back and is reported', async () => {
    const c = await loadConfig(withToken({ tickwatch_players_interval_ms: 'abc' }))

    assert.equal(c.get('playersIntervalMs'), 10000)
    assert.ok(reports(c.problems(), 'is not a number'))
})

test('the word false does not silently disable a collector', async () => {
    // The one measured hole in "unparseable falls back to the default":
    // GetConvarInt reads false as 0, and 0 is this config's disable sentinel.
    // Without the raw-string screen, this typo turns a collector off and looks
    // deliberate doing it.
    const c = await loadConfig(withToken({ tickwatch_entities_interval_ms: 'false' }))

    assert.equal(c.get('entitiesIntervalMs'), 10000)
    assert.ok(reports(c.problems(), 'is not a number'))
})

test('the word true does not silently set an interval to 1 ms', async () => {
    const c = await loadConfig(withToken({ tickwatch_players_interval_ms: 'true' }))

    assert.equal(c.get('playersIntervalMs'), 10000)
    assert.ok(reports(c.problems(), 'is not a number'))
})

test('zero disables a collector and is not treated as an error', async () => {
    const c = await loadConfig(withToken({ tickwatch_entities_interval_ms: '0' }))

    assert.equal(c.get('entitiesIntervalMs'), 0)
    assert.deepEqual(c.problems(), [])
})

test('a collector interval below the floor is raised and reported', async () => {
    const c = await loadConfig(withToken({ tickwatch_players_interval_ms: '50' }))

    // Below a second a collector is closer to a per-frame thread than to a
    // schedule, and this design permits exactly one of those.
    assert.equal(c.get('playersIntervalMs'), 1000)
    assert.ok(reports(c.problems(), 'below the minimum'))
})

test('an absurd interval is lowered and reported', async () => {
    const c = await loadConfig(withToken({ tickwatch_resources_interval_ms: '99999999' }))

    assert.equal(c.get('resourcesIntervalMs'), 600000)
    assert.ok(reports(c.problems(), 'above the maximum'))
})

test('a negative interval is raised to the floor', async () => {
    const c = await loadConfig(withToken({ tickwatch_players_interval_ms: '-5000' }))

    assert.equal(c.get('playersIntervalMs'), 1000)
    assert.ok(reports(c.problems(), 'below the minimum'))
})

test('a fractional interval is truncated by the accessor', async () => {
    const c = await loadConfig(withToken({ tickwatch_players_interval_ms: '2500.9' }))

    assert.equal(c.get('playersIntervalMs'), 2500)
})

test('the render interval cannot be disabled', async () => {
    // Zero means "off" for a collector but there is no exporter without a
    // render, so this one has no disable sentinel and clamps to the floor.
    const c = await loadConfig(withToken({ tickwatch_render_interval_ms: '0' }))

    assert.equal(c.get('renderIntervalMs'), 1000)
    assert.ok(reports(c.problems(), 'below the minimum'))
})

test('the pending queue bound is clamped to something serveable', async () => {
    const low = await loadConfig(withToken({ tickwatch_max_pending: '0' }))
    assert.equal(low.get('maxPending'), 1)

    const high = await loadConfig(withToken({ tickwatch_max_pending: '100000' }))
    assert.equal(high.get('maxPending'), 64)
    assert.ok(reports(high.problems(), 'above the maximum'))
})

//------------------------------------------------------------------------------
// Cross-field
//------------------------------------------------------------------------------

test('freshness cannot be tighter than the render schedule', async () => {
    const c = await loadConfig(withToken({
        tickwatch_render_interval_ms: '10000',
        tickwatch_max_age_ms: '2000'
    }))

    // Asking for data fresher than it is ever produced means every scrape finds
    // a stale cache and defers, which turns the bounded pending queue into the
    // normal path and its drop policy into routine data loss.
    assert.equal(c.get('maxAgeMs'), 20000)
    assert.ok(reports(c.problems(), 'under twice'))
})

test('a freshness threshold at exactly twice the interval is left alone', async () => {
    const c = await loadConfig(withToken({
        tickwatch_render_interval_ms: '5000',
        tickwatch_max_age_ms: '10000'
    }))

    assert.equal(c.get('maxAgeMs'), 10000)
    assert.deepEqual(c.problems(), [])
})

test('the cross-field fix runs after clamping, not before', async () => {
    // render is asked for 100 (clamped up to 1000) and maxAge for 1500. Against
    // the requested value 1500 is fine; against the value actually in effect it
    // is not. Checking the wrong one leaves the config internally inconsistent.
    const c = await loadConfig(withToken({
        tickwatch_render_interval_ms: '100',
        tickwatch_max_age_ms: '1500'
    }))

    assert.equal(c.get('renderIntervalMs'), 1000)
    assert.equal(c.get('maxAgeMs'), 2000)
})

//------------------------------------------------------------------------------
// Reporting
//------------------------------------------------------------------------------

test('several independent mistakes are all reported', async () => {
    const c = await loadConfig({
        tickwatch_enabled: 'yes',
        tickwatch_players_interval_ms: 'abc',
        tickwatch_max_pending: '99999'
    })

    // A startup banner that stops at the first problem sends the operator round
    // the restart loop once per mistake.
    const problems = c.problems()

    assert.ok(reports(problems, 'not a boolean'))
    assert.ok(reports(problems, 'is not a number'))
    assert.ok(reports(problems, 'above the maximum'))
    assert.ok(reports(problems, 'is not set'))
    assert.ok(problems.length >= 4, `expected at least 4 problems, got ${problems.length}`)
})

test('no problem message contains the token', async () => {
    const c = await loadConfig({
        [TOKEN]: `  ${GOOD_TOKEN}  `,
        tickwatch_players_interval_ms: 'abc'
    })

    // The banner is printed to the console and consoles get pasted into issues.
    for (const problem of c.problems())
        assert.ok(!problem.includes(GOOD_TOKEN), `problem line leaked the token: ${problem}`)
})
