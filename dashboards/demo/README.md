# Demo data

Everything in this directory is **fabricated**. It exists so the dashboards can be
screenshotted with something on them, because an idle server produces flat lines and zeroes.

No measurement in `docs/` comes from here, and nothing here is loaded by the exporter.

## The day it generates

The point is not that the panels are full — it is that they **agree**. Each incident is
visible in several places at once, which is what makes the dashboards worth having.

**19:45, a slow database.** `fivem:db_query_duration_seconds:p95` for `select` goes from
7.8 ms to **160 ms**, crossing the `DatabaseQuerySlow` threshold. The error ratio rises to
**13%** alongside it. Event durations follow, because events do database work.

**20:00, the server stalls and 22 players are lost at once.** In order:

| | before | during | after |
|---|---|---|---|
| frame interval p99 | 116 ms | **980 ms** | 86 ms |
| frame rate | 18.9 Hz | **13 Hz** | 19.3 Hz |
| players connected | 49 | **15** | 46 within an hour |
| entities | 255 | **150** | — |
| join success | 91% | **58%** | 96% |

The drop-reason breakdown is what separates this from a quiet evening: **20 `crashed` and 4
`timeout` inside five minutes**, against a baseline that is almost entirely `quit`. Session
length dips for one sample, because the sessions that ended were cut short. The exporter's
own dashboard shows it from the other side — scrapes deferred, then dropped, and the payload
age climbing while the render loop cannot get main-thread time.

**23:30, a resource restart.** `sum(fivem_resource_up)` goes 39 → 38 for four minutes.

**09:45, someone probing the endpoint.** `tickwatch_scrapes_total{result="unauthorized"}`
goes from nothing to **154 in fifteen minutes**, tripping `TickwatchUnauthorizedScrapes`.

**15:20, a milder rough patch** as the server refills, with p99 elevated but no stall.

## Regenerating

Requires Docker and Node. Takes about three minutes.

```bash
# 1. A day of synthetic raw series
node generate.mjs demo.openmetrics

# 2. Backfill it into TSDB blocks
docker run --rm -v "$PWD:/work" -w /work --entrypoint promtool \
  prom/prometheus:v3.13.2 tsdb create-blocks-from openmetrics demo.openmetrics data

# 3. Start the demo stack
docker compose up -d

# 4. Evaluate the real recording rules over the synthetic raw series.
#    --start must be at least 3 h BEFORE the data begins: promtool aligns its
#    output to 2 h block boundaries and drops the leading partial block, which
#    otherwise leaves the first two hours of the window with no recorded series.
docker compose exec prometheus promtool tsdb create-blocks-from rules \
  --url http://localhost:9090 \
  --start "$(date -u -d '27 hours ago' +%Y-%m-%dT%H:%M:%SZ)" \
  --end   "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --output-dir /tmp/rules \
  /etc/prometheus/rules/tickwatch.rules.yml

docker compose exec prometheus sh -c 'cp -r /tmp/rules/* /prometheus/'
docker compose restart prometheus
```

Grafana is then on <http://localhost:3001>, no login. Prometheus on <http://localhost:9091>.

Step 4 is the part worth keeping. The generator emits only the raw series the exporter would
actually publish, and Prometheus computes `fivem:tick_interval_seconds:p50` and the rest from
them using the shipped rules file. The percentile panels are reading real `histogram_quantile`
output over fabricated observations, not numbers the generator invented. If a recording rule
is wrong, the demo shows it.

## Rendering the screenshots

```bash
FROM=$(( ($(date +%s) - 86400) * 1000 )); TO=$(( $(date +%s) * 1000 ))
curl -o out/server-health.png \
  "http://localhost:3001/render/d/tickwatch-server-health/server-health?orgId=1&from=$FROM&to=$TO&width=1700&height=1080&scale=2&kiosk=true&theme=dark"
```

Pin `from`/`to` to the data window rather than using `now-24h`. Prometheus marks a series
stale five minutes after its last sample, so an instant query at `now` returns nothing and
every stat panel renders "No data".

## Tearing it down

```bash
docker compose down
rm -rf data out demo.openmetrics
```

The demo stack has its own project name, ports and bind-mounted storage, so it shares nothing
with `../docker-compose.yml`. The synthetic data cannot reach a real Prometheus.
