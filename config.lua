--[[
    tickwatch — config.lua

    Reads and validates configuration from convars.

    Bad values are clamped and reported, not obeyed and not fatal — a negative
    interval is an operator typo, and taking the server down over it is worse
    than running at the floor and saying so. The auth token is the exception:
    there the safe failure is to refuse.

    The token is read here and leaves only through a comparison function.
]]

local Config = {}

-- Exported because the startup /info.json fetch looks for this exact key: a
-- token set with `sets` lands in that unauthenticated document, which is the one
-- misconfiguration of the three detectable from inside the server.
Config.TOKEN_CONVAR = 'tickwatch_token'

--------------------------------------------------------------------------------
-- Defaults
--------------------------------------------------------------------------------

local DEFAULTS = {
    enabled = true,

    -- The handler never renders, so this is the only place render cost is paid.
    renderIntervalMs = 5000,

    -- Older than this is not served; the request defers and the next render
    -- completes it. Held at or above twice the render interval — see load().
    maxAgeMs = 15000,

    -- Ceiling on responses waiting for a render. Without it the pressure from a
    -- scrape rate above the render rate is unbounded and invisible.
    maxPending = 8,

    -- Unique series per metric before writes are refused. Measured on FXServer:
    -- 583.5 B per labelled counter/gauge series, 1183.5 B per labelled histogram
    -- with ten buckets, so 500 of the worst shape is ~578 KiB for one metric.
    -- Collectors with a legitimately larger label set declare their own cap.
    seriesCap = 500,

    -- 0 disables a collector outright.
    playersIntervalMs = 10000,
    entitiesIntervalMs = 10000,
    resourcesIntervalMs = 30000,
}

-- Below a second a collector is a per-frame thread, and this design permits one.
local MIN_INTERVAL_MS = 1000
local MAX_INTERVAL_MS = 600000

-- A warning rather than a refusal: it is the operator's server.
local MIN_TOKEN_LENGTH = 16

--------------------------------------------------------------------------------
-- Reading
--------------------------------------------------------------------------------

-- A convar value arrives with whatever surrounded it in server.cfg.
local function trim(s)
    return (s:gsub('^%s+', ''):gsub('%s+$', ''))
end

--- Read an integer convar and force it into range, reporting anything changed —
--- a silently corrected value is a setting the operator believes is in effect.
local function intConvar(problems, name, default, min, max, allowZero)
    -- GetConvarInt falls back to the default on text it cannot parse, which is
    -- what makes 0 usable as "disabled" below. One measured exception: it reads
    -- true and false as 1 and 0, so `set ..._interval_ms false` would arrive as
    -- a deliberate-looking 0. Screening the raw string catches that.
    local raw = trim(GetConvar(name, ''))

    if raw ~= '' and tonumber(raw) == nil then
        problems[#problems + 1] = ('%s = %q is not a number, using %d'):format(name, raw, default)
        return default
    end

    local value = GetConvarInt(name, default)

    if type(value) ~= 'number' or value ~= value then
        problems[#problems + 1] = ('%s did not read back as a number, using %d'):format(name, default)
        return default
    end

    -- A fractional convar is truncated by the accessor rather than rejected.
    value = math.floor(value)

    if allowZero and value == 0 then
        return 0
    end

    if value < min then
        problems[#problems + 1] = ('%s = %d is below the minimum, raised to %d'):format(name, value, min)
        return min
    end

    if value > max then
        problems[#problems + 1] = ('%s = %d is above the maximum, lowered to %d'):format(name, value, max)
        return max
    end

    return value
end

-- The only spellings GetConvarBool understands, measured. Case-insensitive.
local BOOL_WORDS = {
    ['true'] = true,
    ['false'] = false,
    ['1'] = true,
    ['0'] = false,
}

--- Read a boolean convar. Two measured behaviours make the obvious version wrong.
---
--- GetConvarBool returns the *number* 1 for true and the *boolean* false for
--- false, never boolean true — so `== true` fails for a convar set to true.
--- And it understands only true/false/1/0: `set tickwatch_enabled no` falls back
--- to the default and reports nothing, leaving the exporter running.
local function boolConvar(problems, name, default)
    local raw = trim(GetConvar(name, ''))

    if raw ~= '' and BOOL_WORDS[raw:lower()] == nil then
        problems[#problems + 1] = ('%s = %q is not a boolean the runtime understands; use true or false. Default %s is in effect.')
            :format(name, raw, tostring(default))
        return default
    end

    local value = GetConvarBool(name, default)

    -- The 0 case cannot occur on the measured build, but 0 is truthy in Lua and
    -- silently inverting a config flag is not worth leaving to a runtime update.
    if value == 0 then return false end
    return value and true or false
end

--------------------------------------------------------------------------------
-- Token
--------------------------------------------------------------------------------

-- Length-independent. Timing analysis is not the realistic threat against an
-- endpoint on plaintext HTTP, but the comparison costs the same either way.
local function constantTimeEquals(a, b)
    if #a ~= #b then return false end

    local diff = 0
    for i = 1, #a do
        diff = diff | (a:byte(i) ~ b:byte(i))
    end

    return diff == 0
end

--------------------------------------------------------------------------------

--- Read the whole configuration. `problems` is for the startup banner; `ok` is
--- false only when the exporter must not serve.
function Config.load()
    local problems = {}

    local enabled = boolConvar(problems, 'tickwatch_enabled', DEFAULTS.enabled)

    local renderIntervalMs = intConvar(problems, 'tickwatch_render_interval_ms',
        DEFAULTS.renderIntervalMs, MIN_INTERVAL_MS, MAX_INTERVAL_MS, false)

    local maxAgeMs = intConvar(problems, 'tickwatch_max_age_ms',
        DEFAULTS.maxAgeMs, MIN_INTERVAL_MS, MAX_INTERVAL_MS, false)

    -- Cross-field, so it cannot be a range on either alone. A freshness threshold
    -- under the render interval makes every scrape defer, turning the pending
    -- queue into the normal path and its drop policy into routine data loss.
    if maxAgeMs < renderIntervalMs * 2 then
        problems[#problems + 1] = ('tickwatch_max_age_ms = %d is under twice tickwatch_render_interval_ms = %d, raised to %d')
            :format(maxAgeMs, renderIntervalMs, renderIntervalMs * 2)
        maxAgeMs = renderIntervalMs * 2
    end

    local raw = GetConvar(Config.TOKEN_CONVAR, '')
    local token = trim(raw)

    -- A trailing space from a pasted config line 401s every request silently.
    if token ~= raw and token ~= '' then
        problems[#problems + 1] = ('%s had surrounding whitespace, which was trimmed'):format(Config.TOKEN_CONVAR)
    end

    if token == '' then
        problems[#problems + 1] = ('%s is not set — refusing to serve. Set it with `set` (not `sets`, which publishes it in /info.json, nor `setr`, which broadcasts it to every client).')
            :format(Config.TOKEN_CONVAR)
    elseif #token < MIN_TOKEN_LENGTH then
        problems[#problems + 1] = ('%s is only %d characters; %d or more is advised')
            :format(Config.TOKEN_CONVAR, #token, MIN_TOKEN_LENGTH)
    end

    local config = {
        enabled = enabled,
        ok = enabled and token ~= '',
        problems = problems,

        renderIntervalMs = renderIntervalMs,
        maxAgeMs = maxAgeMs,

        maxPending = intConvar(problems, 'tickwatch_max_pending',
            DEFAULTS.maxPending, 1, 64, false),

        seriesCap = intConvar(problems, 'tickwatch_series_cap',
            DEFAULTS.seriesCap, 1, 100000, false),

        playersIntervalMs = intConvar(problems, 'tickwatch_players_interval_ms',
            DEFAULTS.playersIntervalMs, MIN_INTERVAL_MS, MAX_INTERVAL_MS, true),

        entitiesIntervalMs = intConvar(problems, 'tickwatch_entities_interval_ms',
            DEFAULTS.entitiesIntervalMs, MIN_INTERVAL_MS, MAX_INTERVAL_MS, true),

        resourcesIntervalMs = intConvar(problems, 'tickwatch_resources_interval_ms',
            DEFAULTS.resourcesIntervalMs, MIN_INTERVAL_MS, MAX_INTERVAL_MS, true),
    }

    --- A closure so the token is never a field on the config table, and so no
    --- accidental print of the config prints the secret.
    function config.tokenMatches(candidate)
        if type(candidate) ~= 'string' or token == '' then return false end
        return constantTimeEquals(candidate, token)
    end

    --- Looks for the token itself rather than the convar key, because `sets`
    --- publishes the value under a name the operator chose.
    function config.tokenLeaksInto(body)
        if token == '' or type(body) ~= 'string' then return false end
        return body:find(token, 1, true) ~= nil
    end

    return config
end

--------------------------------------------------------------------------------

_G.Config = Config
