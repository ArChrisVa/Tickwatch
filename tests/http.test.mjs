import test from 'node:test'
import assert from 'node:assert/strict'
import { loadHttp, TOKEN } from './helpers/load-http.mjs'
import { parseExposition } from './helpers/load-registry.mjs'

const auth = { Authorization: `Bearer ${TOKEN}` }

//------------------------------------------------------------------------------
// Route parsing
//------------------------------------------------------------------------------

test('a query string does not change the route', async () => {
    // Measured: req.path carries the query string. `/metrics?x=1` arrives as
    // exactly that, so an equality test against '/metrics' 404s a request that
    // is asking for metrics. Prometheus does not usually add parameters, which
    // is what makes this survive testing and appear once in production.
    const c = await loadHttp()

    assert.equal(c.route('/metrics'), '/metrics')
    assert.equal(c.route('/metrics?x=1'), '/metrics')
    assert.equal(c.route('/metrics?'), '/metrics')
    assert.equal(c.route('/metrics/'), '/metrics')
    assert.equal(c.route('/'), '/')
    assert.equal(c.route(''), '/')
})

test('a request with a query string is still served', async () => {
    const c = await loadHttp()
    c.render()

    const i = c.request({ path: '/metrics?collect[]=foo', headers: auth })
    assert.equal(c.status(i), 200)
})

//------------------------------------------------------------------------------
// Authorization
//------------------------------------------------------------------------------

test('the auth header is found whatever case it arrives in', async () => {
    // Measured: this runtime passes header keys through byte for byte.
    // `authorization`, `Authorization` and `AUTHORIZATION` all reach the handler
    // unchanged, and HTTP header names are case-insensitive by specification, so
    // indexing the table by one spelling 401s every client that chose another.
    const c = await loadHttp()

    assert.equal(c.authorised({ Authorization: `Bearer ${TOKEN}` }), true)
    assert.equal(c.authorised({ authorization: `Bearer ${TOKEN}` }), true)
    assert.equal(c.authorised({ AUTHORIZATION: `Bearer ${TOKEN}` }), true)
    assert.equal(c.authorised({ AuThOrIzAtIoN: `Bearer ${TOKEN}` }), true)
})

test('the bearer scheme is case-insensitive too', async () => {
    const c = await loadHttp()

    assert.equal(c.authorised({ Authorization: `bearer ${TOKEN}` }), true)
    assert.equal(c.authorised({ Authorization: `BEARER ${TOKEN}` }), true)
})

test('a wrong or missing credential is refused', async () => {
    const c = await loadHttp()

    assert.equal(c.authorised({ Authorization: 'Bearer wrong' }), false)
    assert.equal(c.authorised({ Authorization: `Bearer ${TOKEN}x` }), false)
    assert.equal(c.authorised({ Authorization: `Bearer ${TOKEN.slice(0, -1)}` }), false)
    assert.equal(c.authorised({}), false)
    assert.equal(c.authorised({ Authorization: TOKEN }), false, 'a bare token is not a bearer credential')
    assert.equal(c.authorised({ Authorization: 'Basic ' + TOKEN }), false)
})

test('surrounding whitespace in the credential is tolerated', async () => {
    const c = await loadHttp()

    assert.equal(c.authorised({ Authorization: `Bearer   ${TOKEN}  ` }), true)
})

test('an unauthorised scrape gets 401 and a challenge', async () => {
    const c = await loadHttp()
    c.render()

    const i = c.request({ path: '/metrics' })

    assert.equal(c.status(i), 401)
    assert.match(c.header(i, 'WWW-Authenticate'), /^Bearer /)
    assert.ok(!c.body(i).includes(TOKEN), 'the token must never appear in a response')
})

test('an unauthorised scrape is never handed the payload', async () => {
    const c = await loadHttp()
    c.render()

    const i = c.request({ path: '/metrics', headers: { Authorization: 'Bearer wrong' } })

    assert.equal(c.status(i), 401)
    assert.ok(!c.body(i).includes('# TYPE'), 'exposition leaked to an unauthorised client')
})

//------------------------------------------------------------------------------
// Routing
//------------------------------------------------------------------------------

test('health needs no credential and reports nothing about the server', async () => {
    const c = await loadHttp()

    const i = c.request({ path: '/health' })

    assert.equal(c.status(i), 200)
    assert.equal(c.body(i), 'ok\n')
})

test('a non-GET is 405, not 404 and not 401', async () => {
    // The distinction matters to whoever is debugging: 405 says the route
    // exists, and 401 would say the credential was the problem.
    const c = await loadHttp()
    c.render()

    assert.equal(c.status(c.request({ path: '/metrics', method: 'POST', headers: auth })), 405)
    assert.equal(c.status(c.request({ path: '/metrics', method: 'DELETE' })), 405)
    assert.equal(c.status(c.request({ path: '/health', method: 'POST' })), 405)
})

test('an unknown route is 404', async () => {
    const c = await loadHttp()

    assert.equal(c.status(c.request({ path: '/' })), 404)
    assert.equal(c.status(c.request({ path: '/admin' })), 404)
    assert.equal(c.status(c.request({ path: '/metrics/extra' })), 404)
})

test('the content type names the exposition version', async () => {
    // A scraper reads this to decide which parser to use, so the version
    // parameter is part of the contract rather than decoration.
    const c = await loadHttp()
    c.render()

    const i = c.request({ path: '/metrics', headers: auth })

    assert.equal(c.header(i, 'Content-Type'), 'text/plain; version=0.0.4; charset=utf-8')

    // No Content-Length, and this assertion is here because an earlier version
    // of this suite passed while the server did the opposite. The stub records
    // whatever the handler sets; the real runtime discards Content-Length and
    // chunk-encodes every response. A green test against a header the transport
    // throws away is the failure mode a harness has and a live check does not,
    // which is why step 5 ends with curl against a running server.
    assert.equal(c.header(i, 'Content-Length'), null)
})

test('what is served parses as exposition', async () => {
    const c = await loadHttp({ world: { resources: [{ name: 'chat', state: 'started' }] } })
    c.render()

    const i = c.request({ path: '/metrics', headers: auth })
    const p = parseExposition(c.body(i))

    assert.equal(p.type.fivem_server_up, 'gauge')
    assert.ok(p.of('fivem_server_uptime_seconds').length === 1)
})

//------------------------------------------------------------------------------
// The serving model
//------------------------------------------------------------------------------

test('a fresh payload is served from cache, and the handler never renders', async () => {
    const c = await loadHttp()
    c.render()

    const before = c.state('renderedAt')
    const i = c.request({ path: '/metrics', headers: auth })

    assert.equal(c.status(i), 200)
    assert.equal(c.state('renderedAt'), before, 'the handler rendered — that is a main-thread stall')
    assert.equal(c.state('pending'), 0)
})

test('a scrape arriving before the first render is deferred, not failed', async () => {
    const c = await loadHttp()

    const i = c.request({ path: '/metrics', headers: auth })

    assert.equal(c.sends(i), 0, 'nothing should have been sent yet')
    assert.equal(c.state('pending'), 1)
})

test('the next render completes a deferred response', async () => {
    const c = await loadHttp()

    const i = c.request({ path: '/metrics', headers: auth })
    assert.equal(c.sends(i), 0)

    c.render()

    assert.equal(c.status(i), 200)
    assert.equal(c.sends(i), 1)
    assert.equal(c.state('pending'), 0)
    assert.ok(c.body(i).includes('# TYPE fivem_server_up gauge'))
})

test('a payload past the freshness threshold defers rather than being served stale', async () => {
    const c = await loadHttp()

    c.setTimer(1000)
    c.render()

    // The default threshold is 15 s and the render was at 1 s.
    c.setTimer(20_000)
    const i = c.request({ path: '/metrics', headers: auth })

    assert.equal(c.sends(i), 0)
    assert.equal(c.state('pending'), 1)

    c.render()
    assert.equal(c.status(i), 200)
})

test('a payload inside the threshold is served even when it is not new', async () => {
    const c = await loadHttp()

    c.setTimer(1000)
    c.render()

    c.setTimer(10_000) // 9 s old, threshold is 15 s
    const i = c.request({ path: '/metrics', headers: auth })

    assert.equal(c.status(i), 200)
})

test('cache age is published, lagging by one scrape', async () => {
    // A payload cannot contain a measurement of its own age, so the value a
    // scrape reads describes the previous one. Stated in the help text.
    const c = await loadHttp()

    c.setTimer(1000)
    c.render()

    c.setTimer(5000)
    c.request({ path: '/metrics', headers: auth })

    c.render()
    const i = c.request({ path: '/metrics', headers: auth })

    assert.equal(parseExposition(c.body(i)).one('tickwatch_cache_age_seconds').value, 4)
})

test('render duration is observed into a histogram, not reported as a gauge', async () => {
    // The clock resolves to 1 ms and a render of a small registry takes tens of
    // microseconds, so a gauge would read 0 almost always and 1 occasionally.
    // As a histogram the buckets are empty of meaning below the floor but
    // _sum / _count still converges, and a registry at its cap crosses the floor
    // and gives the buckets something real to say.
    const c = await loadHttp()

    c.render()
    c.render()
    c.render()

    const i = c.request({ path: '/metrics', headers: auth })
    const p = parseExposition(c.body(i))

    // Three renders happened; the third's payload reports the first two.
    assert.ok(p.one('tickwatch_render_duration_seconds_count').value >= 2)
})

//------------------------------------------------------------------------------
// The pending queue
//------------------------------------------------------------------------------

test('the pending queue is bounded and drops the oldest', async () => {
    const c = await loadHttp({ convars: { tickwatch_max_pending: '2' } })
    assert.equal(c.config('maxPending'), 2)

    const first = c.request({ path: '/metrics', headers: auth })
    const second = c.request({ path: '/metrics', headers: auth })
    const third = c.request({ path: '/metrics', headers: auth })

    // The oldest has waited longest and is nearest its client's own timeout, so
    // it is the one whose completion is least likely to be worth anything.
    assert.equal(c.status(first), 503)
    assert.equal(c.state('pending'), 2)

    c.render()

    assert.equal(c.status(second), 200)
    assert.equal(c.status(third), 200)
    assert.equal(c.sends(first), 1, 'the dropped response was answered once, not twice')
})

test('a dropped scrape is counted, never silent', async () => {
    const c = await loadHttp({ convars: { tickwatch_max_pending: '1' } })

    c.request({ path: '/metrics', headers: auth })
    c.request({ path: '/metrics', headers: auth })

    c.render()
    const i = c.request({ path: '/metrics', headers: auth })
    const p = parseExposition(c.body(i))

    assert.equal(p.one('tickwatch_scrapes_total', { result: 'dropped' }).value, 1)
})

test('scrape outcomes are all counted', async () => {
    const c = await loadHttp()

    c.request({ path: '/metrics' })                  // unauthorized
    const deferred = c.request({ path: '/metrics', headers: auth })
    c.render()                                        // completes it: served
    c.request({ path: '/metrics', headers: auth })    // served from cache

    c.render()
    const i = c.request({ path: '/metrics', headers: auth })
    const p = parseExposition(c.body(i))

    assert.equal(c.status(deferred), 200)
    assert.equal(p.one('tickwatch_scrapes_total', { result: 'unauthorized' }).value, 1)
    assert.equal(p.one('tickwatch_scrapes_total', { result: 'deferred' }).value, 1)
    assert.ok(p.one('tickwatch_scrapes_total', { result: 'served' }).value >= 2)
})

test('a client that gave up is never written to', async () => {
    // The render loop completes responses after the handler returned, so without
    // this the exporter writes to sockets that have gone away.
    const c = await loadHttp()

    const i = c.request({ path: '/metrics', headers: auth })
    assert.equal(c.cancel(i), true, 'no cancel handler was registered')

    c.render()

    assert.equal(c.sends(i), 0)
    assert.equal(c.state('pending'), 0)
})

//------------------------------------------------------------------------------
// Wiring
//------------------------------------------------------------------------------

test('start renders once before registering the handler', async () => {
    // Otherwise the first scrape of a server's life is deferred into a queue
    // that nothing has filled yet.
    const c = await loadHttp()
    c.start()

    assert.equal(c.state('rendered'), true)
    assert.ok(c.state('bytes') > 0)
    assert.equal(c.handlerCount(), 2, 'the harness registers one; start registers the second')
})

test('start runs the render loop on its own thread', async () => {
    const c = await loadHttp()
    c.start()

    assert.equal(c.threadCount(), 1)
})

test('the response methods are callable tables, not functions', async () => {
    // This is the property the stubs model, and the reason they model it: on
    // this runtime `type(res.send)` is 'table'. A defensive
    // `type(res.send) == 'function'` check concludes the method is missing when
    // it is present, and nothing about that failure looks like a type error.
    const c = await loadHttp()
    c.render()

    const kind = c.run(`
        local seen
        SetHttpHandler(function(req, res) seen = type(res.send) end)
        T_request({ path = '/health' })
        return seen
    `)

    assert.equal(kind, 'table')
})
