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

-- FXServer's own default. A server.cfg with no endpoint_add_tcp line is legal
-- and listens here, so the fallback has to match the platform rather than
-- whatever port the machine this was written on happened to use.
local DEFAULT_PORT = '30120'

local function selfBase()
    local endpoint = GetConvar('endpoint_add_tcp', '')
    local port = endpoint:match(':(%d+)')

    -- Loopback rather than the bound address: the request never leaves the host,
    -- and a server bound to 0.0.0.0 has no address to send it to otherwise.
    return ('http://127.0.0.1:%s'):format(port or DEFAULT_PORT)
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

--- Fetch /info.json with retries. Returns the body, or nil and the last error.
local function fetchInfo()
    local url = selfBase() .. '/info.json'
    local lastErr

    for attempt = 1, INFO_ATTEMPTS do
        local body, err = httpGet(url, INFO_TIMEOUT_MS)
        if body then return body, url end

        lastErr = err
        if attempt < INFO_ATTEMPTS then Wait(INFO_RETRY_MS) end
    end

    return nil, url, lastErr
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
    local body, url, err = fetchInfo()

    if not body then
        -- Refusing on a failed diagnostic costs an operator whose endpoint is
        -- briefly unreachable at boot their exporter. Still the right way round:
        -- a security check that fails open is not a check.
        say('could not read %s after %d attempts (%s)', url, INFO_ATTEMPTS, tostring(err))
        say('refusing to start: the token could not be checked for public exposure')
        if GetConvar('endpoint_add_tcp', '') == '' then
            say('no endpoint_add_tcp is set, so port %s was assumed — set it if the server listens elsewhere',
                DEFAULT_PORT)
        end
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

    say('serving /tickwatch/metrics on the game port (%s)', selfBase())
    if deferred > 0 then
        say('registered %d metric(s) declared by other resources before startup finished', deferred)
    end
    say('render every %d ms, payload served up to %d ms old, %d series per metric',
        config.renderIntervalMs, config.maxAgeMs, config.seriesCap)
    say('this endpoint is bearer-token auth over plaintext HTTP on a public port — '
        .. 'put it behind a proxy or a firewall rule for anything real')
end)
