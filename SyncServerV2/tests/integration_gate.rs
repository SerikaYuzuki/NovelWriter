//! Opt-in PostgreSQL/HTTP gate. Ordinary test runs emit an explicit skip and
//! never connect to a fixed development or LAN server.
mod support;

use axum::{
    body::{to_bytes, Body},
    http::{header::AUTHORIZATION, HeaderMap, HeaderValue, Request, StatusCode},
};
use base64::{engine::general_purpose::URL_SAFE_NO_PAD, Engine};
use fuminiwa_sync_server_v2::{auth::FixtureAccessAuthenticator, router, AppState, RuntimeMode};
use serde_json::Value;
use std::sync::Arc;
use support::{run_repository_scenarios, ScenarioContext};
use tower::ServiceExt;
use uuid::Uuid;

fn fixture_authenticator() -> Arc<FixtureAccessAuthenticator> {
    Arc::new(FixtureAccessAuthenticator::new(RuntimeMode::Test, "fixture-fence".into()).unwrap())
}

fn headers(account_id: &str) -> HeaderMap {
    let mut headers = HeaderMap::new();
    headers.insert(
        AUTHORIZATION,
        HeaderValue::from_str(&format!("Bearer dev:{account_id}:fixture-fence")).unwrap(),
    );
    headers.insert(
        "x-fuminiwa-server-instance",
        HeaderValue::from_static("sync-v2-scenario"),
    );
    headers.insert(
        "x-fuminiwa-account-fence",
        HeaderValue::from_static("fixture-fence"),
    );
    headers.insert("x-fuminiwa-protocol-epoch", HeaderValue::from_static("2"));
    headers
}

async fn get(
    context: &ScenarioContext,
    account_id: &str,
    path: &str,
) -> (StatusCode, HeaderMap, Vec<u8>) {
    let app = router(AppState {
        repo: Arc::new(context.repo.clone()),
        access_authenticator: fixture_authenticator(),
    });
    let mut request = Request::builder().uri(path).body(Body::empty()).unwrap();
    *request.headers_mut() = headers(account_id);
    let response = app.oneshot(request).await.unwrap();
    let status = response.status();
    let headers = response.headers().clone();
    let body = to_bytes(response.into_body(), 64 * 1024 * 1024)
        .await
        .unwrap()
        .to_vec();
    (status, headers, body)
}

async fn post_resolution(context: &ScenarioContext, account_id: &str) -> (StatusCode, Vec<u8>) {
    let app = router(AppState {
        repo: Arc::new(context.repo.clone()),
        access_authenticator: fixture_authenticator(),
    });
    let mut request = Request::builder()
        .method("POST")
        .uri(format!(
            "/v2/works/{}/conflict/resolve",
            context.rejected_resolution.work_id
        ))
        .body(Body::from(
            context.rejected_resolution.canonical_bytes.clone(),
        ))
        .unwrap();
    *request.headers_mut() = headers(account_id);
    let response = app.oneshot(request).await.unwrap();
    let status = response.status();
    let body = to_bytes(response.into_body(), 64 * 1024)
        .await
        .unwrap()
        .to_vec();
    (status, body)
}

async fn verify_http_contract(context: &ScenarioContext) {
    let account_a = context.account_a.account_id.as_str();
    let account_b = context.account_b.account_id.as_str();
    let missing = Uuid::new_v4();

    let (stale_resolution_status, stale_resolution_body) =
        post_resolution(context, account_a).await;
    assert_eq!(stale_resolution_status, StatusCode::CONFLICT);
    assert_eq!(
        serde_json::from_slice::<Value>(&stale_resolution_body).unwrap()["error"],
        "staleConflictRevision"
    );

    let (foreign_status, _, foreign_body) = get(
        context,
        account_a,
        &format!("/v2/works/{}/head", context.foreign_work),
    )
    .await;
    let (missing_status, _, missing_body) =
        get(context, account_a, &format!("/v2/works/{missing}/head")).await;
    assert_eq!(foreign_status, StatusCode::NOT_FOUND);
    assert_eq!(foreign_status, missing_status);
    assert_eq!(foreign_body, missing_body);

    let (foreign_receipt, _, foreign_receipt_body) = get(
        context,
        account_b,
        &format!("/v2/receipts/{}", context.receipt_id),
    )
    .await;
    let (missing_receipt, _, missing_receipt_body) =
        get(context, account_b, &format!("/v2/receipts/{missing}")).await;
    assert_eq!(foreign_receipt, StatusCode::NOT_FOUND);
    assert_eq!(foreign_receipt, missing_receipt);
    assert_eq!(foreign_receipt_body, missing_receipt_body);

    let (conflict_status, _, conflict_body) = get(
        context,
        account_a,
        &format!("/v2/works/{}/conflict", context.active_conflict_work),
    )
    .await;
    assert_eq!(conflict_status, StatusCode::OK);
    let conflict: Value = serde_json::from_slice(&conflict_body).unwrap();
    assert!(conflict["conflict"].is_object());
    let (foreign_conflict, _, foreign_conflict_body) = get(
        context,
        account_b,
        &format!("/v2/works/{}/conflict", context.active_conflict_work),
    )
    .await;
    let (missing_conflict, _, missing_conflict_body) =
        get(context, account_b, &format!("/v2/works/{missing}/conflict")).await;
    assert_eq!(foreign_conflict, StatusCode::NOT_FOUND);
    assert_eq!(foreign_conflict, missing_conflict);
    assert_eq!(foreign_conflict_body, missing_conflict_body);

    let missing_object = [0xEE; 32];
    let (foreign_object, _, foreign_object_body) = get(
        context,
        account_b,
        &format!("/v2/objects/{}", hex::encode(context.object_id)),
    )
    .await;
    let (missing_object_status, _, missing_object_body) = get(
        context,
        account_b,
        &format!("/v2/objects/{}", hex::encode(missing_object)),
    )
    .await;
    assert_eq!(foreign_object, StatusCode::NOT_FOUND);
    assert_eq!(foreign_object, missing_object_status);
    assert_eq!(foreign_object_body, missing_object_body);

    let (object_status, object_headers, object_body) = get(
        context,
        account_a,
        &format!("/v2/objects/{}", hex::encode(context.object_id)),
    )
    .await;
    assert_eq!(object_status, StatusCode::OK);
    assert_eq!(
        object_headers["x-fuminiwa-object-digest"],
        hex::encode(context.object_id)
    );
    assert_eq!(
        object_headers["x-fuminiwa-byte-count"],
        object_body.len().to_string()
    );
    assert_eq!(object_headers["x-fuminiwa-result"], "noChanges");

    let (receipt_status, _, receipt_body) = get(
        context,
        account_a,
        &format!("/v2/receipts/{}", context.receipt_id),
    )
    .await;
    assert_eq!(receipt_status, StatusCode::OK);
    let receipt: Value = serde_json::from_slice(&receipt_body).unwrap();
    assert!(receipt["readBack"]
        .as_object()
        .unwrap()
        .values()
        .all(|value| value.as_bool() == Some(true)));
    let exact = URL_SAFE_NO_PAD
        .decode(receipt["canonicalResponseBase64URL"].as_str().unwrap())
        .unwrap();
    let original: Value = serde_json::from_slice(&exact).unwrap();
    assert_eq!(receipt["originalResult"], original["result"]);

    let (bad_page, bad_headers, bad_body) =
        get(context, account_a, "/v2/works?pageSize=not-a-number").await;
    assert_eq!(bad_page, StatusCode::UNPROCESSABLE_ENTITY);
    assert_eq!(
        bad_headers["content-type"],
        "application/vnd.fuminiwa.sync.v2+jcs"
    );
    assert_eq!(
        serde_json::from_slice::<Value>(&bad_body).unwrap()["error"],
        "schemaViolation"
    );

    let (first_status, _, first_body) = get(context, account_a, "/v2/works?pageSize=1").await;
    assert_eq!(first_status, StatusCode::OK);
    let first: Value = serde_json::from_slice(&first_body).unwrap();
    let cursor = first["nextCursor"]
        .as_str()
        .expect("catalog has multiple rows");
    let (second_status, _, second_body) = get(
        context,
        account_a,
        &format!("/v2/works?pageSize=1&cursor={cursor}"),
    )
    .await;
    assert_eq!(second_status, StatusCode::OK);
    let second: Value = serde_json::from_slice(&second_body).unwrap();
    assert_ne!(first["items"][0]["workId"], second["items"][0]["workId"]);
    assert!(first["items"]
        .as_array()
        .unwrap()
        .iter()
        .chain(second["items"].as_array().unwrap())
        .all(|item| item["workId"] != context.primary_work.to_string()));

    let (history_status, _, history_body) = get(
        context,
        account_a,
        &format!("/v2/works/{}/history?pageSize=1", context.history_work),
    )
    .await;
    assert_eq!(history_status, StatusCode::OK);
    let history: Value = serde_json::from_slice(&history_body).unwrap();
    assert!(history["items"][0]["createdAt"].is_string());
    let history_cursor = history["nextCursor"]
        .as_str()
        .expect("history has multiple rows");
    let (next_history_status, _, next_history_body) = get(
        context,
        account_a,
        &format!(
            "/v2/works/{}/history?pageSize=1&cursor={history_cursor}",
            context.history_work
        ),
    )
    .await;
    assert_eq!(next_history_status, StatusCode::OK);
    let next_history: Value = serde_json::from_slice(&next_history_body).unwrap();
    assert_ne!(
        history["items"][0]["occurrenceId"],
        next_history["items"][0]["occurrenceId"]
    );

    let app = router(AppState {
        repo: Arc::new(context.repo.clone()),
        access_authenticator: fixture_authenticator(),
    });
    let mut capabilities = Request::builder()
        .uri("/v2/capabilities")
        .body(Body::empty())
        .unwrap();
    capabilities.headers_mut().insert(
        AUTHORIZATION,
        HeaderValue::from_str(&format!("Bearer dev:{account_a}:fixture-fence")).unwrap(),
    );
    capabilities.headers_mut().insert(
        "x-fuminiwa-client-version",
        HeaderValue::from_static("scenario-client"),
    );
    let capabilities = app.clone().oneshot(capabilities).await.unwrap();
    assert_eq!(capabilities.status(), StatusCode::OK);

    let mut missing_scope = Request::builder()
        .uri("/v2/works")
        .body(Body::empty())
        .unwrap();
    missing_scope.headers_mut().insert(
        AUTHORIZATION,
        HeaderValue::from_str(&format!("Bearer dev:{account_a}:fixture-fence")).unwrap(),
    );
    let response = app.oneshot(missing_scope).await.unwrap();
    assert_eq!(response.status(), StatusCode::FORBIDDEN);
    assert_eq!(
        response.headers()["content-type"],
        "application/vnd.fuminiwa.sync.v2+jcs"
    );
}

#[tokio::test]
async fn postgres_and_http_scenarios_are_opt_in() {
    let Ok(url) = std::env::var("FUMINIWA_V2_TEST_DATABASE_URL") else {
        eprintln!(
            "SKIP: set FUMINIWA_V2_TEST_DATABASE_URL to an externally provisioned, newly-created empty fuminiwa_v2_test PostgreSQL database"
        );
        return;
    };
    let context = run_repository_scenarios(&url)
        .await
        .expect("Snapshot Sync v2 PostgreSQL scenario failed");
    verify_http_contract(&context).await;
    context.repo.pool.close().await;
}

#[test]
fn integration_url_requires_an_isolated_sync_test_database() {
    assert!(support::validate_test_database_url(
        "postgres://postgres:secret@postgres-test/fuminiwa_v2_test_1234"
    )
    .is_ok());
    for rejected in [
        "postgres://postgres:secret@192.168.11.5/fuminiwa_v2_test_1234",
        "postgres://postgres:secret@postgres-test/fuminiwa_sync_v2",
        "postgres://postgres:secret@postgres-test/fuminiwa_v2_test_staging",
    ] {
        assert!(support::validate_test_database_url(rejected).is_err());
    }
}
