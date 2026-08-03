//! Phase 1 spike: MySQL 9.x ROW binlog via `mysql-binlog-connector-rust` (git + rustls).
//!
//! ```text
//! CE_STREAM_DB_URL=mysql://ce_stream:...@127.0.0.1:3306?ssl-mode=required
//! ```

use std::collections::{HashMap, HashSet};
use std::time::{Duration, Instant};

use async_std::future::timeout;
use clap::Parser;
use mysql_binlog_connector_rust::binlog_client::{BinlogClient, StartPosition};
use mysql_binlog_connector_rust::event::event_data::EventData;
use tracing_subscriber::EnvFilter;

#[derive(Debug, Parser)]
#[command(name = "ce-stream-spike")]
struct Args {
    #[arg(long, env = "CE_STREAM_DB_URL")]
    db_url: String,

    #[arg(long, env = "CE_STREAM_SERVER_ID", default_value_t = 19001)]
    server_id: u64,

    /// GTID set to resume from; empty = Latest
    #[arg(long, env = "CE_STREAM_GTID", default_value = "")]
    gtid: String,

    #[arg(long, env = "CE_STREAM_MAX_EVENTS", default_value_t = 3)]
    max_events: u32,

    #[arg(long, env = "CE_STREAM_INCLUDE", default_value = "ce_stream_spike.t1")]
    include: String,

    #[arg(long, default_value_t = 120)]
    timeout_secs: u64,
}

#[async_std::main]
async fn main() {
    tracing_subscriber::fmt()
        .with_env_filter(EnvFilter::from_default_env().add_directive("info".parse().unwrap()))
        .init();

    let args = Args::parse();
    if let Err(err) = run(args).await {
        tracing::error!(error = %err, "spike failed");
        std::process::exit(1);
    }
}

async fn run(args: Args) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    let include: HashSet<String> = args
        .include
        .split(',')
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())
        .collect();

    let start = if args.gtid.trim().is_empty() {
        tracing::info!("start_position=Latest");
        StartPosition::Latest
    } else {
        tracing::info!(gtid = %args.gtid, "start_position=Gtid");
        StartPosition::Gtid(args.gtid.clone())
    };

    tracing::info!(
        server_id = args.server_id,
        url_hint = %redact_url(&args.db_url),
        "connecting BinlogClient"
    );

    let mut client = BinlogClient::new(args.db_url.as_str(), args.server_id, start)
        .with_master_heartbeat(Duration::from_secs(5))
        .with_read_timeout(Duration::from_secs(30));
    let mut stream = client.connect().await?;

    tracing::info!("connected — generate DML on ce_stream_spike.t1 if needed");

    let deadline = Instant::now() + Duration::from_secs(args.timeout_secs);
    let mut row_events: u32 = 0;
    let mut last_gtid: Option<String> = None;
    let mut tables: HashMap<u64, String> = HashMap::new();

    while Instant::now() < deadline {
        let remaining = deadline.saturating_duration_since(Instant::now());
        if remaining.is_zero() {
            break;
        }
        let read = timeout(remaining.min(Duration::from_secs(35)), stream.read()).await;
        let (header, data) = match read {
            Ok(Ok(v)) => v,
            Ok(Err(e)) => {
                tracing::warn!(error = %e, "stream read error; continuing until deadline");
                continue;
            }
            Err(_) => {
                tracing::debug!("idle read timeout; continuing until deadline");
                continue;
            }
        };

        match data {
            EventData::Gtid(g) => {
                last_gtid = Some(g.gtid.clone());
                tracing::debug!(?header, gtid = %g.gtid, "gtid");
            }
            EventData::TableMap(tm) => {
                let key = format!("{}.{}", tm.database_name, tm.table_name);
                tables.insert(tm.table_id, key.clone());
                tracing::debug!(table_id = tm.table_id, %key, "table_map");
            }
            EventData::WriteRows(e) => {
                on_rows(
                    "insert",
                    e.table_id,
                    &tables,
                    &include,
                    &e.rows,
                    e.rows.len() as u32,
                    &mut row_events,
                );
            }
            EventData::UpdateRows(e) => {
                on_rows(
                    "update",
                    e.table_id,
                    &tables,
                    &include,
                    &e.rows,
                    e.rows.len() as u32,
                    &mut row_events,
                );
            }
            EventData::DeleteRows(e) => {
                on_rows(
                    "delete",
                    e.table_id,
                    &tables,
                    &include,
                    &e.rows,
                    e.rows.len() as u32,
                    &mut row_events,
                );
            }
            EventData::HeartBeat => tracing::debug!("heartbeat"),
            other => tracing::trace!(?header, ?other, "other"),
        }

        if args.max_events > 0 && row_events >= args.max_events {
            tracing::info!(row_events, last_gtid = ?last_gtid, "PASS: max matching rows reached");
            return Ok(());
        }
    }

    Err(format!(
        "timeout after {}s with only {row_events} matching rows (need {})",
        args.timeout_secs, args.max_events
    )
    .into())
}

fn on_rows(
    op: &str,
    table_id: u64,
    tables: &HashMap<u64, String>,
    include: &HashSet<String>,
    rows: &impl std::fmt::Debug,
    n: u32,
    row_events: &mut u32,
) {
    let name = tables
        .get(&table_id)
        .cloned()
        .unwrap_or_else(|| format!("table_id={table_id}"));
    if !include.is_empty() && !include.contains(&name) {
        tracing::debug!(%op, %name, "filtered out");
        return;
    }
    *row_events += n;
    tracing::info!(%op, %name, ?rows, count = *row_events, "ROW event");
}

fn redact_url(url: &str) -> String {
    // mysql://user:pass@host -> mysql://user:***@host
    if let Some(at) = url.find('@') {
        if let Some(scheme_end) = url.find("://") {
            let after_scheme = scheme_end + 3;
            if let Some(colon) = url[after_scheme..at].find(':') {
                let user = &url[after_scheme..after_scheme + colon];
                return format!("{}{}:***{}", &url[..after_scheme], user, &url[at..]);
            }
        }
    }
    url.to_string()
}
