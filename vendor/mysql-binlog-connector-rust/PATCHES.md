# Patches applied on top of apecloud/mysql-binlog-connector-rust @ f7cca8ec

1. `src/command/command_util.rs` — `show master status` → `show binary log status`
   (MySQL 8.4+ / 9.x; ce-stream does not support older MySQL.)

2. `src/lib.rs` — `#![allow(dead_code)]` to silence unused protocol-field warnings from upstream.
