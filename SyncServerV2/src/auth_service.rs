//! Production composition between Auth v1 application services and HTTP.

use crate::{
    auth::{AccessAuthenticator, AuthenticatedAccess},
    auth_apple::{AppleClientSecretSigner, ProductionAppleProvider, ProductionAppleTransport},
    auth_application::{AuthApplication, AuthRepository, HmacSecretHasher},
    auth_domain::{
        AppleProvider, AuthError, AuthenticatedPrincipal, OperationId, SecretHasher,
        VerifiedProviderCredential, CHALLENGE_LIFETIME_SECONDS, CREATE_CHALLENGE_COMMAND,
        EXCHANGE_APPLE_COMMAND, REFRESH_TOKEN_LIFETIME_SECONDS, REVOKE_SESSION_COMMAND,
        ROTATE_REFRESH_COMMAND,
    },
    auth_http::{AuthApiError, AuthHttpService, AuthResponse},
    auth_postgres::AuthPostgresRepository,
    auth_vault::AesGcmCredentialVault,
    auth_wire::{
        encode_challenge_response, encode_exchange_response, encode_me_response,
        encode_refresh_response, parse_auth_command, AuthCommand, ParsedAuthCommand,
    },
};
use async_trait::async_trait;
use base64::{engine::general_purpose::URL_SAFE_NO_PAD, Engine};
use sqlx::{PgPool, Row};
use std::sync::Arc;

type AppleAdapter = ProductionAppleProvider<ProductionAppleTransport, AesGcmCredentialVault>;

#[derive(Clone)]
pub struct ProductionAuthService {
    application: AuthApplication<AuthPostgresRepository>,
    apple: AppleAdapter,
    hasher: HmacSecretHasher,
    vault: AesGcmCredentialVault,
    server_instance_id: Arc<str>,
}

impl ProductionAuthService {
    #[allow(clippy::too_many_arguments)]
    pub fn new(
        pool: PgPool,
        vault: AesGcmCredentialVault,
        subject_hmac_key: [u8; 32],
        token_hmac_key: [u8; 32],
        server_instance_id: String,
        apple_signer: AppleClientSecretSigner,
        apple_transport: ProductionAppleTransport,
    ) -> Result<Self, AuthError> {
        let repository = AuthPostgresRepository::new(
            pool,
            Arc::new(vault.clone()),
            token_hmac_key,
            server_instance_id.clone(),
        )?;
        Ok(Self {
            application: AuthApplication::new(repository),
            apple: ProductionAppleProvider::new(apple_transport, apple_signer, vault.clone()),
            hasher: HmacSecretHasher::new(subject_hmac_key, token_hmac_key),
            vault,
            server_instance_id: server_instance_id.into(),
        })
    }

    pub async fn ensure_apple_provider_config(pool: &PgPool) -> Result<(), AuthError> {
        let mut transaction = pool
            .begin()
            .await
            .map_err(|error| AuthError::Database(error.to_string()))?;
        sqlx::query("INSERT INTO auth_v1.provider_configs(provider_config_id,provider_kind,exact_issuer,allowed_audiences,enabled,config_version) VALUES('apple-primary-fuminiwa-v1','apple','https://appleid.apple.com',ARRAY['dev.serikayuzuki.fuminiwa','dev.serikayuzuki.fuminiwa.ios'],true,1) ON CONFLICT DO NOTHING")
            .execute(&mut *transaction)
            .await
            .map_err(|error| AuthError::Database(error.to_string()))?;
        let row = sqlx::query("SELECT provider_kind,exact_issuer,allowed_audiences,enabled,config_version FROM auth_v1.provider_configs WHERE provider_config_id='apple-primary-fuminiwa-v1' FOR UPDATE")
            .fetch_one(&mut *transaction)
            .await
            .map_err(|error| AuthError::Database(error.to_string()))?;
        let mut audiences = row
            .try_get::<Vec<String>, _>("allowed_audiences")
            .map_err(|error| AuthError::Database(error.to_string()))?;
        audiences.sort();
        if row
            .try_get::<String, _>("provider_kind")
            .map_err(|error| AuthError::Database(error.to_string()))?
            != "apple"
            || row
                .try_get::<String, _>("exact_issuer")
                .map_err(|error| AuthError::Database(error.to_string()))?
                != "https://appleid.apple.com"
            || audiences
                != [
                    "dev.serikayuzuki.fuminiwa".to_string(),
                    "dev.serikayuzuki.fuminiwa.ios".to_string(),
                ]
            || !row
                .try_get::<bool, _>("enabled")
                .map_err(|error| AuthError::Database(error.to_string()))?
            || row
                .try_get::<i32, _>("config_version")
                .map_err(|error| AuthError::Database(error.to_string()))?
                != 1
        {
            return Err(AuthError::ProviderNotAllowed);
        }
        transaction
            .commit()
            .await
            .map_err(|error| AuthError::Database(error.to_string()))
    }

    pub async fn process_apple_notification(
        &self,
        body: &[u8],
        now_unix: i64,
    ) -> Result<(), AuthError> {
        #[derive(serde::Deserialize)]
        #[serde(deny_unknown_fields)]
        struct Envelope {
            payload: String,
        }
        let envelope: Envelope =
            serde_json::from_slice(body).map_err(|_| AuthError::InvalidRequest)?;
        let notification = self
            .apple
            .verify_s2s_notification(&envelope.payload, now_unix)
            .await?;
        let config =
            crate::auth_domain::ProviderConfigId::new(crate::auth_domain::APPLE_PROVIDER_CONFIG)?;
        let lookup = self
            .hasher
            .subject_lookup(
                &config,
                crate::auth_domain::APPLE_ISSUER,
                &notification.subject,
            )
            .await?;
        self.application
            .repository
            .record_apple_notification(
                &notification,
                &lookup,
                crate::auth_domain::digest_request(body),
            )
            .await
    }

    /// Bounded, restart-safe provider revocation worker. It never runs on an
    /// auth or sync request path; callers may schedule it from a background
    /// task at their preferred cadence.
    pub async fn run_apple_revocation_batch(&self, limit: i64) -> Result<usize, AuthError> {
        let now = chrono::Utc::now();
        let entries = self
            .application
            .repository
            .claim_apple_revocations(now, limit)
            .await?;
        let count = entries.len();
        for entry in entries {
            let operation = OperationId::new(format!("apple-revoke-{}", entry.credential_id))?;
            let credential = VerifiedProviderCredential {
                audience: entry.audience,
                vault_context: entry.vault_context,
                encrypted_refresh_token: entry.secret,
            };
            let result = self.apple.revoke(&credential, &operation).await;
            self.application
                .repository
                .finish_apple_revocation(
                    entry.credential_id,
                    result.as_ref().map(|_| ()),
                    now,
                    entry.attempt,
                )
                .await?;
        }
        Ok(count)
    }

    fn parsed(kind: &str, body: &[u8]) -> Result<ParsedAuthCommand, AuthApiError> {
        parse_auth_command(kind, body).map_err(AuthApiError::from)
    }

    fn context(parsed: &ParsedAuthCommand, error: AuthError) -> AuthApiError {
        match &parsed.command {
            AuthCommand::CreateChallenge(command) => {
                AuthApiError::from(error).operation(command.operation_id.clone())
            }
            AuthCommand::ExchangeApple(command) => AuthApiError::from(error)
                .operation(command.operation_id.clone())
                .challenge(command.challenge_id.clone()),
            AuthCommand::RotateRefresh(command) => {
                AuthApiError::from(error).operation(command.operation_id.clone())
            }
            AuthCommand::RevokeCurrentSession(command) => {
                AuthApiError::from(error).operation(command.operation_id.clone())
            }
        }
    }
}

#[async_trait]
impl AccessAuthenticator for ProductionAuthService {
    async fn authenticate_access(&self, token: &str) -> Result<AuthenticatedAccess, AuthError> {
        let principal = self.application.authenticate_access(token).await?;
        Ok(AuthenticatedAccess {
            account_id: principal.account_id.to_string(),
            account_fence: URL_SAFE_NO_PAD.encode(principal.account_fence),
            account_auth_epoch: principal.account_auth_epoch,
        })
    }
}

#[async_trait]
impl AuthHttpService for ProductionAuthService {
    async fn apple_notification(
        &self,
        body: &[u8],
        now_unix: i64,
    ) -> Result<AuthResponse, AuthApiError> {
        self.process_apple_notification(body, now_unix)
            .await
            .map_err(AuthApiError::from)?;
        Ok(AuthResponse::new(204, b"{}".to_vec()))
    }

    async fn create_challenge(
        &self,
        body: &[u8],
        now_unix: i64,
    ) -> Result<AuthResponse, AuthApiError> {
        let parsed = Self::parsed(CREATE_CHALLENGE_COMMAND, body)?;
        let result = self
            .application
            .create_challenge_from_wire(&parsed, now_unix)
            .await
            .map_err(|error| Self::context(&parsed, error))?;
        let replay_until =
            result.expires_at_unix - CHALLENGE_LIFETIME_SECONDS + REFRESH_TOKEN_LIFETIME_SECONDS;
        Ok(AuthResponse::new(
            201,
            encode_challenge_response(&result, replay_until)
                .map_err(|error| Self::context(&parsed, error))?,
        ))
    }

    async fn exchange(
        &self,
        challenge_id: &str,
        body: &[u8],
        now_unix: i64,
    ) -> Result<AuthResponse, AuthApiError> {
        let parsed = Self::parsed(EXCHANGE_APPLE_COMMAND, body)?;
        let AuthCommand::ExchangeApple(command) = &parsed.command else {
            return Err(AuthApiError::from(AuthError::InvalidRequest));
        };
        if command.challenge_id.as_str() != challenge_id {
            return Err(Self::context(&parsed, AuthError::InvalidRequest));
        }
        let grant = match self
            .application
            .exchange_apple_from_wire(&parsed, &self.apple, &self.hasher, &self.vault, now_unix)
            .await
        {
            Ok(value) => value,
            Err(error) => {
                if let Some(receipt) = self
                    .application
                    .repository
                    .find_operation_receipt(
                        &command.operation_id,
                        EXCHANGE_APPLE_COMMAND,
                        &parsed.digest,
                    )
                    .await
                    .map_err(|failure| Self::context(&parsed, failure))?
                {
                    return Ok(AuthResponse::new(receipt.status, receipt.response_bytes));
                }
                return Err(Self::context(&parsed, error));
            }
        };
        Ok(AuthResponse::new(
            200,
            encode_exchange_response(&grant, &self.server_instance_id, &command.operation_id)
                .map_err(|error| Self::context(&parsed, error))?,
        ))
    }

    async fn refresh(
        &self,
        refresh_token: String,
        body: &[u8],
    ) -> Result<AuthResponse, AuthApiError> {
        let parsed = Self::parsed(ROTATE_REFRESH_COMMAND, body)?;
        let AuthCommand::RotateRefresh(command) = &parsed.command else {
            return Err(AuthApiError::from(AuthError::InvalidRequest));
        };
        let outcome = self
            .application
            .refresh_from_wire(&parsed, refresh_token)
            .await
            .map_err(|error| Self::context(&parsed, error))?;
        if let Some(receipt) = outcome.receipt {
            return Ok(AuthResponse::new(receipt.status, receipt.response_bytes));
        }
        let grant = outcome
            .grant
            .ok_or_else(|| Self::context(&parsed, AuthError::Vault))?;
        Ok(AuthResponse::new(
            200,
            encode_refresh_response(&grant, &self.server_instance_id, &command.operation_id)
                .map_err(|error| Self::context(&parsed, error))?,
        ))
    }

    async fn revoke(
        &self,
        refresh_token: String,
        body: &[u8],
    ) -> Result<AuthResponse, AuthApiError> {
        let parsed = Self::parsed(REVOKE_SESSION_COMMAND, body)?;
        let session = self
            .application
            .resolve_refresh_session(&refresh_token)
            .await
            .map_err(|error| Self::context(&parsed, error))?;
        let receipt = self
            .application
            .revoke_current_session_from_wire(&parsed, session)
            .await
            .map_err(|error| Self::context(&parsed, error))?;
        Ok(AuthResponse::new(receipt.status, receipt.response_bytes))
    }

    async fn me(&self, access_token: &str) -> Result<AuthResponse, AuthApiError> {
        let principal = self
            .application
            .authenticate_access(access_token)
            .await
            .map_err(AuthApiError::from)?;
        Ok(AuthResponse::new(
            200,
            encode_me_response(&principal, &self.server_instance_id).map_err(AuthApiError::from)?,
        ))
    }
}

impl From<&AuthenticatedPrincipal> for AuthenticatedAccess {
    fn from(value: &AuthenticatedPrincipal) -> Self {
        Self {
            account_id: value.account_id.to_string(),
            account_fence: URL_SAFE_NO_PAD.encode(&value.account_fence),
            account_auth_epoch: value.account_auth_epoch,
        }
    }
}
