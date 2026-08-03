# Ops / E2E / production

**Status:** Phase 3–4 path complete (JSON HTTP E2E + continuous prod). Optional Avro: `sink.format = "avro"` ([`avro.md`](avro.md)). Other DB engines deferred.

Happy path: MySQL 9.x **replica** -> ce-stream (continuous) -> HTTP CloudEvents (JSON default).

Also see [`delivery.md`](delivery.md) (at-least-once), [`library.md`](library.md) (embed), [`planning.md`](planning.md) (status).

## MySQL prerequisites

```sql
-- required
-- log_bin=ON, ROW, binlog_row_image=FULL, gtid_mode=ON

-- recommended for named columns
SET PERSIST binlog_row_metadata = 'FULL';
```

Replication user: `REPLICATION SLAVE`, `REPLICATION CLIENT`, typically `SELECT` (`scripts/spike-setup.sql`).

## Production run (continuous)

Do **not** pass `--max-events` (that flag is smoke/CI only).

```powershell
$env:CARGO_TARGET_DIR = "D:\Work\ITART Repos\ce-stream\target"
$env:RUST_LOG = "info"
cargo run -p ce-stream-cli --release -- --config ce-stream.toml
```

Or install the binary and use `deploy/ce-stream.service` (systemd): restart on failure, durable checkpoint path, unique `server_id` per host.

### Config sketch

```toml
[source]
adapter = "mysql"
host = "replica.example"   # prefer replica, not primary
port = 3306
tls = true
server_id = 19001          # unique per ce-stream instance
payload_mode = "full"      # or "signal"
queue_capacity = 64
include_tables = ["demo_perf.orders"]

[checkpoint]
path = "/var/lib/ce-stream/checkpoint.json"

[sink]
kind = "http"
url = "https://hooks.example/events"
```

### Impact notes

- Capture reads the **binlog stream** as a replica client; CPU/network cost is mostly decode + sink.
- Prefer a **replica** so primary OLTP is not coupled to sink latency (backpressure stalls the dump client).
- Tight **include-list** reduces decode/sink work; filtered tables still advance GTID without HTTP.
- Measure lag via `ce_stream::health` (`lag_ms`, `last_gtid`, `events_total`).

## Smoke E2E (one event)

```powershell
# ce-stream.toml: sink.kind=http, url=http://127.0.0.1:18080/events
# Optional: sink.format=avro (see docs/avro.md); default is json
.\scripts\e2e-http.ps1
```

Uses `--max-events 1` and a local HttpListener (emitter + catcher in one script).

## HTTP body

`Content-Type: application/cloudevents+json` — structured-mode JSON with `gtid` / `gtidset` extensions when available.
