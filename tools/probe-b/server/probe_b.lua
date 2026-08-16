-- tickwatch-probe-b — second Lua state for tickwatch Phase 0, Q4.
--
-- Exists only so tickwatch-probe has something to compare against. Q4 asks which
-- lua_State `collectgarbage('count')` reads, and that cannot be answered from
-- inside a single resource: "my own heap grew" looks identical whether the
-- state is per-resource or shared by every Lua resource on the server. This
-- resource is the control.
--
-- Console usage:  probeb     print this state's heap without crossing the
--                            export bridge — a cross-check on the exports
--
-- Nothing here ships.

-- --------------------------------------------------------------------------
-- collection
-- --------------------------------------------------------------------------

--- Two full cycles, not one. The first may resurrect objects through
--- finalizers; the second reclaims them. A single collect leaves that
--- difference sitting in the number.
local function fullCollect()
    collectgarbage('collect')
    collectgarbage('collect')
end

-- --------------------------------------------------------------------------
-- exports
-- --------------------------------------------------------------------------
-- Both return Kbytes exactly as collectgarbage reports it. Conversion to bytes
-- is deliberately left to the caller so that both sides of the comparison do
-- the same arithmetic in the same place, rather than each rounding its own way.

--- This state's heap, as-is. Includes garbage not yet collected.
exports('count', function()
    return collectgarbage('count')
end)

--- This state's heap after a full collection. tickwatch-probe needs to be able to
--- force *this* state's GC before reading it; without that it would be
--- comparing a freshly collected heap against one holding an arbitrary amount
--- of uncollected garbage, and the difference between the two would be noise
--- rather than signal.
exports('collectAndCount', function()
    fullCollect()
    return collectgarbage('count')
end)

-- --------------------------------------------------------------------------
-- Phase 1 — can a function cross the export boundary?
-- --------------------------------------------------------------------------
-- tickwatch's design originally specified `StartTimer()` returning a `stop()`
-- closure. A closure cannot be serialized, so either the runtime wraps it in a
-- reference the caller proxies — which makes calling it a round trip rather than
-- a local call — or it does not survive at all. Neither outcome is visible from
-- inside one resource, and the answer decides the shape of a public API.
--
-- This lives in the control resource rather than in tickwatch because the
-- question is about the runtime, not about the exporter, and answering it here
-- keeps a construct out of the shipping code that the answer might rule out.

--- Returns a closure over a local. If the caller can call what comes back, the
--- runtime proxies functions; the cost of doing so is then measurable from the
--- other side.
exports('makeCounter', function()
    local n = 0
    return function()
        n = n + 1
        return n
    end
end)

--- Returns a table CONTAINING a function, which is the other shape an API might
--- hand back and the one msgpack is least likely to carry.
exports('makeHandle', function()
    local n = 0
    return {
        label = 'handle',
        bump = function() n = n + 1 return n end,
    }
end)

-- --------------------------------------------------------------------------
-- console cross-check
-- --------------------------------------------------------------------------
-- Reading this state through the export bridge and reading it from a command
-- inside the resource are two independent paths to the same number. If they
-- disagree, the bridge is doing something to the measurement and the Q4 result
-- is not trustworthy.

RegisterCommand('probeb', function(source)
    if source ~= 0 then
        return -- server console only
    end

    fullCollect()
    local kb = collectgarbage('count')

    print(('[probe-b] %-30s %s'):format('lua version', _VERSION))
    print(('[probe-b] %-30s %d (%.3f MiB)'):format(
        'heap after full collect',
        math.floor(kb * 1024 + 0.5),
        kb / 1024
    ))
end, true)

AddEventHandler('onResourceStart', function(resource)
    if resource ~= GetCurrentResourceName() then
        return
    end

    print(('[probe-b] ready — %s, exports: count, collectAndCount'):format(_VERSION))
end)
