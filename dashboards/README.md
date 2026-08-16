# Dashboards

A `docker compose` stack: Prometheus with recording and alerting rules, and Grafana with five
dashboards provisioned from files. Nothing is clicked in by hand, so the whole thing is
reviewable in a diff.

```bash
printf '%s' 'your-scrape-token' > secrets/tickwatch_token
# point prometheus/prometheus.yml at your server if it is not on this host at :30120
docker compose up -d
```

Grafana on <http://localhost:3000>, Prometheus on <http://localhost:9090>. Both bind to
loopback.

## The five dashboards

| | answers | empty when |
|---|---|---|
| **Server health** | Is the loop hitting its 50 ms budget, and who felt it? | never |
| **Load** | What was the server carrying when it missed? | never |
| **Player flow** | Are people getting in, staying, and leaving normally? | nobody has connected yet |
| **Instrumented** | How are *your* resources behaving? | until a resource calls the export API |
| **Exporter** | Is tickwatch itself healthy, and what does it cost? | never |

Two of these are empty on a fresh install and that is not a fault. A counter with no
increments and a histogram with no observations render their `HELP` and `TYPE` and no samples,
so the player panels appear the moment someone connects and the instrumented panels appear
when you add the export calls.

## What these dashboards deliberately do not show

tickwatch measures scheduler delay for one thread as a proxy for server load. It reports
*when* the server stalled and *how badly* — never *which resource did it*, because no
interface on this platform exposes per-resource tick time
([notes](../docs/platform-notes.md#tick-timing-and-resource-attribution)).

So there is no leaderboard panel, and there never will be. The layout compensates: one shared
time axis, with load and consequence stacked under the deadline line, so the reader's eye does
the correlation the metric cannot do for them. Any panel implying attribution would be lying.

Attribution is opt-in instead — wrap a function with `TickwatchTimed` and it appears on the
Instrumented dashboard.

## Rules

`prometheus/rules/tickwatch.rules.yml` holds both recording rules (percentiles, frame rate,
join ratio) and alerts. `tickwatch.test.yml` is a promtool unit-test file for them:

```bash
docker run --rm -v "$PWD/prometheus:/p" --entrypoint promtool prom/prometheus:v3.13.2 \
  test rules /p/rules/tickwatch.test.yml
```

Two of those tests exist because the rules were wrong on a live server in ways review did not
catch: a `clamp_min` denominator turned 0/0 into a confident-looking 0%, and the join-failure
alert fired on an idle server.

## Demo data

[demo/](demo) generates a day of synthetic metrics and backfills it into a throwaway
Prometheus, so the dashboards can be screenshotted with something on them. It is fabricated
and it is kept well away from the real stack.
