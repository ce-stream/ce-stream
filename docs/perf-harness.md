# Performance harness (Phase 4.5)

**Status:** Done for baseline / choke / sustained (JSON + Avro). Other DB engines deferred. OSS packaging of this harness is not required for v0.1.

**Location:** [`scripts/perf/`](../scripts/perf/)  
**Goal:** Measure ce-stream under frequent changes and a choking sink; get a grounded feel vs Debezium/Fivetran without fake marketing claims.

## Architecture

```text
loadgen (SQL) --> MySQL 9.x lab
                      |
                   binlog dump
                      v
                  ce-stream  -->  mock HTTP sink (delay_ms, counters)
                      |
                 perf-summary.json
```

Optional: `sink.format = avro` (Phase 5) for the same scenarios; mock sink accepts any body and counts bytes.

## Metrics we collect

| Metric | Source |
|--------|--------|
| Events received | Mock sink `/stats` |
| Wall time, events/sec | Runner |
| Bytes received | Mock sink (JSON vs Avro size) |
| Lag samples | ce-stream `ce_stream::health` / `lag_ms` (log scrape optional) |
| Expected vs received | Loadgen row count vs sink count (choke: must match) |
| Catch-up | Time from loadgen end until sink count stable |
| Sustained track | Sink rate vs target ops/sec over a fixed window |

## Scenarios

| # | Name | Intent |
|---|------|--------|
| 1 | `baseline` | Fast sink (`delay_ms=0`), N inserts, full payload |
| 2 | `choke` | Slow sink (`delay_ms>0`); no drops; lag grows then may drain |
| 3 | `sustained` | Fixed inserts/sec for D seconds; assert sink keeps up (Debezium-style narrative) |
| 4 | `burst` | Burst N then idle until catch-up |
| 5 | `signal` | Same as baseline with `payload_mode=signal` |
| 6 | `noise` | Heavy DML on excluded table + light on included |
| 7 | `restart` | Kill/restart mid-run; resume; duplicates OK |

## Lab results (MySQL 9.x, local HTTP mock sink)

Recorded 2026-08-02 (`payload_mode=full`, sync checkpoint after each HTTP ACK).

### JSON (`format=json`)

| Scenario | Result |
|----------|--------|
| baseline 1000 rows, `delay_ms=0` | **~458 eps**, 1000/1000, ~408 KB |
| choke 500 rows, `delay_ms=10`, queue 32 | **~62 eps**, 500/500 (no drops; sink-bound) |
| sustained 300/s x 60s | **PASS** keep-up (second-half ~288 eps, catch-up ~3.3s) |
| sustained 600/s x 60s | **PASS** keep-up (second-half ~565 eps, catch-up ~2.9s) |
| sustained 1200/s x 60s | **FAIL** keep-up (second-half ~641 eps, catch-up ~62s); all 72k received |

**JSON ceiling:** about **600-650 eps**.

### Avro (`format=avro`)

| Scenario | Result |
|----------|--------|
| baseline 1000 rows, `delay_ms=0` | **~495 eps**, 1000/1000, ~345 KB (~15% smaller than JSON) |
| choke 500 rows, `delay_ms=10`, queue 32 | **~56 eps**, 500/500 (no drops; still sink-bound) |
| sustained 1000/s x 60s | **FAIL** keep-up (second-half ~741 eps, catch-up ~22s); all 60k received |

**Avro ceiling (this run):** about **740 eps** at sustained 1000/s (higher than JSON; still short of 1000/s keep-up). Choke remains delay-dominated either format.

Artifacts: `scripts/perf/out/baseline-20260802-184816.json` / `...-195639.json` (avro), `choke-...-184946.json` / `...-195711.json` (avro), sustained JSON 300/600/1200 and Avro `sustained-20260802-195737.json` (1000).

## Comparison (published numbers, no local Debezium/Fivetran)

We do **not** run Debezium or Fivetran in this repo. Use published methodology for framing only.

### Debezium (official-ish)

- Best method match: [Measuring Debezium Server performance (MySQL to Kafka, 2026)](https://debezium.io/blog/2026/02/02/measuring-debezium-server-performance-mysql-streaming/) on **c5a.xlarge** (4 vCPU / 8 GiB). Defaults; YCSB-style load; sustained **hundreds of ops/sec** (e.g. 300 insert + 300 update). **Finding:** Debezium tracks MySQL write rate; CDC not the bottleneck.
- Field reports vary widely (~0.5k-10k msg/s) with Kafka/RDS/schema shape; not controlled benchmarks.
- Do **not** rescale our ~458 eps by vCPU ratios against Kafka pipelines. Prefer the same question: **does capture keep up with a sustained source rate?** (`run-sustained.ps1`). On this lab, JSON keep-up holds through ~600/s and fails at 1200/s; Avro sustained at 1000/s still fails keep-up but tracks higher (~740 eps).

### Fivetran (official, different product)

- [fivetran.com/benchmarking](https://www.fivetran.com/benchmarking): **GB/hour**, warehouse freshness (**minutes**), TPROC-C ~**16k TPS** with **~15 min** latency targets; historical **500+ GB/h**.
- Not comparable to per-event HTTP CloudEvents. Compare on ops model / SLA axis, not events/sec.

### How to talk about it

1. Report our baseline + choke + sustained keep-up on this lab.  
2. Say we are the same **class** as Debezium (binlog dump client) when sustained lag stays flat (JSON: up to ~600/s; Avro tracks a bit higher on the same HTTP path).  
3. Treat Fivetran as warehouse micro-batch, not a webhook competitor.  
4. No product marketing claims until repeated and scoped.

Worksheet: [`scripts/perf/comparison-worksheet.json`](../scripts/perf/comparison-worksheet.json).

## How to run

```powershell
cd path\to\ce-stream
.\scripts\perf\run-baseline.ps1 -Rows 1000
.\scripts\perf\run-choke.ps1 -Rows 500 -DelayMs 10
.\scripts\perf\run-sustained.ps1 -OpsPerSec 300 -DurationSec 60

# Same scenarios with Avro wire format (Phase 5)
.\scripts\perf\run-baseline.ps1 -Rows 1000 -Format avro
.\scripts\perf\run-choke.ps1 -Rows 500 -DelayMs 10 -Format avro
.\scripts\perf\run-sustained.ps1 -OpsPerSec 300 -DurationSec 60 -Format avro
```

Pass `-MysqlDefaults` (path to a mysql client defaults file) or set `MYSQL_DEFAULTS_FILE`. Set `CE_STREAM_PASSWORD` for the capture user (see `ce-stream.toml.example`).

Artifacts under `scripts/perf/out/` (gitignored). Summaries include `format` (`json`|`avro`).
