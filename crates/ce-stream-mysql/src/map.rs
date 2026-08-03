use mysql_binlog_connector_rust::column::column_value::ColumnValue;
use mysql_binlog_connector_rust::event::row_event::RowEvent;
use serde_json::{Map, Value};

pub fn row_to_object(col_names: &[String], row: &RowEvent) -> Map<String, Value> {
    let mut out = Map::new();
    for (i, val) in row.column_values.iter().enumerate() {
        let key = col_names
            .get(i)
            .cloned()
            .unwrap_or_else(|| format!("col_{i}"));
        out.insert(key, column_value_to_json(val));
    }
    out
}

pub fn column_value_to_json(v: &ColumnValue) -> Value {
    match v {
        ColumnValue::None => Value::Null,
        ColumnValue::Tiny(n) => Value::from(*n),
        ColumnValue::Short(n) => Value::from(*n),
        ColumnValue::Long(n) => Value::from(*n),
        ColumnValue::LongLong(n) => Value::from(*n),
        ColumnValue::Float(n) => Value::from(*n),
        ColumnValue::Double(n) => Value::from(*n),
        ColumnValue::Decimal(s)
        | ColumnValue::Time(s)
        | ColumnValue::Date(s)
        | ColumnValue::DateTime(s) => Value::String(s.clone()),
        ColumnValue::Timestamp(us) => Value::from(*us),
        ColumnValue::Year(y) => Value::from(*y),
        ColumnValue::String(bytes) => match String::from_utf8(bytes.clone()) {
            Ok(s) => Value::String(s),
            Err(_) => Value::String(format!("hex:{}", hex_encode(bytes))),
        },
        ColumnValue::Blob(bytes) | ColumnValue::Json(bytes) => {
            match String::from_utf8(bytes.clone()) {
                Ok(s) => Value::String(s),
                Err(_) => Value::String(format!("hex:{}", hex_encode(bytes))),
            }
        }
        ColumnValue::Bit(n) | ColumnValue::Set(n) => Value::from(*n),
        ColumnValue::Enum(n) => Value::from(*n),
    }
}

fn hex_encode(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

/// Minimal GTID set tracker (`uuid:1-10,uuid2:3`).
#[derive(Debug, Default, Clone)]
pub struct GtidTracker {
    /// uuid -> inclusive end of contiguous 1..=end (MVP assumes single interval from 1).
    ends: std::collections::BTreeMap<String, u64>,
}

impl GtidTracker {
    pub fn from_set_string(s: &str) -> Self {
        let mut t = Self::default();
        for part in s.split(',').map(str::trim).filter(|p| !p.is_empty()) {
            if let Some((uuid, rest)) = part.split_once(':') {
                if let Some((start, end)) = rest.split_once('-') {
                    let start: u64 = start.parse().unwrap_or(1);
                    let end: u64 = end.parse().unwrap_or(start);
                    let cur = t.ends.entry(uuid.to_string()).or_insert(0);
                    *cur = (*cur).max(end);
                    let _ = start;
                } else if let Ok(n) = rest.parse::<u64>() {
                    let cur = t.ends.entry(uuid.to_string()).or_insert(0);
                    *cur = (*cur).max(n);
                }
            }
        }
        t
    }

    pub fn add_gtid(&mut self, gtid: &str) {
        // format uuid:gno
        if let Some((uuid, gno)) = gtid.split_once(':') {
            if let Ok(n) = gno.parse::<u64>() {
                let cur = self.ends.entry(uuid.to_string()).or_insert(0);
                *cur = (*cur).max(n);
            }
        }
    }

    pub fn to_set_string(&self) -> String {
        self.ends
            .iter()
            .map(|(uuid, end)| {
                if *end == 0 {
                    format!("{uuid}:0")
                } else {
                    format!("{uuid}:1-{end}")
                }
            })
            .collect::<Vec<_>>()
            .join(",")
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn gtid_tracker_grows() {
        let mut t = GtidTracker::from_set_string("abc:1-10");
        t.add_gtid("abc:11");
        t.add_gtid("abc:12");
        assert_eq!(t.to_set_string(), "abc:1-12");
    }
}
