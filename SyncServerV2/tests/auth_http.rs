use async_trait::async_trait;
use axum::{
    body::{to_bytes, Body},
    http::{header::AUTHORIZATION, Request, StatusCode},
};
use fuminiwa_sync_server_v2::{
    auth_domain::{AccountId, AuthError, AuthenticatedPrincipal, SessionId, TenantId},
    auth_http::{
        self, AuthApiError, AuthHttpService, AuthHttpState, AuthResponse, AUTH_MEDIA_TYPE,
    },
    auth_wire::encode_me_response,
    domain::canonical_json,
};
use serde_json::{json, Value};
use std::sync::{Arc, Mutex};
use tower::ServiceExt;

const INSTANCE: &str = "00000000-0000-4000-8000-000000000001";

#[derive(Default)]
struct FakeService {
    tokens: Mutex<Vec<String>>,
}

#[async_trait]
impl AuthHttpService for FakeService {
    async fn create_challenge(
        &self,
        _body: &[u8],
        _now_unix: i64,
    ) -> Result<AuthResponse, AuthApiError> {
        Err(AuthError::InvalidRequest.into())
    }

    async fn exchange(
        &self,
        _challenge_id: &str,
        _body: &[u8],
        _now_unix: i64,
    ) -> Result<AuthResponse, AuthApiError> {
        Err(AuthError::InvalidRequest.into())
    }

    async fn refresh(
        &self,
        refresh_token: String,
        _body: &[u8],
    ) -> Result<AuthResponse, AuthApiError> {
        self.tokens.lock().unwrap().push(refresh_token);
        Ok(AuthResponse::new(
            200,
            canonical_json(&json!({"result":"fixture"})).unwrap(),
        ))
    }

    async fn revoke(
        &self,
        _refresh_token: String,
        _body: &[u8],
    ) -> Result<AuthResponse, AuthApiError> {
        Err(AuthError::SessionRevoked.into())
    }

    async fn me(&self, access_token: &str) -> Result<AuthResponse, AuthApiError> {
        self.tokens.lock().unwrap().push(access_token.into());
        let principal = AuthenticatedPrincipal {
            account_id: AccountId::new("acct_fixture").unwrap(),
            tenant_id: TenantId::new("tenant_secret").unwrap(),
            session_id: SessionId::new("00000000-0000-4000-8000-000000000002").unwrap(),
            account_auth_epoch: 7,
            account_fence: vec![9; 32],
        };
        Ok(AuthResponse::new(
            200,
            encode_me_response(&principal, INSTANCE).unwrap(),
        ))
    }
}

fn app(service: Arc<FakeService>) -> axum::Router {
    auth_http::router(AuthHttpState::new(service, INSTANCE.into()))
}

fn request(path: &str) -> http::request::Builder {
    Request::builder()
        .uri(path)
        .header("x-fuminiwa-client-version", "0.1.0")
}

fn assert_single_auth_cache_contract(response: &http::Response<Body>) {
    assert_eq!(
        response.headers().get_all("cache-control").iter().count(),
        1
    );
    assert_eq!(response.headers().get_all("pragma").iter().count(), 1);
    assert_eq!(response.headers()["cache-control"], "no-store");
    assert_eq!(response.headers()["pragma"], "no-cache");
    assert_eq!(response.headers()["content-type"], AUTH_MEDIA_TYPE);
}

#[tokio::test]
async fn capabilities_are_public_closed_and_account_independent() {
    let service = Arc::new(FakeService::default());
    let signed_out = app(service.clone())
        .oneshot(
            request("/v1/auth/capabilities")
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    let signed_in = app(service)
        .oneshot(
            request("/v1/auth/capabilities")
                .header(AUTHORIZATION, "Bearer fma1_not-a-real-token")
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(signed_out.status(), StatusCode::OK);
    assert_eq!(signed_in.status(), StatusCode::OK);
    let signed_out_headers = signed_out.headers().clone();
    assert_eq!(signed_out_headers["content-type"], AUTH_MEDIA_TYPE);
    assert_eq!(signed_out_headers["cache-control"], "no-store");
    assert_single_auth_cache_contract(&signed_out);
    let left = to_bytes(signed_out.into_body(), 64 * 1024).await.unwrap();
    let right = to_bytes(signed_in.into_body(), 64 * 1024).await.unwrap();
    assert_eq!(left, right);
    let value: Value = serde_json::from_slice(&left).unwrap();
    assert_eq!(value["authProtocolEpoch"], 1);
    assert_eq!(value["syncProtocolEpoch"], 2);
    assert_eq!(value["minimumClientVersion"], "0.1.0");
    assert_eq!(value["providers"][0]["provider"], "apple");
    assert!(value.get("accountId").is_none());
    assert!(value.get("tenantId").is_none());
}

#[tokio::test]
async fn old_client_is_rejected_with_closed_upgrade_response() {
    let response = app(Arc::new(FakeService::default()))
        .oneshot(
            Request::builder()
                .uri("/v1/auth/capabilities")
                .header("x-fuminiwa-client-version", "0.0.9")
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::UPGRADE_REQUIRED);
    let bytes = to_bytes(response.into_body(), 64 * 1024).await.unwrap();
    let value: Value = serde_json::from_slice(&bytes).unwrap();
    assert_eq!(value["code"], "clientVersionUnsupported");
    assert_eq!(value["minimumClientVersion"], "0.1.0");
}

#[tokio::test]
async fn me_exposes_only_fuminiwa_binding_and_never_tenant() {
    let service = Arc::new(FakeService::default());
    let response = app(service.clone())
        .oneshot(
            request("/v1/auth/me")
                .header(AUTHORIZATION, "Bearer fma1_fixture-access-token")
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::OK);
    assert_single_auth_cache_contract(&response);
    let bytes = to_bytes(response.into_body(), 64 * 1024).await.unwrap();
    let value: Value = serde_json::from_slice(&bytes).unwrap();
    assert_eq!(value["binding"]["accountId"], "acct_fixture");
    assert_eq!(value["binding"]["accountAuthEpoch"], 7);
    assert_eq!(value["binding"]["syncProtocolEpoch"], 2);
    assert!(value.get("tenantId").is_none());
    assert!(!String::from_utf8_lossy(&bytes).contains("tenant_secret"));
    assert_eq!(
        service.tokens.lock().unwrap().as_slice(),
        ["fma1_fixture-access-token"]
    );
}

#[tokio::test]
async fn refresh_requires_fuminiwa_token_and_exact_media_type() {
    let service = Arc::new(FakeService::default());
    let body =
        canonical_json(&json!({"rotationId":"00000000-0000-4000-8000-000000000003"})).unwrap();
    let response = app(service.clone())
        .oneshot(
            request("/v1/auth/tokens:refresh")
                .method("POST")
                .header(AUTHORIZATION, "Bearer fmr1_fixture-refresh-token")
                .header("content-type", AUTH_MEDIA_TYPE)
                .body(Body::from(body.clone()))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::OK);
    assert_eq!(
        service.tokens.lock().unwrap().as_slice(),
        ["fmr1_fixture-refresh-token"]
    );

    let rejected = app(service)
        .oneshot(
            request("/v1/auth/tokens:refresh")
                .method("POST")
                .header(AUTHORIZATION, "Bearer apple.jwt.token")
                .header("content-type", "application/json")
                .body(Body::from(body))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(rejected.status(), StatusCode::UNAUTHORIZED);
}
