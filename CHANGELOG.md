# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project aims to follow [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added

- Lean OSS MVP: `LICENSE`, `NOTICE` (`Copyright 2026 AxialDB`), `CONTRIBUTING.md`, `SECURITY.md`, GitHub issue/PR templates, CI workflow.
- README credit: created and maintained by the AxialDB vendor ([axialdb.com](https://axialdb.com/), [AxialDB/releases](https://github.com/AxialDB/releases)).

## [0.1.0] - 2026-08-02

### Added

- MySQL 9.x ROW binlog capture (`ce-stream-mysql`) with GTID checkpoint, include-list, TLS.
- CloudEvents 1.0 sinks: stdout and HTTP (`application/cloudevents+json`).
- Optional Avro sink encoding (`sink.format = avro`, schema `ce-stream.cloudevent.v1`).
- At-least-once delivery (checkpoint after successful sink), bounded queue backpressure.
- `payload_mode`: `full` | `signal`.
- CLI (`ce-stream`), embed example, systemd unit, E2E and perf harness scripts.
- Lab perf baselines (JSON and Avro) documented in `docs/perf-harness.md`.

### Deferred

- Other database engines (Phase 6 parked).
- Schema Registry / typed per-table Avro.

[Unreleased]: https://github.com/ce-stream/ce-stream/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/ce-stream/ce-stream/releases/tag/v0.1.0
