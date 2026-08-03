use async_trait::async_trait;

use crate::error::Result;
use crate::event::{CloudEvent, PayloadMode, TableRef};

/// Common knobs every DB adapter understands.
#[derive(Debug, Clone)]
pub struct SourceConfig {
    /// Logical source id for CloudEvents `source` (e.g. `mysql://host:3306/ce-stream`).
    pub source_id: String,
    pub include_tables: Vec<TableRef>,
    /// Full row images vs signal-only.
    pub payload_mode: PayloadMode,
    /// Bounded event queue capacity (backpressure when sink is slow). Default 64.
    pub queue_capacity: usize,
}

impl Default for SourceConfig {
    fn default() -> Self {
        Self {
            source_id: String::new(),
            include_tables: Vec::new(),
            payload_mode: PayloadMode::Full,
            queue_capacity: 64,
        }
    }
}

#[async_trait]
pub trait ChangeSource: Send {
    /// Run until cancelled; emit CloudEvents via callback.
    /// Checkpoint should advance only after the callback returns Ok (at-least-once).
    async fn run<F>(&mut self, mut on_event: F) -> Result<()>
    where
        F: FnMut(CloudEvent) -> Result<()> + Send;
}
