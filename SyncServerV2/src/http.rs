use crate::{
    application::{binding_matches, parse_command, strict_json},
    auth::{authenticate, RuntimeMode},
    domain::*,
    postgres::Repository,
};
use axum::{
    body::Bytes,
    extract::{Path, State},
    http::{HeaderMap, StatusCode},
    response::{IntoResponse, Response},
    routing::{get, post, put},
    Router,
};
use base64::{engine::general_purpose::URL_SAFE_NO_PAD, Engine};
use sqlx::Row;
use std::sync::Arc;
use uuid::Uuid;

#[derive(Clone)]
pub struct AppState {
    pub repo: Arc<Repository>,
    pub runtime_mode: RuntimeMode,
}
fn error_response(error: SyncError) -> Response {
    let status = match error {
        SyncError::Unauthorized => StatusCode::UNAUTHORIZED,
        SyncError::AccountFenceMismatch => StatusCode::FORBIDDEN,
        SyncError::NotFound => StatusCode::NOT_FOUND,
        SyncError::CommandIdReused | SyncError::StaleHead | SyncError::StaleConflictRevision => {
            StatusCode::CONFLICT
        }
        SyncError::InvalidCanonicalBytes | SyncError::SchemaViolation(_) => {
            StatusCode::UNPROCESSABLE_ENTITY
        }
        _ => StatusCode::BAD_REQUEST,
    };
    (
        status,
        axum::Json(serde_json::json!({"error":error.to_string()})),
    )
        .into_response()
}
fn canonical_response(status: StatusCode, value: serde_json::Value) -> Response {
    let bytes = crate::domain::canonical_json(&value)
        .unwrap_or_else(|_| b"{\"error\":\"retryable\"}".to_vec());
    Response::builder()
        .status(status)
        .header("content-type", "application/vnd.fuminiwa.sync.v2+jcs")
        .body(axum::body::Body::from(bytes))
        .unwrap()
}
#[allow(clippy::result_large_err)]
fn principal(headers: &HeaderMap, state: &AppState) -> Result<AuthenticatedPrincipal, Response> {
    let principal = authenticate(
        headers,
        state.runtime_mode,
        &state.repo.server_instance_id,
        "fixture-fence",
    )
    .map_err(error_response)?;
    if headers
        .get("x-fuminiwa-server-instance")
        .and_then(|v| v.to_str().ok())
        .is_some_and(|v| v != principal.server_instance_id)
    {
        return Err(error_response(SyncError::AccountFenceMismatch));
    }
    if headers
        .get("x-fuminiwa-account-fence")
        .and_then(|v| v.to_str().ok())
        .is_some_and(|v| v != principal.account_fence)
    {
        return Err(error_response(SyncError::AccountFenceMismatch));
    }
    if headers
        .get("x-fuminiwa-protocol-epoch")
        .and_then(|v| v.to_str().ok())
        .is_some_and(|v| v != principal.protocol_epoch.to_string())
    {
        return Err(error_response(SyncError::ProtocolEpochMismatch));
    }
    Ok(principal)
}
async fn command(headers: HeaderMap, state: State<AppState>, body: Bytes) -> Response {
    let p = match principal(&headers, &state) {
        Ok(v) => v,
        Err(e) => return e,
    };
    let cmd = match parse_command(&body) {
        Ok(v) => v,
        Err(e) => return error_response(e),
    };
    if !binding_matches(&cmd.value, &p) {
        return error_response(SyncError::AccountFenceMismatch);
    };
    match state.repo.command(&p, &cmd).await {
        Ok((status, bytes)) => Response::builder()
            .status(
                StatusCode::from_u16(status as u16).unwrap_or(StatusCode::INTERNAL_SERVER_ERROR),
            )
            .header("content-type", "application/vnd.fuminiwa.sync.v2+jcs")
            .body(axum::body::Body::from(bytes))
            .unwrap(),
        Err(e) => error_response(e),
    }
}
pub fn router(state: AppState) -> Router {
    Router::new()
        .route("/v2/capabilities", get(capabilities))
        .route("/v2/works", get(list_works).post(command))
        .route("/v2/works/:work_id/head", get(head))
        .route("/v2/works/:work_id/history", get(history))
        .route("/v2/snapshots/:snapshot_id/manifest", get(manifest))
        .route("/v2/objects/:object_id", get(object))
        .route("/v2/objects/missing", post(missing_objects))
        .route("/v2/objects/prepare", post(command))
        .route("/v2/objects/finalize", post(command))
        .route("/v2/uploads/:upload_id", put(upload))
        .route("/v2/snapshots/register", post(command))
        .route("/v2/works/:work_id/publish", post(command))
        .route("/v2/works/:work_id/conflict", get(conflict))
        .route("/v2/works/:work_id/conflict/resolve", post(command))
        .route("/v2/works/:work_id/restore", post(command))
        .route("/v2/receipts/:command_id", get(receipt))
        .with_state(state)
}
async fn capabilities(headers: HeaderMap, state: State<AppState>) -> Response {
    let p = match principal(&headers, &state) {
        Ok(v) => v,
        Err(e) => return e,
    };
    canonical_response(
        StatusCode::OK,
        serde_json::json!({"accountId":p.account_id,"accountFence":p.account_fence,"serverInstanceId":p.server_instance_id,"protocolEpoch":PROTOCOL_EPOCH,"result":"noChanges","limits":{"maxObjectBytes":MAX_OBJECT_BYTES,"maxManifestBytes":MAX_MANIFEST_BYTES}}),
    )
}
async fn list_works(headers: HeaderMap, state: State<AppState>) -> Response {
    let p = match principal(&headers, &state) {
        Ok(v) => v,
        Err(e) => return e,
    };
    let rows=sqlx::query("SELECT work_id,document_id,head_generation,head_snapshot_id FROM sync_v2.works WHERE account_id=$1 ORDER BY work_id LIMIT 500").bind(&p.account_id).fetch_all(&state.repo.pool).await;
    match rows {
        Ok(rows) => {
            let items:Vec<_>=rows.into_iter().map(|r|serde_json::json!({"workId":r.try_get::<Uuid,_>("work_id").ok(),"documentId":r.try_get::<Uuid,_>("document_id").ok(),"head":r.try_get::<Option<i64>,_>("head_generation").ok().flatten().map(|g|serde_json::json!({"generation":g,"snapshotId":hex::encode(r.try_get::<Vec<u8>,_>("head_snapshot_id").unwrap_or_default())}))})).collect();
            canonical_response(
                StatusCode::OK,
                serde_json::json!({"items":items,"nextCursor":null,"result":"noChanges"}),
            )
        }
        Err(e) => error_response(SyncError::Database(e)),
    }
}
async fn head(Path(work): Path<Uuid>, headers: HeaderMap, state: State<AppState>) -> Response {
    let p = match principal(&headers, &state) {
        Ok(v) => v,
        Err(e) => return e,
    };
    let row=sqlx::query("SELECT head_generation,head_snapshot_id FROM sync_v2.works WHERE account_id=$1 AND work_id=$2").bind(&p.account_id).bind(work).fetch_optional(&state.repo.pool).await;
    match row {
        Ok(Some(r)) => {
            let value=r.try_get::<Option<i64>,_>("head_generation").ok().flatten().map(|g|serde_json::json!({"generation":g,"snapshotId":hex::encode(r.try_get::<Vec<u8>,_>("head_snapshot_id").unwrap_or_default())}));
            canonical_response(
                StatusCode::OK,
                serde_json::json!({"head":value,"result":"noChanges"}),
            )
        }
        Ok(None) => error_response(SyncError::NotFound),
        Err(e) => error_response(SyncError::Database(e)),
    }
}
async fn history(Path(work): Path<Uuid>, headers: HeaderMap, state: State<AppState>) -> Response {
    let p = match principal(&headers, &state) {
        Ok(v) => v,
        Err(e) => return e,
    };
    let rows=sqlx::query("SELECT occurrence_id,snapshot_id,reason,pinned,created_at FROM sync_v2.history WHERE account_id=$1 AND work_id=$2 ORDER BY event_id LIMIT 500").bind(&p.account_id).bind(work).fetch_all(&state.repo.pool).await;
    match rows {
        Ok(rows) => canonical_response(
            StatusCode::OK,
            serde_json::json!({"items":rows.into_iter().map(|r|serde_json::json!({"occurrenceId":r.try_get::<Uuid,_>("occurrence_id").ok(),"snapshotId":hex::encode(r.try_get::<Vec<u8>,_>("snapshot_id").unwrap_or_default()),"reason":r.try_get::<String,_>("reason").ok(),"pinned":r.try_get::<bool,_>("pinned").ok()})).collect::<Vec<_>>(),"nextCursor":null,"result":"noChanges"}),
        ),
        Err(e) => error_response(SyncError::Database(e)),
    }
}
async fn manifest(
    Path(snapshot): Path<String>,
    headers: HeaderMap,
    state: State<AppState>,
) -> Response {
    let p = match principal(&headers, &state) {
        Ok(v) => v,
        Err(e) => return e,
    };
    let id = match decode_digest(&snapshot) {
        Ok(v) => v,
        Err(_) => return error_response(SyncError::NotFound),
    };
    let row=sqlx::query("SELECT manifest_bytes,manifest_digest FROM sync_v2.snapshots WHERE account_id=$1 AND snapshot_id=$2").bind(&p.account_id).bind(id.as_slice()).fetch_optional(&state.repo.pool).await;
    match row {
        Ok(Some(r)) => {
            let bytes: Vec<u8> = r.try_get("manifest_bytes").unwrap_or_default();
            canonical_response(
                StatusCode::OK,
                serde_json::json!({"manifestBase64URL":URL_SAFE_NO_PAD.encode(bytes),"manifestBytesDigest":hex::encode(r.try_get::<Vec<u8>,_>("manifest_digest").unwrap_or_default()),"result":"noChanges"}),
            )
        }
        Ok(None) => error_response(SyncError::NotFound),
        Err(e) => error_response(SyncError::Database(e)),
    }
}
async fn object(
    Path(object): Path<String>,
    headers: HeaderMap,
    state: State<AppState>,
) -> Response {
    let p = match principal(&headers, &state) {
        Ok(v) => v,
        Err(e) => return e,
    };
    let id = match decode_digest(&object) {
        Ok(v) => v,
        Err(_) => return error_response(SyncError::NotFound),
    };
    let row=sqlx::query("SELECT b.raw_bytes FROM sync_v2.global_blobs b JOIN sync_v2.account_objects a ON a.object_id=b.object_id WHERE a.account_id=$1 AND a.object_id=$2 AND a.state='available'").bind(&p.account_id).bind(id.as_slice()).fetch_optional(&state.repo.pool).await;
    match row {
        Ok(Some(r)) => {
            let bytes: Vec<u8> = r.try_get("raw_bytes").unwrap_or_default();
            Response::builder()
                .status(200)
                .header("content-type", "application/octet-stream")
                .header("x-fuminiwa-object-digest", hex::encode(id))
                .body(axum::body::Body::from(bytes))
                .unwrap()
        }
        Ok(None) => error_response(SyncError::NotFound),
        Err(e) => error_response(SyncError::Database(e)),
    }
}
async fn missing_objects(headers: HeaderMap, state: State<AppState>, body: Bytes) -> Response {
    let p = match principal(&headers, &state) {
        Ok(v) => v,
        Err(e) => return e,
    };
    let value = match strict_json(&body) {
        Ok(v) => v,
        Err(e) => return error_response(e),
    };
    if value
        .get("schemaVersion")
        .and_then(serde_json::Value::as_i64)
        != Some(PROTOCOL_EPOCH)
        || value
            .get("workId")
            .and_then(serde_json::Value::as_str)
            .and_then(|v| Uuid::parse_str(v).ok())
            .is_none()
    {
        return error_response(SyncError::SchemaViolation("missing objects request".into()));
    }
    let Some(ids) = value.get("objectIds").and_then(serde_json::Value::as_array) else {
        return error_response(SyncError::SchemaViolation("objectIds".into()));
    };
    let mut missing = Vec::new();
    for id in ids {
        let Some(text) = id.as_str() else {
            return error_response(SyncError::SchemaViolation("objectIds".into()));
        };
        let digest = match decode_digest(text) {
            Ok(v) => v,
            Err(e) => return error_response(e),
        };
        let found = match sqlx::query("SELECT 1 FROM sync_v2.account_objects WHERE account_id=$1 AND object_id=$2 AND state='available'")
            .bind(&p.account_id)
            .bind(digest.as_slice())
            .fetch_optional(&state.repo.pool)
            .await
        {
            Ok(v) => v.is_some(),
            Err(e) => return error_response(SyncError::Database(e)),
        };
        if !found {
            missing.push(serde_json::Value::String(text.to_owned()));
        }
    }
    let response = serde_json::json!({
        "missingObjectIds": missing,
        "result": if missing.is_empty() { "noChanges" } else { "applied" }
    });
    let bytes = match crate::domain::canonical_json(&response) {
        Ok(v) => v,
        Err(_) => return error_response(SyncError::Retryable),
    };
    Response::builder()
        .status(StatusCode::OK)
        .header("content-type", "application/vnd.fuminiwa.sync.v2+jcs")
        .body(axum::body::Body::from(bytes))
        .unwrap()
}
async fn upload(
    Path(upload): Path<Uuid>,
    headers: HeaderMap,
    state: State<AppState>,
    body: Bytes,
) -> Response {
    let p = match principal(&headers, &state) {
        Ok(v) => v,
        Err(e) => return e,
    };
    let Some(capability) = headers
        .get("x-fuminiwa-upload-capability")
        .and_then(|v| v.to_str().ok())
    else {
        return error_response(SyncError::UploadCapabilityMismatch);
    };
    match state.repo.upload(&p, upload, capability, &body).await {
        Ok(()) => StatusCode::NO_CONTENT.into_response(),
        Err(e) => error_response(e),
    }
}
async fn conflict(Path(work): Path<Uuid>, headers: HeaderMap, state: State<AppState>) -> Response {
    let p = match principal(&headers, &state) {
        Ok(v) => v,
        Err(e) => return e,
    };
    let row=sqlx::query("SELECT conflict_id,current_revision,state FROM sync_v2.active_conflicts WHERE account_id=$1 AND work_id=$2 AND state='active'").bind(&p.account_id).bind(work).fetch_optional(&state.repo.pool).await;
    match row {
        Ok(Some(r)) => canonical_response(
            StatusCode::OK,
            serde_json::json!({"conflictId":r.try_get::<Uuid,_>("conflict_id").ok(),"conflictRevision":r.try_get::<i64,_>("current_revision").ok(),"state":"active","result":"noChanges"}),
        ),
        Ok(None) => canonical_response(
            StatusCode::OK,
            serde_json::json!({"conflict":null,"result":"noChanges"}),
        ),
        Err(e) => error_response(SyncError::Database(e)),
    }
}
async fn receipt(Path(id): Path<Uuid>, headers: HeaderMap, state: State<AppState>) -> Response {
    let p = match principal(&headers, &state) {
        Ok(v) => v,
        Err(e) => return e,
    };
    match state.repo.receipt(&p, id).await {
        Ok((kind, bytes, status)) => canonical_response(
            StatusCode::OK,
            serde_json::json!({"commandId":id,"commandKind":kind,"responseStatus":status,"canonicalResponseBase64URL":URL_SAFE_NO_PAD.encode(bytes),"result":"noChanges"}),
        ),
        Err(e) => error_response(e),
    }
}
fn decode_digest(value: &str) -> Result<[u8; 32], SyncError> {
    crate::domain::decode_digest(value).map_err(|_| SyncError::NotFound)
}
