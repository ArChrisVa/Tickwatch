--[[
    tickwatch — shared/timed.lua

    Times a function and reports it. Loaded by the resource being instrumented,
    not by tickwatch:

        server_scripts { '@tickwatch/shared/timed.lua', 'server/main.lua' }
        payout = TickwatchTimed('myjob_payout_duration_seconds', payout)

    Hand-written timing skips every early return and every error between the
    clock read and the observe call, and the error path is usually the slow one.

    Not an export: errors do not cross the boundary and a returned function comes
    back as a 6.3 us proxy. See docs/design.md, Public API.
]]

--- @param name string    a histogram registered with tickwatch beforehand
--- @param fn function    the function to time
--- @param labels table|nil
--- @return function      drop-in replacement for `fn`
function TickwatchTimed(name, fn, labels)
    if type(fn) ~= 'function' then
        error('TickwatchTimed expects a function to wrap, got ' .. type(fn), 2)
    end

    return function(...)
        local startedAt = GetGameTimer()

        -- table.pack, not `local ok, a, b =`: the wrapped arity is unknown here
        -- and truncating its returns would be a bug added by the instrument.
        local returned = table.pack(pcall(fn, ...))

        -- Before the re-raise. A call that failed is still a call that took time.
        exports['tickwatch']:ObserveSince(name, labels, startedAt)

        if not returned[1] then
            error(returned[2], 0) -- level 0: keep the original message and position
        end

        return table.unpack(returned, 2, returned.n)
    end
end

return TickwatchTimed
