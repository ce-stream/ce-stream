# Using ce-stream as a library

**Status:** Supported. MySQL 9.x only for v1; other adapters deferred.

The CLI is a thin host. Embed capture in your own process with the same single ordered reader.

## Crates

- `ce-stream-core` - `CloudEvent`, `ChangeSource`, `Sink`, `CheckpointStore`
- `ce-stream-mysql` - `MysqlBinlogSource`, `FileCheckpointStore`

## Minimal callback (in-process push)

```rust
use ce_stream_core::source::{ChangeSource, SourceConfig};
use ce_stream_core::event::TableRef;
use ce_stream_mysql::{MysqlBinlogSource, MysqlSourceOptions};

// inside an async fn on a tokio runtime:
let mut source = MysqlBinlogSource {
    options: MysqlSourceOptions {
        host: "127.0.0.1".into(),
        port: 3306,
        user: "ce_stream".into(),
        password: "...".into(),
        server_id: 19001,
        tls: true,
    },
    config: SourceConfig {
        source_id: "mysql://127.0.0.1:3306/app".into(),
        include_tables: vec![TableRef::new("demo_perf", "orders")],
        payload_mode: Default::default(),
        queue_capacity: 64,
    },
    checkpoint: None,
    checkpoint_store: None, // or Some(Box::new(FileCheckpointStore { ... }))
};

source
    .run(|ev| {
        // your pub/sub, queue, or business logic
        println!("{}", serde_json::to_string(&ev)?);
        Ok(())
    })
    .await?;
```

## Rules

- One dump client / unique `server_id` per process (do not start two readers with the same id).
- Capture stays single-threaded and ordered; fan-out in your callback or downstream bus.
- Prefer TLS; prefer reading a replica; set `binlog_row_metadata=FULL` for column names.
- Optional Avro: `HttpSink::with_format(url, SinkFormat::Avro)` or encode via `ce_stream_core::avro_encode` — see [`avro.md`](avro.md).

See also [`ops-e2e.md`](ops-e2e.md) for the HTTP sidecar path.
