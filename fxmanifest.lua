fx_version 'cerulean'
game 'gta5'
lua54 'yes'

name 'tickwatch'
description 'Prometheus instrumentation for soft-real-time multiplayer game servers.'
author 'ArChrisVa'
version '0.1.0'
repository 'https://github.com/ArChrisVa/Tickwatch'

-- Load order is dependency order. config.lua reads convars and depends on
-- nothing; registry.lua creates the registry every later file writes through;
-- collectors.lua declares the catalog against it. Nothing here starts serving —
-- that is the startup sequence's job, and it has to be able to refuse.
server_scripts {
    'config.lua',
    'server/registry.lua',
    'server/collectors.lua',
    'server/http.lua',
    'server/exports.lua',
    'server/main.lua',
}

-- shared/timed.lua is deliberately NOT in the list above. It runs inside the
-- resources that instrument themselves, reached from their own manifests as
-- `@tickwatch/shared/timed.lua`; loading it here would define a wrapper in the
-- one resource that has nothing to wrap. Declared as a file so it travels with
-- the resource and is readable by another one.
files {
    'shared/timed.lua',
}
