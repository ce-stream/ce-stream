# ce-stream

CloudEvents change streams from database logs.

**v1:** MySQL **9.x** ROW binlog → CloudEvents 1.0 (JSON default; optional Avro). Kafka not required.  
**Deferred:** other DB adapters (Postgres / SQLite / MSSQL) — see [`docs/planning.md`](docs/planning.md).

**Plan:** [`docs/planning.md`](docs/planning.md) · **OSS readiness:** [`docs/oss-readiness.md`](docs/oss-readiness.md)

## Status (2026-08-02)

Phases **0–5 complete**. MySQL 9.x capture → stdout/HTTP sinks; at-least-once + backpressure; signal mode; perf harness; optional Avro. Other engines **deferred**.

```powershell
$env:CARGO_TARGET_DIR = "D:\Work\ITART Repos\ce-stream\target"
cargo run -p ce-stream-cli --release -- --config ce-stream.toml
```

| Doc | Topic |
|-----|--------|
| [`docs/delivery.md`](docs/delivery.md) | At-least-once, backpressure, payload modes |
| [`docs/ops-e2e.md`](docs/ops-e2e.md) | Ops / prod continuous run |
| [`docs/library.md`](docs/library.md) | Embed as a library |
| [`docs/avro.md`](docs/avro.md) | Optional Avro encoding |
| [`docs/perf-harness.md`](docs/perf-harness.md) | Perf scenarios + lab results |
| [`docs/spike-mysql-binlog.md`](docs/spike-mysql-binlog.md) | MySQL 9.x spike notes |

For real column names, set MySQL `binlog_row_metadata=FULL`. Prefer capturing from a **replica**.

## Workspace

```text
ce-stream/
  Cargo.toml
  ce-stream.toml.example
  schemas/                  # Avro .avsc (consumer copy)
  crates/
    ce-stream-core/         # CloudEvent, sinks (stdout|http), Avro, traits
    ce-stream-mysql/        # MySQL 9.x binlog adapter
    ce-stream-cli/          # `ce-stream` binary
    ce-stream-perf-sink/    # mock HTTP sink for perf
  scripts/perf/             # baseline / choke / sustained runners
  vendor/mysql-binlog-connector-rust/   # patched SHOW BINARY LOG STATUS
  docs/
```

Pipeline:

```text
ChangeSource (mysql) → filter include-list → CloudEvent → Sink (stdout|http; json|avro)
                              ↑
                         Checkpoint (GTID)
```

## Build

```powershell
cargo build -p ce-stream-cli --release
cargo run -p ce-stream-cli --release -- --config ce-stream.toml
cargo run -p ce-stream-mysql --example embed_callback
```

Copy `ce-stream.toml.example` → `ce-stream.toml`. Set `sink.format = "json"` (default) or `"avro"`.

## Non-goals (v1)

- Debezium / Kafka Connect
- MySQL &lt; 9.x
- Other DB engines (deferred; Phase 6 parked)
- Full warehouse ELT
- In-mysqld plugins as the capture path
- Schema Registry (optional later)
