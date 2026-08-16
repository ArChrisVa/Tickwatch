--[[
    tickwatch — server/http.lua

    The scrape endpoint, and the render loop that feeds it.

    The handler never renders. HTTP handlers run on the main thread and are
    serialized, so work inside one is a server stall at a rate chosen by whoever
    is scraping — and a stall the engine's own tick histogram cannot see. The
    handler serves a cached payload or defers the response for the next
    scheduled render. See docs/platform-notes.md, HTTP handlers.
]]

local Http = {}

-- The version parameter is how a scraper picks its parser, not decoration.
local EXPOSITION_TYPE = 'text/plain; version=0.0.4; charset=utf-8'
local PLAIN_TYPE = 'text/plain; charset=utf-8'

local AUTH_HEADER = 'authorization'
local BEARER = 'bearer '

--------------------------------------------------------------------------------
-- State
--------------------------------------------------------------------------------

-- nil until the first render, which is a real state: a scrape can arrive before it.
local payload = nil
local payloadAt = 0

-- Responses waiting for the next render. Bounded: a scrape rate above the render
-- rate otherwise accumulates live response objects and nothing reports it.
local pending = {}
local pendingCount = 0

--------------------------------------------------------------------------------
-- Requests
--------------------------------------------------------------------------------

--- Find a header by name, case-insensitively.
---
--- Measured: this runtime passes header keys through byte for byte, so indexing
--- by one spelling works with Prometheus and 401s the next client. The scan is
--- linear over a handful of headers, on a request that costs far more anyway.
local function headerValue(headers, wanted)
    if type(headers) ~= 'table' then return nil end

    for key, value in pairs(headers) do
        if type(key) == 'string' and key:lower() == wanted then
            return value
        end
    end

    return nil
end

--- The credential from an Authorization header, or nil.
local function bearerToken(headers)
    local raw = headerValue(headers, AUTH_HEADER)
    if type(raw) ~= 'string' then return nil end

    -- The scheme is case-insensitive too.
    if raw:sub(1, #BEARER):lower() ~= BEARER then return nil end

    return (raw:sub(#BEARER + 1):gsub('^%s+', ''):gsub('%s+$', ''))
end

--- Does this request carry the configured token?
function Http.authorised(config, req)
    local candidate = bearerToken(type(req) == 'table' and req.headers or nil)
    if candidate == nil then return false end

    -- Comparison lives in config.lua, where the token is a closure upvalue.
    return config.tokenMatches(candidate) and true or false
end

--- The path with any query string removed. Measured: req.path carries it, so
--- `/metrics?x=1` fails an equality test against '/metrics' and 404s.
function Http.route(rawPath)
    if type(rawPath) ~= 'string' then return '/' end

    local path = rawPath:gsub('%?.*$', '')
    if path == '' then return '/' end

    -- A trailing slash names the same route. Not stripped from '/' itself.
    if #path > 1 then path = path:gsub('/+$', '') end

    return path == '' and '/' or path
end

--------------------------------------------------------------------------------
-- Responses
--------------------------------------------------------------------------------

--- Write a response. Wrapped because the socket may be gone: an error out of a
--- completion callback would take the render loop with it, not one dead client.
---
--- No Content-Length — measured, the runtime discards it and chunks regardless.
--- And do not add a `type(res.send) == 'function'` guard: res methods are
--- callable tables and report 'table'. See docs/platform-notes.md.
local function sendText(res, status, body, contentType)
    return pcall(function()
        res.writeHead(status, { ['Content-Type'] = contentType or PLAIN_TYPE })
        res.send(body)
    end)
end

local function countScrape(registry, result)
    registry:inc('tickwatch_scrapes_total', { result = result })
end

--------------------------------------------------------------------------------
-- The pending queue
--------------------------------------------------------------------------------

--- Hold a response until the next render completes it. When the queue is full
--- the OLDEST is 503'd: it is nearest its client's own timeout, so dropping it
--- keeps the responses most likely to still have somebody listening.
local function defer(registry, config, req, res)
    if pendingCount >= config.maxPending then
        local victim = table.remove(pending, 1)
        pendingCount = pendingCount - 1

        if victim and not victim.cancelled then
            sendText(victim.res, 503, 'tickwatch: pending queue full, scrape dropped\n')
        end

        countScrape(registry, 'dropped')
    end

    local entry = { res = res, at = GetGameTimer(), cancelled = false }

    -- A client that gave up must not be written to when the render lands.
    if type(req) == 'table' and req.setCancelHandler then
        pcall(function()
            req.setCancelHandler(function() entry.cancelled = true end)
        end)
    end

    pendingCount = pendingCount + 1
    pending[pendingCount] = entry

    countScrape(registry, 'deferred')
end

--- Complete every waiting response with a freshly rendered payload.
local function flushPending(registry, text)
    if pendingCount == 0 then return end

    local waiting = pending

    -- Swap out before sending: a send can run a cancel handler, and one that
    -- mutated the table being iterated would skip entries.
    pending = {}
    pendingCount = 0

    for i = 1, #waiting do
        local entry = waiting[i]
        if not entry.cancelled then
            sendText(entry.res, 200, text, EXPOSITION_TYPE)
            countScrape(registry, 'served')
        end
    end
end

--------------------------------------------------------------------------------
-- Rendering
--------------------------------------------------------------------------------

--- Render once, publish the payload, and complete anything waiting on it.
function Http.render(registry, collectors)
    -- Immediately before the render, so what a payload says about its own uptime
    -- and heap is as fresh as the payload.
    if collectors then
        pcall(collectors.pass.self, registry)
    end

    local startedAt = GetGameTimer()
    local text = registry:render()
    local finishedAt = GetGameTimer()

    payload = text
    payloadAt = finishedAt

    -- A payload cannot measure its own production, so this lands in the NEXT one.
    local elapsed = finishedAt - startedAt
    if elapsed >= 0 then
        registry:observe('tickwatch_render_duration_seconds', nil, elapsed / 1000)
    end

    flushPending(registry, text)

    return text
end

--------------------------------------------------------------------------------
-- Routes
--------------------------------------------------------------------------------

local function serveMetrics(registry, config, req, res)
    if not Http.authorised(config, req) then
        countScrape(registry, 'unauthorized')

        -- The challenge header is what marks this an auth failure rather than a
        -- broken endpoint.
        pcall(function()
            res.writeHead(401, {
                ['Content-Type'] = PLAIN_TYPE,
                ['WWW-Authenticate'] = 'Bearer realm="tickwatch"',
            })
            res.send('unauthorized\n')
        end)
        return
    end

    local age = payload and (GetGameTimer() - payloadAt) or nil

    -- Set here, not at render time where it would be zero by construction. The
    -- consequence — it describes the previous scrape — is in the help text.
    if age and age >= 0 then
        registry:set('tickwatch_cache_age_seconds', nil, age / 1000)
    end

    if payload and age and age >= 0 and age <= config.maxAgeMs then
        countScrape(registry, 'served')
        sendText(res, 200, payload, EXPOSITION_TYPE)
        return
    end

    -- Stale, or nothing rendered yet. Hold it — rendering inside a handler is
    -- the one thing this design exists to avoid.
    defer(registry, config, req, res)
end

--- Build the handler. Returned rather than registered so a test can drive it.
function Http.handler(registry, config, collectors)
    return function(req, res)
        local ok, err = pcall(function()
            local method = type(req) == 'table' and req.method or 'GET'
            local path = Http.route(type(req) == 'table' and req.path or '/')

            if path == '/metrics' then
                if method ~= 'GET' then
                    sendText(res, 405, 'method not allowed\n')
                    return
                end

                serveMetrics(registry, config, req, res)
                return
            end

            if path == '/health' then
                -- Unauthenticated on purpose: it reports that the resource is
                -- running and nothing else, so it is useful to a load balancer
                -- and useless to anyone enumerating the server.
                if method ~= 'GET' then
                    sendText(res, 405, 'method not allowed\n')
                    return
                end

                sendText(res, 200, 'ok\n')
                return
            end

            sendText(res, 404, 'tickwatch: /metrics or /health\n')
        end)

        if not ok then
            -- A handler that raises leaves the request hanging until the client
            -- times out, and prints nothing.
            print(('[tickwatch] handler error: %s'):format(tostring(err)))
            sendText(res, 500, 'internal error\n')
        end
    end
end

--------------------------------------------------------------------------------

--- Start serving, and start the render loop that keeps the payload fresh.
function Http.start(registry, config, collectors)
    -- Before the endpoint is registered, so the first scrape finds a payload.
    Http.render(registry, collectors)

    CreateThread(function()
        while true do
            Wait(config.renderIntervalMs)

            local ok, err = pcall(Http.render, registry, collectors)
            if not ok then
                -- Unlike a collector, this loop never retires: a dead one defers
                -- every scrape forever. A noisy one is the lesser failure.
                print(('[tickwatch] render failed: %s'):format(tostring(err)))
            end
        end
    end)

    SetHttpHandler(Http.handler(registry, config, collectors))
end

--- Inspect the serving state. For tests and for the startup banner.
function Http.state()
    return {
        rendered = payload ~= nil,
        bytes = payload and #payload or 0,
        renderedAt = payloadAt,
        pending = pendingCount,
    }
end

--- Tests only — the resource never restarts its serving state in place.
function Http.reset()
    payload = nil
    payloadAt = 0
    pending = {}
    pendingCount = 0
end

_G.Http = Http
