use crate::{
    assistant_records::AssistantRecord,
    http::{canonical_response, error_response, principal, AppState},
};
use axum::{
    extract::{DefaultBodyLimit, Query, State},
    http::{HeaderMap, StatusCode},
    response::Response,
    routing::get,
    Json, Router,
};
use serde::Deserialize;
use uuid::Uuid;

pub fn routes() -> Router<AppState> {
    Router::new()
        .route("/v2/assistant/records", get(list).post(append))
        .layer(DefaultBodyLimit::max(2 * 1024 * 1024))
}
#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct RecordQuery {
    work_id: Option<Uuid>,
    after: Option<i64>,
}
async fn list(
    Query(query): Query<RecordQuery>,
    headers: HeaderMap,
    State(state): State<AppState>,
) -> Response {
    let p = match principal(&headers, &state).await {
        Ok(v) => v,
        Err(e) => return e,
    };
    match state
        .repo
        .assistant_record_page(&p, query.work_id, query.after.unwrap_or(0))
        .await
    {
        Ok(v) => canonical_response(StatusCode::OK, v),
        Err(e) => error_response(e),
    }
}
async fn append(
    headers: HeaderMap,
    State(state): State<AppState>,
    Json(record): Json<AssistantRecord>,
) -> Response {
    let p = match principal(&headers, &state).await {
        Ok(v) => v,
        Err(e) => return e,
    };
    match state.repo.append_assistant_record(&p, &record).await {
        Ok(v) => canonical_response(StatusCode::OK, v),
        Err(e) => error_response(e),
    }
}
