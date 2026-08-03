use async_trait::async_trait;

use crate::error::Result;
use crate::event::CloudEvent;

#[async_trait]
pub trait Sink: Send + Sync {
    async fn emit(&self, event: &CloudEvent) -> Result<()>;
}
