use crate::{
    domain::*,
    http::{canonical_response, error_response, principal, AppState},
    work_recovery::RecoveryRequest,
};
use axum::{
    extract::{DefaultBodyLimit, Path, Query, State},
    http::{HeaderMap, StatusCode},
    response::Response,
    routing::{get, post},
    Json, Router,
};
use sqlx::Row;
use std::collections::HashMap;
use uuid::Uuid;

pub fn routes() -> Router<AppState> {
    Router::new()
        .route("/v2/protection", get(list))
        .route("/v2/protection/{work}/status", get(status))
        .route("/v2/protection/{work}/history", get(history))
        .route(
            "/v2/protection/{work}/recover",
            post(recover).layer(DefaultBodyLimit::max(4096)),
        )
}
async fn list(
    Query(params): Query<HashMap<String, String>>,
    headers: HeaderMap,
    State(state): State<AppState>,
) -> Response {
    let p = match principal(&headers, &state).await {
        Ok(p) => p,
        Err(e) => return e,
    };
    let after = match params.get("after").map(|s| Uuid::parse_str(s)).transpose() {
        Ok(v) => v.unwrap_or(Uuid::nil()),
        _ => return error_response(SyncError::SchemaViolation("after".into())),
    };
    let result: SyncResult<serde_json::Value> = async {
        let mut tx = state.repo.pool.begin().await?;
        state.repo.scope(&mut tx, &p).await?;
        let rows = sqlx::query("SELECT w.work_id,d.deleted_at,(SELECT c.title FROM sync_v2.catalog_events c WHERE c.account_id=w.account_id AND c.work_id=w.work_id ORDER BY c.event_id DESC LIMIT 1) AS title FROM sync_v2.works w LEFT JOIN sync_v2.deleted_works d USING(account_id,work_id) WHERE w.account_id=$1 AND w.state='bound' AND w.work_id>$2 AND w.head_snapshot_id IS NOT NULL AND (d.deleted_at IS NULL OR (d.deleted_at AT TIME ZONE 'UTC')+interval '1 year' > (clock_timestamp() AT TIME ZONE 'UTC')) ORDER BY w.work_id LIMIT 501")
            .bind(&p.account_id).bind(after).fetch_all(&mut *tx).await?;
        let mut items = Vec::new();
        for row in rows.iter().take(500) {
            items.push(serde_json::json!({"workId":row.try_get::<Uuid,_>("work_id")?,"title":row.try_get::<Option<String>,_>("title")?.unwrap_or_default(),"deletedAt":row.try_get::<Option<chrono::DateTime<chrono::Utc>>,_>("deleted_at")?.map(|d|d.to_rfc3339())}));
        }
        let next = if rows.len()>500 { items.last().map(|v|v["workId"].clone()) } else { None };
        tx.commit().await?;
        Ok(serde_json::json!({"items":items,"nextAfter":next,"result":"noChanges"}))
    }.await;
    match result {
        Ok(v) => canonical_response(StatusCode::OK, v),
        Err(e) => error_response(e),
    }
}
async fn status(
    Path(work): Path<Uuid>,
    headers: HeaderMap,
    State(state): State<AppState>,
) -> Response {
    let p = match principal(&headers, &state).await {
        Ok(p) => p,
        Err(e) => return e,
    };
    match state.repo.work_protection_status(&p, work).await {
        Ok(v) => canonical_response(StatusCode::OK, v),
        Err(e) => error_response(e),
    }
}
async fn recover(
    Path(work): Path<Uuid>,
    headers: HeaderMap,
    State(state): State<AppState>,
    Json(request): Json<RecoveryRequest>,
) -> Response {
    let p = match principal(&headers, &state).await {
        Ok(p) => p,
        Err(e) => return e,
    };
    let label = crate::device_label::from_headers(&headers);
    match state
        .repo
        .recover_work_with_device_label(&p, work, &request, label.as_deref())
        .await
    {
        Ok(v) => canonical_response(StatusCode::OK, v),
        Err(e) => error_response(e),
    }
}
async fn history(
    Path(work): Path<Uuid>,
    Query(params): Query<HashMap<String, String>>,
    headers: HeaderMap,
    State(state): State<AppState>,
) -> Response {
    let p = match principal(&headers, &state).await {
        Ok(p) => p,
        Err(e) => return e,
    };
    let after = match params.get("after").map(|v| v.parse::<i64>()).transpose() {
        Ok(v) if v.unwrap_or(0) >= 0 => v.unwrap_or(0),
        _ => return error_response(SyncError::SchemaViolation("after".into())),
    };
    let result:SyncResult<serde_json::Value>=async {
        let mut tx=state.repo.pool.begin().await?;
        state.repo.scope(&mut tx,&p).await?;
        let exists:bool=sqlx::query_scalar("SELECT EXISTS(SELECT 1 FROM sync_v2.works w WHERE w.account_id=$1 AND w.work_id=$2 AND w.state='bound' AND NOT EXISTS(SELECT 1 FROM sync_v2.deleted_works d WHERE d.account_id=w.account_id AND d.work_id=w.work_id AND (d.deleted_at AT TIME ZONE 'UTC')+interval '1 year' <= (clock_timestamp() AT TIME ZONE 'UTC')))").bind(&p.account_id).bind(work).fetch_one(&mut *tx).await?;
        if !exists {return Err(SyncError::NotFound);}
        let rows=sqlx::query("WITH points AS (SELECT event_id,snapshot_id,created_at FROM sync_v2.history WHERE account_id=$1 AND work_id=$2), selected AS (SELECT * FROM points WHERE created_at>=now()-interval '7 days' UNION ALL (SELECT DISTINCT ON ((created_at AT TIME ZONE 'Asia/Tokyo')::date) * FROM points WHERE created_at<now()-interval '7 days' ORDER BY (created_at AT TIME ZONE 'Asia/Tokyo')::date,created_at DESC,event_id DESC)) SELECT * FROM selected WHERE event_id>$3 ORDER BY event_id LIMIT 501").bind(&p.account_id).bind(work).bind(after).fetch_all(&mut *tx).await?;
        let mut items=Vec::new();
        for r in rows.iter().take(500) {items.push(serde_json::json!({"eventId":r.try_get::<i64,_>("event_id")?,"snapshotId":hex::encode(r.try_get::<Vec<u8>,_>("snapshot_id")?),"createdAt":r.try_get::<chrono::DateTime<chrono::Utc>,_>("created_at")?.to_rfc3339()}));}
        let next=if rows.len()>500 {items.last().map(|v|v["eventId"].clone())} else {None};
        tx.commit().await?;
        Ok(serde_json::json!({"items":items,"nextAfter":next,"result":"noChanges"}))
    }.await;
    match result {
        Ok(v) => canonical_response(StatusCode::OK, v),
        Err(e) => error_response(e),
    }
}
