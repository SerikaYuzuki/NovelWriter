//! Auth v1 Axum boundary. Bodies are exact canonical bytes and never logged.

use crate::{
    auth::bearer_token,
    auth_domain::{
        AuthError, ChallengeId, OperationId, AUTH_PROTOCOL_EPOCH, AUTH_PROTOCOL_VERSION,
    },
    domain::{canonical_json, PROTOCOL_EPOCH},
};
use async_trait::async_trait;
use axum::{
    body::Bytes,
    extract::{rejection::BytesRejection, DefaultBodyLimit, Path, State},
    http::{header::CONTENT_TYPE, HeaderMap, StatusCode},
    response::Response,
    routing::{get, post},
    Router,
};
use chrono::Utc;
use serde_json::{json, Map, Value};
use std::sync::Arc;
use uuid::Uuid;

pub const AUTH_MEDIA_TYPE: &str = "application/vnd.fuminiwa.auth.v1+jcs";
pub const MAX_AUTH_BODY_BYTES: usize = 65_536;
const MINIMUM_CLIENT_VERSION: &str = "0.1.0";

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct AuthResponse {
    pub status: u16,
    pub canonical_bytes: Vec<u8>,
}

impl AuthResponse {
    pub fn new(status: u16, canonical_bytes: Vec<u8>) -> Self {
        Self {
            status,
            canonical_bytes,
        }
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct AuthApiError {
    pub error: AuthError,
    pub operation_id: Option<OperationId>,
    pub challenge_id: Option<ChallengeId>,
}

impl AuthApiError {
    pub fn operation(mut self, value: OperationId) -> Self {
        self.operation_id = Some(value);
        self
    }
    pub fn challenge(mut self, value: ChallengeId) -> Self {
        self.challenge_id = Some(value);
        self
    }
}

impl From<AuthError> for AuthApiError {
    fn from(error: AuthError) -> Self {
        Self {
            error,
            operation_id: None,
            challenge_id: None,
        }
    }
}

#[async_trait]
pub trait AuthHttpService: Send + Sync {
    async fn create_challenge(
        &self,
        body: &[u8],
        now_unix: i64,
    ) -> Result<AuthResponse, AuthApiError>;
    async fn exchange(
        &self,
        challenge_id: &str,
        body: &[u8],
        now_unix: i64,
    ) -> Result<AuthResponse, AuthApiError>;
    async fn refresh(
        &self,
        refresh_token: String,
        body: &[u8],
    ) -> Result<AuthResponse, AuthApiError>;
    async fn revoke(
        &self,
        refresh_token: String,
        body: &[u8],
    ) -> Result<AuthResponse, AuthApiError>;
    async fn apple_notification(
        &self,
        _body: &[u8],
        _now_unix: i64,
    ) -> Result<AuthResponse, AuthApiError> {
        Err(AuthApiError::from(AuthError::InvalidRequest))
    }
    async fn me(&self, access_token: &str) -> Result<AuthResponse, AuthApiError>;
}

#[derive(Clone)]
pub struct AuthHttpState {
    pub service: Arc<dyn AuthHttpService>,
    pub server_instance_id: Arc<str>,
}

impl AuthHttpState {
    pub fn new(service: Arc<dyn AuthHttpService>, server_instance_id: String) -> Self {
        Self {
            service,
            server_instance_id: server_instance_id.into(),
        }
    }
}

pub fn router(state: AuthHttpState) -> Router {
    Router::new()
        .route("/v1/auth/capabilities", get(capabilities))
        .route(
            "/v1/auth/apple/notifications",
            post(apple_notification).layer(DefaultBodyLimit::max(MAX_AUTH_BODY_BYTES)),
        )
        .route(
            "/v1/auth/challenges",
            post(create_challenge).layer(DefaultBodyLimit::max(MAX_AUTH_BODY_BYTES)),
        )
        .route(
            "/v1/auth/challenges/{exchange_path}",
            post(exchange).layer(DefaultBodyLimit::max(MAX_AUTH_BODY_BYTES)),
        )
        .route(
            "/v1/auth/tokens:refresh",
            post(refresh).layer(DefaultBodyLimit::max(MAX_AUTH_BODY_BYTES)),
        )
        .route(
            "/v1/auth/session:revoke",
            post(revoke).layer(DefaultBodyLimit::max(MAX_AUTH_BODY_BYTES)),
        )
        .route("/v1/auth/me", get(me))
        .with_state(state)
}

async fn capabilities(headers: HeaderMap, State(state): State<AuthHttpState>) -> Response {
    if let Err(response) = require_client_version(&headers) {
        return response;
    }
    let value = json!({
        "authProtocolEpoch":AUTH_PROTOCOL_EPOCH,
        "authProtocolNamespace":"com.fuminiwa.auth",
        "authProtocolVersion":AUTH_PROTOCOL_VERSION,
        "canonicalization":"rfc8785-jcs",
        "contentProtection":content_protection(),
        "limits":{
            "accessTokenLifetimeSeconds":900,
            "authReceiptLifetimeSeconds":7776000,
            "challengeLifetimeSeconds":300,
            "maxCanonicalCommandBytes":65536,
            "maxProviderClockSkewSeconds":300,
            "refreshTokenLifetimeSeconds":7776000
        },
        "minimumClientVersion":MINIMUM_CLIENT_VERSION,
        "providers":[{
            "authorizationEndpoint":"https://appleid.apple.com/auth/authorize",
            "clientPlatforms":["ios","ipados","macos"],
            "flow":"native",
            "issuer":"https://appleid.apple.com",
            "jwksEndpoint":"https://appleid.apple.com/auth/keys",
            "nativeAudiences":[
                {"audience":"dev.serikayuzuki.fuminiwa","clientPlatform":"macos"},
                {"audience":"dev.serikayuzuki.fuminiwa.ios","clientPlatform":"ios"},
                {"audience":"dev.serikayuzuki.fuminiwa.ios","clientPlatform":"ipados"}
            ],
            "provider":"apple",
            "providerConfigurationId":"apple-primary-fuminiwa-v1",
            "requestedScopes":[],
            "tokenEndpoint":"https://appleid.apple.com/auth/token"
        }],
        "serverInstanceId":state.server_instance_id.as_ref(),
        "syncProtocolEpoch":PROTOCOL_EPOCH,
        "syncProtocolNamespace":"com.fuminiwa.snapshot-sync"
    });
    canonical_value_response(StatusCode::OK, value)
}

async fn create_challenge(
    headers: HeaderMap,
    State(state): State<AuthHttpState>,
    body: Result<Bytes, BytesRejection>,
) -> Response {
    let body = match command_body(&headers, body) {
        Ok(value) => value,
        Err(response) => return response,
    };
    service_response(
        state
            .service
            .create_challenge(&body, Utc::now().timestamp())
            .await,
        ErrorScope::Operation,
    )
}

async fn exchange(
    Path(exchange_path): Path<String>,
    headers: HeaderMap,
    State(state): State<AuthHttpState>,
    body: Result<Bytes, BytesRejection>,
) -> Response {
    let Some(challenge_id) = exchange_path.strip_suffix(":exchange") else {
        return error_response(
            AuthApiError::from(AuthError::InvalidIdentifier),
            ErrorScope::Operation,
        );
    };
    if !lowercase_uuid(challenge_id) {
        return error_response(
            AuthApiError::from(AuthError::InvalidIdentifier),
            ErrorScope::Operation,
        );
    }
    let body = match command_body(&headers, body) {
        Ok(value) => value,
        Err(response) => return response,
    };
    service_response(
        state
            .service
            .exchange(challenge_id, &body, Utc::now().timestamp())
            .await,
        ErrorScope::Operation,
    )
}

async fn refresh(
    headers: HeaderMap,
    State(state): State<AuthHttpState>,
    body: Result<Bytes, BytesRejection>,
) -> Response {
    let token = match bearer_token(&headers) {
        Some(value) if value.starts_with("fmr1_") => value.to_owned(),
        _ => return error_response(AuthError::AccountNotFound.into(), ErrorScope::Rotation),
    };
    let body = match command_body(&headers, body) {
        Ok(value) => value,
        Err(response) => return response,
    };
    service_response(
        state.service.refresh(token, &body).await,
        ErrorScope::Rotation,
    )
}

async fn revoke(
    headers: HeaderMap,
    State(state): State<AuthHttpState>,
    body: Result<Bytes, BytesRejection>,
) -> Response {
    let token = match bearer_token(&headers) {
        Some(value) if value.starts_with("fmr1_") => value.to_owned(),
        _ => return error_response(AuthError::AccountNotFound.into(), ErrorScope::Operation),
    };
    let body = match command_body(&headers, body) {
        Ok(value) => value,
        Err(response) => return response,
    };
    service_response(
        state.service.revoke(token, &body).await,
        ErrorScope::Operation,
    )
}

async fn apple_notification(
    State(state): State<AuthHttpState>,
    body: Result<Bytes, BytesRejection>,
) -> Response {
    let body = match body {
        Ok(body) => body,
        Err(_) => return error_response(AuthError::InvalidRequest.into(), ErrorScope::Operation),
    };
    service_response(
        state
            .service
            .apple_notification(&body, Utc::now().timestamp())
            .await,
        ErrorScope::Operation,
    )
}

async fn me(headers: HeaderMap, State(state): State<AuthHttpState>) -> Response {
    if let Err(response) = require_client_version(&headers) {
        return response;
    }
    let token = match bearer_token(&headers) {
        Some(value) if value.starts_with("fma1_") => value,
        _ => return error_response(AuthError::AccountNotFound.into(), ErrorScope::Access),
    };
    service_response(state.service.me(token).await, ErrorScope::Access)
}

#[allow(clippy::result_large_err)]
fn command_body(
    headers: &HeaderMap,
    body: Result<Bytes, BytesRejection>,
) -> Result<Bytes, Response> {
    require_client_version(headers)?;
    if headers
        .get(CONTENT_TYPE)
        .and_then(|value| value.to_str().ok())
        != Some(AUTH_MEDIA_TYPE)
    {
        return Err(invalid_request_response("unsupportedMediaType"));
    }
    let body = body.map_err(|_| payload_too_large_response())?;
    if body.is_empty() || body.len() > MAX_AUTH_BODY_BYTES {
        return Err(payload_too_large_response());
    }
    Ok(body)
}

#[allow(clippy::result_large_err)]
fn require_client_version(headers: &HeaderMap) -> Result<(), Response> {
    let version = headers
        .get("x-fuminiwa-client-version")
        .and_then(|value| value.to_str().ok());
    match version.and_then(parse_semantic_version) {
        Some(value) if value >= (0, 1, 0) => Ok(()),
        Some(_) => Err(canonical_value_response(
            StatusCode::UPGRADE_REQUIRED,
            json!({
                "code":"clientVersionUnsupported",
                "minimumClientVersion":MINIMUM_CLIENT_VERSION,
                "recoveryAction":"updateClient",
                "requestId":Uuid::new_v4().to_string(),
                "retryability":"afterClientUpgrade"
            }),
        )),
        None => Err(invalid_request_response("invalidRequest")),
    }
}

fn parse_semantic_version(value: &str) -> Option<(u32, u32, u32)> {
    let parts = value.split('.').collect::<Vec<_>>();
    if parts.len() != 3
        || !parts.iter().all(|part| {
            !part.is_empty()
                && (part == &"0" || !part.starts_with('0'))
                && part.len() <= 9
                && part.bytes().all(|byte| byte.is_ascii_digit())
        })
    {
        return None;
    }
    Some((
        parts[0].parse().ok()?,
        parts[1].parse().ok()?,
        parts[2].parse().ok()?,
    ))
}

fn service_response(result: Result<AuthResponse, AuthApiError>, scope: ErrorScope) -> Response {
    match result {
        Ok(result) => canonical_bytes_response(result.status, result.canonical_bytes),
        Err(error) => error_response(error, scope),
    }
}

fn canonical_value_response(status: StatusCode, value: Value) -> Response {
    let bytes = canonical_json(&value).unwrap_or_else(|_| {
        br#"{"code":"temporarilyUnavailable","recoveryAction":"retrySameRequestAfterBackoff","requestId":"00000000-0000-4000-8000-000000000000","retryAfterSeconds":30,"retryability":"afterBackoff"}"#.to_vec()
    });
    canonical_bytes_response(status.as_u16(), bytes)
}

fn canonical_bytes_response(status: u16, bytes: Vec<u8>) -> Response {
    Response::builder()
        .status(StatusCode::from_u16(status).unwrap_or(StatusCode::SERVICE_UNAVAILABLE))
        .header(CONTENT_TYPE, AUTH_MEDIA_TYPE)
        .header("cache-control", "no-store")
        .header("pragma", "no-cache")
        .body(axum::body::Body::from(bytes))
        .expect("fixed auth response")
}

#[derive(Clone, Copy, Debug)]
enum ErrorScope {
    Access,
    Operation,
    Rotation,
}

fn error_response(error: AuthApiError, scope: ErrorScope) -> Response {
    // Keep provider credentials, tokens, request bodies, and database details
    // out of logs.  The operation/challenge IDs are the safe correlation
    // handles already returned in the typed response envelope.
    tracing::warn!(
        target: "fuminiwa::auth",
        error_kind = auth_error_kind(&error.error),
        operation_id = error
            .operation_id
            .as_ref()
            .map(OperationId::as_str)
            .unwrap_or("none"),
        challenge_id = error
            .challenge_id
            .as_ref()
            .map(ChallengeId::as_str)
            .unwrap_or("none"),
        scope = ?scope,
        "auth request rejected"
    );
    let (status, code, recovery, retryability) = match error.error {
        AuthError::OperationIdReused => (409, "operationIdReused", "none", "never"),
        AuthError::ChallengeExpired => (
            409,
            "challengeExpired",
            "interactiveAppleSignIn",
            "afterInteractiveAuthentication",
        ),
        AuthError::ChallengeConsumed | AuthError::InvalidChallengePhase => (
            409,
            "challengeConsumed",
            "interactiveAppleSignIn",
            "afterInteractiveAuthentication",
        ),
        AuthError::InvalidExternalIdentity => (
            422,
            "providerIdentityInvalid",
            "interactiveAppleSignIn",
            "afterInteractiveAuthentication",
        ),
        AuthError::ProviderExchangeIndeterminate => (
            502,
            "providerExchangeIndeterminate",
            "interactiveAppleSignIn",
            "afterInteractiveAuthentication",
        ),
        AuthError::RefreshTokenReused => (
            401,
            "refreshTokenReused",
            "interactiveAppleSignIn",
            "afterInteractiveAuthentication",
        ),
        AuthError::AccountNotFound
        | AuthError::SessionRevoked
        | AuthError::FenceMismatch
        | AuthError::NotFound => match scope {
            ErrorScope::Access => (
                401,
                "authenticationRequired",
                "refreshFuminiwaSession",
                "afterTokenRefresh",
            ),
            _ => (
                401,
                "authenticationRequired",
                "interactiveAppleSignIn",
                "afterInteractiveAuthentication",
            ),
        },
        AuthError::Vault | AuthError::Database(_) => (
            503,
            "temporarilyUnavailable",
            "retrySameRequestAfterBackoff",
            "afterBackoff",
        ),
        AuthError::InvalidIdentifier | AuthError::InvalidFence | AuthError::InvalidRequest => {
            (400, "invalidRequest", "correctRequest", "never")
        }
        AuthError::ProviderNotAllowed => (400, "invalidRequest", "correctRequest", "never"),
    };
    let mut map = Map::from_iter([
        ("code".into(), Value::String(code.into())),
        ("recoveryAction".into(), Value::String(recovery.into())),
        (
            "requestId".into(),
            Value::String(Uuid::new_v4().to_string()),
        ),
        ("retryability".into(), Value::String(retryability.into())),
    ]);
    if let Some(challenge) = error.challenge_id {
        map.insert("challengeId".into(), Value::String(challenge.to_string()));
    }
    if let Some(operation) = error.operation_id {
        let key = match scope {
            ErrorScope::Rotation => "rotationId",
            _ => "operationId",
        };
        map.insert(key.into(), Value::String(operation.to_string()));
    }
    if status == 503 {
        map.insert("retryAfterSeconds".into(), Value::from(30));
    }
    canonical_value_response(
        StatusCode::from_u16(status).unwrap_or(StatusCode::SERVICE_UNAVAILABLE),
        Value::Object(map),
    )
}

fn auth_error_kind(error: &AuthError) -> &'static str {
    match error {
        AuthError::OperationIdReused => "operationIdReused",
        AuthError::ChallengeExpired => "challengeExpired",
        AuthError::ChallengeConsumed => "challengeConsumed",
        AuthError::InvalidChallengePhase => "invalidChallengePhase",
        AuthError::InvalidExternalIdentity => "invalidExternalIdentity",
        AuthError::ProviderExchangeIndeterminate => "providerExchangeIndeterminate",
        AuthError::RefreshTokenReused => "refreshTokenReused",
        AuthError::AccountNotFound => "accountNotFound",
        AuthError::SessionRevoked => "sessionRevoked",
        AuthError::FenceMismatch => "fenceMismatch",
        AuthError::NotFound => "notFound",
        AuthError::Vault => "vault",
        AuthError::Database(_) => "database",
        AuthError::InvalidIdentifier => "invalidIdentifier",
        AuthError::InvalidFence => "invalidFence",
        AuthError::InvalidRequest => "invalidRequest",
        AuthError::ProviderNotAllowed => "providerNotAllowed",
    }
}

fn payload_too_large_response() -> Response {
    canonical_value_response(
        StatusCode::PAYLOAD_TOO_LARGE,
        json!({
            "code":"payloadTooLarge",
            "maxCanonicalCommandBytes":MAX_AUTH_BODY_BYTES,
            "recoveryAction":"correctRequest",
            "requestId":Uuid::new_v4().to_string(),
            "retryability":"never"
        }),
    )
}

fn invalid_request_response(code: &str) -> Response {
    canonical_value_response(
        StatusCode::BAD_REQUEST,
        json!({
            "code":code,
            "recoveryAction":"correctRequest",
            "requestId":Uuid::new_v4().to_string(),
            "retryability":"never"
        }),
    )
}

fn content_protection() -> Value {
    json!({
        "e2ee":false,
        "profile":"serverReadableV1",
        "serverCanReadContent":true,
        "userManagedContentKey":false
    })
}

fn lowercase_uuid(value: &str) -> bool {
    Uuid::parse_str(value).is_ok_and(|parsed| parsed.to_string() == value)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn semantic_version_is_closed() {
        assert!(parse_semantic_version("0.1.0").is_some());
        assert!(parse_semantic_version("12.3.4").is_some());
        assert!(parse_semantic_version("scenario-client").is_none());
        assert!(parse_semantic_version("01.0.0").is_none());
        assert!(parse_semantic_version("1.0").is_none());
        assert_eq!(parse_semantic_version("0.1.0"), Some((0, 1, 0)));
    }
}
