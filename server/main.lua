--[[
    tickwatch — server/main.lua

    The startup sequence, and the only file that decides whether this resource
    serves anything at all.

    The order is the point: configuration, then the two refusals, then
    registration, then serving. Nothing listens on the game port until every
    check above it has passed — serving first and validating afterwards leaves a
    window where a misconfigured endpoint is reachable.

    Two conditions refuse outright: no scrape token, or a token publicly readable
    in the server's own /info.json. Everything else is clamped and survived.
]]

local BANNER = '[tickwatch]'

-- /info.json is served by this same process, so a failure is not a network
-- problem — but it is not instant at resource start either.
local INFO_ATTEMPTS = 5
local INFO_RETRY_MS = 2000
local INFO_TIMEOUT_MS = 5000

local function say(fmt, ...)
    print(('%s ' .. fmt):format(BANNER, ...))
end

--------------------------------------------------------------------------------
-- The server's own /info.json
--------------------------------------------------------------------------------

-- FXServer's default, and the last resort.
local DEFAULT_PORT = '30120'

-- Published into our own /info.json for the length of the check, so the endpoint
-- that answers can be identified as this process rather than assumed to be.
local PROBE_CONVAR = 'tickwatch_probe'

local function trim(s)
    return (s:gsub('^%s+', ''):gsub('%s+$', ''))
end

--- Ports this server might be listening on, best first.
---
--- Measured on FXServer v1.0.0.25770: `endpoint_add_tcp` is a command, not a
--- convar, so GetConvar returns empty for it and parsing it never worked on any
--- server. `netPort` is the one that answers. Both are kept — the parse is
--- harmless if a build ever does set it — and the identity check below is what
--- makes a wrong guess safe rather than silent.
local function selfPorts()
    local ports, seen = {}, {}

    local function add(p)
        p = p and trim(tostring(p)) or ''
        if p ~= '' and p:match('^%d+$') and not seen[p] then
            seen[p] = true
            ports[#ports + 1] = p
        end
    end

    add(GetConvar('tickwatch_self_port', ''))
    add(GetConvar('netPort', ''))
    add(GetConvar('endpoint_add_tcp', ''):match(':(%d+)'))
    add(DEFAULT_PORT)

    return ports
end

--- Loopback rather than the bound address: the request never leaves the host,
--- and a server bound to 0.0.0.0 has no address to send it to otherwise.
local function urlFor(port)
    return ('http://127.0.0.1:%s/info.json'):format(port)
end

--- One blocking GET, on a thread that can wait.
local function httpGet(url, timeoutMs)
    local done, body, code = false, nil, nil

    local ok, err = pcall(function()
        PerformHttpRequest(url, function(c, d)
            code, body, done = c, d, true
        end, 'GET', '', {})
    end)

    if not ok then
        return nil, 'PerformHttpRequest raised: ' .. tostring(err)
    end

    local deadline = GetGameTimer() + timeoutMs
    while not done and GetGameTimer() < deadline do
        Wait(25)
    end

    if not done then return nil, 'timeout' end
    if code ~= 200 then return nil, 'HTTP ' .. tostring(code) end

    return body
end

--- Find this server's own /info.json and return its body, the URL it came from,
--- and nil; or nil, the ports tried, and the last error.
---
--- The nonce is what makes this correct rather than hopeful. Two servers on one
--- machine both answer on loopback, and the wrong one's /info.json would pass a
--- token check that means nothing — the token would be absent from it because it
--- belongs to a different server, not because it is private. So a body is only
--- trusted if it contains a value we published into our own /info.json moments
--- earlier. An endpoint that cannot prove it is us is not us.
local function fetchOwnInfo(nonce)
    local ports = selfPorts()
    local lastErr

    -- Said out loud, once per URL. A candidate that answers but is not us is the
    -- interesting case: the operator has a stale port configured, and the
    -- fall-through would otherwise succeed silently and leave them believing a
    -- wrong number was used. Once, not per attempt — five identical lines read
    -- as a fault rather than a note.
    local warned = {}

    for attempt = 1, INFO_ATTEMPTS do
        for i = 1, #ports do
            local url = urlFor(ports[i])
            local body, err = httpGet(url, INFO_TIMEOUT_MS)

            if body then
                if body:find(nonce, 1, true) then
                    return body, url
                end
                lastErr = ('%s answered, but it is a different server'):format(url)
                if not warned[url] then
                    warned[url] = true
                    say('%s — ignoring it', lastErr)
                end
            else
                lastErr = ('%s: %s'):format(url, tostring(err))
            end
        end

        if attempt < INFO_ATTEMPTS then Wait(INFO_RETRY_MS) end
    end

    return nil, table.concat(ports, ', '), lastErr
end

--- A value an unrelated server cannot be holding. Not a secret — it is published
--- in a public document by design, and cleared once the check is done.
local function makeNonce()
    return ('%x%x%x'):format(GetGameTimer(), math.random(0, 0xFFFFFF), math.random(0, 0xFFFFFF))
end

--- Matched rather than parsed: one pattern is a smaller thing to depend on than
--- a JSON parser, and the token check below works on raw text either way. A
--- second field needed here is the moment to stop and use one.
local function gamenameFrom(body)
    return body:match('"gamename"%s*:%s*"([^"]*)"')
end

--------------------------------------------------------------------------------
-- Boot
--------------------------------------------------------------------------------

CreateThread(function()
    local config = Config.load()

    for i = 1, #config.problems do
        say('config: %s', config.problems[i])
    end

    if not config.enabled then
        say('disabled by convar — not starting')
        Exports.refuseToStart()
        return
    end

    if not config.ok then
        say('refusing to start')
        Exports.refuseToStart()
        return
    end

    -- The gate. `sets` publishes a convar in the unauthenticated /info.json, and
    -- that is the one of the three verbs detectable from inside the server —
    -- `setr` broadcasts to every client and reports nothing. One case out of two
    -- bad ones, said out loud rather than implying the check is complete.
    local nonce = makeNonce()
    SetConvarServerInfo(PROBE_CONVAR, nonce)

    local body, url, err = fetchOwnInfo(nonce)

    -- Cleared on every path. It is not a secret, but it is noise in a public
    -- document and it advertises what is installed.
    SetConvarServerInfo(PROBE_CONVAR, '')

    if not body then
        -- Refusing on a failed diagnostic costs an operator whose endpoint is
        -- briefly unreachable at boot their exporter. Still the right way round:
        -- a security check that fails open is not a check.
        say('could not identify this server\'s own /info.json on port(s) %s after %d attempts',
            url, INFO_ATTEMPTS)
        say('last error: %s', tostring(err))
        say('refusing to start: the token could not be checked for public exposure')
        say('if this server listens somewhere else, set tickwatch_self_port to its HTTP port')
        Exports.refuseToStart()
        return
    end

    if config.tokenLeaksInto(body) then
        say('the scrape token is publicly readable in %s', url)
        say('it was set with `sets`, which publishes it. Use `set` instead, and rotate it.')
        say('refusing to start')
        Exports.refuseToStart()
        return
    end

    local gamename = gamenameFrom(body)

    -- Created here rather than in registry.lua, because the cap is configuration.
    Metrics = Registry.new({ defaultCap = config.seriesCap })

    Collectors.register(Metrics)
    Collectors.start(Metrics, config, { gamename = gamename })
    Http.start(Metrics, config, Collectors)

    -- Last, and only on this path. Every refusal above returns without binding,
    -- so a caller gets a visible refusal rather than a write into a registry
    -- nothing will render. Replays anything declared while we were starting.
    local deferred = Exports.pending()
    Exports.bind(Metrics)

    -- For callers that would rather wait than rely on the queue. After bind, so
    -- a handler can register and write immediately.
    TriggerEvent('tickwatch:ready')

    -- The URL is the one that proved it was us, not a guess reported as fact.
    say('serving /tickwatch/metrics on %s', (url:gsub('/info%.json$', '/tickwatch/metrics')))
    if deferred > 0 then
        say('registered %d metric(s) declared by other resources before startup finished', deferred)
    end
    say('render every %d ms, payload served up to %d ms old, %d series per metric',
        config.renderIntervalMs, config.maxAgeMs, config.seriesCap)
    say('this endpoint is bearer-token auth over plaintext HTTP on a public port — '
        .. 'put it behind a proxy or a firewall rule for anything real')
end)
