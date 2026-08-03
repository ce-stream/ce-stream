# Delivery semantics (Phase 4)

**Status:** Done. At-least-once + backpressure + `payload_mode`. Encoding: JSON default; optional Avro ([`avro.md`](avro.md)). Other DB engines deferred ([`planning.md`](planning.md)).

ce-stream is **at-least-once**, not exactly-once.

## What “issued” means

1. Sink callback / HTTP POST returns **Ok** (HTTP 2xx).
2. **Then** GTID checkpoint is written to disk (`.ce-stream/checkpoint.json`).

If the process crashes after a successful HTTP POST but before the checkpoint flush, the same GTID may be delivered again after restart. Consumers should be **idempotent** (dedupe on business key and/or CloudEvent `id` / `gtid`).

## What we do not claim

- Exactly-once end-to-end delivery
- Global order after a fan-out bus (Kafka/NATS/…)
- Zero duplicates across crashes

## Backpressure

The binlog reader pushes into a **bounded** queue (`source.queue_capacity`, default 64). When the sink is slow, `blocking_send` stalls the reader (does **not** drop events). MySQL may see the dump client slow down; prefer a replica and size the webhook accordingly.

## Signal vs full payload

| `payload_mode` | `data` contents |
|----------------|-----------------|
| `full` (default) | `op` + `before` / `after` images |
| `signal` | `{ "op": "...", "signal": true }` only |

Signal mode reduces payload size and sink cost; you lose row images.

## Encoding (JSON vs Avro)

Default sink encoding is CloudEvents structured **JSON**. Set `sink.format = "avro"` for optional binary Avro (same logical event). See [`avro.md`](avro.md). Checkpoint and delivery semantics are unchanged.
