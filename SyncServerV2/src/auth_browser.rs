//! Browser OAuth boundary. Provider tokens never appear in browser responses.
use crate::{
    auth_apple::{AppleClientSecretSigner, ProductionAppleProvider, ProductionAppleTransport},
    auth_application::HmacSecretHasher,
    auth_domain::{
        AuthError, CredentialVault, OperationId, ProviderConfigId, SealedSecret, SecretHasher,
        VerifiedProviderCredential,
    },
    auth_google::GoogleOAuthProvider,
    auth_postgres::AuthPostgresRepository,
    auth_vault::AesGcmCredentialVault,
};
use axum::{
    extract::{DefaultBodyLimit, Form, Path, Query, State},
    http::{header, StatusCode},
    response::{IntoResponse, Response},
    routing::{get, post},
    Json, Router,
};
use base64::{engine::general_purpose::URL_SAFE_NO_PAD, Engine};
use serde::Deserialize;
use serde_json::json;
use sha2::{Digest, Sha256};
use sqlx::{PgPool, Row};
use std::sync::Arc;
use uuid::Uuid;

pub(crate) struct BrowserIdentity {
    pub subject: String,
    pub authenticated_at: i64,
    pub credential: Option<VerifiedProviderCredential>,
}

pub(crate) fn provider_binding(
    provider: &str,
) -> Result<(&'static str, &'static str, &'static str), AuthError> {
    match provider {
        "apple" => Ok((
            "apple-primary-fuminiwa-v1",
            "https://appleid.apple.com",
            "dev.serikayuzuki.fuminiwa.web",
        )),
        "google" => Ok((
            "google-fuminiwa-v2",
            "https://accounts.google.com",
            "560354700432-aq87npqhidi1m4n671m8pb9bugml609d.apps.googleusercontent.com",
        )),
        _ => Err(AuthError::ProviderNotAllowed),
    }
}

#[derive(Clone)]
pub struct BrowserAuthService {
    pool: PgPool,
    repository: AuthPostgresRepository,
    vault: AesGcmCredentialVault,
    hasher: HmacSecretHasher,
    apple: ProductionAppleProvider<ProductionAppleTransport, AesGcmCredentialVault>,
    google: GoogleOAuthProvider,
    server_instance: String,
}
impl BrowserAuthService {
    #[allow(clippy::too_many_arguments)]
    pub fn new(
        pool: PgPool,
        vault: AesGcmCredentialVault,
        subject_key: [u8; 32],
        token_key: [u8; 32],
        server_instance: String,
        signer: AppleClientSecretSigner,
        transport: ProductionAppleTransport,
        google: GoogleOAuthProvider,
    ) -> Result<Self, AuthError> {
        Ok(Self {
            repository: AuthPostgresRepository::new(
                pool.clone(),
                Arc::new(vault.clone()),
                token_key,
                server_instance.clone(),
            )?,
            pool,
            hasher: HmacSecretHasher::new(subject_key, token_key),
            apple: ProductionAppleProvider::new(transport, signer, vault.clone()),
            vault,
            google,
            server_instance,
        })
    }
    async fn start(&self, request: StartRequest) -> Result<serde_json::Value, AuthError> {
        let (_, _, audience) = provider_binding(&request.provider)?;
        if !matches!(request.client_platform.as_str(), "macos" | "ios" | "ipados")
            || request.provider == "apple" && request.client_platform != "macos"
        {
            return Err(AuthError::InvalidRequest);
        }
        let claim_hash = hex::decode(&request.claim_hash).map_err(|_| AuthError::InvalidRequest)?;
        if claim_hash.len() != 32 || hex::encode(&claim_hash) != request.claim_hash {
            return Err(AuthError::InvalidRequest);
        }
        let state = random_secret()?;
        let nonce = random_secret()?;
        let attempt = Uuid::new_v4();
        let mut tx = self.pool.begin().await.map_err(db)?;
        // Keep unauthenticated attempt creation bounded even before the edge limiter.
        sqlx::query("SELECT pg_advisory_xact_lock(78214691)")
            .execute(&mut *tx)
            .await
            .map_err(db)?;
        sqlx::query("DELETE FROM auth_v1.browser_attempts WHERE expires_at<now()")
            .execute(&mut *tx)
            .await
            .map_err(db)?;
        let count: i64 = sqlx::query_scalar("SELECT count(*) FROM auth_v1.browser_attempts")
            .fetch_one(&mut *tx)
            .await
            .map_err(db)?;
        if count >= 1000 {
            return Err(AuthError::ProviderExchangeIndeterminate);
        }
        sqlx::query("INSERT INTO auth_v1.browser_attempts(attempt_id,provider,client_platform,state_hash,claim_hash,nonce,phase,expires_at) VALUES($1,$2,$3,$4,$5,$6,'pending',now()+interval '5 minutes')")
            .bind(attempt).bind(&request.provider).bind(request.client_platform).bind(Sha256::digest(state.as_bytes()).as_slice()).bind(claim_hash).bind(&nonce).execute(&mut *tx).await.map_err(db)?;
        tx.commit().await.map_err(db)?;
        let endpoint = if request.provider == "apple" {
            "https://appleid.apple.com/auth/authorize"
        } else {
            "https://accounts.google.com/o/oauth2/v2/auth"
        };
        let mut url = reqwest::Url::parse(endpoint).map_err(|_| AuthError::InvalidRequest)?;
        url.query_pairs_mut()
            .append_pair("client_id", audience)
            .append_pair(
                "redirect_uri",
                &format!(
                    "https://sync.serika.work/v2/auth/browser/{}/callback",
                    request.provider
                ),
            )
            .append_pair("response_type", "code")
            .append_pair("state", &state)
            .append_pair("nonce", &nonce);
        if request.provider == "google" {
            url.query_pairs_mut()
                .append_pair("scope", "openid")
                .append_pair("prompt", "select_account");
        } else {
            url.query_pairs_mut()
                .append_pair("response_mode", "form_post");
        }
        Ok(json!({"attemptId":attempt,"authorizationURL":url.as_str(),"expiresIn":300}))
    }
    async fn callback(&self, provider: &str, input: Callback) -> Result<(), AuthError> {
        provider_binding(provider)?;
        if input.state.len() > 256 || input.state.len() < 32 {
            return Err(AuthError::InvalidRequest);
        }
        let row=sqlx::query("UPDATE auth_v1.browser_attempts SET phase='exchanging' WHERE state_hash=$1 AND provider=$2 AND phase='pending' AND expires_at>now() RETURNING attempt_id,nonce,client_platform")
            .bind(Sha256::digest(input.state.as_bytes()).as_slice()).bind(provider).fetch_optional(&self.pool).await.map_err(db)?.ok_or(AuthError::InvalidRequest)?;
        let attempt: Uuid = row.try_get("attempt_id").map_err(db)?;
        let nonce: String = row.try_get("nonce").map_err(db)?;
        let platform: String = row.try_get("client_platform").map_err(db)?;
        let result=async {
            if input.error.is_some() { return Err(AuthError::InvalidExternalIdentity); }
            let code=input.code.ok_or(AuthError::InvalidExternalIdentity)?;
            let now=chrono::Utc::now().timestamp();
            let identity=if provider=="apple" { self.apple.exchange_browser(&code,&nonce,now).await? } else {
                let value=self.google.exchange_and_verify(&code,&nonce,now).await?;
                BrowserIdentity {subject:value.subject,authenticated_at:value.authenticated_at_unix,credential:None}
            };
            let (config,issuer,_)=provider_binding(provider)?;
            let lookup=self.hasher.subject_lookup(&ProviderConfigId::new(config)?,issuer,&identity.subject).await?;
            let mut tx=self.pool.begin().await.map_err(db)?;
            let active:bool=sqlx::query_scalar("SELECT phase='exchanging' AND expires_at>now() FROM auth_v1.browser_attempts WHERE attempt_id=$1 FOR UPDATE").bind(attempt).fetch_optional(&mut *tx).await.map_err(db)?.unwrap_or(false);
            if !active {return Err(AuthError::InvalidRequest);}
            let grant=self.repository.issue_browser_session(&mut tx,&identity,provider,&platform,lookup,now).await?;
            let operation=OperationId::new(attempt.to_string())?;
            let native_bytes=crate::auth_wire::encode_exchange_response(&grant,&self.server_instance,&operation)?;
            let mut envelope:serde_json::Value=serde_json::from_slice(&native_bytes).map_err(|_|AuthError::InvalidRequest)?;
            envelope["receipt"]["commandKind"]=json!("exchangeBrowserCredential");
            let bytes=serde_json::to_vec(&envelope).map_err(|_|AuthError::InvalidRequest)?;
            let sealed=self.vault.seal("browser_auth_receipt_v2",&attempt.to_string(),&bytes).await?;
            sqlx::query("UPDATE auth_v1.browser_attempts SET phase='ready',response_ciphertext=$2,response_key_version=$3 WHERE attempt_id=$1").bind(attempt).bind(sealed.ciphertext).bind(sealed.key_version).execute(&mut *tx).await.map_err(db)?;
            tx.commit().await.map_err(db)?;
            Ok(())
        }.await;
        if result.is_err() {
            let _=sqlx::query("UPDATE auth_v1.browser_attempts SET phase='failed' WHERE attempt_id=$1 AND phase='exchanging'").bind(attempt).execute(&self.pool).await;
        }
        result
    }
    async fn claim(
        &self,
        attempt: Uuid,
        request: ClaimRequest,
    ) -> Result<Option<Vec<u8>>, AuthError> {
        let secret = URL_SAFE_NO_PAD
            .decode(&request.secret)
            .map_err(|_| AuthError::InvalidRequest)?;
        if secret.len() != 32 || URL_SAFE_NO_PAD.encode(&secret) != request.secret {
            return Err(AuthError::InvalidRequest);
        }
        let row=sqlx::query("SELECT phase,response_ciphertext,response_key_version FROM auth_v1.browser_attempts WHERE attempt_id=$1 AND claim_hash=$2 AND expires_at>now()")
            .bind(attempt).bind(Sha256::digest(&secret).as_slice()).fetch_optional(&self.pool).await.map_err(db)?.ok_or(AuthError::InvalidRequest)?;
        match row.try_get::<String, _>("phase").map_err(db)?.as_str() {
            "pending" | "exchanging" => Ok(None),
            "ready" => {
                let bytes = self
                    .vault
                    .open(
                        "browser_auth_receipt_v2",
                        &attempt.to_string(),
                        &SealedSecret {
                            ciphertext: row.try_get("response_ciphertext").map_err(db)?,
                            key_version: row.try_get("response_key_version").map_err(db)?,
                        },
                    )
                    .await?;
                Ok(Some(bytes))
            }
            _ => Err(AuthError::InvalidExternalIdentity),
        }
    }
}
fn random_secret() -> Result<String, AuthError> {
    let mut bytes = [0u8; 32];
    getrandom::getrandom(&mut bytes).map_err(|_| AuthError::Vault)?;
    Ok(URL_SAFE_NO_PAD.encode(bytes))
}
fn db(error: sqlx::Error) -> AuthError {
    AuthError::Database(error.to_string())
}
#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct StartRequest {
    provider: String,
    client_platform: String,
    claim_hash: String,
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct ClaimRequest {
    secret: String,
}
#[derive(Deserialize)]
struct Callback {
    state: String,
    code: Option<String>,
    error: Option<String>,
}

pub fn router(service: BrowserAuthService) -> Router {
    Router::new()
        .route("/v2/auth/browser/start", post(start))
        .route("/v2/auth/browser/{attempt}/claim", post(claim))
        .route("/v2/auth/browser/google/callback", get(google_callback))
        .route("/v2/auth/browser/apple/callback", post(apple_callback))
        .layer(DefaultBodyLimit::max(16384))
        .with_state(Arc::new(service))
}
fn json_response(status: StatusCode, bytes: Vec<u8>) -> Response {
    (
        status,
        [
            (header::CONTENT_TYPE, "application/json"),
            (header::CACHE_CONTROL, "no-store"),
        ],
        bytes,
    )
        .into_response()
}
fn failure() -> Response {
    json_response(
        StatusCode::BAD_REQUEST,
        b"{\"error\":\"authenticationFailed\"}".to_vec(),
    )
}
async fn start(
    State(service): State<Arc<BrowserAuthService>>,
    Json(request): Json<StartRequest>,
) -> Response {
    match service.start(request).await {
        Ok(value) => json_response(StatusCode::CREATED, serde_json::to_vec(&value).unwrap()),
        Err(_) => failure(),
    }
}
async fn claim(
    State(service): State<Arc<BrowserAuthService>>,
    Path(attempt): Path<Uuid>,
    Json(request): Json<ClaimRequest>,
) -> Response {
    match service.claim(attempt, request).await {
        Ok(Some(bytes)) => json_response(StatusCode::OK, bytes),
        Ok(None) => json_response(StatusCode::ACCEPTED, b"{\"pending\":true}".to_vec()),
        Err(_) => failure(),
    }
}
fn callback_response(_result: Result<(), AuthError>) -> Response {
    (
        StatusCode::SEE_OTHER,
        [
            (header::LOCATION, "fuminiwa-auth://complete"),
            (header::CACHE_CONTROL, "no-store"),
            (header::REFERRER_POLICY, "no-referrer"),
        ],
    )
        .into_response()
}
async fn google_callback(
    State(service): State<Arc<BrowserAuthService>>,
    Query(input): Query<Callback>,
) -> Response {
    callback_response(service.callback("google", input).await)
}
async fn apple_callback(
    State(service): State<Arc<BrowserAuthService>>,
    Form(input): Form<Callback>,
) -> Response {
    callback_response(service.callback("apple", input).await)
}

#[cfg(test)]
mod tests {
    use super::*;
    #[tokio::test]
    #[ignore = "requires an explicitly selected isolated browser-auth database"]
    async fn browser_database_gate() {
        let url =
            std::env::var("AUTH_BROWSER_TEST_DATABASE_URL").expect("isolated DB URL required");
        let parsed = reqwest::Url::parse(&url).unwrap();
        assert_eq!(parsed.host_str(), Some("127.0.0.1"));
        assert!(parsed.path().starts_with("/auth_v2_test_"));
        let instance = "80000000-0000-4000-8000-000000000001".to_string();
        let pool = sqlx::postgres::PgPoolOptions::new()
            .connect(&url)
            .await
            .unwrap();
        let vault = AesGcmCredentialVault::new(1, [6; 32]).unwrap();
        let service = BrowserAuthService::new(
            pool.clone(),
            vault.clone(),
            [17; 32],
            [34; 32],
            instance,
            AppleClientSecretSigner::browser_test_signer(),
            ProductionAppleTransport::new().unwrap(),
            GoogleOAuthProvider::new("test-only-secret".into()).unwrap(),
        )
        .unwrap();
        let secret = [91u8; 32];
        let start = service
            .start(StartRequest {
                provider: "google".into(),
                client_platform: "ios".into(),
                claim_hash: hex::encode(Sha256::digest(secret)),
            })
            .await
            .unwrap();
        let attempt = Uuid::parse_str(start["attemptId"].as_str().unwrap()).unwrap();
        let authorization =
            reqwest::Url::parse(start["authorizationURL"].as_str().unwrap()).unwrap();
        assert_eq!(authorization.host_str(), Some("accounts.google.com"));
        let state = authorization
            .query_pairs()
            .find(|(key, _)| key == "state")
            .unwrap()
            .1
            .to_string();
        assert!(service
            .claim(
                attempt,
                ClaimRequest {
                    secret: URL_SAFE_NO_PAD.encode([92u8; 32])
                }
            )
            .await
            .is_err());
        assert!(service
            .claim(
                attempt,
                ClaimRequest {
                    secret: URL_SAFE_NO_PAD.encode(secret)
                }
            )
            .await
            .unwrap()
            .is_none());
        assert!(service
            .callback(
                "apple",
                Callback {
                    state: state.clone(),
                    code: None,
                    error: Some("denied".into())
                }
            )
            .await
            .is_err());
        let phase: String =
            sqlx::query_scalar("SELECT phase FROM auth_v1.browser_attempts WHERE attempt_id=$1")
                .bind(attempt)
                .fetch_one(&pool)
                .await
                .unwrap();
        assert_eq!(phase, "pending");
        assert!(service
            .callback(
                "google",
                Callback {
                    state,
                    code: None,
                    error: Some("denied".into())
                }
            )
            .await
            .is_err());
        assert!(service
            .claim(
                attempt,
                ClaimRequest {
                    secret: URL_SAFE_NO_PAD.encode(secret)
                }
            )
            .await
            .is_err());

        let subject = format!("fixture-browser-{}", Uuid::new_v4());
        let identity = BrowserIdentity {
            subject: subject.clone(),
            authenticated_at: chrono::Utc::now().timestamp(),
            credential: None,
        };
        let mut accounts = Vec::new();
        let mut grant_bytes = Vec::new();
        for (provider, platform) in [("google", "ios"), ("google", "macos"), ("apple", "macos")] {
            let (config, issuer, _) = provider_binding(provider).unwrap();
            let lookup = service
                .hasher
                .subject_lookup(&ProviderConfigId::new(config).unwrap(), issuer, &subject)
                .await
                .unwrap();
            let mut tx = pool.begin().await.unwrap();
            let grant = service
                .repository
                .issue_browser_session(
                    &mut tx,
                    &identity,
                    provider,
                    platform,
                    lookup,
                    chrono::Utc::now().timestamp(),
                )
                .await
                .unwrap();
            accounts.push(grant.principal.account_id.clone());
            grant_bytes = crate::auth_wire::encode_exchange_response(
                &grant,
                &service.server_instance,
                &OperationId::new(attempt.to_string()).unwrap(),
            )
            .unwrap();
            tx.commit().await.unwrap();
        }
        assert_eq!(accounts[0], accounts[1]);
        assert_ne!(accounts[0], accounts[2]);
        let sealed = vault
            .seal(
                "browser_auth_receipt_v2",
                &attempt.to_string(),
                &grant_bytes,
            )
            .await
            .unwrap();
        sqlx::query("UPDATE auth_v1.browser_attempts SET phase='ready',response_ciphertext=$2,response_key_version=$3 WHERE attempt_id=$1").bind(attempt).bind(sealed.ciphertext).bind(sealed.key_version).execute(&pool).await.unwrap();
        let restarted = service.clone();
        let (a, b) = tokio::join!(
            service.claim(
                attempt,
                ClaimRequest {
                    secret: URL_SAFE_NO_PAD.encode(secret)
                }
            ),
            restarted.claim(
                attempt,
                ClaimRequest {
                    secret: URL_SAFE_NO_PAD.encode(secret)
                }
            )
        );
        assert_eq!(a.unwrap().unwrap(), grant_bytes);
        assert_eq!(b.unwrap().unwrap(), grant_bytes);
        sqlx::query("UPDATE auth_v1.browser_attempts SET expires_at=now()-interval '1 second' WHERE attempt_id=$1").bind(attempt).execute(&pool).await.unwrap();
        assert!(service
            .claim(
                attempt,
                ClaimRequest {
                    secret: URL_SAFE_NO_PAD.encode(secret)
                }
            )
            .await
            .is_err());
        let violation=sqlx::query("INSERT INTO auth_v1.external_identities(identity_id,account_id,provider_config_id,exact_issuer,lookup_key_version,subject_lookup_hmac,state) VALUES($1,$2,'apple-primary-fuminiwa-v1','https://appleid.apple.com',1,$3,'active')")
            .bind(Uuid::new_v4()).bind(accounts[0].as_str()).bind(Sha256::digest(Uuid::new_v4().as_bytes()).as_slice()).execute(&pool).await;
        assert!(violation.is_err());
    }
}
