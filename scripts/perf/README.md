# Perf scripts (Phase 4.5)

See [`docs/perf-harness.md`](../../docs/perf-harness.md). Avro option: [`docs/avro.md`](../../docs/avro.md).

```powershell
.\scripts\perf\run-baseline.ps1 -Rows 1000
.\scripts\perf\run-choke.ps1 -Rows 500 -DelayMs 10
.\scripts\perf\run-sustained.ps1 -OpsPerSec 300 -DurationSec 60

# Optional Avro wire format (same scenarios)
.\scripts\perf\run-baseline.ps1 -Rows 1000 -Format avro
.\scripts\perf\run-choke.ps1 -Rows 500 -DelayMs 10 -Format avro
.\scripts\perf\run-sustained.ps1 -OpsPerSec 300 -DurationSec 60 -Format avro
```

Outputs: `scripts/perf/out/*.json` (gitignored via `out/`). Summaries include `format`.
