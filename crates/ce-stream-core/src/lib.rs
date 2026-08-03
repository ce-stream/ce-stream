//! Shared types: CloudEvents envelope, change ops, source/sink traits, checkpoint.

pub mod avro_encode;
pub mod checkpoint;
pub mod error;
pub mod event;
pub mod sink;
pub mod sinks;
pub mod source;

pub use checkpoint::{Checkpoint, CheckpointStore};
pub use error::Error;
pub use event::{ChangeOp, CloudEvent, PayloadMode, SinkFormat, TableRef};
pub use sink::Sink;
pub use sinks::{HttpSink, StdoutSink};
pub use source::{ChangeSource, SourceConfig};
