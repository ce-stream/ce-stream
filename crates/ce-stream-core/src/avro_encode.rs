//! Optional Avro encoding for CloudEvents (Phase 5).
//!
//! Schema: `schemas/cloudevent-v1.avsc` (id `ce-stream.cloudevent.v1`).
//! Wire: single Avro datum (no OCF); HTTP `Content-Type: application/cloudevents+avro`.
//! Schema Registry is out of scope for this path; consumers use the published `.avsc`.

use std::sync::OnceLock;

use apache_avro::types::Value;
use apache_avro::{from_avro_datum, to_avro_datum, Schema};

use crate::error::{Error, Result};
use crate::event::CloudEvent;

/// Stable schema identifier (not a Confluent Schema Registry id).
pub const SCHEMA_ID: &str = "ce-stream.cloudevent.v1";

/// HTTP Content-Type for Avro-encoded CloudEvents.
pub const CONTENT_TYPE_AVRO: &str = "application/cloudevents+avro";

/// Embedded copy of `schemas/cloudevent-v1.avsc` (crate + repo root).
pub const SCHEMA_JSON: &str = include_str!("../schemas/cloudevent-v1.avsc");

fn schema() -> &'static Schema {
    static SCHEMA: OnceLock<Schema> = OnceLock::new();
    SCHEMA.get_or_init(|| {
        Schema::parse_str(SCHEMA_JSON).expect("embedded cloudevent-v1.avsc must parse")
    })
}

/// Encode a CloudEvent as a single Avro binary datum.
pub fn encode_cloudevent(event: &CloudEvent) -> Result<Vec<u8>> {
    let extensions_json =
        serde_json::to_string(&event.extensions).map_err(|e| Error::Sink(e.to_string()))?;
    let data_json = serde_json::to_string(&event.data).map_err(|e| Error::Sink(e.to_string()))?;

    let value = Value::Record(vec![
        (
            "specversion".into(),
            Value::String(event.specversion.clone()),
        ),
        ("id".into(), Value::String(event.id.clone())),
        ("type".into(), Value::String(event.ty.clone())),
        ("source".into(), Value::String(event.source.clone())),
        ("subject".into(), Value::String(event.subject.clone())),
        ("time".into(), Value::String(event.time.clone())),
        ("extensions_json".into(), Value::String(extensions_json)),
        ("data_json".into(), Value::String(data_json)),
    ]);

    to_avro_datum(schema(), value).map_err(|e| Error::Sink(format!("avro encode: {e}")))
}

/// Decode a single Avro datum back to a CloudEvent (tests / consumers).
pub fn decode_cloudevent(bytes: &[u8]) -> Result<CloudEvent> {
    let mut cursor = std::io::Cursor::new(bytes);
    let value = from_avro_datum(schema(), &mut cursor, None)
        .map_err(|e| Error::Sink(format!("avro decode: {e}")))?;

    let Value::Record(fields) = value else {
        return Err(Error::Sink("avro decode: expected record".into()));
    };

    let get = |name: &str| -> Result<String> {
        fields
            .iter()
            .find(|(k, _)| k == name)
            .and_then(|(_, v)| match v {
                Value::String(s) => Some(s.clone()),
                _ => None,
            })
            .ok_or_else(|| Error::Sink(format!("avro decode: missing string field {name}")))
    };

    let extensions: serde_json::Map<String, serde_json::Value> =
        serde_json::from_str(&get("extensions_json")?)
            .map_err(|e| Error::Sink(format!("avro decode extensions_json: {e}")))?;
    let data: serde_json::Value = serde_json::from_str(&get("data_json")?)
        .map_err(|e| Error::Sink(format!("avro decode data_json: {e}")))?;

    Ok(CloudEvent {
        specversion: get("specversion")?,
        id: get("id")?,
        ty: get("type")?,
        source: get("source")?,
        subject: get("subject")?,
        time: get("time")?,
        extensions,
        data,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::event::{ChangeOp, TableRef};

    #[test]
    fn roundtrip_avro() {
        let mut ext = serde_json::Map::new();
        ext.insert("gtid".into(), "uuid:1-2-3".into());
        let ev = CloudEvent::row_change(
            "mysql://lab/ce-stream",
            &TableRef::new("db", "t1"),
            ChangeOp::Insert,
            serde_json::json!({"op": "insert", "after": {"id": 1}}),
            ext,
        );
        let bytes = encode_cloudevent(&ev).expect("encode");
        assert!(!bytes.is_empty());
        let back = decode_cloudevent(&bytes).expect("decode");
        assert_eq!(back.id, ev.id);
        assert_eq!(back.ty, ev.ty);
        assert_eq!(back.subject, "db.t1");
        assert_eq!(
            back.extensions.get("gtid").and_then(|v| v.as_str()),
            Some("uuid:1-2-3")
        );
        assert_eq!(back.data["op"], "insert");
    }
}
