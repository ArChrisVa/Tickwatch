# tickwatch-adapter

An example. Not part of tickwatch and not required by it.

Fills `fivem_events_total` and `fivem_db_queries_total` on a server whose scripts you would
rather not edit, by listening to events the server already raises. Copy it into `resources/`
and `ensure tickwatch-adapter`.

It copies nothing and depends on nothing. If none of the events it listens for are ever
raised, it does nothing at all — so it is safe on a server that is not QBCore. Edit `EVENTS`
in `server/main.lua` to match your framework.

## What it cannot do

Time a query. oxmysql raises an event when a query **fails** and none when one succeeds, so
there is nothing to time from the outside. The two `_duration_seconds` histograms need
`TickwatchTimed` inside the resource making the call:

```lua
-- in that resource's fxmanifest.lua
server_scripts { '@tickwatch/shared/timed.lua', 'server/main.lua' }

-- then wrap once
payout = TickwatchTimed('fivem_event_duration_seconds', payout, { event = 'payout' })
```

It also loads *after* the framework, so events raised during the framework's own startup —
`QBCore:Server:UpdateObject` among them — happen before anything is listening. Hooking from
outside sees steady-state traffic, not boot.
