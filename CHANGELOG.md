# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project aims to follow [Semantic Versioning](https://semver.org/).

## [Unreleased]

## [0.1.1] - 2026-08-02

### Security

- Removed lab password and machine-local AxialDB paths from examples, scripts, and docs. Use `CHANGE_ME` / `CE_STREAM_PASSWORD` / `MYSQL_DEFAULTS_FILE` (or `-MysqlDefaults`). Rotate any MySQL password that matched the old example value; it remains in `v0.1.0` git history.

## [0.1.0] - 2026-08-02

### Added

- MySQL 9.x ROW binlog capture (`ce-stream-mysql`) with GTID checkpoint, include-list, TLS.
- CloudEvents 1.0 sinks: stdout and HTTP (`application/cloudevents+json`).
- Optional Avro sink encoding (`sink.format = avro`, schema `ce-stream.cloudevent.v1`).
- At-least-once delivery (checkpoint after successful sink), bounded queue backpressure.
- `payload_mode`: `full` | `signal`.
- CLI (`ce-stream`), embed example, systemd unit, E2E and perf harness scripts.
- Lab perf baselines (JSON and Avro) documented in `docs/perf-harness.md`.
- Lean OSS MVP: `LICENSE`, `NOTICE` (`Copyright 2026 AxialDB`), `CONTRIBUTING.md`, `SECURITY.md`, CI, issue/PR templates.
- Discussion category forms (`q-a`, `ideas`, `general`) and Issues contact links to Discussions.
- README credit: created and maintained by the AxialDB vendor ([axialdb.com](https://axialdb.com/), [AxialDB/releases](https://github.com/AxialDB/releases)).

### Deferred

- Other database engines (Phase 6 parked).
- Schema Registry / typed per-table Avro.

[Unreleased]: https://github.com/ce-stream/ce-stream/compare/v0.1.1...HEAD
[0.1.1]: https://github.com/ce-stream/ce-stream/releases/tag/v0.1.1
[0.1.0]: https://github.com/ce-stream/ce-stream/releases/tag/v0.1.0
