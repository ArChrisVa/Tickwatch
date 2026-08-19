--[[
    tickwatch-adapter — an example. Not part of tickwatch, not required by it.

    Fills fivem_events_total and fivem_db_queries_total on a server whose
    scripts you would rather not edit, by listening to what the server already
    raises. It copies nothing and depends on nothing: if none of the events
    below are ever raised, this resource does nothing at all.

    What it deliberately does not do is time a query. oxmysql raises an event
    when a query fails and none when one succeeds, so there is nothing to time
    from the outside. The duration histograms need TickwatchTimed inside the
    resource making the call — see the readme.
]]

-- A fixed list, not anything discovered at runtime: fivem_events_total is
-- capped at 64 label values, and an unbounded event name would spend that cap
-- on noise and then start dropping the ones that matter.
--
-- These are QBCore's. Replace them with your framework's; nothing here knows
-- or cares which framework is installed.
local EVENTS = {
    'QBCore:Server:PlayerLoaded',
    'QBCore:Server:OnPlayerUnload',
    'QBCore:Server:OnMoneyChange',
    'QBCore:Server:UpdateObject',
    'QBCore:Server:OnJobUpdate',
    'QBCore:Server:OnGangUpdate',
}

-- AddEventHandler, never RegisterNetEvent. Registering these as net events
-- would let any connected client raise them, which turns every metric below
-- into a number a player can forge. A server-side handler cannot be reached
-- from a client at all.
for i = 1, #EVENTS do
    local name = EVENTS[i]

    AddEventHandler(name, function()
        exports['tickwatch']:Event(name)
    end)
end

--- The leading SQL verb, lowercased: select, insert, update, delete. Bounded by
--- the grammar, which is the point — the full statement as a label would be
--- unbounded cardinality, and the parameters would put user data in a metric.
local function opOf(query)
    if type(query) ~= 'string' then return 'unknown' end
    return (query:match('^%s*(%a+)') or 'unknown'):lower()
end

-- Payload is { query, parameters, message, err, resource }, raised server-side.
AddEventHandler('oxmysql:error', function(data)
    exports['tickwatch']:Query(opOf(data and data.query), 'error')
end)

AddEventHandler('oxmysql:transaction-error', function()
    exports['tickwatch']:Query('transaction', 'error')
end)
