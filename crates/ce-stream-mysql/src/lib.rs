//! MySQL 9.x ROW binlog → [`ce_stream_core::CloudEvent`].

mod map;

use std::collections::{HashMap, HashSet};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::time::Duration;

use async_trait::async_trait;
use ce_stream_core::{
    error::{Error, Result},
    event::{ChangeOp, CloudEvent, PayloadMode, TableRef},
    source::{ChangeSource, SourceConfig},
    Checkpoint, CheckpointStore,
};
use map::GtidTracker;
use mysql_binlog_connector_rust::binlog_client::{BinlogClient, StartPosition};
use mysql_binlog_connector_rust::event::event_data::EventData;
use percent_encoding::{utf8_percent_encode, NON_ALPHANUMERIC};
use tracing::{debug, info, warn};

pub use map::column_value_to_json;

#[derive(Debug, Clone)]
pub struct MysqlSourceOptions {
    pub host: String,
    pub port: u16,
    pub user: String,
    pub password: String,
    /// Unique replica server_id for this capture client.
    pub server_id: u64,
    /// Require TLS (`ssl-mode=required`).
    pub tls: bool,
}

impl MysqlSourceOptions {
    pub fn connection_url(&self) -> String {
        let user = utf8_percent_encode(&self.user, NON_ALPHANUMERIC);
        let pass = utf8_percent_encode(&self.password, NON_ALPHANUMERIC);
        let ssl = if self.tls {
            "ssl-mode=required"
        } else {
            "ssl-mode=disabled"
        };
        format!("mysql://{user}:{pass}@{}:{}/?{ssl}", self.host, self.port)
    }
}

pub struct MysqlBinlogSource {
    pub options: MysqlSourceOptions,
    pub config: SourceConfig,
    pub checkpoint: Option<Checkpoint>,
    pub checkpoint_store: Option<Box<dyn CheckpointStore>>,
}

impl MysqlBinlogSource {
    fn start_position(&self) -> StartPosition {
        if let Some(cp) = &self.checkpoint {
            if cp.adapter == "mysql" {
                if let Some(gtid) = cp.payload.get("gtid").and_then(|v| v.as_str()) {
                    if !gtid.is_empty() {
                        return StartPosition::Gtid(gtid.to_string());
                    }
                }
            }
        }
        StartPosition::Latest
    }

    fn include_set(&self) -> HashSet<String> {
        self.config
            .include_tables
            .iter()
            .map(|t| t.as_subject())
            .collect()
    }

    fn initial_gtid_tracker(&self) -> GtidTracker {
        if let Some(cp) = &self.checkpoint {
            if let Some(gtid) = cp.payload.get("gtid").and_then(|v| v.as_str()) {
                return GtidTracker::from_set_string(gtid);
            }
        }
        GtidTracker::default()
    }

    async fn persist_gtid_set(&mut self, gtid_set: &str) -> Result<()> {
        if gtid_set.is_empty() {
            return Ok(());
        }
        let cp = Checkpoint {
            adapter: "mysql".into(),
            payload: serde_json::json!({ "gtid": gtid_set }),
        };
        if let Some(store) = &self.checkpoint_store {
            store.save(&cp).await?;
        }
        self.checkpoint = Some(cp);
        Ok(())
    }
}

#[async_trait]
impl ChangeSource for MysqlBinlogSource {
    async fn run<F>(&mut self, mut on_event: F) -> Result<()>
    where
        F: FnMut(CloudEvent) -> Result<()> + Send,
    {
        let url = self.options.connection_url();
        let server_id = self.options.server_id;
        let start = self.start_position();
        let source_id = self.config.source_id.clone();
        let include = self.include_set();
        let tracker = self.initial_gtid_tracker();
        let payload_mode = self.config.payload_mode;
        let capacity = self.config.queue_capacity.max(1);

        info!(
            server_id,
            source = %source_id,
            include = ?include,
            ?payload_mode,
            queue_capacity = capacity,
            "starting MySQL binlog source"
        );

        let (tx, mut rx) =
            tokio::sync::mpsc::channel::<std::result::Result<StreamMsg, String>>(capacity);
        let stop = Arc::new(AtomicBool::new(false));
        let stop_bg = Arc::clone(&stop);

        let join = tokio::task::spawn_blocking(move || {
            async_std::task::block_on(binlog_loop(
                url,
                server_id,
                start,
                source_id,
                include,
                tracker,
                payload_mode,
                tx,
                stop_bg,
            ))
        });

        let result = async {
            while let Some(msg) = rx.recv().await {
                match msg {
                    Ok(StreamMsg::Event { event, gtid_set }) => {
                        // At-least-once: only advance checkpoint after sink Ok.
                        on_event(event)?;
                        self.persist_gtid_set(&gtid_set).await?;
                    }
                    Ok(StreamMsg::Advance { gtid_set }) => {
                        // Filtered / no delivery; safe to advance without sink.
                        self.persist_gtid_set(&gtid_set).await?;
                    }
                    Err(e) => return Err(Error::Source(e)),
                }
            }
            Ok(())
        }
        .await;

        stop.store(true, Ordering::SeqCst);
        let _ = join.await;

        result
    }
}

enum StreamMsg {
    /// Deliver event; persist `gtid_set` only after callback Ok.
    Event { event: CloudEvent, gtid_set: String },
    /// No event (filtered); persist `gtid_set` immediately.
    Advance { gtid_set: String },
}

#[allow(clippy::too_many_arguments)]
async fn binlog_loop(
    url: String,
    server_id: u64,
    start: StartPosition,
    source_id: String,
    include: HashSet<String>,
    mut tracker: GtidTracker,
    payload_mode: PayloadMode,
    tx: tokio::sync::mpsc::Sender<std::result::Result<StreamMsg, String>>,
    stop: Arc<AtomicBool>,
) -> std::result::Result<(), String> {
    let mut client = BinlogClient::new(url.as_str(), server_id, start)
        .with_master_heartbeat(Duration::from_secs(5))
        .with_read_timeout(Duration::from_secs(3));

    let mut stream = client
        .connect()
        .await
        .map_err(|e| format!("binlog connect: {e}"))?;

    info!("binlog connected");

    let mut tables: HashMap<u64, TableMap> = HashMap::new();
    let mut last_gtid: Option<String> = None;

    while !stop.load(Ordering::SeqCst) {
        let read = stream.read().await;
        let (_header, data) = match read {
            Ok(v) => v,
            Err(e) => {
                if stop.load(Ordering::SeqCst) {
                    break;
                }
                let msg = e.to_string();
                if msg.to_ascii_lowercase().contains("timeout") {
                    continue;
                }
                return Err(format!("binlog read: {e}"));
            }
        };

        match data {
            EventData::Gtid(g) => {
                last_gtid = Some(g.gtid.clone());
                tracker.add_gtid(&g.gtid);
            }
            EventData::TableMap(tm) => {
                let col_names = column_names_from_table_map(&tm);
                tables.insert(
                    tm.table_id,
                    TableMap {
                        table: TableRef::new(tm.database_name, tm.table_name),
                        col_names,
                    },
                );
            }
            EventData::WriteRows(e) => {
                emit_rows(
                    &tx,
                    &source_id,
                    &include,
                    &tables,
                    e.table_id,
                    ChangeOp::Insert,
                    &last_gtid,
                    &tracker,
                    payload_mode,
                    e.rows.iter().map(|r| (None, Some(r))),
                )?;
            }
            EventData::UpdateRows(e) => {
                emit_rows(
                    &tx,
                    &source_id,
                    &include,
                    &tables,
                    e.table_id,
                    ChangeOp::Update,
                    &last_gtid,
                    &tracker,
                    payload_mode,
                    e.rows.iter().map(|(b, a)| (Some(b), Some(a))),
                )?;
            }
            EventData::DeleteRows(e) => {
                emit_rows(
                    &tx,
                    &source_id,
                    &include,
                    &tables,
                    e.table_id,
                    ChangeOp::Delete,
                    &last_gtid,
                    &tracker,
                    payload_mode,
                    e.rows.iter().map(|r| (Some(r), None)),
                )?;
            }
            EventData::Xid(_) => {
                // Covered by per-event / Advance checkpoints.
            }
            EventData::HeartBeat => debug!("heartbeat"),
            other => debug!(?other, "ignored binlog event"),
        }
    }

    Ok(())
}

struct TableMap {
    table: TableRef,
    col_names: Vec<String>,
}

fn column_names_from_table_map(
    tm: &mysql_binlog_connector_rust::event::table_map_event::TableMapEvent,
) -> Vec<String> {
    if let Some(meta) = &tm.table_metadata {
        let names: Vec<String> = meta
            .columns
            .iter()
            .enumerate()
            .map(|(i, c)| c.column_name.clone().unwrap_or_else(|| format!("col_{i}")))
            .collect();
        if names.iter().any(|n| !n.starts_with("col_")) {
            return names;
        }
        if !names.is_empty() {
            return names;
        }
    }
    (0..tm.column_types.len())
        .map(|i| format!("col_{i}"))
        .collect()
}

#[allow(clippy::too_many_arguments)]
fn emit_rows<'a, I>(
    tx: &tokio::sync::mpsc::Sender<std::result::Result<StreamMsg, String>>,
    source_id: &str,
    include: &HashSet<String>,
    tables: &HashMap<u64, TableMap>,
    table_id: u64,
    op: ChangeOp,
    last_gtid: &Option<String>,
    tracker: &GtidTracker,
    payload_mode: PayloadMode,
    rows: I,
) -> std::result::Result<(), String>
where
    I: Iterator<
        Item = (
            Option<&'a mysql_binlog_connector_rust::event::row_event::RowEvent>,
            Option<&'a mysql_binlog_connector_rust::event::row_event::RowEvent>,
        ),
    >,
{
    let Some(tm) = tables.get(&table_id) else {
        warn!(table_id, "row event without table_map; skipping");
        return Ok(());
    };
    let subject = tm.table.as_subject();
    let gtid_set = tracker.to_set_string();

    if !include.is_empty() && !include.contains(&subject) {
        // Backpressure-aware advance for filtered traffic.
        if !gtid_set.is_empty() {
            tx.blocking_send(Ok(StreamMsg::Advance { gtid_set }))
                .map_err(|_| "event channel closed".to_string())?;
        }
        return Ok(());
    }

    let mut emitted = 0u32;
    for (before, after) in rows {
        let data = match payload_mode {
            PayloadMode::Signal => serde_json::json!({
                "op": op.as_str(),
                "signal": true,
            }),
            PayloadMode::Full => match op {
                ChangeOp::Insert => {
                    let after = after.ok_or_else(|| "insert missing after".to_string())?;
                    serde_json::json!({
                        "op": "insert",
                        "after": map::row_to_object(&tm.col_names, after),
                    })
                }
                ChangeOp::Update => {
                    let before = before.ok_or_else(|| "update missing before".to_string())?;
                    let after = after.ok_or_else(|| "update missing after".to_string())?;
                    serde_json::json!({
                        "op": "update",
                        "before": map::row_to_object(&tm.col_names, before),
                        "after": map::row_to_object(&tm.col_names, after),
                    })
                }
                ChangeOp::Delete => {
                    let before = before.ok_or_else(|| "delete missing before".to_string())?;
                    serde_json::json!({
                        "op": "delete",
                        "before": map::row_to_object(&tm.col_names, before),
                    })
                }
            },
        };

        let mut extensions = serde_json::Map::new();
        if let Some(gtid) = last_gtid {
            extensions.insert("gtid".into(), serde_json::Value::String(gtid.clone()));
        }
        if !gtid_set.is_empty() {
            extensions.insert(
                "gtidset".into(),
                serde_json::Value::String(gtid_set.clone()),
            );
        }

        let event = CloudEvent::row_change(source_id, &tm.table, op, data, extensions);
        // Bounded queue: blocks here when sink is slow (do not drop).
        tx.blocking_send(Ok(StreamMsg::Event {
            event,
            gtid_set: gtid_set.clone(),
        }))
        .map_err(|_| "event channel closed".to_string())?;
        emitted += 1;
    }

    if emitted == 0 && !gtid_set.is_empty() {
        tx.blocking_send(Ok(StreamMsg::Advance { gtid_set }))
            .map_err(|_| "event channel closed".to_string())?;
    }

    Ok(())
}

/// File-backed checkpoint (GTID JSON in payload).
pub struct FileCheckpointStore {
    pub path: std::path::PathBuf,
}

#[async_trait]
impl CheckpointStore for FileCheckpointStore {
    async fn load(&self) -> Result<Option<Checkpoint>> {
        if !self.path.exists() {
            return Ok(None);
        }
        let bytes = tokio::fs::read(&self.path).await?;
        let cp: Checkpoint = serde_json::from_slice(&bytes)?;
        Ok(Some(cp))
    }

    async fn save(&self, checkpoint: &Checkpoint) -> Result<()> {
        if let Some(parent) = self.path.parent() {
            tokio::fs::create_dir_all(parent).await?;
        }
        let bytes = serde_json::to_vec_pretty(checkpoint)?;
        tokio::fs::write(&self.path, bytes).await?;
        Ok(())
    }
}
