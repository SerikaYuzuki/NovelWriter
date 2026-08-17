use crate::{
    application::{binding_matches, parse_command, strict_json},
    auth::{authenticate, RuntimeMode},
    domain::*,
    postgres::Repository,
};
use axum::{
    body::Bytes,
    extract::{rejection::BytesRejection, DefaultBodyLimit, Path, Query, State},
    http::{HeaderMap, StatusCode},
    response::Response,
    routing::{get, post, put},
    Router,
};
use base64::{engine::general_purpose::URL_SAFE_NO_PAD, Engine};
use sqlx::Row;
use std::{collections::HashMap, sync::Arc};
use uuid::Uuid;

#[derive(Clone)]
pub struct AppState {
    pub repo: Arc<Repository>,
    pub runtime_mode: RuntimeMode,
}
fn error_response(error: SyncError) -> Response {
    let status = match error {
        SyncError::Unauthorized => StatusCode::UNAUTHORIZED,
        SyncError::AccountFenceMismatch | SyncError::UploadCapabilityMismatch => {
            StatusCode::FORBIDDEN
        }
        SyncError::ProtocolEpochMismatch => StatusCode::UPGRADE_REQUIRED,
        SyncError::NotFound => StatusCode::NOT_FOUND,
        SyncError::CommandIdReused
        | SyncError::StaleHead
        | SyncError::StaleConflictRevision
        | SyncError::UploadExpired => StatusCode::CONFLICT,
        SyncError::InvalidCanonicalBytes
        | SyncError::SchemaViolation(_)
        | SyncError::ObjectDigestMismatch
        | SyncError::SnapshotDigestMismatch
        | SyncError::LineageViolation
        | SyncError::SizeLimitExceeded => StatusCode::UNPROCESSABLE_ENTITY,
        SyncError::Retryable | SyncError::Database(_) => StatusCode::SERVICE_UNAVAILABLE,
    };
    let code = match &error {
        SyncError::InvalidCanonicalBytes => "invalidCanonicalBytes",
        SyncError::SchemaViolation(_) => "schemaViolation",
        SyncError::Unauthorized => "unauthorized",
        SyncError::AccountFenceMismatch => "accountFenceMismatch",
        SyncError::ProtocolEpochMismatch => "protocolEpochMismatch",
        SyncError::CommandIdReused => "commandIdReused",
        SyncError::NotFound => "notFoundInAccount",
        SyncError::StaleHead => "staleHead",
        SyncError::StaleConflictRevision => "staleConflictRevision",
        SyncError::ObjectDigestMismatch => "objectDigestMismatch",
        SyncError::SnapshotDigestMismatch => "snapshotDigestMismatch",
        SyncError::LineageViolation => "lineageViolation",
        SyncError::UploadCapabilityMismatch => "uploadCapabilityMismatch",
        SyncError::UploadExpired => "uploadExpired",
        SyncError::SizeLimitExceeded => "sizeLimitExceeded",
        SyncError::Retryable | SyncError::Database(_) => "retryable",
    };
    let retryable = matches!(error, SyncError::Retryable | SyncError::Database(_));
    let value = serde_json::json!({"error": code,"result":if retryable {"retryable"} else {"parked"},"retryable":retryable});
    let bytes = crate::domain::canonical_json(&value).unwrap_or_else(|_| {
        br#"{"error":"retryable","result":"retryable","retryable":true}"#.to_vec()
    });
    Response::builder()
        .status(status)
        .header("content-type", "application/vnd.fuminiwa.sync.v2+jcs")
        .body(axum::body::Body::from(bytes))
        .unwrap()
}
fn canonical_response(status: StatusCode, value: serde_json::Value) -> Response {
    let bytes = crate::domain::canonical_json(&value).unwrap_or_else(|_| {
        br#"{"error":"retryable","result":"retryable","retryable":true}"#.to_vec()
    });
    Response::builder()
        .status(status)
        .header("content-type", "application/vnd.fuminiwa.sync.v2+jcs")
        .body(axum::body::Body::from(bytes))
        .unwrap()
}
const MAX_PAGE_SIZE: i64 = 500;
const DEFAULT_PAGE_SIZE: i64 = 100;

fn cursor_digest(endpoint: &str) -> String {
    hex::encode(sha256(endpoint.as_bytes()))
}

fn encode_cursor(value: serde_json::Value) -> Result<String, SyncError> {
    let bytes = canonical_json(&value).map_err(|_| SyncError::Retryable)?;
    Ok(URL_SAFE_NO_PAD.encode(bytes))
}

fn decode_cursor(encoded: &str) -> SyncResult<serde_json::Value> {
    if encoded.len() > 2048 {
        return Err(SyncError::SizeLimitExceeded);
    }
    let bytes = URL_SAFE_NO_PAD
        .decode(encoded)
        .map_err(|_| SyncError::SchemaViolation("cursor".into()))?;
    let value = strict_json(&bytes)?;
    if canonical_json(&value).map_err(|_| SyncError::InvalidCanonicalBytes)? != bytes {
        return Err(SyncError::InvalidCanonicalBytes);
    }
    Ok(value)
}

fn page_size(params: &HashMap<String, String>) -> SyncResult<i64> {
    let value = match params.get("pageSize") {
        Some(value) => value
            .parse::<i64>()
            .map_err(|_| SyncError::SchemaViolation("pageSize".into()))?,
        None => DEFAULT_PAGE_SIZE,
    };
    if !(1..=MAX_PAGE_SIZE).contains(&value) {
        return Err(SyncError::SchemaViolation("pageSize".into()));
    }
    Ok(value)
}

fn cursor_scope(
    value: &serde_json::Value,
    endpoint: &str,
    p: &AuthenticatedPrincipal,
    page: i64,
    work: Option<Uuid>,
) -> SyncResult<(i64, String)> {
    if value.get("endpoint").and_then(serde_json::Value::as_str) != Some(endpoint)
        || value.get("accountId").and_then(serde_json::Value::as_str) != Some(p.account_id.as_str())
        || value
            .get("accountFence")
            .and_then(serde_json::Value::as_str)
            != Some(p.account_fence.as_str())
        || value
            .get("protocolEpoch")
            .and_then(serde_json::Value::as_i64)
            != Some(PROTOCOL_EPOCH)
        || value.get("queryDigest").and_then(serde_json::Value::as_str)
            != Some(cursor_digest(endpoint).as_str())
        || value.get("pageSize").and_then(serde_json::Value::as_i64) != Some(page)
    {
        return Err(SyncError::AccountFenceMismatch);
    }
    if let Some(work_id) = work {
        if value.get("workId").and_then(serde_json::Value::as_str)
            != Some(work_id.to_string().as_str())
        {
            return Err(SyncError::AccountFenceMismatch);
        }
    }
    let high = value
        .get("highWater")
        .and_then(serde_json::Value::as_i64)
        .ok_or_else(|| SyncError::SchemaViolation("cursor.highWater".into()))?;
    if high < 1 {
        return Err(SyncError::SchemaViolation("cursor.highWater".into()));
    }
    let last = value
        .get("last")
        .and_then(serde_json::Value::as_str)
        .filter(|last| !last.is_empty())
        .ok_or_else(|| SyncError::SchemaViolation("cursor.last".into()))?
        .to_owned();
    Ok((high, last))
}

#[allow(clippy::result_large_err)]
fn authenticated(
    headers: &HeaderMap,
    state: &AppState,
) -> Result<AuthenticatedPrincipal, Response> {
    authenticate(
        headers,
        state.runtime_mode,
        &state.repo.server_instance_id,
        "fixture-fence",
    )
    .map_err(error_response)
}

#[allow(clippy::result_large_err)]
fn required_header<'a>(
    headers: &'a HeaderMap,
    name: &str,
    max_length: usize,
    error: SyncError,
) -> Result<&'a str, Response> {
    headers
        .get(name)
        .and_then(|value| value.to_str().ok())
        .filter(|value| !value.is_empty() && value.len() <= max_length)
        .ok_or_else(|| error_response(error))
}

#[allow(clippy::result_large_err)]
fn principal(headers: &HeaderMap, state: &AppState) -> Result<AuthenticatedPrincipal, Response> {
    let principal = authenticated(headers, state)?;
    let server_instance = required_header(
        headers,
        "x-fuminiwa-server-instance",
        128,
        SyncError::AccountFenceMismatch,
    )?;
    if server_instance != principal.server_instance_id {
        return Err(error_response(SyncError::AccountFenceMismatch));
    }
    let account_fence = required_header(
        headers,
        "x-fuminiwa-account-fence",
        256,
        SyncError::AccountFenceMismatch,
    )?;
    if account_fence != principal.account_fence {
        return Err(error_response(SyncError::AccountFenceMismatch));
    }
    let protocol_epoch = required_header(
        headers,
        "x-fuminiwa-protocol-epoch",
        8,
        SyncError::ProtocolEpochMismatch,
    )?;
    if protocol_epoch.parse::<i64>().ok() != Some(principal.protocol_epoch) {
        return Err(error_response(SyncError::ProtocolEpochMismatch));
    }
    Ok(principal)
}

#[allow(clippy::result_large_err)]
fn capabilities_principal(
    headers: &HeaderMap,
    state: &AppState,
) -> Result<AuthenticatedPrincipal, Response> {
    required_header(
        headers,
        "x-fuminiwa-client-version",
        64,
        SyncError::SchemaViolation("x-fuminiwa-client-version".into()),
    )?;
    authenticated(headers, state)
}

#[allow(clippy::result_large_err)]
fn body_or_error(body: Result<Bytes, BytesRejection>) -> Result<Bytes, Response> {
    body.map_err(|_| error_response(SyncError::SizeLimitExceeded))
}

const MAX_COMMAND_BODY_BYTES: usize = 32 * 1024 * 1024;
const MAX_MISSING_BODY_BYTES: usize = 8 * 1024 * 1024;

async fn command(
    headers: HeaderMap,
    state: State<AppState>,
    body: Result<Bytes, BytesRejection>,
) -> Response {
    let body = match body_or_error(body) {
        Ok(body) => body,
        Err(response) => return response,
    };
    command_inner(headers, state, body, None).await
}
async fn command_inner(
    headers: HeaderMap,
    state: State<AppState>,
    body: Bytes,
    route_work_id: Option<Uuid>,
) -> Response {
    if body.len() > MAX_COMMAND_BODY_BYTES {
        return error_response(SyncError::SizeLimitExceeded);
    }
    let p = match principal(&headers, &state) {
        Ok(v) => v,
        Err(e) => return e,
    };
    let cmd = match parse_command(&body) {
        Ok(v) => v,
        Err(e) => return error_response(e),
    };
    if route_work_id.is_some_and(|route| route != cmd.work_id) {
        return error_response(SyncError::NotFound);
    }
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
async fn routed_command(
    Path(work_id): Path<String>,
    headers: HeaderMap,
    state: State<AppState>,
    body: Result<Bytes, BytesRejection>,
) -> Response {
    let work_id = match parse_uuid_path(&work_id) {
        Ok(value) => value,
        Err(error) => return error_response(error),
    };
    let body = match body_or_error(body) {
        Ok(body) => body,
        Err(response) => return response,
    };
    command_inner(headers, state, body, Some(work_id)).await
}
pub fn router(state: AppState) -> Router {
    Router::new()
        .route("/v2/capabilities", get(capabilities))
        .route(
            "/v2/works",
            get(list_works)
                .post(command)
                .layer(DefaultBodyLimit::max(MAX_COMMAND_BODY_BYTES)),
        )
        .route("/v2/works/:work_id/head", get(head))
        .route("/v2/works/:work_id/history", get(history))
        .route("/v2/snapshots/:snapshot_id/manifest", get(manifest))
        .route("/v2/objects/:object_id", get(object))
        .route(
            "/v2/objects/missing",
            post(missing_objects).layer(DefaultBodyLimit::max(MAX_MISSING_BODY_BYTES)),
        )
        .route(
            "/v2/objects/prepare",
            post(command).layer(DefaultBodyLimit::max(MAX_COMMAND_BODY_BYTES)),
        )
        .route(
            "/v2/objects/finalize",
            post(command).layer(DefaultBodyLimit::max(MAX_COMMAND_BODY_BYTES)),
        )
        .route(
            "/v2/uploads/:upload_id",
            put(upload).layer(DefaultBodyLimit::max(MAX_OBJECT_BYTES)),
        )
        .route(
            "/v2/snapshots/register",
            post(command).layer(DefaultBodyLimit::max(MAX_COMMAND_BODY_BYTES)),
        )
        .route(
            "/v2/works/:work_id/publish",
            post(routed_command).layer(DefaultBodyLimit::max(MAX_COMMAND_BODY_BYTES)),
        )
        .route("/v2/works/:work_id/conflict", get(conflict))
        .route(
            "/v2/works/:work_id/conflict/resolve",
            post(routed_command).layer(DefaultBodyLimit::max(MAX_COMMAND_BODY_BYTES)),
        )
        .route(
            "/v2/works/:work_id/restore",
            post(routed_command).layer(DefaultBodyLimit::max(MAX_COMMAND_BODY_BYTES)),
        )
        .route("/v2/receipts/:command_id", get(receipt))
        .with_state(state)
}
async fn capabilities(headers: HeaderMap, state: State<AppState>) -> Response {
    let p = match capabilities_principal(&headers, &state) {
        Ok(v) => v,
        Err(e) => return e,
    };
    canonical_response(
        StatusCode::OK,
        serde_json::json!({"accountId":p.account_id,"accountFence":p.account_fence,"serverInstanceId":p.server_instance_id,"protocolEpoch":PROTOCOL_EPOCH,"result":"noChanges","limits":{"maxObjectBytes":MAX_OBJECT_BYTES,"maxManifestBytes":MAX_MANIFEST_BYTES,"maxEntries":100000}}),
    )
}
async fn list_works(
    headers: HeaderMap,
    Query(params): Query<HashMap<String, String>>,
    state: State<AppState>,
) -> Response {
    let p = match principal(&headers, &state) {
        Ok(v) => v,
        Err(e) => return e,
    };
    let requested_page = match page_size(&params) {
        Ok(value) => value,
        Err(error) => return error_response(error),
    };
    let cursor_page = if let Some(encoded) = params.get("cursor") {
        let cursor = match decode_cursor(encoded) {
            Ok(value) => value,
            Err(error) => return error_response(error),
        };
        let page = match cursor.get("pageSize").and_then(serde_json::Value::as_i64) {
            Some(value) if (1..=MAX_PAGE_SIZE).contains(&value) => value,
            None => return error_response(SyncError::SchemaViolation("cursor.pageSize".into())),
            _ => return error_response(SyncError::SchemaViolation("cursor.pageSize".into())),
        };
        if params.contains_key("pageSize") && page != requested_page {
            return error_response(SyncError::SchemaViolation("cursor.pageSize".into()));
        }
        match cursor_scope(&cursor, "works", &p, page, None) {
            Ok((high, last)) => match Uuid::parse_str(&last) {
                Ok(last_work) if last_work.to_string() == last => Some((high, last, page)),
                _ => return error_response(SyncError::SchemaViolation("cursor.last".into())),
            },
            Err(error) => return error_response(error),
        }
    } else {
        None
    };
    let mut tx = match state.repo.pool.begin().await {
        Ok(value) => value,
        Err(error) => return error_response(SyncError::Database(error)),
    };
    if let Err(error) = sqlx::query("SET TRANSACTION ISOLATION LEVEL REPEATABLE READ, READ ONLY")
        .execute(&mut *tx)
        .await
    {
        return error_response(SyncError::Database(error));
    }
    let (high_water, last, page) = if let Some((high_water, last, page)) = cursor_page {
        let current_high = match sqlx::query_scalar::<_, Option<i64>>(
            "SELECT MAX(event_id) FROM sync_v2.catalog_events WHERE account_id=$1",
        )
        .bind(&p.account_id)
        .fetch_one(&mut *tx)
        .await
        {
            Ok(value) => value.unwrap_or(0),
            Err(error) => return error_response(SyncError::Database(error)),
        };
        if high_water > current_high {
            return error_response(SyncError::SchemaViolation("cursor.highWater".into()));
        }
        (high_water, last, page)
    } else {
        let high_water = match sqlx::query_scalar::<_, Option<i64>>(
            "SELECT MAX(event_id) FROM sync_v2.catalog_events WHERE account_id=$1",
        )
        .bind(&p.account_id)
        .fetch_one(&mut *tx)
        .await
        {
            Ok(value) => value.unwrap_or(0),
            Err(error) => return error_response(SyncError::Database(error)),
        };
        (high_water, String::new(), requested_page)
    };
    let mut rows = match sqlx::query(
        "WITH latest AS (
             SELECT DISTINCT ON (work_id)
                    work_id,head_generation,head_snapshot_id,title,tombstoned
             FROM sync_v2.catalog_events
             WHERE account_id=$1 AND event_id <= $2
             ORDER BY work_id,event_id DESC
         )
         SELECT work_id,head_generation,head_snapshot_id,title
         FROM latest
         WHERE work_id::text > $3 AND tombstoned=false
         ORDER BY work_id
         LIMIT $4",
    )
    .bind(&p.account_id)
    .bind(high_water)
    .bind(&last)
    .bind(page + 1)
    .fetch_all(&mut *tx)
    .await
    {
        Ok(value) => value,
        Err(error) => return error_response(SyncError::Database(error)),
    };
    if let Err(error) = tx.commit().await {
        return error_response(SyncError::Database(error));
    }
    let has_more = rows.len() as i64 > page;
    if has_more {
        rows.truncate(page as usize);
    }
    let mut items = Vec::with_capacity(rows.len());
    let mut last_work = None;
    for row in rows {
        let work_id = match row.try_get::<Uuid, _>("work_id") {
            Ok(value) => value,
            Err(error) => return error_response(SyncError::Database(error)),
        };
        let generation = match row.try_get::<Option<i64>, _>("head_generation") {
            Ok(Some(value)) => value,
            Ok(None) => return error_response(SyncError::Retryable),
            Err(error) => return error_response(SyncError::Database(error)),
        };
        let snapshot = match row.try_get::<Option<Vec<u8>>, _>("head_snapshot_id") {
            Ok(Some(value)) if value.len() == 32 => value,
            Ok(_) => return error_response(SyncError::Retryable),
            Err(error) => return error_response(SyncError::Database(error)),
        };
        let title = match row.try_get::<String, _>("title") {
            Ok(value) => value,
            Err(error) => return error_response(SyncError::Database(error)),
        };
        last_work = Some(work_id.to_string());
        items.push(serde_json::json!({"workId":work_id,"title":title,"head":{"generation":generation,"snapshotId":hex::encode(snapshot)}}));
    }
    let next_cursor = if has_more {
        match last_work {
            Some(last) => match encode_cursor(
                serde_json::json!({"accountFence":p.account_fence,"accountId":p.account_id,"endpoint":"works","highWater":high_water,"last":last,"pageSize":page,"protocolEpoch":PROTOCOL_EPOCH,"queryDigest":cursor_digest("works")}),
            ) {
                Ok(cursor) => Some(cursor),
                Err(error) => return error_response(error),
            },
            None => return error_response(SyncError::Retryable),
        }
    } else {
        None
    };
    canonical_response(
        StatusCode::OK,
        serde_json::json!({"items":items,"nextCursor":next_cursor,"result":"noChanges"}),
    )
}
async fn head(Path(work): Path<String>, headers: HeaderMap, state: State<AppState>) -> Response {
    let work = match parse_uuid_path(&work) {
        Ok(value) => value,
        Err(error) => return error_response(error),
    };
    let p = match principal(&headers, &state) {
        Ok(v) => v,
        Err(e) => return e,
    };
    let row=sqlx::query("SELECT head_generation,head_snapshot_id FROM sync_v2.works WHERE account_id=$1 AND work_id=$2").bind(&p.account_id).bind(work).fetch_optional(&state.repo.pool).await;
    match row {
        Ok(Some(r)) => {
            let generation = match r.try_get::<Option<i64>, _>("head_generation") {
                Ok(value) => value,
                Err(error) => return error_response(SyncError::Database(error)),
            };
            let snapshot = match r.try_get::<Option<Vec<u8>>, _>("head_snapshot_id") {
                Ok(value) => value,
                Err(error) => return error_response(SyncError::Database(error)),
            };
            let value = match (generation, snapshot) {
                (None, None) => serde_json::Value::Null,
                (Some(generation), Some(snapshot)) if snapshot.len() == 32 => {
                    serde_json::json!({"generation":generation,"snapshotId":hex::encode(snapshot)})
                }
                _ => return error_response(SyncError::Retryable),
            };
            canonical_response(
                StatusCode::OK,
                serde_json::json!({"head":value,"result":"noChanges"}),
            )
        }
        Ok(None) => error_response(SyncError::NotFound),
        Err(e) => error_response(SyncError::Database(e)),
    }
}
async fn history(
    Path(work): Path<String>,
    headers: HeaderMap,
    Query(params): Query<HashMap<String, String>>,
    state: State<AppState>,
) -> Response {
    let work = match parse_uuid_path(&work) {
        Ok(value) => value,
        Err(error) => return error_response(error),
    };
    let p = match principal(&headers, &state) {
        Ok(v) => v,
        Err(e) => return e,
    };
    let exists = match sqlx::query("SELECT 1 FROM sync_v2.works WHERE account_id=$1 AND work_id=$2")
        .bind(&p.account_id)
        .bind(work)
        .fetch_optional(&state.repo.pool)
        .await
    {
        Ok(value) => value.is_some(),
        Err(error) => return error_response(SyncError::Database(error)),
    };
    if !exists {
        return error_response(SyncError::NotFound);
    }
    let requested_page = match page_size(&params) {
        Ok(value) => value,
        Err(error) => return error_response(error),
    };
    let (high_water, last, page) = if let Some(encoded) = params.get("cursor") {
        let cursor = match decode_cursor(encoded) {
            Ok(value) => value,
            Err(error) => return error_response(error),
        };
        let page = match cursor.get("pageSize").and_then(serde_json::Value::as_i64) {
            Some(value) if (1..=MAX_PAGE_SIZE).contains(&value) => value,
            None => return error_response(SyncError::SchemaViolation("cursor.pageSize".into())),
            _ => return error_response(SyncError::SchemaViolation("cursor.pageSize".into())),
        };
        if params.contains_key("pageSize") && page != requested_page {
            return error_response(SyncError::SchemaViolation("cursor.pageSize".into()));
        }
        match cursor_scope(&cursor, "history", &p, page, Some(work)) {
            Ok((high, last)) => match last.parse::<i64>() {
                Ok(last) if last > 0 => (high, last, page),
                _ => return error_response(SyncError::SchemaViolation("cursor.last".into())),
            },
            Err(error) => return error_response(error),
        }
    } else {
        let high = match sqlx::query_scalar::<_, Option<i64>>(
            "SELECT MAX(event_id) FROM sync_v2.history WHERE account_id=$1 AND work_id=$2",
        )
        .bind(&p.account_id)
        .bind(work)
        .fetch_one(&state.repo.pool)
        .await
        {
            Ok(value) => value.unwrap_or(0),
            Err(error) => return error_response(SyncError::Database(error)),
        };
        (high, 0, requested_page)
    };
    if params.contains_key("cursor") {
        let current_high = match sqlx::query_scalar::<_, Option<i64>>(
            "SELECT MAX(event_id) FROM sync_v2.history WHERE account_id=$1 AND work_id=$2",
        )
        .bind(&p.account_id)
        .bind(work)
        .fetch_one(&state.repo.pool)
        .await
        {
            Ok(value) => value.unwrap_or(0),
            Err(error) => return error_response(SyncError::Database(error)),
        };
        if high_water > current_high || last >= high_water {
            return error_response(SyncError::SchemaViolation("cursor.highWater".into()));
        }
    }
    let rows=sqlx::query("SELECT occurrence_id,snapshot_id,reason,pinned,created_at,event_id FROM sync_v2.history WHERE account_id=$1 AND work_id=$2 AND event_id <= $3 AND event_id > $4 ORDER BY event_id LIMIT $5").bind(&p.account_id).bind(work).bind(high_water).bind(last).bind(page + 1).fetch_all(&state.repo.pool).await;
    match rows {
        Ok(mut rows) => {
            let has_more = rows.len() as i64 > page;
            if has_more {
                rows.truncate(page as usize);
            }
            let mut items = Vec::with_capacity(rows.len());
            let mut last_event = None;
            for row in rows {
                let occurrence_id = match row.try_get::<Uuid, _>("occurrence_id") {
                    Ok(value) => value,
                    Err(error) => return error_response(SyncError::Database(error)),
                };
                let snapshot = match row.try_get::<Vec<u8>, _>("snapshot_id") {
                    Ok(value) if value.len() == 32 => value,
                    Ok(_) => return error_response(SyncError::Retryable),
                    Err(error) => return error_response(SyncError::Database(error)),
                };
                let reason = match row.try_get::<String, _>("reason") {
                    Ok(value) => value,
                    Err(error) => return error_response(SyncError::Database(error)),
                };
                let pinned = match row.try_get::<bool, _>("pinned") {
                    Ok(value) => value,
                    Err(error) => return error_response(SyncError::Database(error)),
                };
                let created_at = match row.try_get::<chrono::DateTime<chrono::Utc>, _>("created_at")
                {
                    Ok(value) => value,
                    Err(error) => return error_response(SyncError::Database(error)),
                };
                last_event = match row.try_get::<i64, _>("event_id") {
                    Ok(value) => Some(value),
                    Err(error) => return error_response(SyncError::Database(error)),
                };
                items.push(serde_json::json!({"occurrenceId":occurrence_id,"snapshotId":hex::encode(snapshot),"reason":reason,"pinned":pinned,"createdAt":created_at.to_rfc3339()}));
            }
            let next_cursor = if has_more {
                match last_event {
                    Some(last) => match encode_cursor(
                        serde_json::json!({"accountFence":p.account_fence,"accountId":p.account_id,"endpoint":"history","highWater":high_water,"last":last.to_string(),"pageSize":page,"protocolEpoch":PROTOCOL_EPOCH,"queryDigest":cursor_digest("history"),"workId":work}),
                    ) {
                        Ok(cursor) => Some(cursor),
                        Err(error) => return error_response(error),
                    },
                    None => return error_response(SyncError::Retryable),
                }
            } else {
                None
            };
            canonical_response(
                StatusCode::OK,
                serde_json::json!({"items":items,"nextCursor":next_cursor,"result":"noChanges"}),
            )
        }
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
            let bytes: Vec<u8> = match r.try_get("manifest_bytes") {
                Ok(value) => value,
                Err(error) => return error_response(SyncError::Database(error)),
            };
            let digest: Vec<u8> = match r.try_get("manifest_digest") {
                Ok(value) => value,
                Err(error) => return error_response(SyncError::Database(error)),
            };
            if digest.as_slice() != id.as_slice() || sha256(&bytes) != id {
                return error_response(SyncError::Retryable);
            }
            canonical_response(
                StatusCode::OK,
                serde_json::json!({"manifestBase64URL":URL_SAFE_NO_PAD.encode(bytes),"manifestBytesDigest":hex::encode(digest),"snapshotId":hex::encode(id),"result":"noChanges"}),
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
    match state.repo.object_store.get(&p.account_id, &id).await {
        Ok(bytes) => Response::builder()
            .status(200)
            .header("content-type", "application/octet-stream")
            .header("x-fuminiwa-object-digest", hex::encode(id))
            .header("x-fuminiwa-byte-count", bytes.len().to_string())
            .header("x-fuminiwa-result", "noChanges")
            .body(axum::body::Body::from(bytes))
            .unwrap(),
        Err(e) => error_response(e),
    }
}
async fn missing_objects(
    headers: HeaderMap,
    state: State<AppState>,
    body: Result<Bytes, BytesRejection>,
) -> Response {
    let body = match body_or_error(body) {
        Ok(body) if body.len() <= MAX_MISSING_BODY_BYTES => body,
        Ok(_) => return error_response(SyncError::SizeLimitExceeded),
        Err(response) => return response,
    };
    let p = match principal(&headers, &state) {
        Ok(v) => v,
        Err(e) => return e,
    };
    let value = match strict_json(&body) {
        Ok(v) => v,
        Err(e) => return error_response(e),
    };
    let canonical = match canonical_json(&value) {
        Ok(bytes) => bytes,
        Err(_) => return error_response(SyncError::InvalidCanonicalBytes),
    };
    if canonical.as_slice() != body.as_ref() {
        return error_response(SyncError::SchemaViolation("missing objects request".into()));
    }
    if value
        .get("schemaVersion")
        .and_then(serde_json::Value::as_i64)
        != Some(PROTOCOL_EPOCH)
        || value
            .as_object()
            .map(|object| {
                object
                    .keys()
                    .any(|key| !["objectIds", "schemaVersion", "workId"].contains(&key.as_str()))
            })
            .unwrap_or(true)
    {
        return error_response(SyncError::SchemaViolation("missing objects request".into()));
    }
    let work = match value
        .get("workId")
        .and_then(serde_json::Value::as_str)
        .and_then(|value| Uuid::parse_str(value).ok())
    {
        Some(work) => work,
        None => return error_response(SyncError::SchemaViolation("workId".into())),
    };
    if value.get("workId").and_then(serde_json::Value::as_str) != Some(work.to_string().as_str()) {
        return error_response(SyncError::SchemaViolation("workId".into()));
    }
    let work_exists =
        match sqlx::query("SELECT 1 FROM sync_v2.works WHERE account_id=$1 AND work_id=$2")
            .bind(&p.account_id)
            .bind(work)
            .fetch_optional(&state.repo.pool)
            .await
        {
            Ok(value) => value.is_some(),
            Err(error) => return error_response(SyncError::Database(error)),
        };
    if !work_exists {
        return error_response(SyncError::NotFound);
    }
    let Some(ids) = value.get("objectIds").and_then(serde_json::Value::as_array) else {
        return error_response(SyncError::SchemaViolation("objectIds".into()));
    };
    if ids.len() > 100_000 {
        return error_response(SyncError::SizeLimitExceeded);
    }
    let mut missing = Vec::new();
    let mut seen = std::collections::HashSet::new();
    for id in ids {
        let Some(text) = id.as_str() else {
            return error_response(SyncError::SchemaViolation("objectIds".into()));
        };
        let digest = match decode_digest(text) {
            Ok(v) => v,
            Err(e) => return error_response(e),
        };
        if !seen.insert(digest) {
            return error_response(SyncError::SchemaViolation("objectIds.unique".into()));
        }
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
    Path(upload): Path<String>,
    headers: HeaderMap,
    state: State<AppState>,
    body: Result<Bytes, BytesRejection>,
) -> Response {
    let upload = match parse_uuid_path(&upload) {
        Ok(value) => value,
        Err(error) => return error_response(error),
    };
    let body = match body_or_error(body) {
        Ok(body) => body,
        Err(response) => return response,
    };
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
        Ok(()) => Response::builder()
            .status(StatusCode::NO_CONTENT)
            .header("x-fuminiwa-result", "applied")
            .body(axum::body::Body::empty())
            .unwrap(),
        Err(e) => error_response(e),
    }
}
async fn conflict(
    Path(work): Path<String>,
    headers: HeaderMap,
    state: State<AppState>,
) -> Response {
    let work = match parse_uuid_path(&work) {
        Ok(value) => value,
        Err(error) => return error_response(error),
    };
    let p = match principal(&headers, &state) {
        Ok(v) => v,
        Err(e) => return e,
    };
    let exists = match sqlx::query("SELECT 1 FROM sync_v2.works WHERE account_id=$1 AND work_id=$2")
        .bind(&p.account_id)
        .bind(work)
        .fetch_optional(&state.repo.pool)
        .await
    {
        Ok(value) => value.is_some(),
        Err(error) => return error_response(SyncError::Database(error)),
    };
    if !exists {
        return error_response(SyncError::NotFound);
    }
    let row=sqlx::query("SELECT a.conflict_id,a.current_revision,a.source_generation,c.base_snapshot_id,c.local_snapshot_id,c.remote_snapshot_id FROM sync_v2.active_conflicts a JOIN sync_v2.conflict_candidates c ON c.account_id=a.account_id AND c.conflict_id=a.conflict_id AND c.revision=a.current_revision WHERE a.account_id=$1 AND a.work_id=$2 AND a.state='active'").bind(&p.account_id).bind(work).fetch_optional(&state.repo.pool).await;
    match row {
        Ok(Some(r)) => {
            let base = match r.try_get::<Option<Vec<u8>>, _>("base_snapshot_id") {
                Ok(Some(value)) if value.len() == 32 => Some(hex::encode(value)),
                Ok(None) => None,
                Ok(Some(_)) => return error_response(SyncError::Retryable),
                Err(error) => return error_response(SyncError::Database(error)),
            };
            let conflict_id = match r.try_get::<Uuid, _>("conflict_id") {
                Ok(value) => value,
                Err(error) => return error_response(SyncError::Database(error)),
            };
            let local = match r.try_get::<Vec<u8>, _>("local_snapshot_id") {
                Ok(value) if value.len() == 32 => value,
                Ok(_) => return error_response(SyncError::Retryable),
                Err(error) => return error_response(SyncError::Database(error)),
            };
            let remote = match r.try_get::<Vec<u8>, _>("remote_snapshot_id") {
                Ok(value) if value.len() == 32 => value,
                Ok(_) => return error_response(SyncError::Retryable),
                Err(error) => return error_response(SyncError::Database(error)),
            };
            let revision = match r.try_get::<i64, _>("current_revision") {
                Ok(value) => value,
                Err(error) => return error_response(SyncError::Database(error)),
            };
            let source_generation = match r.try_get::<i64, _>("source_generation") {
                Ok(value) => value,
                Err(error) => return error_response(SyncError::Database(error)),
            };
            canonical_response(
                StatusCode::OK,
                serde_json::json!({"conflict":{"baseSnapshotId":base,"conflictId":conflict_id,"localSnapshotId":hex::encode(local),"remoteSnapshotId":hex::encode(remote),"revision":revision,"sourceGeneration":source_generation,"workId":work},"result":"noChanges"}),
            )
        }
        Ok(None) => canonical_response(
            StatusCode::OK,
            serde_json::json!({"conflict":null,"result":"noChanges"}),
        ),
        Err(e) => error_response(SyncError::Database(e)),
    }
}
async fn receipt(Path(id): Path<String>, headers: HeaderMap, state: State<AppState>) -> Response {
    let id = match parse_uuid_path(&id) {
        Ok(value) => value,
        Err(error) => return error_response(error),
    };
    let p = match principal(&headers, &state) {
        Ok(v) => v,
        Err(e) => return e,
    };
    match state.repo.receipt(&p, id).await {
        Ok((kind, work_id, request_digest, bytes, _status)) => {
            if request_digest.len() != 32 {
                return error_response(SyncError::Retryable);
            }
            let original = match strict_json(&bytes) {
                Ok(value) => value,
                Err(_) => return error_response(SyncError::Retryable),
            };
            let recanonical = match canonical_json(&original) {
                Ok(value) => value,
                Err(_) => return error_response(SyncError::Retryable),
            };
            if recanonical != bytes {
                return error_response(SyncError::Retryable);
            }
            let result = match original.get("result").and_then(serde_json::Value::as_str) {
                Some(
                    value @ ("noChanges" | "applied" | "conflictPending" | "parked" | "retryable"),
                ) => serde_json::Value::String(value.into()),
                _ => return error_response(SyncError::Retryable),
            };
            let embedded_receipt = match original.get("receipt") {
                Some(value) => value,
                None => return error_response(SyncError::Retryable),
            };
            let expected_digest = hex::encode(&request_digest);
            if embedded_receipt.as_object().map(serde_json::Map::len) != Some(5)
                || embedded_receipt
                    .get("commandId")
                    .and_then(serde_json::Value::as_str)
                    != Some(id.to_string().as_str())
                || embedded_receipt
                    .get("commandKind")
                    .and_then(serde_json::Value::as_str)
                    != Some(kind.as_str())
                || embedded_receipt
                    .get("workId")
                    .and_then(serde_json::Value::as_str)
                    != Some(work_id.to_string().as_str())
                || embedded_receipt
                    .get("requestDigest")
                    .and_then(serde_json::Value::as_str)
                    != Some(expected_digest.as_str())
            {
                return error_response(SyncError::Retryable);
            }
            let read_back = match embedded_receipt.get("readBack").filter(|read_back| {
                read_back.as_object().map(serde_json::Map::len) == Some(5)
                    && [
                        "accountMatched",
                        "commandDigestMatched",
                        "headMatched",
                        "resourceMatched",
                        "stateMatched",
                    ]
                    .iter()
                    .all(|key| {
                        read_back.get(key).and_then(serde_json::Value::as_bool) == Some(true)
                    })
            }) {
                Some(value) => value.clone(),
                None => return error_response(SyncError::Retryable),
            };
            canonical_response(
                StatusCode::OK,
                serde_json::json!({"commandId":id,"commandKind":kind,"workId":work_id,"requestDigest":hex::encode(request_digest),"canonicalResponseBase64URL":URL_SAFE_NO_PAD.encode(bytes),"originalResult":result,"readBack":read_back,"result":"noChanges"}),
            )
        }
        Err(e) => error_response(e),
    }
}
fn decode_digest(value: &str) -> Result<[u8; 32], SyncError> {
    crate::domain::decode_digest(value).map_err(|_| SyncError::NotFound)
}

fn parse_uuid_path(value: &str) -> Result<Uuid, SyncError> {
    let parsed = Uuid::parse_str(value).map_err(|_| SyncError::NotFound)?;
    if parsed.to_string() != value {
        return Err(SyncError::NotFound);
    }
    Ok(parsed)
}
