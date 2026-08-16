use std::{
    collections::{HashMap, HashSet},
    sync::Arc,
};

use aes_gcm::{aead::Aead, Aes256Gcm, KeyInit, Nonce};
use axum::{
    body::Bytes,
    extract::{Path, State},
    http::{header, HeaderMap, StatusCode},
    response::{IntoResponse, Response},
    routing::{get, post},
    Json, Router,
};
use base64::{engine::general_purpose::STANDARD as BASE64, Engine};
use chrono::{DateTime, Utc};
use rand::{distr::Alphanumeric, Rng, RngCore};
use serde::{de::DeserializeOwned, Deserialize, Serialize};
use sha2::{Digest, Sha256};
use sqlx::{postgres::PgPoolOptions, PgPool, Row};
use thiserror::Error;
use tokio::sync::RwLock;
use uuid::Uuid;

pub const MAX_OBJECT_BYTES: usize = 250 * 1024 * 1024;
pub const MAX_MANIFEST_BYTES: usize = 16 * 1024 * 1024;

pub type SharedState = Arc<RwLock<ServerState>>;

#[derive(Clone)]
pub struct AppConfig {
    pub dev_token: Option<String>,
    pub server_instance_id: Uuid,
    pub protocol_epoch: u64,
    pub apple: AppleConfig,
}

impl Default for AppConfig {
    fn default() -> Self {
        Self {
            dev_token: std::env::var("FUMINIWA_DEV_TOKEN").ok(),
            server_instance_id: std::env::var("FUMINIWA_SERVER_INSTANCE_ID")
                .ok()
                .and_then(|value| Uuid::parse_str(&value).ok())
                .unwrap_or_else(Uuid::new_v4),
            protocol_epoch: 1,
            apple: AppleConfig::from_env(),
        }
    }
}

#[derive(Clone)]
pub struct AppleConfig {
    pub client_ids: Vec<String>,
    pub team_id: Option<String>,
    pub key_id: Option<String>,
    pub private_key_pem: Option<String>,
    pub jwks_url: String,
    pub token_url: String,
    pub vault_key: Option<Vec<u8>>,
}

impl AppleConfig {
    fn from_env() -> Self {
        let client_ids = std::env::var("APPLE_CLIENT_IDS")
            .unwrap_or_default()
            .split(',')
            .map(str::trim)
            .filter(|value| !value.is_empty())
            .map(ToOwned::to_owned)
            .collect();
        Self {
            client_ids,
            team_id: std::env::var("APPLE_TEAM_ID").ok(),
            key_id: std::env::var("APPLE_KEY_ID").ok(),
            // Compose/.env transports multiline secrets as literal `\\n`.
            // Restore PEM line breaks before jsonwebtoken parses the key.
            private_key_pem: std::env::var("APPLE_PRIVATE_KEY_PEM")
                .ok()
                .map(|value| value.replace("\\n", "\n")),
            jwks_url: std::env::var("APPLE_JWKS_URL")
                .unwrap_or_else(|_| "https://appleid.apple.com/auth/keys".to_owned()),
            token_url: std::env::var("APPLE_TOKEN_URL")
                .unwrap_or_else(|_| "https://appleid.apple.com/auth/token".to_owned()),
            vault_key: std::env::var("FUMINIWA_VAULT_KEY_B64")
                .ok()
                .and_then(|value| BASE64.decode(value).ok())
                .filter(|value| value.len() == 32),
        }
    }

    fn is_configured(&self) -> bool {
        !self.client_ids.is_empty()
            && self.team_id.is_some()
            && self.key_id.is_some()
            && self.private_key_pem.is_some()
            && self.vault_key.is_some()
    }
}

#[derive(Default)]
pub struct ServerState {
    pub works: HashMap<Uuid, WorkRecord>,
    pub objects: HashMap<String, ObjectRecord>,
    pub snapshots: HashMap<String, SnapshotManifest>,
    pub operations: HashMap<Uuid, OperationReceipt>,
    pub conflicts: HashMap<Uuid, ConflictRecord>,
    pub auth_challenges: HashMap<Uuid, AuthChallenge>,
    pub accounts: HashMap<String, AccountRecord>,
    pub provider_credentials: HashMap<(String, String), ProviderCredential>,
    pub auth_sessions: HashMap<String, AuthSession>,
    pub refresh_families: HashMap<Uuid, RefreshTokenFamily>,
    pub database: Option<PgPool>,
}

impl ServerState {
    pub async fn from_database_url(url: &str) -> Result<Self, sqlx::Error> {
        let pool = PgPoolOptions::new()
            .max_connections(10)
            .connect(url)
            .await?;
        sqlx::migrate!("./migrations").run(&pool).await?;
        let mut state = Self {
            database: Some(pool.clone()),
            ..Self::default()
        };
        for row in sqlx::query("SELECT work_id, head_generation, head_snapshot_id FROM works")
            .fetch_all(&pool)
            .await?
        {
            let work_id: Uuid = row.try_get("work_id")?;
            let head_generation: Option<i64> = row.try_get("head_generation")?;
            let head_snapshot_id: Option<String> = row.try_get("head_snapshot_id")?;
            state.works.insert(
                work_id,
                WorkRecord {
                    work_id,
                    head: head_generation
                        .zip(head_snapshot_id)
                        .map(|(generation, snapshot_id)| Head {
                            generation: generation as u64,
                            snapshot_id,
                        }),
                },
            );
        }
        for row in sqlx::query("SELECT object_id, byte_count, bytes FROM objects")
            .fetch_all(&pool)
            .await?
        {
            let object_id: String = row.try_get("object_id")?;
            let byte_count: i64 = row.try_get("byte_count")?;
            let bytes: Vec<u8> = row.try_get("bytes")?;
            state.objects.insert(
                object_id.clone(),
                ObjectRecord {
                    object_id,
                    byte_count: byte_count as usize,
                    bytes: Bytes::from(bytes),
                },
            );
        }
        for row in sqlx::query("SELECT snapshot_id, manifest FROM snapshots")
            .fetch_all(&pool)
            .await?
        {
            let snapshot_id: String = row.try_get("snapshot_id")?;
            let value: serde_json::Value = row.try_get("manifest")?;
            state.snapshots.insert(
                snapshot_id,
                serde_json::from_value(value)
                    .map_err(|error| sqlx::Error::Decode(Box::new(error)))?,
            );
        }
        for row in sqlx::query(
            "SELECT operation_id, kind, request_sha256, result, created_at FROM operations",
        )
        .fetch_all(&pool)
        .await?
        {
            let operation_id: Uuid = row.try_get("operation_id")?;
            state.operations.insert(
                operation_id,
                OperationReceipt {
                    operation_id,
                    kind: row.try_get("kind")?,
                    request_sha256: row.try_get("request_sha256")?,
                    result: row.try_get("result")?,
                    created_at: row.try_get("created_at")?,
                },
            );
        }
        for row in sqlx::query("SELECT conflict_id, work_id, base_snapshot_id, local_snapshot_id, remote_snapshot_id, state, created_at FROM conflicts")
            .fetch_all(&pool)
            .await?
        {
            let conflict_id: Uuid = row.try_get("conflict_id")?;
            state.conflicts.insert(conflict_id, ConflictRecord {
                conflict_id,
                work_id: row.try_get("work_id")?,
                base_snapshot_id: row.try_get("base_snapshot_id")?,
                local_snapshot_id: row.try_get("local_snapshot_id")?,
                remote_snapshot_id: row.try_get("remote_snapshot_id")?,
                state: row.try_get("state")?,
                created_at: row.try_get("created_at")?,
            });
        }
        for row in sqlx::query(
            "SELECT challenge_id, state, nonce, expires_at, consumed FROM auth_challenges",
        )
        .fetch_all(&pool)
        .await?
        {
            let challenge_id: Uuid = row.try_get("challenge_id")?;
            state.auth_challenges.insert(
                challenge_id,
                AuthChallenge {
                    state: row.try_get("state")?,
                    nonce: row.try_get("nonce")?,
                    expires_at: row.try_get("expires_at")?,
                    consumed: row.try_get("consumed")?,
                },
            );
        }
        for row in
            sqlx::query("SELECT account_id, issuer, subject_hash, auth_epoch, fence FROM accounts")
                .fetch_all(&pool)
                .await?
        {
            let account_id: String = row.try_get("account_id")?;
            state.accounts.insert(
                account_id.clone(),
                AccountRecord {
                    account_id,
                    issuer: row.try_get("issuer")?,
                    subject_hash: row.try_get("subject_hash")?,
                    auth_epoch: row.try_get::<i64, _>("auth_epoch")? as u64,
                    fence: row.try_get("fence")?,
                },
            );
        }
        for row in sqlx::query("SELECT account_id, client_id, refresh_token_ciphertext, created_at FROM provider_credentials")
            .fetch_all(&pool)
            .await?
        {
            let account_id: String = row.try_get("account_id")?;
            let client_id: String = row.try_get("client_id")?;
            state.provider_credentials.insert((account_id.clone(), client_id.clone()), ProviderCredential {
                account_id,
                client_id,
                refresh_token_ciphertext: row.try_get("refresh_token_ciphertext")?,
                created_at: row.try_get("created_at")?,
            });
        }
        for row in sqlx::query(
            "SELECT access_token_hash, account_id, auth_epoch, fence, refresh_family_id, expires_at, revoked FROM auth_sessions",
        )
        .fetch_all(&pool)
        .await?
        {
            let access_token_hash: String = row.try_get("access_token_hash")?;
            state.auth_sessions.insert(
                access_token_hash,
                AuthSession {
                    account_id: row.try_get("account_id")?,
                    auth_epoch: row.try_get::<i64, _>("auth_epoch")? as u64,
                    fence: row.try_get("fence")?,
                    refresh_family_id: row.try_get("refresh_family_id")?,
                    expires_at: row.try_get("expires_at")?,
                    revoked: row.try_get("revoked")?,
                },
            );
        }
        for row in sqlx::query(
            "SELECT family_id, account_id, current_token_hash, generation, last_rotation_id, last_response, revoked FROM refresh_token_families",
        )
        .fetch_all(&pool)
        .await?
        {
            let family_id: Uuid = row.try_get("family_id")?;
            state.refresh_families.insert(
                family_id,
                RefreshTokenFamily {
                    family_id,
                    account_id: row.try_get("account_id")?,
                    current_token_hash: row.try_get("current_token_hash")?,
                    generation: row.try_get::<i64, _>("generation")? as u64,
                    last_rotation_id: row.try_get("last_rotation_id")?,
                    last_response: row.try_get("last_response")?,
                    revoked: row.try_get("revoked")?,
                },
            );
        }
        Ok(state)
    }
}

#[derive(Clone, Debug)]
pub struct ProviderCredential {
    pub account_id: String,
    pub client_id: String,
    pub refresh_token_ciphertext: String,
    pub created_at: DateTime<Utc>,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct AuthSession {
    pub account_id: String,
    pub auth_epoch: u64,
    pub fence: String,
    pub refresh_family_id: Uuid,
    pub expires_at: DateTime<Utc>,
    pub revoked: bool,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct RefreshTokenFamily {
    pub family_id: Uuid,
    pub account_id: String,
    pub current_token_hash: String,
    pub generation: u64,
    pub last_rotation_id: Option<Uuid>,
    pub last_response: Option<serde_json::Value>,
    pub revoked: bool,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct AuthenticatedPrincipal {
    pub account_id: String,
    pub auth_epoch: u64,
    pub fence: String,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Head {
    pub generation: u64,
    pub snapshot_id: String,
}

/// Lightweight server catalog projection used by the startup shelf. The
/// immutable snapshot manifest remains the source of the title; this row is
/// only a discoverability hint and is never used for conflict decisions.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct WorkCatalogEntry {
    #[serde(rename = "workId")]
    pub work_id: Uuid,
    pub title: String,
    pub head: Option<Head>,
}

#[derive(Clone, Debug, Default)]
pub struct WorkRecord {
    pub work_id: Uuid,
    pub head: Option<Head>,
}

#[derive(Clone, Debug)]
pub struct ObjectRecord {
    pub object_id: String,
    pub byte_count: usize,
    pub bytes: Bytes,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct SnapshotManifest {
    #[serde(rename = "schemaVersion")]
    pub schema_version: u64,
    #[serde(rename = "workId")]
    pub work_id: Uuid,
    #[serde(rename = "parentSnapshotIds")]
    pub parent_snapshot_ids: Vec<String>,
    pub entries: Vec<SnapshotEntry>,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct SnapshotEntry {
    #[serde(rename = "entityKey")]
    pub entity_key: String,
    #[serde(rename = "objectId")]
    pub object_id: String,
    #[serde(rename = "byteCount")]
    pub byte_count: usize,
    #[serde(rename = "contentType")]
    pub content_type: String,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct PublishCommand {
    #[serde(rename = "operationId")]
    pub operation_id: Uuid,
    #[serde(rename = "workId")]
    pub work_id: Uuid,
    #[serde(rename = "expectedHead")]
    pub expected_head: Option<Head>,
    #[serde(rename = "candidateSnapshotId")]
    pub candidate_snapshot_id: String,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct PublishResult {
    pub receipt: OperationReceipt,
    pub head: Head,
    pub replayed: bool,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct OperationReceipt {
    #[serde(rename = "operationId")]
    pub operation_id: Uuid,
    pub kind: String,
    pub request_sha256: String,
    pub result: serde_json::Value,
    pub created_at: DateTime<Utc>,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct ConflictRecord {
    pub conflict_id: Uuid,
    pub work_id: Uuid,
    pub base_snapshot_id: Option<String>,
    pub local_snapshot_id: String,
    pub remote_snapshot_id: String,
    pub state: String,
    pub created_at: DateTime<Utc>,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct ResolveConflictCommand {
    #[serde(rename = "operationId")]
    pub operation_id: Uuid,
    pub choice: String,
    #[serde(rename = "expectedRemoteSnapshotId")]
    pub expected_remote_snapshot_id: String,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Capabilities {
    pub server_instance_id: Uuid,
    pub protocol_epoch: u64,
    pub content_protection_profile: &'static str,
    pub e2ee: bool,
    pub account_id: String,
    pub account_auth_epoch: u64,
    pub account_fence: String,
    pub providers: Vec<&'static str>,
}

#[derive(Clone, Debug)]
pub struct AuthChallenge {
    pub state: String,
    pub nonce: String,
    pub expires_at: DateTime<Utc>,
    pub consumed: bool,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct AuthChallengeResponse {
    #[serde(rename = "challengeId")]
    pub challenge_id: Uuid,
    pub state: String,
    pub nonce: String,
    #[serde(rename = "expiresAt")]
    pub expires_at: DateTime<Utc>,
    pub provider: String,
    pub flow: String,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct AccountRecord {
    pub account_id: String,
    pub issuer: String,
    pub subject_hash: String,
    pub auth_epoch: u64,
    pub fence: String,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct AppleExchangeRequest {
    #[serde(rename = "operationId")]
    pub operation_id: Uuid,
    pub provider: String,
    pub state: String,
    #[serde(rename = "authorizationCode")]
    pub authorization_code: String,
    #[serde(rename = "identityToken")]
    pub identity_token: String,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct AuthTokenResponse {
    #[serde(rename = "accessToken")]
    pub access_token: String,
    #[serde(rename = "refreshToken")]
    pub refresh_token: String,
    #[serde(rename = "accountId")]
    pub account_id: String,
    #[serde(rename = "accountAuthEpoch")]
    pub account_auth_epoch: u64,
    #[serde(rename = "accountFence")]
    pub account_fence: String,
    #[serde(rename = "refreshGeneration")]
    pub refresh_generation: u64,
}

#[derive(Clone, Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct RefreshRequest {
    #[serde(rename = "rotationId")]
    pub rotation_id: Uuid,
}

#[derive(Clone, Debug, Serialize)]
pub struct RevokeResponse {
    pub revoked: bool,
}

#[derive(Clone, Debug)]
struct AppleExchangeResult {
    identity: AppleIdentity,
    client_id: String,
    refresh_token: String,
}

#[derive(Debug, Error)]
pub enum ApiError {
    #[error("unauthorized")]
    Unauthorized,
    #[error("not found: {0}")]
    NotFound(String),
    #[error("invalid request: {0}")]
    InvalidRequest(String),
    #[error("conflict: {0}")]
    Conflict(String),
    #[error("payload too large")]
    PayloadTooLarge,
    #[error("upstream Apple authentication is not configured")]
    AppleNotConfigured,
    #[error("Apple authentication failed")]
    AppleAuthenticationFailed,
    #[error("internal error")]
    Internal,
}

impl IntoResponse for ApiError {
    fn into_response(self) -> Response {
        let (status, code) = match self {
            Self::Unauthorized => (StatusCode::UNAUTHORIZED, "unauthorized"),
            Self::NotFound(_) => (StatusCode::NOT_FOUND, "notFound"),
            Self::InvalidRequest(_) => (StatusCode::UNPROCESSABLE_ENTITY, "invalidRequest"),
            Self::Conflict(_) => (StatusCode::CONFLICT, "headConflict"),
            Self::PayloadTooLarge => (StatusCode::PAYLOAD_TOO_LARGE, "payloadTooLarge"),
            Self::AppleNotConfigured => (StatusCode::SERVICE_UNAVAILABLE, "appleNotConfigured"),
            Self::AppleAuthenticationFailed => {
                (StatusCode::UNAUTHORIZED, "appleAuthenticationFailed")
            }
            Self::Internal => (StatusCode::INTERNAL_SERVER_ERROR, "internalError"),
        };
        let body = Json(serde_json::json!({
            "code": code,
            "message": self.to_string(),
            "retryability": if matches!(self, Self::Conflict(_) | Self::AppleNotConfigured) { "retryable" } else { "never" }
        }));
        (status, body).into_response()
    }
}

pub fn router(state: SharedState, config: AppConfig) -> Router {
    Router::new()
        .route("/health", get(health))
        .route("/v1/auth/capabilities", get(auth_capabilities))
        .route("/v1/auth/challenges", post(create_auth_challenge))
        .route("/v1/auth/challenges/{challenge_path}", post(exchange_apple))
        .route("/v1/auth/tokens:refresh", post(refresh_session))
        .route("/v1/auth/session:revoke", post(revoke_session))
        .route("/v1/capabilities", get(capabilities))
        .route("/v1/works", get(list_works))
        .route(
            "/v1/objects/{object_id}",
            get(download_object).put(upload_object),
        )
        .route(
            "/v1/works/{work_id}/snapshots/{snapshot_id}",
            get(get_snapshot).put(register_snapshot),
        )
        .route("/v1/works/{work_id}/head", get(get_head).post(publish_head))
        .route("/v1/works/{work_id}/conflicts", get(list_conflicts))
        .route(
            "/v1/works/{work_id}/conflicts/{conflict_id}/resolve",
            post(resolve_conflict),
        )
        .with_state((state, Arc::new(config)))
}

type HandlerState = (SharedState, Arc<AppConfig>);

async fn health() -> Json<serde_json::Value> {
    Json(serde_json::json!({"status":"ok","service":"fuminiwa-sync-server"}))
}

async fn auth_capabilities() -> Json<serde_json::Value> {
    Json(serde_json::json!({
        "authProtocolVersion": 1,
        "providers": ["apple"],
        "supportedFlows": ["native"],
        "e2ee": false,
        "contentProtectionProfile": "serverReadableV1"
    }))
}

async fn create_auth_challenge(
    State((state, _config)): State<HandlerState>,
) -> Result<(HeaderMap, Json<AuthChallengeResponse>), ApiError> {
    let challenge_id = Uuid::new_v4();
    let state_value = random_secret();
    let nonce = random_secret();
    let expires_at = Utc::now() + chrono::Duration::seconds(300);
    let mut locked = state.write().await;
    locked.auth_challenges.insert(
        challenge_id,
        AuthChallenge {
            state: state_value.clone(),
            nonce: nonce.clone(),
            expires_at,
            consumed: false,
        },
    );
    persist_state(&locked).await?;
    let mut headers = HeaderMap::new();
    headers.insert("cache-control", "no-store".parse().unwrap());
    headers.insert("pragma", "no-cache".parse().unwrap());
    Ok((
        headers,
        Json(AuthChallengeResponse {
            challenge_id,
            state: state_value,
            nonce,
            expires_at,
            provider: "apple".into(),
            flow: "native".into(),
        }),
    ))
}

async fn exchange_apple(
    State((state, config)): State<HandlerState>,
    Path(challenge_path): Path<String>,
    Json(request): Json<AppleExchangeRequest>,
) -> Result<(HeaderMap, Json<AuthTokenResponse>), ApiError> {
    let challenge_id = challenge_path
        .strip_suffix(":exchange")
        .ok_or_else(|| ApiError::NotFound("challenge exchange".into()))?
        .parse::<Uuid>()
        .map_err(|_| ApiError::NotFound("challenge".into()))?;
    if request.provider != "apple" {
        return Err(ApiError::InvalidRequest("provider must be apple".into()));
    }
    if !config.apple.is_configured() {
        return Err(ApiError::AppleNotConfigured);
    }
    let request_hash = digest(&serde_json::to_vec(&request).map_err(|_| ApiError::Internal)?);
    {
        let locked = state.read().await;
        if let Some(receipt) = locked.operations.get(&request.operation_id) {
            if receipt.kind != "appleExchange" || receipt.request_sha256 != request_hash {
                return Err(ApiError::Conflict(
                    "operationId was reused with a different request".into(),
                ));
            }
            let response: AuthTokenResponse =
                serde_json::from_value(receipt.result.clone()).map_err(|_| ApiError::Internal)?;
            let mut headers = HeaderMap::new();
            headers.insert("cache-control", "no-store".parse().unwrap());
            headers.insert("pragma", "no-cache".parse().unwrap());
            return Ok((headers, Json(response)));
        }
    }
    let mut locked = state.write().await;
    let challenge = locked
        .auth_challenges
        .get_mut(&challenge_id)
        .ok_or_else(|| ApiError::NotFound("challenge".into()))?;
    if challenge.consumed || challenge.expires_at < Utc::now() || challenge.state != request.state {
        return Err(ApiError::AppleAuthenticationFailed);
    }
    challenge.consumed = true;
    let expected_nonce = challenge.nonce.clone();
    drop(locked);

    let exchange = verify_apple_identity(&config.apple, &request, &expected_nonce).await?;
    let mut locked = state.write().await;
    let subject_hash = digest(exchange.identity.subject.as_bytes());
    let account_id = format!("acct_{}", &subject_hash[..24]);
    let (resolved_account_id, account_auth_epoch, account_fence) = {
        let account = locked
            .accounts
            .entry(account_id.clone())
            .or_insert_with(|| AccountRecord {
                account_id: account_id.clone(),
                issuer: exchange.identity.issuer.clone(),
                subject_hash: subject_hash.clone(),
                auth_epoch: 1,
                fence: format!("fence_{}", random_secret()),
            });
        (
            account.account_id.clone(),
            account.auth_epoch,
            account.fence.clone(),
        )
    };
    let ciphertext = encrypt_secret(
        &exchange.refresh_token,
        config
            .apple
            .vault_key
            .as_deref()
            .ok_or(ApiError::AppleNotConfigured)?,
    )?;
    locked.provider_credentials.insert(
        (resolved_account_id.clone(), exchange.client_id.clone()),
        ProviderCredential {
            account_id: resolved_account_id.clone(),
            client_id: exchange.client_id,
            refresh_token_ciphertext: ciphertext,
            created_at: Utc::now(),
        },
    );
    let response = issue_session(
        &mut locked,
        resolved_account_id,
        account_auth_epoch,
        account_fence,
    );
    let body = serde_json::to_value(&response).map_err(|_| ApiError::Internal)?;
    locked.operations.insert(
        request.operation_id,
        OperationReceipt {
            operation_id: request.operation_id,
            kind: "appleExchange".into(),
            request_sha256: request_hash,
            result: body.clone(),
            created_at: Utc::now(),
        },
    );
    persist_state(&locked).await?;
    let mut headers = HeaderMap::new();
    headers.insert("cache-control", "no-store".parse().unwrap());
    headers.insert("pragma", "no-cache".parse().unwrap());
    Ok((headers, Json(response)))
}

async fn refresh_session(
    State((state, _config)): State<HandlerState>,
    headers: HeaderMap,
    Json(request): Json<RefreshRequest>,
) -> Result<(HeaderMap, Json<AuthTokenResponse>), ApiError> {
    let token = bearer_token(&headers).ok_or(ApiError::Unauthorized)?;
    if !token.starts_with("fmr_") {
        return Err(ApiError::Unauthorized);
    }
    let token_hash = digest(token.as_bytes());
    let mut locked = state.write().await;
    let family_id = locked
        .refresh_families
        .iter()
        .find_map(|(id, family)| (family.current_token_hash == token_hash).then_some(*id));
    let Some(family_id) = family_id else {
        // A rotated token is not accepted as a new rotation. This is the
        // replay-detection boundary; the family is revoked conservatively.
        for family in locked.refresh_families.values_mut() {
            if family.last_rotation_id == Some(request.rotation_id) {
                if let Some(response) = family.last_response.clone() {
                    let token_response: AuthTokenResponse =
                        serde_json::from_value(response).map_err(|_| ApiError::Internal)?;
                    let mut response_headers = HeaderMap::new();
                    response_headers.insert("cache-control", "no-store".parse().unwrap());
                    response_headers.insert("pragma", "no-cache".parse().unwrap());
                    return Ok((response_headers, Json(token_response)));
                }
            }
        }
        return Err(ApiError::Unauthorized);
    };
    let family = locked
        .refresh_families
        .get(&family_id)
        .cloned()
        .ok_or(ApiError::Unauthorized)?;
    if family.revoked {
        return Err(ApiError::Unauthorized);
    }
    if family.last_rotation_id == Some(request.rotation_id) {
        if let Some(response) = family.last_response.clone() {
            let token_response: AuthTokenResponse =
                serde_json::from_value(response).map_err(|_| ApiError::Internal)?;
            let mut response_headers = HeaderMap::new();
            response_headers.insert("cache-control", "no-store".parse().unwrap());
            response_headers.insert("pragma", "no-cache".parse().unwrap());
            return Ok((response_headers, Json(token_response)));
        }
    }
    let account = locked
        .accounts
        .get(&family.account_id)
        .cloned()
        .ok_or(ApiError::Unauthorized)?;
    let response = rotate_session(
        &mut locked,
        family_id,
        account.account_id,
        account.auth_epoch,
        account.fence,
        family.generation + 1,
    );
    let new_hash = digest(response.refresh_token.as_bytes());
    let previous_family = locked
        .refresh_families
        .get_mut(&family_id)
        .ok_or(ApiError::Internal)?;
    previous_family.current_token_hash = new_hash;
    previous_family.generation = response.refresh_generation;
    previous_family.last_rotation_id = Some(request.rotation_id);
    previous_family.last_response =
        Some(serde_json::to_value(&response).map_err(|_| ApiError::Internal)?);
    persist_state(&locked).await?;
    let mut response_headers = HeaderMap::new();
    response_headers.insert("cache-control", "no-store".parse().unwrap());
    response_headers.insert("pragma", "no-cache".parse().unwrap());
    Ok((response_headers, Json(response)))
}

async fn revoke_session(
    State((state, _config)): State<HandlerState>,
    headers: HeaderMap,
) -> Result<Json<RevokeResponse>, ApiError> {
    let token = bearer_token(&headers).ok_or(ApiError::Unauthorized)?;
    let token_hash = digest(token.as_bytes());
    let mut locked = state.write().await;
    let family_id = locked
        .refresh_families
        .iter()
        .find_map(|(id, family)| (family.current_token_hash == token_hash).then_some(*id));
    let Some(family_id) = family_id else {
        return Err(ApiError::Unauthorized);
    };
    if let Some(family) = locked.refresh_families.get_mut(&family_id) {
        family.revoked = true;
    }
    for session in locked.auth_sessions.values_mut() {
        if session.refresh_family_id == family_id {
            session.revoked = true;
        }
    }
    persist_state(&locked).await?;
    Ok(Json(RevokeResponse { revoked: true }))
}

async fn capabilities(
    State((state, config)): State<HandlerState>,
    headers: HeaderMap,
) -> Result<Json<Capabilities>, ApiError> {
    let principal = authenticate_bearer(&state, &headers, &config).await?;
    Ok(Json(Capabilities {
        server_instance_id: config.server_instance_id,
        protocol_epoch: config.protocol_epoch,
        content_protection_profile: "serverReadableV1",
        e2ee: false,
        account_id: principal.account_id,
        account_auth_epoch: principal.auth_epoch,
        account_fence: principal.fence,
        providers: vec!["apple"],
    }))
}

async fn upload_object(
    State((state, config)): State<HandlerState>,
    headers: HeaderMap,
    Path(object_id): Path<String>,
    body: Bytes,
) -> Result<Json<serde_json::Value>, ApiError> {
    let _principal = authenticate_bearer(&state, &headers, &config).await?;
    if body.len() > MAX_OBJECT_BYTES {
        return Err(ApiError::PayloadTooLarge);
    }
    if digest(&body) != object_id {
        return Err(ApiError::InvalidRequest(
            "objectId does not match SHA-256(bytes)".into(),
        ));
    }
    let mut locked = state.write().await;
    if let Some(existing) = locked.objects.get(&object_id) {
        if existing.byte_count != body.len() || existing.bytes != body {
            return Err(ApiError::Conflict(
                "object bytes differ for existing objectId".into(),
            ));
        }
        return Ok(Json(
            serde_json::json!({"objectId":object_id,"byteCount":body.len(),"alreadyAvailable":true}),
        ));
    }
    locked.objects.insert(
        object_id.clone(),
        ObjectRecord {
            object_id: object_id.clone(),
            byte_count: body.len(),
            bytes: body.clone(),
        },
    );
    persist_state(&locked).await?;
    Ok(Json(
        serde_json::json!({"objectId":object_id,"byteCount":body.len(),"alreadyAvailable":false}),
    ))
}

async fn download_object(
    State((state, config)): State<HandlerState>,
    headers: HeaderMap,
    Path(object_id): Path<String>,
) -> Result<Response, ApiError> {
    let _principal = authenticate_bearer(&state, &headers, &config).await?;
    let object = state
        .read()
        .await
        .objects
        .get(&object_id)
        .cloned()
        .ok_or_else(|| ApiError::NotFound("object".into()))?;
    let mut response = Response::new(object.bytes.into_response().into_body());
    *response.status_mut() = StatusCode::OK;
    response.headers_mut().insert(
        header::CONTENT_TYPE,
        "application/octet-stream"
            .parse()
            .expect("static content type"),
    );
    response.headers_mut().insert(
        header::CONTENT_LENGTH,
        object
            .byte_count
            .to_string()
            .parse()
            .expect("content length is numeric"),
    );
    Ok(response)
}

async fn register_snapshot(
    State((state, config)): State<HandlerState>,
    headers: HeaderMap,
    Path((work_id, snapshot_id)): Path<(Uuid, String)>,
    body: Bytes,
) -> Result<Json<serde_json::Value>, ApiError> {
    let _principal = authenticate_bearer(&state, &headers, &config).await?;
    if body.len() > MAX_MANIFEST_BYTES {
        return Err(ApiError::PayloadTooLarge);
    }
    let manifest: SnapshotManifest = parse_json(&body)?;
    if manifest.work_id != work_id {
        return Err(ApiError::InvalidRequest("workId path/body mismatch".into()));
    }
    let expected_id = digest(&body);
    if expected_id != snapshot_id {
        return Err(ApiError::InvalidRequest(
            "snapshotId must be SHA-256(canonical manifest bytes)".into(),
        ));
    }
    validate_manifest(&manifest, &state).await?;
    let mut locked = state.write().await;
    if let Some(existing) = locked.snapshots.get(&snapshot_id) {
        // Compare the decoded canonical model, not re-serialized bytes. A
        // retry from another language may use a different JSON member order
        // while representing the exact same manifest.
        if existing.work_id != work_id || existing != &manifest {
            return Err(ApiError::Conflict(
                "snapshotId already contains different bytes".into(),
            ));
        }
        return Ok(Json(
            serde_json::json!({"snapshotId":snapshot_id,"alreadyRegistered":true}),
        ));
    }
    locked.snapshots.insert(snapshot_id.clone(), manifest);
    locked.works.entry(work_id).or_insert_with(|| WorkRecord {
        work_id,
        head: None,
    });
    persist_state(&locked).await?;
    Ok(Json(
        serde_json::json!({"snapshotId":snapshot_id,"alreadyRegistered":false}),
    ))
}

async fn get_snapshot(
    State((state, config)): State<HandlerState>,
    headers: HeaderMap,
    Path((work_id, snapshot_id)): Path<(Uuid, String)>,
) -> Result<Json<SnapshotManifest>, ApiError> {
    let _principal = authenticate_bearer(&state, &headers, &config).await?;
    let manifest = state
        .read()
        .await
        .snapshots
        .get(&snapshot_id)
        .cloned()
        .ok_or_else(|| ApiError::NotFound("snapshot".into()))?;
    if manifest.work_id != work_id {
        return Err(ApiError::NotFound("snapshot".into()));
    }
    Ok(Json(manifest))
}

async fn list_works(
    State((state, config)): State<HandlerState>,
    headers: HeaderMap,
) -> Result<Json<Vec<WorkCatalogEntry>>, ApiError> {
    let _principal = authenticate_bearer(&state, &headers, &config).await?;
    let locked = state.read().await;
    let mut entries = locked
        .works
        .values()
        .map(|work| WorkCatalogEntry {
            work_id: work.work_id,
            title: work
                .head
                .as_ref()
                .and_then(|head| locked.snapshots.get(&head.snapshot_id))
                .and_then(|manifest| {
                    manifest
                        .entries
                        .iter()
                        .find(|entry| entry.entity_key == "work/document")
                })
                .and_then(|entry| locked.objects.get(&entry.object_id))
                .and_then(|object| serde_json::from_slice::<serde_json::Value>(&object.bytes).ok())
                .and_then(|value| {
                    value
                        .get("title")
                        .and_then(serde_json::Value::as_str)
                        .map(ToOwned::to_owned)
                })
                .filter(|title| !title.trim().is_empty())
                .unwrap_or_else(|| "名称未設定の作品".to_owned()),
            head: work.head.clone(),
        })
        .collect::<Vec<_>>();
    entries.sort_by(|left, right| left.work_id.cmp(&right.work_id));
    Ok(Json(entries))
}

async fn get_head(
    State((state, config)): State<HandlerState>,
    headers: HeaderMap,
    Path(work_id): Path<Uuid>,
) -> Result<Json<Option<Head>>, ApiError> {
    let _principal = authenticate_bearer(&state, &headers, &config).await?;
    Ok(Json(
        state
            .read()
            .await
            .works
            .get(&work_id)
            .and_then(|work| work.head.clone()),
    ))
}

async fn publish_head(
    State((state, config)): State<HandlerState>,
    headers: HeaderMap,
    Path(work_id): Path<Uuid>,
    Json(command): Json<PublishCommand>,
) -> Result<Json<PublishResult>, ApiError> {
    let _principal = authenticate_bearer(&state, &headers, &config).await?;
    if command.work_id != work_id {
        return Err(ApiError::InvalidRequest("workId path/body mismatch".into()));
    }
    let request_bytes = serde_json::to_vec(&command).map_err(|_| ApiError::Internal)?;
    let request_hash = digest(&request_bytes);
    let mut locked = state.write().await;
    if let Some(receipt) = locked.operations.get(&command.operation_id) {
        if receipt.request_sha256 != request_hash || receipt.kind != "publishHead" {
            return Err(ApiError::Conflict(
                "operationId was reused with a different request".into(),
            ));
        }
        let result: PublishResult =
            serde_json::from_value(receipt.result.clone()).map_err(|_| ApiError::Internal)?;
        return Ok(Json(PublishResult {
            replayed: true,
            ..result
        }));
    }
    let candidate = locked
        .snapshots
        .get(&command.candidate_snapshot_id)
        .ok_or_else(|| ApiError::NotFound("candidate snapshot".into()))?;
    if candidate.work_id != work_id {
        return Err(ApiError::InvalidRequest(
            "candidate belongs to another work".into(),
        ));
    }
    let current = locked
        .works
        .get(&work_id)
        .and_then(|work| work.head.clone());
    if current != command.expected_head {
        // A client may retry the same blocked intent many times while the
        // user has not chosen a branch yet. Keep one durable ConflictRecord
        // for the same divergence instead of creating a new record on every
        // retry; the conflict ID is the stable UI handle.
        if let Some(existing) = locked.conflicts.values().find(|conflict| {
            conflict.work_id == work_id
                && conflict.state == "needsChoice"
                && conflict.base_snapshot_id
                    == command
                        .expected_head
                        .as_ref()
                        .map(|head| head.snapshot_id.clone())
                && conflict.local_snapshot_id == command.candidate_snapshot_id
                && conflict.remote_snapshot_id
                    == current
                        .as_ref()
                        .map(|head| head.snapshot_id.clone())
                        .unwrap_or_default()
        }) {
            return Err(ApiError::Conflict(format!(
                "head advanced; conflictId={}",
                existing.conflict_id
            )));
        }
        let conflict_id = Uuid::new_v4();
        locked.conflicts.insert(
            conflict_id,
            ConflictRecord {
                conflict_id,
                work_id,
                base_snapshot_id: command
                    .expected_head
                    .as_ref()
                    .map(|head| head.snapshot_id.clone()),
                local_snapshot_id: command.candidate_snapshot_id.clone(),
                remote_snapshot_id: current
                    .as_ref()
                    .map(|head| head.snapshot_id.clone())
                    .unwrap_or_default(),
                state: "needsChoice".into(),
                created_at: Utc::now(),
            },
        );
        persist_state(&locked).await?;
        return Err(ApiError::Conflict(format!(
            "head advanced; conflictId={conflict_id}"
        )));
    }
    let work = locked.works.entry(work_id).or_insert_with(|| WorkRecord {
        work_id,
        head: None,
    });
    let next_generation = work.head.as_ref().map_or(1, |head| head.generation + 1);
    let head = Head {
        generation: next_generation,
        snapshot_id: command.candidate_snapshot_id.clone(),
    };
    work.head = Some(head.clone());
    for conflict in locked.conflicts.values_mut() {
        if conflict.work_id == work_id
            && conflict.state == "needsChoice"
            && conflict.local_snapshot_id == command.candidate_snapshot_id
        {
            conflict.state = "resolved".into();
        }
    }
    let result = PublishResult {
        receipt: OperationReceipt {
            operation_id: command.operation_id,
            kind: "publishHead".into(),
            request_sha256: request_hash,
            result: serde_json::Value::Null,
            created_at: Utc::now(),
        },
        head: head.clone(),
        replayed: false,
    };
    let result_value = serde_json::to_value(&result).map_err(|_| ApiError::Internal)?;
    let receipt = OperationReceipt {
        result: result_value.clone(),
        ..result.receipt.clone()
    };
    locked.operations.insert(command.operation_id, receipt);
    persist_state(&locked).await?;
    Ok(Json(result))
}

async fn list_conflicts(
    State((state, config)): State<HandlerState>,
    headers: HeaderMap,
    Path(work_id): Path<Uuid>,
) -> Result<Json<Vec<ConflictRecord>>, ApiError> {
    let _principal = authenticate_bearer(&state, &headers, &config).await?;
    let mut conflicts: Vec<ConflictRecord> = state
        .read()
        .await
        .conflicts
        .values()
        .filter(|conflict| conflict.work_id == work_id && conflict.state == "needsChoice")
        .cloned()
        .collect();
    conflicts.sort_by(|left, right| {
        left.created_at
            .cmp(&right.created_at)
            .then_with(|| left.conflict_id.cmp(&right.conflict_id))
    });
    let mut seen = HashSet::new();
    conflicts.retain(|conflict| {
        seen.insert((
            conflict.base_snapshot_id.clone(),
            conflict.local_snapshot_id.clone(),
            conflict.remote_snapshot_id.clone(),
        ))
    });
    Ok(Json(conflicts))
}

async fn resolve_conflict(
    State((state, config)): State<HandlerState>,
    headers: HeaderMap,
    Path((work_id, conflict_id)): Path<(Uuid, Uuid)>,
    Json(command): Json<ResolveConflictCommand>,
) -> Result<Json<serde_json::Value>, ApiError> {
    let _principal = authenticate_bearer(&state, &headers, &config).await?;
    if command.choice != "useOnline" && command.choice != "keepBothAsSeparateWorks" {
        return Err(ApiError::InvalidRequest(
            "unsupported conflict choice".into(),
        ));
    }
    let request_bytes = serde_json::to_vec(&command).map_err(|_| ApiError::Internal)?;
    let request_hash = digest(&request_bytes);
    let mut locked = state.write().await;
    if let Some(receipt) = locked.operations.get(&command.operation_id) {
        if receipt.request_sha256 != request_hash || receipt.kind != "resolveConflict" {
            return Err(ApiError::Conflict(
                "operationId was reused with a different request".into(),
            ));
        }
        return Ok(Json(receipt.result.clone()));
    }
    let conflict_work_id = locked
        .conflicts
        .get(&conflict_id)
        .map(|conflict| conflict.work_id)
        .ok_or_else(|| ApiError::NotFound("conflict".into()))?;
    if conflict_work_id != work_id {
        return Err(ApiError::NotFound("conflict".into()));
    }
    if locked
        .conflicts
        .get(&conflict_id)
        .map(|conflict| conflict.state.as_str())
        != Some("needsChoice")
    {
        return Err(ApiError::Conflict("conflict already resolved".into()));
    }
    let current_head = locked
        .works
        .get(&work_id)
        .and_then(|work| work.head.clone())
        .ok_or_else(|| ApiError::NotFound("work head".into()))?;
    if current_head.snapshot_id != command.expected_remote_snapshot_id {
        return Err(ApiError::Conflict("remote head moved".into()));
    }
    locked
        .conflicts
        .get_mut(&conflict_id)
        .ok_or_else(|| ApiError::NotFound("conflict".into()))?
        .state = "resolved".into();
    let result = serde_json::json!({
        "outcome": "resolved",
        "choice": command.choice,
        "conflictId": conflict_id,
        "head": current_head,
        "operationId": command.operation_id,
    });
    locked.operations.insert(
        command.operation_id,
        OperationReceipt {
            operation_id: command.operation_id,
            kind: "resolveConflict".into(),
            request_sha256: request_hash,
            result: result.clone(),
            created_at: Utc::now(),
        },
    );
    persist_state(&locked).await?;
    Ok(Json(result))
}

async fn validate_manifest(
    manifest: &SnapshotManifest,
    state: &SharedState,
) -> Result<(), ApiError> {
    if manifest.schema_version != 1 || manifest.entries.is_empty() {
        return Err(ApiError::InvalidRequest(
            "unsupported or empty snapshot manifest".into(),
        ));
    }
    let keys = manifest
        .entries
        .iter()
        .map(|entry| entry.entity_key.clone())
        .collect::<Vec<_>>();
    let mut sorted = keys.clone();
    sorted.sort();
    sorted.dedup();
    if sorted != keys {
        return Err(ApiError::InvalidRequest(
            "entries must be sorted and unique by entityKey".into(),
        ));
    }
    let locked = state.read().await;
    for entry in &manifest.entries {
        let object = locked.objects.get(&entry.object_id).ok_or_else(|| {
            ApiError::InvalidRequest(format!("missing object {}", entry.object_id))
        })?;
        if object.byte_count != entry.byte_count {
            return Err(ApiError::InvalidRequest(
                "entry byteCount does not match object".into(),
            ));
        }
    }
    for parent in &manifest.parent_snapshot_ids {
        if !locked.snapshots.contains_key(parent) {
            return Err(ApiError::InvalidRequest(format!(
                "missing parent snapshot {parent}"
            )));
        }
    }
    Ok(())
}

fn bearer_token(headers: &HeaderMap) -> Option<&str> {
    headers
        .get("authorization")
        .and_then(|value| value.to_str().ok())
        .and_then(|value| value.strip_prefix("Bearer "))
}

async fn authenticate_bearer(
    state: &SharedState,
    headers: &HeaderMap,
    config: &AppConfig,
) -> Result<AuthenticatedPrincipal, ApiError> {
    let token = bearer_token(headers).ok_or(ApiError::Unauthorized)?;
    if config.dev_token.as_deref() == Some(token) {
        return Ok(AuthenticatedPrincipal {
            account_id: "dev-account".into(),
            auth_epoch: 1,
            fence: "dev-fence".into(),
        });
    }
    let session = state
        .read()
        .await
        .auth_sessions
        .get(&digest(token.as_bytes()))
        .cloned()
        .ok_or(ApiError::Unauthorized)?;
    if session.revoked || session.expires_at <= Utc::now() {
        return Err(ApiError::Unauthorized);
    }
    Ok(AuthenticatedPrincipal {
        account_id: session.account_id,
        auth_epoch: session.auth_epoch,
        fence: session.fence,
    })
}

fn parse_json<T: DeserializeOwned>(body: &[u8]) -> Result<T, ApiError> {
    serde_json::from_slice(body).map_err(|error| ApiError::InvalidRequest(error.to_string()))
}

fn digest(bytes: &[u8]) -> String {
    let mut hasher = Sha256::new();
    hasher.update(bytes);
    hex::encode(hasher.finalize())
}

async fn persist_state(state: &ServerState) -> Result<(), ApiError> {
    let Some(pool) = state.database.clone() else {
        return Ok(());
    };
    let mut transaction = pool.begin().await.map_err(|_| ApiError::Internal)?;
    sqlx::query(
        "TRUNCATE provider_credentials, auth_sessions, refresh_token_families, accounts, auth_challenges, conflicts, operations, snapshots, objects, works",
    )
    .execute(&mut *transaction)
    .await
    .map_err(|_| ApiError::Internal)?;
    for work in state.works.values() {
        sqlx::query(
            "INSERT INTO works(work_id, head_generation, head_snapshot_id) VALUES ($1, $2, $3)",
        )
        .bind(work.work_id)
        .bind(work.head.as_ref().map(|head| head.generation as i64))
        .bind(work.head.as_ref().map(|head| &head.snapshot_id))
        .execute(&mut *transaction)
        .await
        .map_err(|_| ApiError::Internal)?;
    }
    for object in state.objects.values() {
        sqlx::query("INSERT INTO objects(object_id, byte_count, bytes) VALUES ($1, $2, $3)")
            .bind(&object.object_id)
            .bind(object.byte_count as i64)
            .bind(object.bytes.as_ref())
            .execute(&mut *transaction)
            .await
            .map_err(|_| ApiError::Internal)?;
    }
    for (snapshot_id, manifest) in &state.snapshots {
        let value = serde_json::to_value(manifest).map_err(|_| ApiError::Internal)?;
        sqlx::query("INSERT INTO snapshots(snapshot_id, work_id, manifest) VALUES ($1, $2, $3)")
            .bind(snapshot_id)
            .bind(manifest.work_id)
            .bind(value)
            .execute(&mut *transaction)
            .await
            .map_err(|_| ApiError::Internal)?;
    }
    for receipt in state.operations.values() {
        sqlx::query("INSERT INTO operations(operation_id, kind, request_sha256, result, created_at) VALUES ($1, $2, $3, $4, $5)")
            .bind(receipt.operation_id)
            .bind(&receipt.kind)
            .bind(&receipt.request_sha256)
            .bind(&receipt.result)
            .bind(receipt.created_at)
            .execute(&mut *transaction)
            .await
            .map_err(|_| ApiError::Internal)?;
    }
    for conflict in state.conflicts.values() {
        sqlx::query("INSERT INTO conflicts(conflict_id, work_id, base_snapshot_id, local_snapshot_id, remote_snapshot_id, state, created_at) VALUES ($1, $2, $3, $4, $5, $6, $7)")
            .bind(conflict.conflict_id)
            .bind(conflict.work_id)
            .bind(&conflict.base_snapshot_id)
            .bind(&conflict.local_snapshot_id)
            .bind(&conflict.remote_snapshot_id)
            .bind(&conflict.state)
            .bind(conflict.created_at)
            .execute(&mut *transaction)
            .await
            .map_err(|_| ApiError::Internal)?;
    }
    for (challenge_id, challenge) in &state.auth_challenges {
        sqlx::query("INSERT INTO auth_challenges(challenge_id, state, nonce, expires_at, consumed) VALUES ($1, $2, $3, $4, $5)")
            .bind(challenge_id)
            .bind(&challenge.state)
            .bind(&challenge.nonce)
            .bind(challenge.expires_at)
            .bind(challenge.consumed)
            .execute(&mut *transaction)
            .await
            .map_err(|_| ApiError::Internal)?;
    }
    for account in state.accounts.values() {
        sqlx::query("INSERT INTO accounts(account_id, issuer, subject_hash, auth_epoch, fence) VALUES ($1, $2, $3, $4, $5)")
            .bind(&account.account_id)
            .bind(&account.issuer)
            .bind(&account.subject_hash)
            .bind(account.auth_epoch as i64)
            .bind(&account.fence)
            .execute(&mut *transaction)
            .await
            .map_err(|_| ApiError::Internal)?;
    }
    for credential in state.provider_credentials.values() {
        sqlx::query("INSERT INTO provider_credentials(account_id, client_id, refresh_token_ciphertext, created_at) VALUES ($1, $2, $3, $4)")
            .bind(&credential.account_id)
            .bind(&credential.client_id)
            .bind(&credential.refresh_token_ciphertext)
            .bind(credential.created_at)
            .execute(&mut *transaction)
            .await
            .map_err(|_| ApiError::Internal)?;
    }
    for (access_token_hash, session) in &state.auth_sessions {
        sqlx::query("INSERT INTO auth_sessions(access_token_hash, account_id, auth_epoch, fence, refresh_family_id, expires_at, revoked) VALUES ($1, $2, $3, $4, $5, $6, $7)")
            .bind(access_token_hash)
            .bind(&session.account_id)
            .bind(session.auth_epoch as i64)
            .bind(&session.fence)
            .bind(session.refresh_family_id)
            .bind(session.expires_at)
            .bind(session.revoked)
            .execute(&mut *transaction)
            .await
            .map_err(|_| ApiError::Internal)?;
    }
    for family in state.refresh_families.values() {
        sqlx::query("INSERT INTO refresh_token_families(family_id, account_id, current_token_hash, generation, last_rotation_id, last_response, revoked) VALUES ($1, $2, $3, $4, $5, $6, $7)")
            .bind(family.family_id)
            .bind(&family.account_id)
            .bind(&family.current_token_hash)
            .bind(family.generation as i64)
            .bind(family.last_rotation_id)
            .bind(&family.last_response)
            .bind(family.revoked)
            .execute(&mut *transaction)
            .await
            .map_err(|_| ApiError::Internal)?;
    }
    transaction.commit().await.map_err(|_| ApiError::Internal)
}

fn random_secret() -> String {
    rand::rng()
        .sample_iter(Alphanumeric)
        .take(43)
        .map(char::from)
        .collect()
}

fn issue_session(
    state: &mut ServerState,
    account_id: String,
    auth_epoch: u64,
    fence: String,
) -> AuthTokenResponse {
    let family_id = Uuid::new_v4();
    let response = mint_tokens(account_id.clone(), auth_epoch, fence.clone(), 1);
    let access_hash = digest(response.access_token.as_bytes());
    let refresh_hash = digest(response.refresh_token.as_bytes());
    state.auth_sessions.insert(
        access_hash,
        AuthSession {
            account_id: account_id.clone(),
            auth_epoch,
            fence,
            refresh_family_id: family_id,
            expires_at: Utc::now() + chrono::Duration::days(30),
            revoked: false,
        },
    );
    state.refresh_families.insert(
        family_id,
        RefreshTokenFamily {
            family_id,
            account_id,
            current_token_hash: refresh_hash,
            generation: 1,
            last_rotation_id: None,
            last_response: None,
            revoked: false,
        },
    );
    response
}

fn rotate_session(
    state: &mut ServerState,
    family_id: Uuid,
    account_id: String,
    auth_epoch: u64,
    fence: String,
    generation: u64,
) -> AuthTokenResponse {
    let response = mint_tokens(account_id.clone(), auth_epoch, fence.clone(), generation);
    state.auth_sessions.insert(
        digest(response.access_token.as_bytes()),
        AuthSession {
            account_id,
            auth_epoch,
            fence,
            refresh_family_id: family_id,
            expires_at: Utc::now() + chrono::Duration::days(30),
            revoked: false,
        },
    );
    response
}

fn mint_tokens(
    account_id: String,
    account_auth_epoch: u64,
    account_fence: String,
    refresh_generation: u64,
) -> AuthTokenResponse {
    AuthTokenResponse {
        access_token: format!("fma_{}", random_secret()),
        refresh_token: format!("fmr_{}", random_secret()),
        account_id,
        account_auth_epoch,
        account_fence,
        refresh_generation,
    }
}

#[derive(Clone, Debug)]
struct AppleIdentity {
    issuer: String,
    subject: String,
}

#[derive(Clone, Debug)]
struct AppleIdentityWithAudience {
    identity: AppleIdentity,
    audience: String,
}

async fn verify_apple_identity(
    config: &AppleConfig,
    request: &AppleExchangeRequest,
    expected_nonce: &str,
) -> Result<AppleExchangeResult, ApiError> {
    let claims =
        verify_signed_apple_token(config, &request.identity_token, None, Some(expected_nonce))
            .await?;
    let client_id = claims.audience.clone();
    let exchanged = exchange_apple_code(config, &request.authorization_code, &client_id).await?;
    if exchanged.identity.subject != claims.identity.subject
        || exchanged.identity.issuer != claims.identity.issuer
        || exchanged.client_id != client_id
    {
        return Err(ApiError::AppleAuthenticationFailed);
    }
    Ok(exchanged)
}

async fn exchange_apple_code(
    config: &AppleConfig,
    code: &str,
    client_id: &str,
) -> Result<AppleExchangeResult, ApiError> {
    if code.is_empty()
        || !config.is_configured()
        || !config.client_ids.iter().any(|id| id == client_id)
    {
        return Err(ApiError::AppleAuthenticationFailed);
    }
    let team_id = config
        .team_id
        .as_deref()
        .ok_or(ApiError::AppleNotConfigured)?;
    let key_id = config
        .key_id
        .as_deref()
        .ok_or(ApiError::AppleNotConfigured)?;
    let private_key = config
        .private_key_pem
        .as_deref()
        .ok_or(ApiError::AppleNotConfigured)?;
    let now = Utc::now().timestamp() as usize;
    let secret_claims = AppleClientSecretClaims {
        iss: team_id.to_owned(),
        iat: now,
        exp: now + 86_400,
        aud: "https://appleid.apple.com".into(),
        sub: client_id.to_owned(),
    };
    let mut header = jsonwebtoken::Header::new(jsonwebtoken::Algorithm::ES256);
    header.kid = Some(key_id.to_owned());
    let encoding_key = jsonwebtoken::EncodingKey::from_ec_pem(private_key.as_bytes())
        .map_err(|_| ApiError::AppleNotConfigured)?;
    let client_secret = jsonwebtoken::encode(&header, &secret_claims, &encoding_key)
        .map_err(|_| ApiError::Internal)?;
    let token_response: AppleTokenResponse = reqwest::Client::new()
        .post(&config.token_url)
        .form(&[
            ("client_id", client_id),
            ("client_secret", client_secret.as_str()),
            ("code", code),
            ("grant_type", "authorization_code"),
        ])
        .send()
        .await
        .map_err(|_| ApiError::AppleAuthenticationFailed)?
        .error_for_status()
        .map_err(|_| ApiError::AppleAuthenticationFailed)?
        .json()
        .await
        .map_err(|_| ApiError::AppleAuthenticationFailed)?;
    let refresh_token = token_response
        .refresh_token
        .ok_or(ApiError::AppleAuthenticationFailed)?;
    let identity_token = token_response
        .id_token
        .ok_or(ApiError::AppleAuthenticationFailed)?;
    let identity = verify_signed_apple_token(config, &identity_token, Some(client_id), None)
        .await?
        .identity;
    Ok(AppleExchangeResult {
        identity,
        client_id: client_id.to_owned(),
        refresh_token,
    })
}

async fn verify_signed_apple_token(
    config: &AppleConfig,
    token: &str,
    expected_audience: Option<&str>,
    expected_nonce: Option<&str>,
) -> Result<AppleIdentityWithAudience, ApiError> {
    let header =
        jsonwebtoken::decode_header(token).map_err(|_| ApiError::AppleAuthenticationFailed)?;
    if header.alg != jsonwebtoken::Algorithm::RS256 {
        return Err(ApiError::AppleAuthenticationFailed);
    }
    let jwks: AppleJwks = reqwest::Client::new()
        .get(&config.jwks_url)
        .send()
        .await
        .map_err(|_| ApiError::AppleAuthenticationFailed)?
        .error_for_status()
        .map_err(|_| ApiError::AppleAuthenticationFailed)?
        .json()
        .await
        .map_err(|_| ApiError::AppleAuthenticationFailed)?;
    let key = jwks
        .keys
        .iter()
        .find(|key| key.kid == header.kid.clone().unwrap_or_default())
        .ok_or(ApiError::AppleAuthenticationFailed)?;
    let decoding_key = jsonwebtoken::DecodingKey::from_rsa_components(&key.n, &key.e)
        .map_err(|_| ApiError::AppleAuthenticationFailed)?;
    let mut validation = jsonwebtoken::Validation::new(jsonwebtoken::Algorithm::RS256);
    validation.set_issuer(&["https://appleid.apple.com"]);
    if let Some(audience) = expected_audience {
        validation.set_audience(&[audience]);
    } else {
        validation.set_audience(&config.client_ids);
    }
    let claims: AppleClaims = jsonwebtoken::decode(token, &decoding_key, &validation)
        .map_err(|_| ApiError::AppleAuthenticationFailed)?
        .claims;
    if claims.sub.is_empty()
        || expected_nonce.is_some_and(|nonce| claims.nonce.as_deref() != Some(nonce))
    {
        return Err(ApiError::AppleAuthenticationFailed);
    }
    Ok(AppleIdentityWithAudience {
        identity: AppleIdentity {
            issuer: claims.iss,
            subject: claims.sub,
        },
        audience: claims.aud,
    })
}

fn encrypt_secret(secret: &str, key: &[u8]) -> Result<String, ApiError> {
    let cipher = Aes256Gcm::new_from_slice(key).map_err(|_| ApiError::AppleNotConfigured)?;
    let mut nonce_bytes = [0_u8; 12];
    rand::rng().fill_bytes(&mut nonce_bytes);
    let nonce = Nonce::from_slice(&nonce_bytes);
    let ciphertext = cipher
        .encrypt(nonce, secret.as_bytes())
        .map_err(|_| ApiError::Internal)?;
    let mut encoded = nonce_bytes.to_vec();
    encoded.extend(ciphertext);
    Ok(BASE64.encode(encoded))
}

#[derive(Debug, Deserialize)]
struct AppleJwks {
    keys: Vec<AppleJwk>,
}

#[derive(Debug, Deserialize)]
struct AppleJwk {
    kid: String,
    n: String,
    e: String,
}

#[derive(Debug, Deserialize)]
struct AppleClaims {
    iss: String,
    sub: String,
    aud: String,
    #[serde(rename = "exp")]
    _exp: usize,
    #[serde(rename = "iat")]
    _iat: usize,
    nonce: Option<String>,
}

#[derive(Debug, Serialize)]
struct AppleClientSecretClaims {
    iss: String,
    iat: usize,
    exp: usize,
    aud: String,
    sub: String,
}

#[derive(Debug, Deserialize)]
struct AppleTokenResponse {
    #[serde(rename = "refresh_token")]
    refresh_token: Option<String>,
    #[serde(rename = "id_token")]
    id_token: Option<String>,
}

#[cfg(test)]
mod tests {
    use super::*;
    use axum::body::Body;
    use http::{Request, StatusCode};
    use tower::ServiceExt;

    fn test_app() -> Router {
        let config = AppConfig {
            dev_token: Some("test-token".into()),
            ..AppConfig::default()
        };
        router(Arc::new(RwLock::new(ServerState::default())), config)
    }

    #[tokio::test]
    async fn health_is_available_without_authentication() {
        let response = test_app()
            .oneshot(
                Request::builder()
                    .uri("/health")
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::OK);
    }

    #[tokio::test]
    async fn capabilities_require_bearer_when_dev_fence_is_enabled() {
        let response = test_app()
            .oneshot(
                Request::builder()
                    .uri("/v1/capabilities")
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::UNAUTHORIZED);
    }

    #[tokio::test]
    async fn auth_challenge_is_single_use_state_material() {
        let response = test_app()
            .oneshot(
                Request::builder()
                    .method("POST")
                    .uri("/v1/auth/challenges")
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::OK);
        let bytes = axum::body::to_bytes(response.into_body(), 4096)
            .await
            .unwrap();
        let body: AuthChallengeResponse = serde_json::from_slice(&bytes).unwrap();
        assert_ne!(body.state, body.nonce);
        assert_eq!(body.provider, "apple");
        assert_eq!(body.flow, "native");
    }

    #[tokio::test]
    async fn refresh_rotates_and_replays_exactly() {
        let state = Arc::new(RwLock::new(ServerState::default()));
        let response = {
            let mut locked = state.write().await;
            locked.accounts.insert(
                "acct_test".into(),
                AccountRecord {
                    account_id: "acct_test".into(),
                    issuer: "https://appleid.apple.com".into(),
                    subject_hash: "subject".into(),
                    auth_epoch: 1,
                    fence: "fence_test".into(),
                },
            );
            issue_session(&mut locked, "acct_test".into(), 1, "fence_test".into())
        };
        let app = router(state, AppConfig::default());
        let rotation_id = Uuid::new_v4();
        let body = serde_json::json!({"rotationId": rotation_id});
        assert!(response.refresh_token.starts_with("fmr_"));
        let first = app
            .clone()
            .oneshot(
                Request::builder()
                    .method("POST")
                    .uri("/v1/auth/tokens:refresh")
                    .header(
                        "authorization",
                        format!("Bearer {}", response.refresh_token),
                    )
                    .header("content-type", "application/json")
                    .body(Body::from(body.to_string()))
                    .unwrap(),
            )
            .await
            .unwrap();
        let first_status = first.status();
        let first_bytes = axum::body::to_bytes(first.into_body(), usize::MAX)
            .await
            .unwrap();
        assert_eq!(
            first_status,
            StatusCode::OK,
            "{}",
            String::from_utf8_lossy(&first_bytes)
        );
        let first_response: AuthTokenResponse = serde_json::from_slice(&first_bytes).unwrap();
        assert_eq!(first_response.refresh_generation, 2);
        let replay = app
            .oneshot(
                Request::builder()
                    .method("POST")
                    .uri("/v1/auth/tokens:refresh")
                    .header(
                        "authorization",
                        format!("Bearer {}", response.refresh_token),
                    )
                    .header("content-type", "application/json")
                    .body(Body::from(body.to_string()))
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(replay.status(), StatusCode::OK);
        let replay_bytes = axum::body::to_bytes(replay.into_body(), usize::MAX)
            .await
            .unwrap();
        assert_eq!(first_bytes, replay_bytes);
    }

    #[tokio::test]
    async fn registering_the_same_manifest_is_idempotent_after_server_reparse() {
        let app = test_app();
        let object = Bytes::from_static(b"snapshot-object");
        let object_id = digest(&object);
        let object_response = app
            .clone()
            .oneshot(
                Request::builder()
                    .method("PUT")
                    .uri(format!("/v1/objects/{object_id}"))
                    .header("authorization", "Bearer test-token")
                    .body(Body::from(object.clone()))
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(object_response.status(), StatusCode::OK);

        let work_id = Uuid::new_v4();
        // This is the Swift canonical member order. The server stores a
        // decoded manifest, so a retry must not compare against Rust's own
        // struct serialization order.
        let manifest = format!(
            "{{\"entries\":[{{\"byteCount\":{},\"contentType\":\"application/octet-stream\",\"entityKey\":\"work/document\",\"objectId\":\"{}\"}}],\"parentSnapshotIds\":[],\"schemaVersion\":1,\"workId\":\"{}\"}}",
            object.len(), object_id, work_id
        );
        let snapshot_id = digest(manifest.as_bytes());
        let register = || {
            app.clone().oneshot(
                Request::builder()
                    .method("PUT")
                    .uri(format!("/v1/works/{work_id}/snapshots/{snapshot_id}"))
                    .header("authorization", "Bearer test-token")
                    .header("content-type", "application/json")
                    .body(Body::from(manifest.clone()))
                    .unwrap(),
            )
        };
        let first = register().await.unwrap();
        assert_eq!(first.status(), StatusCode::OK);
        let retry = register().await.unwrap();
        assert_eq!(retry.status(), StatusCode::OK);
        let retry_body = axum::body::to_bytes(retry.into_body(), 4096).await.unwrap();
        assert!(String::from_utf8_lossy(&retry_body).contains("alreadyRegistered"));
    }

    #[tokio::test]
    async fn retrying_the_same_head_conflict_reuses_one_conflict_record() {
        let app = test_app();
        let work_id = Uuid::new_v4();

        async fn register_candidate(app: &Router, work_id: Uuid, value: &'static [u8]) -> String {
            let object = Bytes::from_static(value);
            let object_id = digest(&object);
            let object_response = app
                .clone()
                .oneshot(
                    Request::builder()
                        .method("PUT")
                        .uri(format!("/v1/objects/{object_id}"))
                        .header("authorization", "Bearer test-token")
                        .body(Body::from(object))
                        .unwrap(),
                )
                .await
                .unwrap();
            assert_eq!(object_response.status(), StatusCode::OK);

            let manifest = format!(
                "{{\"entries\":[{{\"byteCount\":{},\"contentType\":\"application/octet-stream\",\"entityKey\":\"work/document\",\"objectId\":\"{}\"}}],\"parentSnapshotIds\":[],\"schemaVersion\":1,\"workId\":\"{}\"}}",
                value.len(), object_id, work_id
            );
            let snapshot_id = digest(manifest.as_bytes());
            let response = app
                .clone()
                .oneshot(
                    Request::builder()
                        .method("PUT")
                        .uri(format!("/v1/works/{work_id}/snapshots/{snapshot_id}"))
                        .header("authorization", "Bearer test-token")
                        .header("content-type", "application/json")
                        .body(Body::from(manifest))
                        .unwrap(),
                )
                .await
                .unwrap();
            assert_eq!(response.status(), StatusCode::OK);
            snapshot_id
        }

        let remote_snapshot_id = register_candidate(&app, work_id, b"remote").await;
        let local_snapshot_id = register_candidate(&app, work_id, b"local").await;
        let publish_remote = serde_json::json!({
            "operationId": Uuid::new_v4(),
            "workId": work_id,
            "expectedHead": null,
            "candidateSnapshotId": remote_snapshot_id,
        });
        let response = app
            .clone()
            .oneshot(
                Request::builder()
                    .method("POST")
                    .uri(format!("/v1/works/{work_id}/head"))
                    .header("authorization", "Bearer test-token")
                    .header("content-type", "application/json")
                    .body(Body::from(publish_remote.to_string()))
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::OK);

        let operation_id = Uuid::new_v4();
        let publish_local = serde_json::json!({
            "operationId": operation_id,
            "workId": work_id,
            "expectedHead": null,
            "candidateSnapshotId": local_snapshot_id,
        });
        let publish_conflict = || {
            app.clone().oneshot(
                Request::builder()
                    .method("POST")
                    .uri(format!("/v1/works/{work_id}/head"))
                    .header("authorization", "Bearer test-token")
                    .header("content-type", "application/json")
                    .body(Body::from(publish_local.to_string()))
                    .unwrap(),
            )
        };
        assert_eq!(
            publish_conflict().await.unwrap().status(),
            StatusCode::CONFLICT
        );
        assert_eq!(
            publish_conflict().await.unwrap().status(),
            StatusCode::CONFLICT
        );

        let conflicts = app
            .clone()
            .oneshot(
                Request::builder()
                    .uri(format!("/v1/works/{work_id}/conflicts"))
                    .header("authorization", "Bearer test-token")
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(conflicts.status(), StatusCode::OK);
        let body = axum::body::to_bytes(conflicts.into_body(), usize::MAX)
            .await
            .unwrap();
        let records: Vec<ConflictRecord> = serde_json::from_slice(&body).unwrap();
        assert_eq!(records.len(), 1);
        assert_eq!(records[0].local_snapshot_id, local_snapshot_id);
        assert_eq!(records[0].remote_snapshot_id, remote_snapshot_id);

        let catalog = app
            .clone()
            .oneshot(
                Request::builder()
                    .uri("/v1/works")
                    .header("authorization", "Bearer test-token")
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(catalog.status(), StatusCode::OK);
        let catalog_body = axum::body::to_bytes(catalog.into_body(), usize::MAX)
            .await
            .unwrap();
        let catalog_entries: Vec<WorkCatalogEntry> = serde_json::from_slice(&catalog_body).unwrap();
        assert_eq!(catalog_entries.len(), 1);
        assert_eq!(catalog_entries[0].work_id, work_id);
        assert_eq!(
            catalog_entries[0].head.as_ref().unwrap().snapshot_id,
            remote_snapshot_id
        );

        let resolve = app
            .clone()
            .oneshot(
                Request::builder()
                    .method("POST")
                    .uri(format!(
                        "/v1/works/{work_id}/conflicts/{}/resolve",
                        records[0].conflict_id
                    ))
                    .header("authorization", "Bearer test-token")
                    .header("content-type", "application/json")
                    .body(Body::from(
                        serde_json::json!({
                            "operationId": Uuid::new_v4(),
                            "choice": "useOnline",
                            "expectedRemoteSnapshotId": remote_snapshot_id,
                        })
                        .to_string(),
                    ))
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(resolve.status(), StatusCode::OK);
        let remaining = app
            .oneshot(
                Request::builder()
                    .uri(format!("/v1/works/{work_id}/conflicts"))
                    .header("authorization", "Bearer test-token")
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();
        let remaining_body = axum::body::to_bytes(remaining.into_body(), usize::MAX)
            .await
            .unwrap();
        let remaining_records: Vec<ConflictRecord> =
            serde_json::from_slice(&remaining_body).unwrap();
        assert!(remaining_records.is_empty());
    }
}
