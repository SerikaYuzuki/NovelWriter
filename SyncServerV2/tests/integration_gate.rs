//! Opt-in PostgreSQL/HTTP gate. Ordinary test runs emit an explicit skip and
//! never connect to a fixed development or LAN server.
mod support;

use axum::{
    body::{to_bytes, Body},
    http::{header::AUTHORIZATION, HeaderMap, HeaderValue, Request, StatusCode},
};
use base64::{engine::general_purpose::URL_SAFE_NO_PAD, Engine};
use fuminiwa_sync_server_v2::{
    application::parse_command,
    auth::FixtureAccessAuthenticator,
    domain::{canonical_json, CommandKind},
    router, AppState, RuntimeMode,
};
use serde_json::Value;
use sqlx::Row;
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
    request(context, account_id, "GET", path, None, None).await
}

async fn request(
    context: &ScenarioContext,
    account_id: &str,
    method: &str,
    path: &str,
    body: Option<Vec<u8>>,
    content_type: Option<&str>,
) -> (StatusCode, HeaderMap, Vec<u8>) {
    let app = router(AppState {
        repo: Arc::new(context.repo.clone()),
        access_authenticator: fixture_authenticator(),
    });
    let mut builder = Request::builder().method(method).uri(path);
    if let Some(content_type) = content_type {
        builder = builder.header("content-type", content_type);
    }
    let mut request = builder.body(Body::from(body.unwrap_or_default())).unwrap();
    *request.headers_mut() = headers(account_id);
    if let Some(content_type) = content_type {
        request.headers_mut().insert(
            "content-type",
            HeaderValue::from_str(content_type).expect("test media type"),
        );
    }
    let response = app.oneshot(request).await.unwrap();
    let status = response.status();
    let headers = response.headers().clone();
    let body = to_bytes(response.into_body(), 64 * 1024 * 1024)
        .await
        .unwrap()
        .to_vec();
    (status, headers, body)
}

const SYNC_MEDIA_TYPE: &str = "application/vnd.fuminiwa.sync.v2+jcs";
const OBJECT_MEDIA_TYPE: &str = "application/octet-stream";

fn command_bytes(
    account_id: &str,
    kind: CommandKind,
    command_id: Uuid,
    work_id: Uuid,
    source_snapshot_id: [u8; 32],
    source_generation: i64,
    payload: Value,
) -> Vec<u8> {
    let value = serde_json::json!({
        "binding": {
            "accountFence": "fixture-fence",
            "accountId": account_id,
            "protocolEpoch": 2,
            "serverInstanceId": "sync-v2-scenario"
        },
        "commandId": command_id,
        "commandKind": kind.as_str(),
        "payload": payload,
        "schemaVersion": 2,
        "sourceGeneration": source_generation,
        "sourceSnapshotId": hex::encode(source_snapshot_id)
    });
    let bytes = canonical_json(&value).expect("canonical test command");
    let parsed = parse_command(&bytes).expect("test command is valid");
    assert_eq!(parsed.work_id, work_id);
    bytes
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
    request.headers_mut().insert(
        "content-type",
        HeaderValue::from_static("application/vnd.fuminiwa.sync.v2+jcs"),
    );
    let response = app.oneshot(request).await.unwrap();
    let status = response.status();
    let body = to_bytes(response.into_body(), 64 * 1024)
        .await
        .unwrap()
        .to_vec();
    (status, body)
}

async fn account_inventory(context: &ScenarioContext, account_id: &str) -> Vec<i64> {
    let row = sqlx::query(
        "SELECT
           (SELECT COUNT(*) FROM sync_v2.works WHERE account_id=$1),
           (SELECT COUNT(*) FROM sync_v2.snapshots WHERE account_id=$1),
           (SELECT COUNT(*) FROM sync_v2.account_objects WHERE account_id=$1),
           (SELECT COUNT(*) FROM sync_v2.history WHERE account_id=$1),
           (SELECT COUNT(*) FROM sync_v2.active_conflicts WHERE account_id=$1),
           (SELECT COUNT(*) FROM sync_v2.conflict_events WHERE account_id=$1),
           (SELECT COUNT(*) FROM sync_v2.catalog_events WHERE account_id=$1),
           (SELECT COUNT(*) FROM sync_v2.receipts WHERE account_id=$1),
           (SELECT COUNT(*) FROM sync_v2.sealed_commands WHERE account_id=$1)",
    )
    .bind(account_id)
    .fetch_one(&context.repo.pool)
    .await
    .expect("account inventory query");
    (0..9)
        .map(|index| row.try_get::<i64, _>(index).expect("inventory count"))
        .collect()
}

async fn upload_as(
    context: &ScenarioContext,
    account_id: &str,
    upload_id: Uuid,
    capability: &str,
    bytes: &[u8],
) -> (StatusCode, HeaderMap, Vec<u8>) {
    let app = router(AppState {
        repo: Arc::new(context.repo.clone()),
        access_authenticator: fixture_authenticator(),
    });
    let mut request = Request::builder()
        .method("PUT")
        .uri(format!("/v2/uploads/{upload_id}"))
        .header("content-type", OBJECT_MEDIA_TYPE)
        .header("x-fuminiwa-upload-capability", capability)
        .body(Body::from(bytes.to_vec()))
        .unwrap();
    *request.headers_mut() = headers(account_id);
    request
        .headers_mut()
        .insert("content-type", HeaderValue::from_static(OBJECT_MEDIA_TYPE));
    request.headers_mut().insert(
        "x-fuminiwa-upload-capability",
        HeaderValue::from_str(capability).expect("test upload capability"),
    );
    let response = app.oneshot(request).await.unwrap();
    let status = response.status();
    let response_headers = response.headers().clone();
    let body = to_bytes(response.into_body(), 64 * 1024 * 1024)
        .await
        .unwrap()
        .to_vec();
    (status, response_headers, body)
}

async fn verify_http_account_boundaries(context: &ScenarioContext) {
    let account_a = context.account_a.account_id.as_str();
    let account_b = context.account_b.account_id.as_str();
    let missing = Uuid::new_v4();

    // Every known A resource must look exactly like an absent resource to B.
    let (foreign_manifest, _, foreign_manifest_body) = get(
        context,
        account_b,
        &format!(
            "/v2/snapshots/{}/manifest",
            hex::encode(context.root_snapshot)
        ),
    )
    .await;
    let (missing_manifest, _, missing_manifest_body) = get(
        context,
        account_b,
        &format!("/v2/snapshots/{}/manifest", hex::encode([0xEE; 32])),
    )
    .await;
    assert_eq!(foreign_manifest, StatusCode::NOT_FOUND);
    assert_eq!(foreign_manifest, missing_manifest);
    assert_eq!(foreign_manifest_body, missing_manifest_body);

    let foreign_history_path = format!("/v2/works/{}/history", context.primary_work);
    let (foreign_history, _, foreign_history_body) =
        get(context, account_b, &foreign_history_path).await;
    let (missing_history, _, missing_history_body) =
        get(context, account_b, &format!("/v2/works/{missing}/history")).await;
    assert_eq!(foreign_history, StatusCode::NOT_FOUND);
    assert_eq!(foreign_history, missing_history);
    assert_eq!(foreign_history_body, missing_history_body);

    let (foreign_catalog, _, foreign_catalog_body) = get(context, account_b, "/v2/works").await;
    assert_eq!(foreign_catalog, StatusCode::OK);
    let catalog: Value = serde_json::from_slice(&foreign_catalog_body).unwrap();
    assert!(catalog["items"]
        .as_array()
        .unwrap()
        .iter()
        .all(|item| item["workId"] != context.primary_work.to_string()));

    let missing_objects_body = canonical_json(&serde_json::json!({
        "objectIds": [hex::encode(context.object_id)],
        "schemaVersion": 2,
        "workId": context.primary_work
    }))
    .unwrap();
    let (foreign_missing, _, foreign_missing_body) = request(
        context,
        account_b,
        "POST",
        "/v2/objects/missing",
        Some(missing_objects_body),
        Some(SYNC_MEDIA_TYPE),
    )
    .await;
    let unknown_objects_body = canonical_json(&serde_json::json!({
        "objectIds": [hex::encode([0xEE; 32])],
        "schemaVersion": 2,
        "workId": missing
    }))
    .unwrap();
    let (missing_objects, _, missing_objects_response) = request(
        context,
        account_b,
        "POST",
        "/v2/objects/missing",
        Some(unknown_objects_body),
        Some(SYNC_MEDIA_TYPE),
    )
    .await;
    assert_eq!(foreign_missing, StatusCode::NOT_FOUND);
    assert_eq!(foreign_missing, missing_objects);
    assert_eq!(foreign_missing_body, missing_objects_response);

    // Prepare one A-owned upload capability before taking the mutation
    // inventory. Every command below is an A command envelope sent with B's
    // headers; binding rejection happens before any Work/receipt lookup.
    let upload_bytes = b"account-boundary-upload";
    let upload_object = fuminiwa_sync_server_v2::domain::sha256(upload_bytes);
    let prepare_bytes = command_bytes(
        account_a,
        CommandKind::PrepareObject,
        Uuid::new_v4(),
        context.primary_work,
        context.root_snapshot,
        1,
        serde_json::json!({
            "byteCount": upload_bytes.len(),
            "objectId": hex::encode(upload_object),
            "workId": context.primary_work
        }),
    );
    let prepare_command = parse_command(&prepare_bytes).unwrap();
    let (prepare_status, prepare_response) = context
        .repo
        .command(&context.account_a, &prepare_command)
        .await
        .expect("prepare A upload capability");
    assert_eq!(prepare_status, StatusCode::CREATED.as_u16() as i32);
    let prepare_value: Value = serde_json::from_slice(&prepare_response).unwrap();
    let upload_id = Uuid::parse_str(prepare_value["uploadId"].as_str().unwrap()).unwrap();
    let capability = prepare_value["uploadCapability"]
        .as_str()
        .unwrap()
        .to_owned();

    let before = account_inventory(context, account_a).await;

    let (foreign_upload, _, foreign_upload_body) =
        upload_as(context, account_b, upload_id, &capability, upload_bytes).await;
    let (missing_upload, _, missing_upload_body) =
        upload_as(context, account_b, missing, &capability, upload_bytes).await;
    assert_eq!(foreign_upload, StatusCode::NOT_FOUND);
    assert_eq!(foreign_upload, missing_upload);
    assert_eq!(foreign_upload_body, missing_upload_body);

    let finalize_bytes = command_bytes(
        account_a,
        CommandKind::FinalizeObject,
        Uuid::new_v4(),
        context.primary_work,
        context.root_snapshot,
        1,
        serde_json::json!({
            "byteCount": upload_bytes.len(),
            "objectId": hex::encode(upload_object),
            "uploadId": upload_id,
            "workId": context.primary_work
        }),
    );
    let register_bytes = command_bytes(
        account_a,
        CommandKind::RegisterSnapshot,
        Uuid::new_v4(),
        context.primary_work,
        context.root_snapshot,
        1,
        serde_json::json!({
            "manifestBase64URL": "",
            "manifestBytesDigest": hex::encode(context.root_snapshot),
            "snapshotId": hex::encode(context.root_snapshot),
            "workId": context.primary_work
        }),
    );
    let publish_bytes = command_bytes(
        account_a,
        CommandKind::Publish,
        Uuid::new_v4(),
        context.primary_work,
        context.root_snapshot,
        1,
        serde_json::json!({
            "candidateSnapshotId": hex::encode(context.root_snapshot),
            "expectedRemoteHead": Value::Null,
            "workId": context.primary_work
        }),
    );
    let conflict_payload = &context.rejected_resolution.value["payload"];
    let resolve_device_bytes = command_bytes(
        account_a,
        CommandKind::ResolveDevice,
        Uuid::new_v4(),
        context.active_conflict_work,
        context.root_snapshot,
        1,
        serde_json::json!({
            "conflictId": conflict_payload["conflictId"],
            "conflictRevision": conflict_payload["conflictRevision"],
            "decisionSnapshotId": hex::encode(context.root_snapshot),
            "expectedRemoteHead": Value::Null,
            "localCandidateSnapshotId": conflict_payload["preAdoptionSnapshotId"],
            "workId": context.active_conflict_work
        }),
    );
    let clone_work = Uuid::new_v4();
    let clone_document = Uuid::new_v4();
    let clone_bytes = command_bytes(
        account_a,
        CommandKind::CloneWork,
        Uuid::new_v4(),
        context.active_conflict_work,
        context.root_snapshot,
        1,
        serde_json::json!({
            "conflictId": conflict_payload["conflictId"],
            "conflictRevision": conflict_payload["conflictRevision"],
            "expectedOriginalHead": Value::Null,
            "localCandidateSnapshotId": conflict_payload["preAdoptionSnapshotId"],
            "newDocumentId": clone_document,
            "newRootSnapshotId": hex::encode(context.root_snapshot),
            "newWorkId": clone_work,
            "sourceWorkId": context.active_conflict_work
        }),
    );
    let restore_bytes = command_bytes(
        account_a,
        CommandKind::Restore,
        Uuid::new_v4(),
        context.primary_work,
        context.root_snapshot,
        1,
        serde_json::json!({
            "expectedCurrentSnapshotId": hex::encode(context.root_snapshot),
            "expectedLocalGeneration": 1,
            "expectedRemoteHead": Value::Null,
            "newSnapshotId": hex::encode(context.root_snapshot),
            "selectedSnapshotId": hex::encode(context.root_snapshot),
            "workId": context.primary_work
        }),
    );
    let command_routes = [
        ("/v2/objects/prepare", prepare_bytes, None),
        ("/v2/objects/finalize", finalize_bytes, None),
        ("/v2/snapshots/register", register_bytes, None),
        (
            "/v2/works/{work}/publish",
            publish_bytes,
            Some(context.primary_work),
        ),
        (
            "/v2/works/{work}/conflict/resolve",
            resolve_device_bytes,
            Some(context.active_conflict_work),
        ),
        (
            "/v2/works/{work}/conflict/resolve",
            context.rejected_resolution.canonical_bytes.clone(),
            Some(context.active_conflict_work),
        ),
        (
            "/v2/works/{work}/conflict/resolve",
            clone_bytes,
            Some(context.active_conflict_work),
        ),
        (
            "/v2/works/{work}/restore",
            restore_bytes,
            Some(context.primary_work),
        ),
    ];
    for (route, body, work) in command_routes {
        let path = route.replace("{work}", &work.unwrap_or(context.primary_work).to_string());
        let (status, _, body) = request(
            context,
            account_b,
            "POST",
            &path,
            Some(body),
            Some(SYNC_MEDIA_TYPE),
        )
        .await;
        assert_eq!(status, StatusCode::FORBIDDEN, "cross-account route {path}");
        assert_eq!(
            serde_json::from_slice::<Value>(&body).unwrap()["error"],
            "accountFenceMismatch",
            "cross-account route {path} disclosed a resource"
        );
    }

    let after = account_inventory(context, account_a).await;
    assert_eq!(before, after, "cross-account HTTP changed Account A state");
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
    assert_eq!(bad_headers["cache-control"], "no-store");
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

    verify_http_account_boundaries(context).await;
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
