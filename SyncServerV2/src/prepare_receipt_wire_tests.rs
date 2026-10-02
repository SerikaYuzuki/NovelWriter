//! Shared regression bytes for the real-iPhone prepare/applied failure.
//! Uses the same canonical_response and RFC3339 serializer as the HTTP handler.
use super::canonical_response;
use axum::{body::to_bytes, http::StatusCode};
use base64::{engine::general_purpose::URL_SAFE_NO_PAD, Engine};
use serde_json::{json, Value};

#[tokio::test]
async fn prepare_applied_and_receipt_match_shared_swift_fixture() {
    let post = include_bytes!("../tests/fixtures/prepare-object/applied.json");
    let wrapper = include_bytes!("../tests/fixtures/prepare-object/receipt.json");
    let original: Value = serde_json::from_slice(post).unwrap();
    let expiry =
        chrono::DateTime::parse_from_rfc3339(original["expiresAt"].as_str().unwrap()).unwrap();
    assert_eq!(expiry.to_rfc3339(), original["expiresAt"]);
    assert_eq!(post.len() % 3, 0);
    let response = canonical_response(StatusCode::CREATED, original.clone());
    assert_eq!(response.status(), StatusCode::CREATED);
    assert_eq!(
        to_bytes(response.into_body(), usize::MAX)
            .await
            .unwrap()
            .as_ref(),
        post
    );
    let receipt = &original["receipt"];
    let value = json!({
        "canonicalResponseBase64URL": URL_SAFE_NO_PAD.encode(post),
        "commandId": original["commandId"], "commandKind": original["commandKind"],
        "originalResponseStatus": 201, "originalResult": original["result"],
        "readBack": receipt["readBack"], "requestDigest": receipt["requestDigest"],
        "result": "noChanges", "workId": receipt["workId"]
    });
    let response = canonical_response(StatusCode::OK, value);
    assert_eq!(
        response.headers()["content-type"],
        "application/vnd.fuminiwa.sync.v2+jcs"
    );
    assert_eq!(
        to_bytes(response.into_body(), usize::MAX)
            .await
            .unwrap()
            .as_ref(),
        wrapper
    );
}
