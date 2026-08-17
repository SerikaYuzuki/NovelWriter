//! Authentication v1 domain for the Snapshot Sync v2 server.
//!
//! This module deliberately contains no Axum, SQLx, or Apple SDK code.  A
//! provider adapter ends at `VerifiedExternalIdentity`; the sync side only
//! receives an `AuthenticatedPrincipal` issued by the auth application.

use async_trait::async_trait;
use hmac::{Hmac, Mac};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::{fmt, str::FromStr};
use uuid::Uuid;

pub const AUTH_PROTOCOL_EPOCH: i64 = 1;
pub const AUTH_PROTOCOL_VERSION: &str = "1.0.0";
pub const APPLE_PROVIDER_CONFIG: &str = "apple-primary-fuminiwa-v1";
pub const APPLE_ISSUER: &str = "https://appleid.apple.com";
pub const ACCESS_TOKEN_LIFETIME_SECONDS: i64 = 900;
pub const REFRESH_TOKEN_LIFETIME_SECONDS: i64 = 7_776_000;
pub const CHALLENGE_LIFETIME_SECONDS: i64 = 300;
pub const TOKEN_HMAC_KEY_VERSION: i32 = 1;
pub const SUBJECT_LOOKUP_KEY_VERSION: i32 = 1;
pub const CREATE_CHALLENGE_COMMAND: &str = "createChallenge";
pub const EXCHANGE_APPLE_COMMAND: &str = "exchangeAppleNativeCredential";
pub const ROTATE_REFRESH_COMMAND: &str = "rotateRefreshToken";
pub const REVOKE_SESSION_COMMAND: &str = "revokeCurrentSession";
pub const ROTATE_ACCOUNT_FENCE_COMMAND: &str = "rotateAccountFence";
type HmacSha256 = Hmac<Sha256>;

macro_rules! opaque_id {
    ($name:ident) => {
        #[derive(Clone, Debug, Eq, Hash, Ord, PartialEq, PartialOrd, Serialize, Deserialize)]
        #[serde(transparent)]
        pub struct $name(String);
        impl $name {
            pub fn new(value: impl Into<String>) -> Result<Self, AuthError> {
                let value = value.into();
                if value.is_empty()
                    || value.len() > 200
                    || value.bytes().any(|b| b < 0x21 || b == 0x7f)
                {
                    return Err(AuthError::InvalidIdentifier);
                }
                Ok(Self(value))
            }
            pub fn random(prefix: &str) -> Self {
                Self(format!("{prefix}_{}", Uuid::new_v4()))
            }
            pub fn as_str(&self) -> &str {
                &self.0
            }
        }
        impl FromStr for $name {
            type Err = AuthError;
            fn from_str(value: &str) -> Result<Self, Self::Err> {
                Self::new(value)
            }
        }
        impl fmt::Display for $name {
            fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
                f.write_str(&self.0)
            }
        }
    };
}

opaque_id!(AccountId);
opaque_id!(TenantId);
opaque_id!(SessionId);
opaque_id!(SessionFamilyId);
opaque_id!(ChallengeId);
opaque_id!(OperationId);
opaque_id!(ProviderConfigId);
opaque_id!(CredentialId);

#[derive(Clone, Eq, PartialEq, Serialize, Deserialize)]
pub struct AccountFence {
    pub epoch: i64,
    pub value: Vec<u8>,
}
impl AccountFence {
    pub fn new(epoch: i64, value: Vec<u8>) -> Result<Self, AuthError> {
        if epoch < 1 || value.len() != 32 {
            return Err(AuthError::InvalidFence);
        }
        Ok(Self { epoch, value })
    }
}

#[derive(Clone, Eq, PartialEq)]
pub struct AppleIdentityEvidence {
    provider_config_id: ProviderConfigId,
    exact_issuer: String,
    subject: String,
    audience: String,
    nonce_hash: Vec<u8>,
    authenticated_at_unix: i64,
    provider_credential: Option<VerifiedProviderCredential>,
}
impl AppleIdentityEvidence {
    #[allow(clippy::too_many_arguments)]
    pub fn from_verified_claims(
        provider_config_id: ProviderConfigId,
        exact_issuer: impl Into<String>,
        subject: impl Into<String>,
        audience: impl Into<String>,
        nonce_hash: Vec<u8>,
        authenticated_at_unix: i64,
        provider_credential: Option<VerifiedProviderCredential>,
    ) -> Result<Self, AuthError> {
        let exact_issuer = exact_issuer.into();
        let subject = subject.into();
        let audience = audience.into();
        if exact_issuer.is_empty()
            || subject.is_empty()
            || subject.len() > 512
            || subject.bytes().any(|byte| byte == 0)
            || audience.is_empty()
            || audience.len() > 255
            || nonce_hash.len() != 32
        {
            return Err(AuthError::InvalidExternalIdentity);
        }
        Ok(Self {
            provider_config_id,
            exact_issuer,
            subject,
            audience,
            nonce_hash,
            authenticated_at_unix,
            provider_credential,
        })
    }
}
impl fmt::Debug for AppleIdentityEvidence {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("AppleIdentityEvidence")
            .field("provider_config_id", &self.provider_config_id)
            .field("exact_issuer", &self.exact_issuer)
            .field("subject", &"<redacted>")
            .field("audience", &self.audience)
            .field("nonce_hash", &"<redacted>")
            .field("authenticated_at_unix", &self.authenticated_at_unix)
            .field("provider_credential", &self.provider_credential.is_some())
            .finish()
    }
}

#[derive(Clone, Eq, PartialEq)]
pub struct VerifiedExternalIdentity {
    provider_config_id: ProviderConfigId,
    exact_issuer: String,
    subject: String,
    verified_audience: String,
    verified_nonce_hash: Vec<u8>,
    provider_authenticated_at_unix: i64,
    freshness_verified_at_unix: i64,
    provider_credential: Option<VerifiedProviderCredential>,
}
impl fmt::Debug for VerifiedExternalIdentity {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("VerifiedExternalIdentity")
            .field("provider_config_id", &self.provider_config_id)
            .field("exact_issuer", &self.exact_issuer)
            .field("subject", &"<redacted>")
            .field("verified_audience", &self.verified_audience)
            .field("verified_nonce_hash", &"<redacted>")
            .field(
                "provider_authenticated_at_unix",
                &self.provider_authenticated_at_unix,
            )
            .field(
                "freshness_verified_at_unix",
                &self.freshness_verified_at_unix,
            )
            .field("provider_credential", &self.provider_credential.is_some())
            .finish()
    }
}
#[derive(Clone, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct VerifiedProviderCredential {
    pub audience: String,
    /// Opaque vault AAD context used to recover this credential generation.
    pub vault_context: String,
    pub encrypted_refresh_token: SealedSecret,
}
impl fmt::Debug for VerifiedProviderCredential {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("VerifiedProviderCredential")
            .field("audience", &self.audience)
            .field("vault_context", &self.vault_context)
            .field("encrypted_refresh_token", &"<redacted>")
            .finish()
    }
}
#[derive(Clone, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct DurableVerifiedIdentity {
    pub provider_config_id: ProviderConfigId,
    pub exact_issuer: String,
    pub subject: String,
    pub verified_audience: String,
    pub verified_nonce_hash: Vec<u8>,
    pub provider_authenticated_at_unix: i64,
    pub freshness_verified_at_unix: i64,
    pub provider_credential: Option<VerifiedProviderCredential>,
}
impl fmt::Debug for DurableVerifiedIdentity {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("DurableVerifiedIdentity")
            .field("provider_config_id", &self.provider_config_id)
            .field("exact_issuer", &self.exact_issuer)
            .field("subject", &"<redacted>")
            .field("verified_audience", &self.verified_audience)
            .field("verified_nonce_hash", &"<redacted>")
            .field(
                "provider_authenticated_at_unix",
                &self.provider_authenticated_at_unix,
            )
            .field(
                "freshness_verified_at_unix",
                &self.freshness_verified_at_unix,
            )
            .field("provider_credential", &self.provider_credential.is_some())
            .finish()
    }
}
impl From<&VerifiedExternalIdentity> for DurableVerifiedIdentity {
    fn from(value: &VerifiedExternalIdentity) -> Self {
        Self {
            provider_config_id: value.provider_config_id.clone(),
            exact_issuer: value.exact_issuer.clone(),
            subject: value.subject.clone(),
            verified_audience: value.verified_audience.clone(),
            verified_nonce_hash: value.verified_nonce_hash.clone(),
            provider_authenticated_at_unix: value.provider_authenticated_at_unix,
            freshness_verified_at_unix: value.freshness_verified_at_unix,
            provider_credential: value.provider_credential.clone(),
        }
    }
}
impl From<DurableVerifiedIdentity> for VerifiedExternalIdentity {
    fn from(value: DurableVerifiedIdentity) -> Self {
        Self {
            provider_config_id: value.provider_config_id,
            exact_issuer: value.exact_issuer,
            subject: value.subject,
            verified_audience: value.verified_audience,
            verified_nonce_hash: value.verified_nonce_hash,
            provider_authenticated_at_unix: value.provider_authenticated_at_unix,
            freshness_verified_at_unix: value.freshness_verified_at_unix,
            provider_credential: value.provider_credential,
        }
    }
}
impl VerifiedExternalIdentity {
    pub fn bind_apple(
        evidence: AppleIdentityEvidence,
        challenge: &ChallengeClaim,
        freshness_verified_at_unix: i64,
    ) -> Result<Self, AuthError> {
        if evidence.provider_config_id.as_str() != APPLE_PROVIDER_CONFIG
            || evidence.provider_config_id != challenge.provider_config_id
            || evidence.exact_issuer != APPLE_ISSUER
            || evidence.audience != challenge.audience
        {
            return Err(AuthError::ProviderNotAllowed);
        }
        if evidence.nonce_hash != challenge.nonce_hash
            || evidence
                .authenticated_at_unix
                .abs_diff(freshness_verified_at_unix)
                > 300
            || evidence
                .provider_credential
                .as_ref()
                .is_some_and(|credential| {
                    credential.audience != challenge.audience
                        || credential.vault_context.is_empty()
                        || credential.vault_context.len() > 512
                })
        {
            return Err(AuthError::InvalidRequest);
        }
        Ok(Self {
            provider_config_id: evidence.provider_config_id,
            exact_issuer: evidence.exact_issuer,
            subject: evidence.subject,
            verified_audience: evidence.audience,
            verified_nonce_hash: evidence.nonce_hash,
            provider_authenticated_at_unix: evidence.authenticated_at_unix,
            freshness_verified_at_unix,
            provider_credential: evidence.provider_credential,
        })
    }
    pub fn validate_durable_for_challenge(
        &self,
        challenge: &ChallengeClaim,
    ) -> Result<(), AuthError> {
        if self.provider_config_id.as_str() != APPLE_PROVIDER_CONFIG
            || self.provider_config_id != challenge.provider_config_id
            || self.exact_issuer != APPLE_ISSUER
            || self.verified_audience != challenge.audience
        {
            return Err(AuthError::ProviderNotAllowed);
        }
        if self.verified_nonce_hash != challenge.nonce_hash
            || self
                .provider_authenticated_at_unix
                .abs_diff(self.freshness_verified_at_unix)
                > 300
            || self.provider_credential.as_ref().is_some_and(|credential| {
                credential.audience != challenge.audience
                    || credential.vault_context.is_empty()
                    || credential.vault_context.len() > 512
            })
        {
            return Err(AuthError::InvalidRequest);
        }
        if self.subject.is_empty()
            || self.subject.len() > 512
            || self.subject.bytes().any(|byte| byte == 0)
        {
            return Err(AuthError::InvalidExternalIdentity);
        }
        Ok(())
    }
    pub fn provider_config_id(&self) -> &ProviderConfigId {
        &self.provider_config_id
    }
    pub fn exact_issuer(&self) -> &str {
        &self.exact_issuer
    }
    pub fn subject(&self) -> &str {
        &self.subject
    }
    pub fn provider_credential(&self) -> Option<&VerifiedProviderCredential> {
        self.provider_credential.as_ref()
    }
}

#[derive(Clone, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct AuthenticatedPrincipal {
    pub account_id: AccountId,
    pub tenant_id: TenantId,
    pub session_id: SessionId,
    pub account_auth_epoch: i64,
    pub account_fence: Vec<u8>,
}
impl fmt::Debug for AuthenticatedPrincipal {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("AuthenticatedPrincipal")
            .field("account_id", &self.account_id)
            .field("tenant_id", &self.tenant_id)
            .field("session_id", &self.session_id)
            .field("account_auth_epoch", &self.account_auth_epoch)
            .field("account_fence", &"<redacted>")
            .finish()
    }
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub enum AccountState {
    Active,
    Locked,
    DeletionPending,
    Deleted,
}
#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub enum IdentityState {
    Pending,
    Active,
    Revoked,
    Unlinked,
    ProviderDeleted,
}
#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub enum SessionState {
    Active,
    ReauthRequired,
    Revoked,
    Expired,
}
#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub enum RefreshFamilyState {
    Active,
    Rotated,
    ReuseDetected,
    Revoked,
    Expired,
}
impl RefreshFamilyState {
    pub fn can_rotate(&self) -> bool {
        matches!(self, Self::Active)
    }
    pub fn can_revoke_for_reuse(&self) -> bool {
        matches!(self, Self::Active | Self::Rotated)
    }
}
#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub enum ChallengePhase {
    Claimed,
    ProviderCallStarted,
    ProviderResultKnown,
    Terminal,
}
impl ChallengePhase {
    pub fn can_start_provider(&self) -> bool {
        matches!(self, Self::Claimed)
    }
    pub fn can_store_result(&self) -> bool {
        matches!(self, Self::ProviderCallStarted)
    }
    pub fn can_terminal(&self) -> bool {
        matches!(self, Self::ProviderResultKnown)
    }
}
#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub enum CredentialState {
    Active,
    Superseded,
    RevokeRetryPending,
    Revoked,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub struct AppleProviderConfig {
    pub id: ProviderConfigId,
    pub issuer: String,
    pub audiences: Vec<String>,
    pub enabled: bool,
}
impl Default for AppleProviderConfig {
    fn default() -> Self {
        Self {
            id: ProviderConfigId::new(APPLE_PROVIDER_CONFIG).expect("constant"),
            issuer: APPLE_ISSUER.into(),
            audiences: vec![
                "dev.serikayuzuki.fuminiwa".into(),
                "dev.serikayuzuki.fuminiwa.ios".into(),
            ],
            enabled: true,
        }
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ChallengeClaim {
    pub id: ChallengeId,
    pub operation_id: OperationId,
    pub provider_config_id: ProviderConfigId,
    pub audience: String,
    pub platform: String,
    pub state_hash: Vec<u8>,
    pub nonce_hash: Vec<u8>,
    pub phase: ChallengePhase,
    pub lease_until_unix: i64,
    pub expires_at_unix: i64,
}
#[derive(Clone, Debug, Eq, PartialEq)]
pub enum ChallengeClaimResult {
    ProviderCallRequired(ChallengeClaim),
    ProviderResultKnown(ChallengeClaim, SealedSecret),
    ProviderExchangeIndeterminate,
}

#[derive(Clone, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct SessionGrant {
    pub principal: AuthenticatedPrincipal,
    pub access_token: String,
    pub refresh_token: String,
    pub refresh_generation: i64,
    pub access_expires_at_unix: i64,
    pub refresh_expires_at_unix: i64,
}
impl fmt::Debug for SessionGrant {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("SessionGrant")
            .field("principal", &self.principal)
            .field("access_token", &"<redacted>")
            .field("refresh_token", &"<redacted>")
            .field("refresh_generation", &self.refresh_generation)
            .field("access_expires_at_unix", &self.access_expires_at_unix)
            .field("refresh_expires_at_unix", &self.refresh_expires_at_unix)
            .finish()
    }
}

#[derive(Clone, Eq, PartialEq)]
pub struct RefreshRequest {
    pub operation_id: OperationId,
    pub refresh_token: String,
    pub request_digest: [u8; 32],
}
impl fmt::Debug for RefreshRequest {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("RefreshRequest")
            .field("operation_id", &self.operation_id)
            .field("refresh_token", &"<redacted>")
            .field("request_digest", &"<redacted>")
            .finish()
    }
}

#[derive(Clone, Eq, PartialEq)]
pub struct AuthReceipt {
    pub operation_id: OperationId,
    pub command_kind: String,
    pub request_digest: [u8; 32],
    pub response_bytes: Vec<u8>,
    pub status: u16,
    /// Hydrated only inside the auth repository. Exact wire bytes never expose
    /// the internal TenantID, but application replay still needs the same
    /// domain grant without issuing a second session.
    pub session_grant: Option<SessionGrant>,
}
impl fmt::Debug for AuthReceipt {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("AuthReceipt")
            .field("operation_id", &self.operation_id)
            .field("command_kind", &self.command_kind)
            .field("request_digest", &"<redacted>")
            .field("response_bytes", &"<redacted>")
            .field("status", &self.status)
            .field("session_grant", &self.session_grant)
            .finish()
    }
}

#[derive(Clone, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct SealedSecret {
    pub key_version: i32,
    pub ciphertext: Vec<u8>,
}
impl fmt::Debug for SealedSecret {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("SealedSecret")
            .field("key_version", &self.key_version)
            .field("ciphertext", &"<redacted>")
            .finish()
    }
}

#[async_trait]
pub trait CredentialVault: Send + Sync {
    fn active_key_version(&self) -> i32;
    async fn seal(
        &self,
        purpose: &str,
        row_id: &str,
        plaintext: &[u8],
    ) -> Result<SealedSecret, AuthError>;
    async fn open(
        &self,
        purpose: &str,
        row_id: &str,
        secret: &SealedSecret,
    ) -> Result<Vec<u8>, AuthError>;
}

#[async_trait]
pub trait SecretHasher: Send + Sync {
    async fn subject_lookup(
        &self,
        provider_config: &ProviderConfigId,
        issuer: &str,
        subject: &str,
    ) -> Result<Vec<u8>, AuthError>;
    async fn token_verifier(&self, purpose: &str, token: &str) -> Result<Vec<u8>, AuthError>;
}

#[async_trait]
pub trait AppleProvider: Send + Sync {
    async fn exchange(
        &self,
        challenge: &ChallengeClaim,
        authorization_code: &[u8],
        identity_token: &[u8],
    ) -> Result<AppleIdentityEvidence, AuthError>;
    async fn revoke(
        &self,
        credential: &VerifiedProviderCredential,
        operation_id: &OperationId,
    ) -> Result<(), AuthError>;
}

pub fn digest_request(bytes: &[u8]) -> [u8; 32] {
    Sha256::digest(bytes).into()
}

pub fn token_hmac(key: &[u8; 32], purpose: &str, token: &str) -> Result<Vec<u8>, AuthError> {
    let mut mac = HmacSha256::new_from_slice(key).map_err(|_| AuthError::Vault)?;
    mac.update(b"FUMINIWA-TOKEN-V1");
    let purpose_len = u32::try_from(purpose.len()).map_err(|_| AuthError::InvalidRequest)?;
    let token_len = u32::try_from(token.len()).map_err(|_| AuthError::InvalidRequest)?;
    mac.update(&purpose_len.to_be_bytes());
    mac.update(purpose.as_bytes());
    mac.update(&token_len.to_be_bytes());
    mac.update(token.as_bytes());
    Ok(mac.finalize().into_bytes().to_vec())
}

pub fn subject_lookup_hmac(
    key: &[u8; 32],
    provider_config: &ProviderConfigId,
    issuer: &str,
    subject: &str,
) -> Result<Vec<u8>, AuthError> {
    let mut mac = HmacSha256::new_from_slice(key).map_err(|_| AuthError::Vault)?;
    mac.update(b"FUMINIWA-EXTERNAL-IDENTITY-LOOKUP-V1");
    for value in [provider_config.as_str(), issuer, subject] {
        let length = u32::try_from(value.len()).map_err(|_| AuthError::InvalidExternalIdentity)?;
        mac.update(&length.to_be_bytes());
        mac.update(value.as_bytes());
    }
    Ok(mac.finalize().into_bytes().to_vec())
}

#[derive(Clone, Debug, Eq, PartialEq, thiserror::Error)]
pub enum AuthError {
    #[error("invalid identifier")]
    InvalidIdentifier,
    #[error("invalid account fence")]
    InvalidFence,
    #[error("invalid external identity")]
    InvalidExternalIdentity,
    #[error("provider is not allowed")]
    ProviderNotAllowed,
    #[error("invalid challenge phase")]
    InvalidChallengePhase,
    #[error("challenge expired")]
    ChallengeExpired,
    #[error("challenge already consumed")]
    ChallengeConsumed,
    #[error("operation id reused")]
    OperationIdReused,
    #[error("refresh token reused")]
    RefreshTokenReused,
    #[error("session revoked")]
    SessionRevoked,
    #[error("account fence mismatch")]
    FenceMismatch,
    #[error("account not found")]
    AccountNotFound,
    #[error("not found")]
    NotFound,
    #[error("provider exchange indeterminate")]
    ProviderExchangeIndeterminate,
    #[error("vault error")]
    Vault,
    #[error("database error: {0}")]
    Database(String),
    #[error("invalid request")]
    InvalidRequest,
}
