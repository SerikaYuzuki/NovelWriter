use crate::domain::*;
use serde::de::{Deserializer, Error as _, MapAccess, SeqAccess, Visitor};
use serde_json::Value;
use std::{collections::HashSet, fmt, str};
use uuid::Uuid;

const MAX_SAFE_INTEGER: i128 = 9_007_199_254_740_991;

fn reject_noncanonical_lexemes(bytes: &[u8]) -> Result<(), ()> {
    let mut i = 0;
    while i < bytes.len() {
        match bytes[i] {
            b'"' => {
                i += 1;
                while i < bytes.len() {
                    match bytes[i] {
                        b'"' => {
                            i += 1;
                            break;
                        }
                        b'\\' => {
                            i += 1;
                            if i >= bytes.len() {
                                return Err(());
                            }
                            if bytes[i] == b'u' {
                                if i + 4 >= bytes.len() {
                                    return Err(());
                                }
                                let hex = |b: u8| b.is_ascii_hexdigit();
                                if !(hex(bytes[i + 1])
                                    && hex(bytes[i + 2])
                                    && hex(bytes[i + 3])
                                    && hex(bytes[i + 4]))
                                {
                                    return Err(());
                                }
                                let unit = u16::from_str_radix(
                                    str::from_utf8(&bytes[i + 1..i + 5]).map_err(|_| ())?,
                                    16,
                                )
                                .map_err(|_| ())?;
                                if (0xDC00..=0xDFFF).contains(&unit) {
                                    return Err(());
                                }
                                if (0xD800..=0xDBFF).contains(&unit) {
                                    if i + 10 >= bytes.len()
                                        || bytes[i + 5] != b'\\'
                                        || bytes[i + 6] != b'u'
                                        || !hex(bytes[i + 7])
                                        || !hex(bytes[i + 8])
                                        || !hex(bytes[i + 9])
                                        || !hex(bytes[i + 10])
                                    {
                                        return Err(());
                                    }
                                    let low = u16::from_str_radix(
                                        str::from_utf8(&bytes[i + 7..i + 11]).map_err(|_| ())?,
                                        16,
                                    )
                                    .map_err(|_| ())?;
                                    if !(0xDC00..=0xDFFF).contains(&low) {
                                        return Err(());
                                    }
                                    i += 10;
                                }
                            } else if !matches!(
                                bytes[i],
                                b'"' | b'\\' | b'/' | b'b' | b'f' | b'n' | b'r' | b't'
                            ) {
                                return Err(());
                            }
                        }
                        b if b < 0x20 => return Err(()),
                        _ => {}
                    }
                    i += 1;
                }
            }
            b' ' | b'\n' | b'\r' | b'\t' => return Err(()),
            b'-' | b'0'..=b'9' => {
                let start = i;
                while i < bytes.len() && !matches!(bytes[i], b',' | b']' | b'}') {
                    i += 1;
                }
                let token = str::from_utf8(&bytes[start..i]).map_err(|_| ())?;
                if token == "-0"
                    || token.contains('.')
                    || token.contains('e')
                    || token.contains('E')
                {
                    return Err(());
                }
            }
            _ => i += 1,
        }
    }
    Ok(())
}

struct StrictVisitor;
impl<'de> Visitor<'de> for StrictVisitor {
    type Value = Value;
    fn expecting(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str("a strict RFC 8785 JSON value")
    }
    fn visit_unit<E: serde::de::Error>(self) -> Result<Value, E> {
        Ok(Value::Null)
    }
    fn visit_bool<E: serde::de::Error>(self, value: bool) -> Result<Value, E> {
        Ok(Value::Bool(value))
    }
    fn visit_i64<E: serde::de::Error>(self, value: i64) -> Result<Value, E> {
        if (value as i128).abs() > MAX_SAFE_INTEGER {
            Err(E::custom("unsafe integer"))
        } else {
            Ok(Value::Number(value.into()))
        }
    }
    fn visit_u64<E: serde::de::Error>(self, value: u64) -> Result<Value, E> {
        if value as i128 > MAX_SAFE_INTEGER {
            Err(E::custom("unsafe integer"))
        } else {
            Ok(Value::Number(value.into()))
        }
    }
    fn visit_i128<E: serde::de::Error>(self, value: i128) -> Result<Value, E> {
        if value.abs() > MAX_SAFE_INTEGER {
            Err(E::custom("unsafe integer"))
        } else {
            Ok(Value::Number((value as i64).into()))
        }
    }
    fn visit_u128<E: serde::de::Error>(self, value: u128) -> Result<Value, E> {
        if value > MAX_SAFE_INTEGER as u128 {
            Err(E::custom("unsafe integer"))
        } else {
            Ok(Value::Number((value as u64).into()))
        }
    }
    fn visit_f64<E: serde::de::Error>(self, _value: f64) -> Result<Value, E> {
        Err(E::custom("non-integer number"))
    }
    fn visit_str<E: serde::de::Error>(self, value: &str) -> Result<Value, E> {
        Ok(Value::String(value.to_owned()))
    }
    fn visit_string<E: serde::de::Error>(self, value: String) -> Result<Value, E> {
        Ok(Value::String(value))
    }
    fn visit_seq<A: SeqAccess<'de>>(self, mut seq: A) -> Result<Value, A::Error> {
        let mut values = Vec::new();
        while let Some(value) = seq.next_element_seed(StrictSeed)? {
            values.push(value);
        }
        Ok(Value::Array(values))
    }
    fn visit_map<A: MapAccess<'de>>(self, mut map: A) -> Result<Value, A::Error> {
        let mut values = serde_json::Map::new();
        let mut keys = HashSet::new();
        while let Some(key) = map.next_key::<String>()? {
            if !keys.insert(key.clone()) {
                return Err(A::Error::custom("duplicate object key"));
            }
            values.insert(key, map.next_value_seed(StrictSeed)?);
        }
        Ok(Value::Object(values))
    }
}
struct StrictSeed;
impl<'de> serde::de::DeserializeSeed<'de> for StrictSeed {
    type Value = Value;
    fn deserialize<D: serde::Deserializer<'de>>(self, deserializer: D) -> Result<Value, D::Error> {
        deserializer.deserialize_any(StrictVisitor)
    }
}

pub fn strict_json(body: &[u8]) -> Result<Value, SyncError> {
    if body.starts_with(&[0xEF, 0xBB, 0xBF])
        || str::from_utf8(body).is_err()
        || reject_noncanonical_lexemes(body).is_err()
    {
        return Err(SyncError::InvalidCanonicalBytes);
    }
    let mut deserializer = serde_json::Deserializer::from_slice(body);
    let value = deserializer
        .deserialize_any(StrictVisitor)
        .map_err(|_| SyncError::InvalidCanonicalBytes)?;
    deserializer
        .end()
        .map_err(|_| SyncError::InvalidCanonicalBytes)?;
    Ok(value)
}

fn closed_object(value: &Value, allowed: &[&str], required: &[&str], name: &str) -> SyncResult<()> {
    let Some(object) = value.as_object() else {
        return Err(SyncError::SchemaViolation(name.into()));
    };
    if object.keys().any(|key| !allowed.contains(&key.as_str()))
        || required.iter().any(|key| !object.contains_key(*key))
    {
        return Err(SyncError::SchemaViolation(name.into()));
    }
    Ok(())
}

#[derive(Clone, Debug)]
pub struct ManifestEntry {
    pub entity_key: String,
    pub object_id: [u8; 32],
    pub byte_count: i64,
    pub content_type: String,
}

pub fn validate_entity_payload(key: &str, value: &Value) -> SyncResult<()> {
    let uuid_value = |value: Option<&Value>| {
        let text = value
            .and_then(Value::as_str)
            .ok_or_else(|| SyncError::SchemaViolation(key.into()))?;
        let id = Uuid::parse_str(text).map_err(|_| SyncError::SchemaViolation(key.into()))?;
        if text.len() != 36 || id.to_string() != text {
            return Err(SyncError::SchemaViolation(key.into()));
        }
        Ok::<(), SyncError>(())
    };
    let string_value = || {
        closed_object(value, &["value"], &["value"], key)?;
        if value
            .get("value")
            .and_then(Value::as_str)
            .map_or(true, |text| text.len() > 1_048_576)
        {
            return Err(SyncError::SchemaViolation(key.into()));
        }
        Ok(())
    };
    if key == "work/document" {
        closed_object(
            value,
            &["documentCreatedAt", "documentId"],
            &["documentCreatedAt", "documentId"],
            key,
        )?;
        uuid_value(value.get("documentId"))?;
        let created_at = value
            .get("documentCreatedAt")
            .and_then(Value::as_str)
            .ok_or_else(|| SyncError::SchemaViolation(key.into()))?;
        let timestamp_ok = created_at.len() == 20
            && [4, 7, 10, 13, 16, 19].into_iter().all(|index| {
                matches!(index, 10) && created_at.as_bytes()[index] == b'T'
                    || matches!(index, 19) && created_at.as_bytes()[index] == b'Z'
                    || matches!(index, 4 | 7) && created_at.as_bytes()[index] == b'-'
                    || matches!(index, 13 | 16) && created_at.as_bytes()[index] == b':'
            })
            && created_at.bytes().enumerate().all(|(index, byte)| {
                [4, 7, 10, 13, 16, 19].contains(&index) || byte.is_ascii_digit()
            });
        if !timestamp_ok {
            return Err(SyncError::SchemaViolation(key.into()));
        }
        return Ok(());
    }
    if key.ends_with("/title")
        || key.ends_with("/body")
        || key.ends_with("/memo")
        || key == "work/synopsis"
    {
        return string_value();
    }
    if key.ends_with("-order") {
        closed_object(value, &["ids"], &["ids"], key)?;
        let ids = value
            .get("ids")
            .and_then(Value::as_array)
            .ok_or_else(|| SyncError::SchemaViolation(key.into()))?;
        let mut seen = HashSet::new();
        for id in ids {
            uuid_value(Some(id))?;
            if !seen.insert(id.as_str().unwrap()) {
                return Err(SyncError::SchemaViolation(key.into()));
            }
        }
        return Ok(());
    }
    if key.starts_with("character/") {
        closed_object(
            value,
            &[
                "age",
                "appearance",
                "background",
                "colorHex",
                "firstPerson",
                "gender",
                "id",
                "kana",
                "memo",
                "name",
                "personality",
                "role",
                "secondPerson",
                "speechStyle",
            ],
            &[
                "age",
                "appearance",
                "background",
                "colorHex",
                "firstPerson",
                "gender",
                "id",
                "kana",
                "memo",
                "name",
                "personality",
                "role",
                "secondPerson",
                "speechStyle",
            ],
            key,
        )?;
        uuid_value(value.get("id"))?;
        if ["name", "kana", "memo"].iter().any(|name| {
            value
                .get(*name)
                .and_then(Value::as_str)
                .map_or(true, |text| text.len() > 1_048_576)
        }) {
            return Err(SyncError::SchemaViolation(key.into()));
        }
        for name in [
            "age",
            "appearance",
            "background",
            "firstPerson",
            "gender",
            "personality",
            "role",
            "secondPerson",
            "speechStyle",
        ] {
            if !value.get(name).is_some_and(|field| {
                field.is_null() || field.as_str().is_some_and(|text| text.len() <= 1_048_576)
            }) {
                return Err(SyncError::SchemaViolation(key.into()));
            }
        }
        let color = value
            .get("colorHex")
            .ok_or_else(|| SyncError::SchemaViolation(key.into()))?;
        if !color.is_null()
            && !color.as_str().is_some_and(|text| {
                text.len() == 7
                    && text.as_bytes()[0] == b'#'
                    && text.as_bytes()[1..].iter().all(u8::is_ascii_hexdigit)
            })
        {
            return Err(SyncError::SchemaViolation(key.into()));
        }
        return Ok(());
    }
    if key.starts_with("plot-card/") {
        closed_object(
            value,
            &["chapterId", "id", "memo", "title"],
            &["chapterId", "id", "memo", "title"],
            key,
        )?;
        uuid_value(value.get("id"))?;
        if value
            .get("title")
            .and_then(Value::as_str)
            .map_or(true, |text| text.len() > 1_048_576)
            || value
                .get("memo")
                .and_then(Value::as_str)
                .map_or(true, |text| text.len() > 1_048_576)
        {
            return Err(SyncError::SchemaViolation(key.into()));
        }
        if let Some(chapter) = value.get("chapterId") {
            if !chapter.is_null() {
                uuid_value(Some(chapter))?;
            }
        }
        return Ok(());
    }
    if key.starts_with("flag/") {
        closed_object(
            value,
            &[
                "id",
                "isResolved",
                "note",
                "plantedChapterId",
                "resolvedChapterId",
                "title",
            ],
            &[
                "id",
                "isResolved",
                "note",
                "plantedChapterId",
                "resolvedChapterId",
                "title",
            ],
            key,
        )?;
        uuid_value(value.get("id"))?;
        if !value.get("isResolved").is_some_and(Value::is_boolean)
            || value
                .get("note")
                .and_then(Value::as_str)
                .map_or(true, |text| text.len() > 1_048_576)
            || value
                .get("title")
                .and_then(Value::as_str)
                .map_or(true, |text| text.len() > 1_048_576)
        {
            return Err(SyncError::SchemaViolation(key.into()));
        }
        for name in ["plantedChapterId", "resolvedChapterId"] {
            if let Some(id) = value.get(name) {
                if !id.is_null() {
                    uuid_value(Some(id))?;
                }
            }
        }
        return Ok(());
    }
    if key.starts_with("world-note/") {
        closed_object(
            value,
            &["content", "id", "title"],
            &["content", "id", "title"],
            key,
        )?;
        uuid_value(value.get("id"))?;
        if value
            .get("content")
            .and_then(Value::as_str)
            .map_or(true, |text| text.len() > 1_048_576)
            || value
                .get("title")
                .and_then(Value::as_str)
                .map_or(true, |text| text.len() > 1_048_576)
        {
            return Err(SyncError::SchemaViolation(key.into()));
        }
        return Ok(());
    }
    if key.starts_with("attachment/") && key.ends_with("/metadata") {
        closed_object(
            value,
            &["attachmentId", "byteCount", "fileName"],
            &["attachmentId", "byteCount", "fileName"],
            key,
        )?;
        uuid_value(value.get("attachmentId"))?;
        if value
            .get("byteCount")
            .and_then(Value::as_i64)
            .map_or(true, |count| {
                !(0..=MAX_OBJECT_BYTES as i64).contains(&count)
            })
            || value
                .get("fileName")
                .and_then(Value::as_str)
                .map_or(true, |name| name.is_empty() || name.len() > 255)
        {
            return Err(SyncError::SchemaViolation(key.into()));
        }
        return Ok(());
    }
    Err(SyncError::SchemaViolation(key.into()))
}

fn entity_kind(key: &str) -> Option<&'static str> {
    let parts: Vec<_> = key.split('/').collect();
    let is_uuid = |value: &str| {
        Uuid::parse_str(value).is_ok()
            && value.len() == 36
            && value.chars().all(|c| c.is_ascii_hexdigit() || c == '-')
            && Uuid::parse_str(value)
                .ok()
                .map(|id| id.to_string() == value)
                .unwrap_or(false)
    };
    match parts.as_slice() {
        ["work", name]
            if matches!(
                *name,
                "document"
                    | "title"
                    | "synopsis"
                    | "chapter-order"
                    | "character-order"
                    | "plot-card-order"
                    | "flag-order"
                    | "world-note-order"
                    | "attachment-order"
            ) =>
        {
            Some("json")
        }
        ["chapter", id, name] if is_uuid(id) && matches!(*name, "title" | "episode-order") => {
            Some("json")
        }
        ["episode", id, name] if is_uuid(id) && matches!(*name, "title" | "body" | "memo") => {
            Some("json")
        }
        [kind, id]
            if is_uuid(id)
                && matches!(*kind, "character" | "plot-card" | "flag" | "world-note") =>
        {
            Some("json")
        }
        ["attachment", id, name] if is_uuid(id) && *name == "metadata" => Some("json"),
        ["attachment", id, name] if is_uuid(id) && *name == "bytes" => Some("bytes"),
        _ => None,
    }
}

/// Validates the exact manifest bytes before any database mutation. This is
/// deliberately independent of PostgreSQL/JSONB: the returned entries are
/// the bytes' closed, canonical projection used for exact object read-back.
pub fn validate_manifest_bytes(bytes: &[u8], work_id: Uuid) -> SyncResult<Vec<ManifestEntry>> {
    if bytes.is_empty() || bytes.len() > MAX_MANIFEST_BYTES {
        return Err(SyncError::SizeLimitExceeded);
    }
    let value = strict_json(bytes)?;
    if canonical_json(&value).map_err(|_| SyncError::InvalidCanonicalBytes)? != bytes {
        return Err(SyncError::InvalidCanonicalBytes);
    }
    closed_object(
        &value,
        &["schemaVersion", "workId", "parentSnapshotIds", "entries"],
        &["schemaVersion", "workId", "parentSnapshotIds", "entries"],
        "manifest",
    )?;
    if value.get("schemaVersion").and_then(Value::as_i64) != Some(2) {
        return Err(SyncError::SchemaViolation("manifest.schemaVersion".into()));
    }
    if canonical_uuid(&value, "workId")? != work_id {
        return Err(SyncError::LineageViolation);
    }
    let parents = value
        .get("parentSnapshotIds")
        .and_then(Value::as_array)
        .ok_or_else(|| SyncError::SchemaViolation("parentSnapshotIds".into()))?;
    if parents.len() > 2 {
        return Err(SyncError::SchemaViolation("parentSnapshotIds".into()));
    }
    let mut previous_parent: Option<[u8; 32]> = None;
    let mut parent_seen = HashSet::new();
    for parent in parents {
        let text = parent
            .as_str()
            .ok_or_else(|| SyncError::SchemaViolation("parentSnapshotIds".into()))?;
        let digest = decode_digest(text).map_err(SyncError::SchemaViolation)?;
        if !parent_seen.insert(digest) || previous_parent.is_some_and(|previous| previous >= digest)
        {
            return Err(SyncError::LineageViolation);
        }
        previous_parent = Some(digest);
    }
    let entries = value
        .get("entries")
        .and_then(Value::as_array)
        .ok_or_else(|| SyncError::SchemaViolation("entries".into()))?;
    if entries.len() < 9 || entries.len() > 100_000 {
        return Err(SyncError::SizeLimitExceeded);
    }
    let mandatory: HashSet<&str> = [
        "work/document",
        "work/title",
        "work/synopsis",
        "work/chapter-order",
        "work/character-order",
        "work/plot-card-order",
        "work/flag-order",
        "work/world-note-order",
        "work/attachment-order",
    ]
    .into_iter()
    .collect();
    let mut found = HashSet::new();
    let mut result = Vec::with_capacity(entries.len());
    let mut previous_key: Option<Vec<u8>> = None;
    for raw in entries {
        closed_object(
            raw,
            &["byteCount", "contentType", "entityKey", "objectId"],
            &["byteCount", "contentType", "entityKey", "objectId"],
            "manifest.entry",
        )?;
        let key = raw
            .get("entityKey")
            .and_then(Value::as_str)
            .ok_or_else(|| SyncError::SchemaViolation("entry.entityKey".into()))?;
        if key.is_empty() || key.len() > 256 || entity_kind(key).is_none() {
            return Err(SyncError::SchemaViolation("entry.entityKey".into()));
        }
        if previous_key
            .as_deref()
            .is_some_and(|previous| previous >= key.as_bytes())
        {
            return Err(SyncError::SchemaViolation("entries.order".into()));
        }
        previous_key = Some(key.as_bytes().to_vec());
        if !found.insert(key) {
            return Err(SyncError::SchemaViolation("entries.unique".into()));
        }
        let object_id = canonical_digest(raw, "objectId")?;
        let byte_count = raw
            .get("byteCount")
            .and_then(Value::as_i64)
            .ok_or_else(|| SyncError::SchemaViolation("entry.byteCount".into()))?;
        if !(0..=MAX_OBJECT_BYTES as i64).contains(&byte_count) {
            return Err(SyncError::SizeLimitExceeded);
        }
        let content_type = raw
            .get("contentType")
            .and_then(Value::as_str)
            .ok_or_else(|| SyncError::SchemaViolation("entry.contentType".into()))?;
        let expected = if entity_kind(key) == Some("bytes") {
            "application/octet-stream"
        } else {
            "application/vnd.fuminiwa.entity+json;version=2"
        };
        if content_type != expected {
            return Err(SyncError::SchemaViolation("entry.contentType".into()));
        }
        result.push(ManifestEntry {
            entity_key: key.to_owned(),
            object_id,
            byte_count,
            content_type: content_type.to_owned(),
        });
    }
    if !mandatory.iter().all(|key| found.contains(key)) {
        return Err(SyncError::SchemaViolation("manifest.mandatory".into()));
    }
    Ok(result)
}
fn canonical_uuid(value: &Value, key: &str) -> SyncResult<Uuid> {
    let text = value
        .get(key)
        .and_then(Value::as_str)
        .ok_or_else(|| SyncError::SchemaViolation(key.into()))?;
    let id = Uuid::parse_str(text).map_err(|_| SyncError::SchemaViolation(key.into()))?;
    if text.len() != 36 || id.to_string() != text {
        return Err(SyncError::SchemaViolation(key.into()));
    }
    Ok(id)
}
fn canonical_digest(value: &Value, key: &str) -> SyncResult<[u8; 32]> {
    let text = value
        .get(key)
        .and_then(Value::as_str)
        .ok_or_else(|| SyncError::SchemaViolation(key.into()))?;
    decode_digest(text).map_err(SyncError::SchemaViolation)
}
fn validate_head(value: &Value, key: &str, nullable: bool) -> SyncResult<()> {
    let Some(head) = value.get(key) else {
        return Err(SyncError::SchemaViolation(key.into()));
    };
    if head.is_null() {
        if nullable {
            return Ok(());
        }
        return Err(SyncError::SchemaViolation(key.into()));
    }
    closed_object(
        head,
        &["generation", "snapshotId"],
        &["generation", "snapshotId"],
        key,
    )?;
    let generation = head
        .get("generation")
        .and_then(Value::as_i64)
        .ok_or_else(|| SyncError::SchemaViolation(format!("{key}.generation")))?;
    if !(1..=MAX_SAFE_INTEGER as i64).contains(&generation) {
        return Err(SyncError::SchemaViolation(format!("{key}.generation")));
    }
    let _ = canonical_digest(head, "snapshotId")?;
    Ok(())
}
fn validate_payload(kind: CommandKind, payload: &Value) -> SyncResult<Uuid> {
    let (allowed, required): (&[&str], &[&str]) = match kind {
        CommandKind::CreateWork => (&["documentId", "workId"], &["documentId", "workId"]),
        CommandKind::PrepareObject => (
            &["byteCount", "objectId", "workId"],
            &["byteCount", "objectId", "workId"],
        ),
        CommandKind::FinalizeObject => (
            &["byteCount", "objectId", "uploadId", "workId"],
            &["byteCount", "objectId", "uploadId", "workId"],
        ),
        CommandKind::RegisterSnapshot => (
            &[
                "manifestBase64URL",
                "manifestBytesDigest",
                "snapshotId",
                "workId",
            ],
            &[
                "manifestBase64URL",
                "manifestBytesDigest",
                "snapshotId",
                "workId",
            ],
        ),
        CommandKind::Publish => (
            &["candidateSnapshotId", "expectedRemoteHead", "workId"],
            &["candidateSnapshotId", "expectedRemoteHead", "workId"],
        ),
        CommandKind::ResolveDevice => (
            &[
                "conflictId",
                "conflictRevision",
                "decisionSnapshotId",
                "expectedRemoteHead",
                "localCandidateSnapshotId",
                "workId",
            ],
            &[
                "conflictId",
                "conflictRevision",
                "decisionSnapshotId",
                "expectedRemoteHead",
                "localCandidateSnapshotId",
                "workId",
            ],
        ),
        CommandKind::ResolveServer => (
            &[
                "conflictId",
                "conflictRevision",
                "expectedCurrentSnapshotId",
                "expectedLocalGeneration",
                "preAdoptionSnapshotId",
                "remoteSnapshotId",
                "workId",
            ],
            &[
                "conflictId",
                "conflictRevision",
                "expectedCurrentSnapshotId",
                "expectedLocalGeneration",
                "preAdoptionSnapshotId",
                "remoteSnapshotId",
                "workId",
            ],
        ),
        CommandKind::CloneWork => (
            &[
                "conflictId",
                "conflictRevision",
                "expectedOriginalHead",
                "localCandidateSnapshotId",
                "newDocumentId",
                "newRootSnapshotId",
                "newWorkId",
                "sourceWorkId",
            ],
            &[
                "conflictId",
                "conflictRevision",
                "expectedOriginalHead",
                "localCandidateSnapshotId",
                "newDocumentId",
                "newRootSnapshotId",
                "newWorkId",
                "sourceWorkId",
            ],
        ),
        CommandKind::Restore => (
            &[
                "expectedCurrentSnapshotId",
                "expectedLocalGeneration",
                "expectedRemoteHead",
                "newSnapshotId",
                "selectedSnapshotId",
                "workId",
            ],
            &[
                "expectedCurrentSnapshotId",
                "expectedLocalGeneration",
                "expectedRemoteHead",
                "newSnapshotId",
                "selectedSnapshotId",
                "workId",
            ],
        ),
    };
    closed_object(payload, allowed, required, "payload")?;
    let work = if kind == CommandKind::CloneWork {
        canonical_uuid(payload, "sourceWorkId")?
    } else {
        canonical_uuid(payload, "workId")?
    };
    for key in [
        "conflictId",
        "uploadId",
        "newDocumentId",
        "newWorkId",
        "sourceWorkId",
    ] {
        if payload.get(key).is_some() {
            let _ = canonical_uuid(payload, key)?;
        }
    }
    for key in [
        "objectId",
        "snapshotId",
        "manifestBytesDigest",
        "candidateSnapshotId",
        "decisionSnapshotId",
        "localCandidateSnapshotId",
        "expectedCurrentSnapshotId",
        "preAdoptionSnapshotId",
        "remoteSnapshotId",
        "newRootSnapshotId",
        "newSnapshotId",
        "selectedSnapshotId",
    ] {
        if payload.get(key).is_some() {
            let _ = canonical_digest(payload, key)?;
        }
    }
    if let Some(value) = payload.get("byteCount") {
        let n = value
            .as_i64()
            .ok_or_else(|| SyncError::SchemaViolation("byteCount".into()))?;
        if !(0..=MAX_OBJECT_BYTES as i64).contains(&n) {
            return Err(SyncError::SizeLimitExceeded);
        }
    }
    match kind {
        CommandKind::Publish => validate_head(payload, "expectedRemoteHead", true)?,
        CommandKind::ResolveDevice => validate_head(payload, "expectedRemoteHead", true)?,
        CommandKind::ResolveServer => {
            let _ = canonical_digest(payload, "expectedCurrentSnapshotId")?;
            let generation = payload
                .get("expectedLocalGeneration")
                .and_then(Value::as_i64)
                .ok_or_else(|| SyncError::SchemaViolation("expectedLocalGeneration".into()))?;
            if generation < 1 {
                return Err(SyncError::SchemaViolation("expectedLocalGeneration".into()));
            }
        }
        CommandKind::CloneWork => validate_head(payload, "expectedOriginalHead", true)?,
        CommandKind::Restore => {
            let generation = payload
                .get("expectedLocalGeneration")
                .and_then(Value::as_i64)
                .ok_or_else(|| SyncError::SchemaViolation("expectedLocalGeneration".into()))?;
            if generation < 1 {
                return Err(SyncError::SchemaViolation("expectedLocalGeneration".into()));
            }
            validate_head(payload, "expectedRemoteHead", true)?;
        }
        _ => {}
    }
    Ok(work)
}

pub fn parse_command(body: &[u8]) -> SyncResult<SealedCommand> {
    if body.len() > 33_554_432 {
        return Err(SyncError::SizeLimitExceeded);
    }
    let value = strict_json(body)?;
    let canonical = canonical_json(&value).map_err(|_| SyncError::InvalidCanonicalBytes)?;
    if canonical != body {
        return Err(SyncError::InvalidCanonicalBytes);
    }
    let command_id = canonical_uuid(&value, "commandId")?;
    let kind = value
        .get("commandKind")
        .and_then(Value::as_str)
        .and_then(CommandKind::parse)
        .ok_or_else(|| SyncError::SchemaViolation("commandKind".into()))?;
    if value.get("schemaVersion").and_then(Value::as_i64) != Some(2) {
        return Err(SyncError::SchemaViolation("schemaVersion".into()));
    }
    let binding = value
        .get("binding")
        .ok_or_else(|| SyncError::SchemaViolation("binding".into()))?;
    let payload = value
        .get("payload")
        .ok_or_else(|| SyncError::SchemaViolation("payload".into()))?;
    closed_object(
        &value,
        &[
            "binding",
            "commandId",
            "commandKind",
            "payload",
            "schemaVersion",
            "sourceGeneration",
            "sourceSnapshotId",
        ],
        &[
            "binding",
            "commandId",
            "commandKind",
            "payload",
            "schemaVersion",
            "sourceGeneration",
            "sourceSnapshotId",
        ],
        "envelope",
    )?;
    closed_object(
        binding,
        &[
            "accountFence",
            "accountId",
            "protocolEpoch",
            "serverInstanceId",
        ],
        &[
            "accountFence",
            "accountId",
            "protocolEpoch",
            "serverInstanceId",
        ],
        "binding",
    )?;
    for (key, max) in [
        ("accountId", 128usize),
        ("accountFence", 256),
        ("serverInstanceId", 128),
    ] {
        if binding
            .get(key)
            .and_then(Value::as_str)
            .map(|s| s.is_empty() || s.len() > max)
            .unwrap_or(true)
        {
            return Err(SyncError::SchemaViolation(key.into()));
        }
    }
    let work_id = validate_payload(kind, payload)?;
    let source_snapshot_id = canonical_digest(&value, "sourceSnapshotId")?;
    let source_generation = value
        .get("sourceGeneration")
        .and_then(Value::as_i64)
        .ok_or_else(|| SyncError::SchemaViolation("sourceGeneration".into()))?;
    if !(1..=9_007_199_254_740_991).contains(&source_generation) {
        return Err(SyncError::SchemaViolation("sourceGeneration".into()));
    }
    if binding.get("protocolEpoch").and_then(Value::as_i64) != Some(PROTOCOL_EPOCH) {
        return Err(SyncError::ProtocolEpochMismatch);
    }
    Ok(SealedCommand {
        command_id,
        kind,
        work_id,
        source_snapshot_id,
        source_generation,
        request_digest: sha256(body),
        canonical_bytes: body.to_vec(),
        value,
    })
}

pub fn binding_matches(value: &Value, p: &AuthenticatedPrincipal) -> bool {
    let Some(b) = value.get("binding") else {
        return false;
    };
    b.get("accountId").and_then(Value::as_str) == Some(&p.account_id)
        && b.get("accountFence").and_then(Value::as_str) == Some(&p.account_fence)
        && b.get("serverInstanceId").and_then(Value::as_str) == Some(&p.server_instance_id)
        && b.get("protocolEpoch").and_then(Value::as_i64) == Some(p.protocol_epoch)
}
