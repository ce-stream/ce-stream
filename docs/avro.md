# Optional Avro encoding (Phase 5)

**Status:** Done. JSON remains default. Lab perf: [`perf-harness.md`](perf-harness.md).

JSON CloudEvents remain the **default**. Avro is an optional sink encoding of the same logical event.

## Config

```toml
[sink]
kind = "http"   # or stdout
url = "http://127.0.0.1:18080/events"
format = "avro" # default: json
```

| `format` | HTTP `Content-Type` | Body |
|----------|---------------------|------|
| `json` (default) | `application/cloudevents+json` | Structured-mode JSON |
| `avro` | `application/cloudevents+avro` | Single Avro datum (no OCF) |

HTTP also sends `x-ce-stream-avro-schema: ce-stream.cloudevent.v1`.

Stdout + Avro prints **one base64 line per event** (binary on a TTY is hostile).

## Schema

Published copies (keep in sync):

- [`schemas/cloudevent-v1.avsc`](../schemas/cloudevent-v1.avsc) (repo)
- [`crates/ce-stream-core/schemas/cloudevent-v1.avsc`](../crates/ce-stream-core/schemas/cloudevent-v1.avsc) (embedded in the crate)

- Schema id: `ce-stream.cloudevent.v1`
- Envelope fields are Avro strings
- Variable CDC payload stays in `data_json` / `extensions_json` as JSON text (row shapes change; typed column schemas are later)

**Not included yet:** Confluent Schema Registry wire format, schema evolution tooling, or per-table Avro records.

## Library

```rust
use ce_stream_core::avro_encode::{decode_cloudevent, encode_cloudevent};
use ce_stream_core::{HttpSink, SinkFormat};

let bytes = encode_cloudevent(&event)?;
let again = decode_cloudevent(&bytes)?;
let sink = HttpSink::with_format(url, SinkFormat::Avro)?;
```

## Perf

Same harness as JSON (`-Format avro`). Lab (2026-08-02): baseline ~495 eps / ~345 KB (vs JSON ~458 / ~408 KB); choke no drops; sustained 1000/s FAIL keep-up (~741 eps). Details in [`perf-harness.md`](perf-harness.md).
