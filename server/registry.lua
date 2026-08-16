--[[
    tickwatch — server/registry.lua

    Metric primitives (counter, gauge, histogram) and the Prometheus text
    exposition renderer. No dependencies: everything else writes through it.

    Two properties drive the shape of this file:

      * a write is O(1) in the number of series and allocates nothing, so
        instrumenting a hot path costs a bounded amount;
      * a render is O(total series) and runs on a schedule, never in a handler.

    So anything expensive is paid at registration or on first sight of a label
    set — never on a repeat write.
]]

-- FXServer/LuaGLM extension, both arguments required; presizes to an exact
-- capacity so a table grown by assignment does not rehash at every power of two.
-- Stock Lua (where the tests run) falls back to no presizing, same semantics.
local tableCreate = table.create or function() return {} end

local concat = table.concat
local format = string.format
local sort = table.sort
local floor = math.floor
local huge = math.huge

-- Floored at 1 ms: GetGameTimer() is an integer-millisecond interface, so
-- nothing below one tick is resolvable and no bucket is defined there.
local DEFAULT_BUCKETS = { 0.001, 0.002, 0.005, 0.01, 0.02, 0.05, 0.1, 0.25, 0.5, 1 }

-- Metric names may contain a colon (reserved for recording rules, never emitted
-- by an exporter); label names may not.
local METRIC_NAME_PATTERN = '^[a-zA-Z_:][a-zA-Z0-9_:]*$'
local LABEL_NAME_PATTERN = '^[a-zA-Z_][a-zA-Z0-9_]*$'

-- Registered by the registry, not a collector: the guard reporting through it is
-- the registry's own.
local DROPPED_METRIC = 'tickwatch_series_dropped_total'

--------------------------------------------------------------------------------
-- Formatting
--------------------------------------------------------------------------------

-- Lua has no shortest-round-trip float formatter, so integers are emitted
-- exactly and floats at 14 significant digits: ~1e-14 relative error, far below
-- what a monitoring system resolves, and a sum reads as 0.003.
local function formatValue(v)
    if v ~= v then return 'NaN' end
    if v == huge then return '+Inf' end
    if v == -huge then return '-Inf' end

    if math.type(v) == 'integer' then return format('%d', v) end

    -- A float holding an exact integer reads as 42, not 42.0. The magnitude
    -- guard is because %d raises on a float with no integer representation.
    if v == floor(v) and v < 1e15 and v > -1e15 then return format('%d', v) end

    return format('%.14g', v)
end

-- Exactly three characters, and the backslash must go first or the escapes the
-- later substitutions introduce get escaped in turn.
local function escapeLabelValue(s)
    return (s:gsub('\\', '\\\\'):gsub('"', '\\"'):gsub('\n', '\\n'))
end

-- Not the double quote: HELP is the rest of the line, not a quoted string.
local function escapeHelp(s)
    return (s:gsub('\\', '\\\\'):gsub('\n', '\\n'))
end

--------------------------------------------------------------------------------
-- Registry
--------------------------------------------------------------------------------

local Registry = {}
Registry.__index = Registry

--- Create an empty registry.
-- @param opts table|nil  { defaultCap = number }
function Registry.new(opts)
    opts = opts or {}

    local self = setmetatable({
        metrics = tableCreate(0, 32), -- name -> metric
        order = tableCreate(32, 0),   -- registration order, so render is stable
        -- Measured, not chosen: 583.5 B per labelled counter/gauge series and
        -- 1183.5 B per ten-bucket histogram, so 500 of the worst shape is
        -- ~578 KiB for one metric.
        defaultCap = opts.defaultCap or 500,
        inDrop = false,
    }, Registry)

    -- First, so it is always present to be written to — including on the very
    -- first drop.
    self:register({
        name = DROPPED_METRIC,
        type = 'counter',
        help = 'Writes refused by the cardinality guard, by metric.',
        labels = { 'metric' },

        -- Its label values are registered metric names, so this only has to
        -- clear the metric count.
        cap = 64,
    })

    return self
end

--------------------------------------------------------------------------------
-- Registration
--------------------------------------------------------------------------------

local function validateBuckets(bounds)
    if type(bounds) ~= 'table' or #bounds == 0 then
        error('registry: a histogram needs at least one bucket bound', 3)
    end

    local out = tableCreate(#bounds, 0)
    local previous

    for i = 1, #bounds do
        local bound = bounds[i]

        if type(bound) ~= 'number' or bound ~= bound or bound == huge then
            error(('registry: bucket bound %d is not a finite number'):format(i), 3)
        end

        -- A duplicate or out-of-order bound renders a bucket list a consumer
        -- reads as cumulative and is not.
        if previous and bound <= previous then
            error(('registry: bucket bounds must strictly ascend (bound %d)'):format(i), 3)
        end

        previous = bound
        out[i] = bound
    end

    return out
end

--- Declare a metric. Everything expensive about a metric family happens here.
-- @param def table  { name, type, help, labels?, buckets?, cap? }
function Registry:register(def)
    if type(def) ~= 'table' then
        error('registry: register expects a definition table', 2)
    end

    local name = def.name
    if type(name) ~= 'string' or not name:match(METRIC_NAME_PATTERN) then
        error(('registry: invalid metric name %s'):format(tostring(name)), 2)
    end

    if self.metrics[name] then
        error(('registry: metric %s is already registered'):format(name), 2)
    end

    local kind = def.type
    if kind ~= 'counter' and kind ~= 'gauge' and kind ~= 'histogram' then
        error(('registry: metric %s has invalid type %s'):format(name, tostring(kind)), 2)
    end

    local help = def.help
    if type(help) ~= 'string' or help == '' then
        error(('registry: metric %s needs a non-empty help string'):format(name), 2)
    end

    -- Sorted once, here. That is what lets the write path read label values in a
    -- fixed order without sorting: two callers passing the same labels in
    -- different table orders land on the same series.
    local declared = def.labels or {}
    local labelNames = tableCreate(#declared, 0)
    local seen = {}

    for i = 1, #declared do
        local label = declared[i]

        if type(label) ~= 'string' or not label:match(LABEL_NAME_PATTERN) then
            error(('registry: metric %s has invalid label name %s'):format(name, tostring(label)), 2)
        end

        if seen[label] then
            error(('registry: metric %s declares label %s twice'):format(name, label), 2)
        end

        -- le carries the bound on a _bucket series; a user-supplied one collides
        -- and produces two series that render as one line.
        if kind == 'histogram' and label == 'le' then
            error(('registry: metric %s cannot declare the reserved label le'):format(name), 2)
        end

        seen[label] = true
        labelNames[i] = label
    end

    sort(labelNames)

    local metric = {
        name = name,
        kind = kind,
        help = help,
        labelNames = labelNames,
        labelCount = #labelNames,
        cap = def.cap or self.defaultCap,

        -- Creation order: the format does not require sorted output, and sorting
        -- every render is main-thread work for no consumer benefit.
        series = tableCreate(8, 0),
        seriesCount = 0,

        -- One table level per declared label; the series directly when there
        -- are none.
        index = nil,
    }

    if kind == 'histogram' then
        local bounds = validateBuckets(def.buckets or DEFAULT_BUCKETS)

        metric.bounds = bounds
        metric.bucketCount = #bounds

        -- The le label value for each bound, formatted once.
        local boundLabels = tableCreate(#bounds, 0)
        for i = 1, #bounds do
            boundLabels[i] = formatValue(bounds[i])
        end
        metric.boundLabels = boundLabels
    end

    self.metrics[name] = metric
    self.order[#self.order + 1] = metric

    return metric
end

--------------------------------------------------------------------------------
-- Series resolution
--------------------------------------------------------------------------------

local function newSeries(metric, labelText)
    local series = {
        -- 'op="select",status="ok"', or '' when the metric has no labels.
        labelText = labelText,

        -- Rendered forms, built once so a render is pure concatenation.
        braced = labelText ~= '' and ('{' .. labelText .. '}') or '',
        bucketPrefix = labelText ~= '' and (labelText .. ',') or '',

        value = 0,
    }

    if metric.kind == 'histogram' then
        -- counts[i] holds observations in (bounds[i-1], bounds[i]], and the last
        -- slot the overflow. These are NOT what the exposition emits: observe()
        -- increments exactly one, and render() makes them cumulative. That keeps
        -- the hot path O(1) — and a non-cumulative histogram is valid exposition
        -- text no linter rejects that returns wrong percentiles, so the tests
        -- assert monotonicity and +Inf == _count.
        local counts = tableCreate(metric.bucketCount + 1, 0)
        for i = 1, metric.bucketCount + 1 do
            counts[i] = 0
        end

        series.counts = counts
        series.sum = 0.0
        series.count = 0
    end

    return series
end

local function buildLabelText(metric, labels)
    local names = metric.labelNames
    local parts = tableCreate(metric.labelCount, 0)

    for i = 1, metric.labelCount do
        parts[i] = names[i] .. '="' .. escapeLabelValue(labels[names[i]]) .. '"'
    end

    return concat(parts, ',')
end

--- Record that a write was dropped by the cardinality guard. Reentrancy guarded:
-- the drop counter is itself a metric, and one sitting at its own cap recurses.
function Registry:recordDrop(metricName)
    if self.inDrop then return end

    self.inDrop = true

    local metric = self.metrics[DROPPED_METRIC]
    if metric then
        local series = self:seriesFor(metric, { metric = metricName })
        if series then
            series.value = series.value + 1
        end
    end

    self.inDrop = false
end

--- Resolve the series a label set names, creating it on first sight. nil when
-- the cap refuses it, in which case the caller's write is a no-op.
function Registry:seriesFor(metric, labels)
    local n = metric.labelCount

    -- Unlabelled metrics are the hot ones — the tick histogram observes every
    -- frame — so they short-circuit before any table work.
    if n == 0 then
        if labels ~= nil then
            if type(labels) ~= 'table' then
                error(('registry: metric %s takes no labels'):format(metric.name), 3)
            end
            if next(labels) ~= nil then
                error(('registry: metric %s takes no labels'):format(metric.name), 3)
            end
        end

        local series = metric.index
        if series == nil then
            series = newSeries(metric, '')
            metric.index = series
            metric.seriesCount = 1
            metric.series[1] = series
        end

        return series
    end

    if type(labels) ~= 'table' then
        error(('registry: metric %s requires a labels table'):format(metric.name), 3)
    end

    local names = metric.labelNames
    local node = metric.index

    -- One pass that validates and descends. A repeat write is n table lookups
    -- and no string building: the label text was built when the series was.
    for i = 1, n do
        local value = labels[names[i]]

        -- No coercion: 1 and "1" would index different nodes while rendering to
        -- the same line, which is two series that look like one.
        if type(value) ~= 'string' then
            error(('registry: metric %s label %s must be a string, got %s')
                :format(metric.name, names[i], type(value)), 3)
        end

        if node ~= nil then
            node = node[value]
        end
    end

    if node ~= nil then
        return node
    end

    -- Every declared label was present, so a larger table means an undeclared
    -- one — usually a typo, which must fail rather than quietly create a near
    -- duplicate of an existing series.
    local provided = 0
    for _ in pairs(labels) do
        provided = provided + 1
    end

    if provided ~= n then
        error(('registry: metric %s was given %d labels but declares %d')
            :format(metric.name, provided, n), 3)
    end

    -- A miss, and the cap is checked before anything is allocated: an index tree
    -- that grew on refused writes would bound the series count while the memory
    -- the guard exists to protect grew anyway.
    if metric.seriesCount >= metric.cap then
        self:recordDrop(metric.name)
        return nil
    end

    local series = newSeries(metric, buildLabelText(metric, labels))

    local parent = metric.index
    if parent == nil then
        parent = tableCreate(0, 4)
        metric.index = parent
    end

    for i = 1, n - 1 do
        local value = labels[names[i]]
        local child = parent[value]

        if child == nil then
            child = tableCreate(0, 4)
            parent[value] = child
        end

        parent = child
    end

    parent[labels[names[n]]] = series

    local count = metric.seriesCount + 1
    metric.seriesCount = count
    metric.series[count] = series

    return series
end

--------------------------------------------------------------------------------
-- Writes
--------------------------------------------------------------------------------

function Registry:lookup(name, expectedKind, level)
    local metric = self.metrics[name]

    -- Never created on demand: a typo must fail loudly rather than open a series
    -- that looks almost right and is never graphed.
    if metric == nil then
        error(('registry: %s is not a registered metric'):format(tostring(name)), level)
    end

    if metric.kind ~= expectedKind then
        error(('registry: %s is a %s, not a %s'):format(name, metric.kind, expectedKind), level)
    end

    return metric
end

--- Add to a counter. Defaults to 1.
function Registry:inc(name, labels, value)
    local metric = self:lookup(name, 'counter', 3)
    local amount = value == nil and 1 or value

    if type(amount) ~= 'number' or amount ~= amount then
        error(('registry: %s increment must be a number'):format(name), 2)
    end

    -- rate() reads any decrease as a process restart, so a negative increment
    -- would produce a series queries silently misinterpret.
    if amount < 0 then
        error(('registry: %s is a counter and cannot decrease'):format(name), 2)
    end

    local series = self:seriesFor(metric, labels)
    if series then
        series.value = series.value + amount
    end
end

--- Set a gauge to an absolute value.
function Registry:set(name, labels, value)
    local metric = self:lookup(name, 'gauge', 3)

    if type(value) ~= 'number' or value ~= value then
        error(('registry: %s value must be a number'):format(name), 2)
    end

    local series = self:seriesFor(metric, labels)
    if series then
        series.value = value
    end
end

--- Record one observation into a histogram.
function Registry:observe(name, labels, value)
    local metric = self:lookup(name, 'histogram', 3)

    if type(value) ~= 'number' or value ~= value then
        error(('registry: %s observation must be a number'):format(name), 2)
    end

    local series = self:seriesFor(metric, labels)
    if series == nil then return end

    -- Linear scan, not a concession: bucket lists are short and fixed, and the
    -- common observation matches early. Falls through to the overflow slot.
    local bounds = metric.bounds
    local slot = metric.bucketCount + 1

    for i = 1, metric.bucketCount do
        if value <= bounds[i] then
            slot = i
            break
        end
    end

    series.counts[slot] = series.counts[slot] + 1
    series.sum = series.sum + value
    series.count = series.count + 1
end

--------------------------------------------------------------------------------
-- Rendering
--------------------------------------------------------------------------------

--- Exact number of lines render() will produce, used to presize its buffer.
function Registry:lineCount()
    local total = 0

    for i = 1, #self.order do
        local metric = self.order[i]

        -- HELP and TYPE.
        total = total + 2

        if metric.kind == 'histogram' then
            -- One line per finite bound, plus +Inf, _sum and _count.
            total = total + metric.seriesCount * (metric.bucketCount + 3)
        else
            total = total + metric.seriesCount
        end
    end

    return total
end

--- Render the whole registry as Prometheus text exposition v0.0.4.
function Registry:render()
    -- concat, not repeated concatenation: appending to a string in a loop is
    -- quadratic, because each append copies everything written so far.
    local out = tableCreate(self:lineCount() + 1, 0)
    local n = 0

    for i = 1, #self.order do
        local metric = self.order[i]
        local name = metric.name

        n = n + 1
        out[n] = '# HELP ' .. name .. ' ' .. escapeHelp(metric.help)
        n = n + 1
        out[n] = '# TYPE ' .. name .. ' ' .. metric.kind

        if metric.kind == 'histogram' then
            local bucketCount = metric.bucketCount
            local boundLabels = metric.boundLabels

            for j = 1, metric.seriesCount do
                local series = metric.series[j]
                local counts = series.counts
                local prefix = series.bucketPrefix
                local cumulative = 0

                -- The running sum is what makes the buckets cumulative.
                for b = 1, bucketCount do
                    cumulative = cumulative + counts[b]
                    n = n + 1
                    out[n] = name .. '_bucket{' .. prefix .. 'le="' .. boundLabels[b] .. '"} '
                        .. formatValue(cumulative)
                end

                -- Carried through the overflow slot, not copied from _count.
                -- Copying would make the two agree by construction and leave the
                -- test asserting nothing.
                cumulative = cumulative + counts[bucketCount + 1]

                n = n + 1
                out[n] = name .. '_bucket{' .. prefix .. 'le="+Inf"} ' .. formatValue(cumulative)
                n = n + 1
                out[n] = name .. '_sum' .. series.braced .. ' ' .. formatValue(series.sum)
                n = n + 1
                out[n] = name .. '_count' .. series.braced .. ' ' .. formatValue(series.count)
            end
        else
            for j = 1, metric.seriesCount do
                local series = metric.series[j]
                n = n + 1
                out[n] = name .. series.braced .. ' ' .. formatValue(series.value)
            end
        end
    end

    -- The exposition must end with a newline; an empty element gives concat one.
    out[n + 1] = ''

    return concat(out, '\n')
end

--------------------------------------------------------------------------------

-- The class only. main.lua creates the instance, because its cardinality cap is
-- configuration and configuration has not been read when this file loads.
_G.Registry = Registry
