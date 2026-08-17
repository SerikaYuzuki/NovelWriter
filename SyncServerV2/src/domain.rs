use serde::{Deserialize, Serialize};
use serde_json::{Map, Value};
use sha2::{Digest, Sha256};
use std::fmt;
use uuid::Uuid;

pub const PROTOCOL_EPOCH: i64 = 2;
pub const MAX_OBJECT_BYTES: usize = 250 * 1024 * 1024;
pub const MAX_MANIFEST_BYTES: usize = 16 * 1024 * 1024;

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct AuthenticatedPrincipal {
    pub account_id: String,
    pub account_fence: String,
    pub server_instance_id: String,
    pub protocol_epoch: i64,
}

impl AuthenticatedPrincipal {
    pub fn fixture(account_id: impl Into<String>) -> Self {
        Self {
            account_id: account_id.into(),
            account_fence: "fixture-fence".into(),
            server_instance_id: "fixture-server".into(),
            protocol_epoch: PROTOCOL_EPOCH,
        }
    }
}

#[derive(Clone, Copy, Debug, Serialize, Deserialize, Eq, PartialEq)]
#[serde(rename_all = "camelCase")]
pub enum CommandKind {
    CreateWork,
    PrepareObject,
    FinalizeObject,
    RegisterSnapshot,
    Publish,
    ResolveDevice,
    ResolveServer,
    CloneWork,
    Restore,
}
impl CommandKind {
    pub fn as_str(&self) -> &'static str {
        match self {
            Self::CreateWork => "createWork",
            Self::PrepareObject => "prepareObject",
            Self::FinalizeObject => "finalizeObject",
            Self::RegisterSnapshot => "registerSnapshot",
            Self::Publish => "publish",
            Self::ResolveDevice => "resolveDevice",
            Self::ResolveServer => "resolveServer",
            Self::CloneWork => "cloneWork",
            Self::Restore => "restore",
        }
    }
    pub fn parse(value: &str) -> Option<Self> {
        Some(match value {
            "createWork" => Self::CreateWork,
            "prepareObject" => Self::PrepareObject,
            "finalizeObject" => Self::FinalizeObject,
            "registerSnapshot" => Self::RegisterSnapshot,
            "publish" => Self::Publish,
            "resolveDevice" => Self::ResolveDevice,
            "resolveServer" => Self::ResolveServer,
            "cloneWork" => Self::CloneWork,
            "restore" => Self::Restore,
            _ => return None,
        })
    }
}
impl fmt::Display for CommandKind {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(self.as_str())
    }
}

#[derive(Clone, Debug)]
pub struct SealedCommand {
    pub command_id: Uuid,
    pub kind: CommandKind,
    pub work_id: Uuid,
    pub source_snapshot_id: [u8; 32],
    pub source_generation: i64,
    pub canonical_bytes: Vec<u8>,
    pub request_digest: [u8; 32],
    pub value: Value,
}

pub fn canonical_json(value: &Value) -> Result<Vec<u8>, String> {
    fn write(value: &Value, out: &mut String) -> Result<(), String> {
        match value {
            Value::Null => out.push_str("null"),
            Value::Bool(v) => out.push_str(if *v { "true" } else { "false" }),
            Value::Number(n) => {
                if n.is_f64() {
                    return Err("floating point is not a canonical v2 value".into());
                }
                out.push_str(&n.to_string());
            }
            Value::String(v) => out.push_str(&serde_json::to_string(v).map_err(|e| e.to_string())?),
            Value::Array(values) => {
                out.push('[');
                for (i, v) in values.iter().enumerate() {
                    if i != 0 {
                        out.push(',');
                    }
                    write(v, out)?;
                }
                out.push(']');
            }
            Value::Object(values) => {
                out.push('{');
                let mut keys: Vec<_> = values.keys().collect();
                keys.sort_by(|left, right| left.encode_utf16().cmp(right.encode_utf16()));
                for (i, key) in keys.iter().enumerate() {
                    if i != 0 {
                        out.push(',');
                    }
                    out.push_str(&serde_json::to_string(*key).map_err(|e| e.to_string())?);
                    out.push(':');
                    write(&values[*key], out)?;
                }
                out.push('}');
            }
        };
        Ok(())
    }
    let mut out = String::new();
    write(value, &mut out)?;
    Ok(out.into_bytes())
}
pub fn sha256(bytes: &[u8]) -> [u8; 32] {
    Sha256::digest(bytes).into()
}
pub fn upload_capability(account: &str, fence: &str, upload_id: Uuid, command_id: Uuid) -> String {
    hex::encode(sha256(
        format!("fuminiwa-sync-v2\0{account}\0{fence}\0{upload_id}\0{command_id}").as_bytes(),
    ))
}
pub fn digest_hex(bytes: &[u8]) -> String {
    hex::encode(sha256(bytes))
}
pub fn decode_digest(value: &str) -> Result<[u8; 32], String> {
    if value.len() != 64 || value != value.to_ascii_lowercase() {
        return Err("invalid digest".to_string());
    }
    let bytes = hex::decode(value).map_err(|_| "invalid digest".to_string())?;
    bytes
        .try_into()
        .map_err(|_| "invalid digest length".to_string())
}
pub fn uuid(value: &Value, path: &str) -> Result<Uuid, String> {
    value
        .get(path)
        .and_then(Value::as_str)
        .ok_or_else(|| format!("missing {path}"))
        .and_then(|v| Uuid::parse_str(v).map_err(|_| format!("invalid {path}")))
}
pub fn digest_field(value: &Value, path: &str) -> Result<[u8; 32], String> {
    value
        .get(path)
        .and_then(Value::as_str)
        .ok_or_else(|| format!("missing {path}"))
        .and_then(decode_digest)
}
pub fn object(map: impl IntoIterator<Item = (String, Value)>) -> Value {
    Value::Object(map.into_iter().collect::<Map<_, _>>())
}

#[derive(Debug, thiserror::Error)]
pub enum SyncError {
    #[error("invalidCanonicalBytes")]
    InvalidCanonicalBytes,
    #[error("schemaViolation: {0}")]
    SchemaViolation(String),
    #[error("unauthorized")]
    Unauthorized,
    #[error("accountFenceMismatch")]
    AccountFenceMismatch,
    #[error("protocolEpochMismatch")]
    ProtocolEpochMismatch,
    #[error("commandIdReused")]
    CommandIdReused,
    #[error("notFoundInAccount")]
    NotFound,
    #[error("staleHead")]
    StaleHead,
    #[error("staleConflictRevision")]
    StaleConflictRevision,
    #[error("objectDigestMismatch")]
    ObjectDigestMismatch,
    #[error("snapshotDigestMismatch")]
    SnapshotDigestMismatch,
    #[error("lineageViolation")]
    LineageViolation,
    #[error("uploadCapabilityMismatch")]
    UploadCapabilityMismatch,
    #[error("uploadExpired")]
    UploadExpired,
    #[error("sizeLimitExceeded")]
    SizeLimitExceeded,
    #[error("retryable")]
    Retryable,
    #[error("database: {0}")]
    Database(#[from] sqlx::Error),
}
pub type SyncResult<T> = Result<T, SyncError>;

/// Checks the immutable `(account_id, command_id)` receipt contract before a
/// transaction touches any resource. Replay returns stored response bytes
/// without parsing or re-serializing them.
pub fn replay_receipt(
    existing_kind: &str,
    existing_digest: &[u8],
    requested_kind: &str,
    requested_digest: &[u8],
    completed: bool,
    status: Option<i32>,
    response: Option<&[u8]>,
) -> SyncResult<Option<(i32, Vec<u8>)>> {
    if existing_kind != requested_kind || existing_digest != requested_digest {
        return Err(SyncError::CommandIdReused);
    }
    if !completed {
        return Ok(None);
    }
    Ok(Some((
        status.ok_or(SyncError::Retryable)?,
        response.ok_or(SyncError::Retryable)?.to_vec(),
    )))
}
