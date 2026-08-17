//! Authentication v1 domain for the Snapshot Sync v2 server.
//!
//! This module deliberately contains no Axum, SQLx, or Apple SDK code.  A
//! provider adapter ends at `VerifiedExternalIdentity`; the sync side only
//! receives an `AuthenticatedPrincipal` issued by the auth application.

use async_trait::async_trait;
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

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
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

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub struct VerifiedExternalIdentity {
    pub provider_config_id: ProviderConfigId,
    pub exact_issuer: String,
    /// This value is memory-only.  Persistence receives only a versioned HMAC
    /// and an envelope ciphertext returned by the vault port.
    #[serde(skip)]
    pub subject: String,
    pub authenticated_at_unix: i64,
    /// Already envelope-encrypted provider refresh material. It never enters
    /// the sync domain or a plaintext log/database field.
    #[serde(skip)]
    pub provider_credential: Option<VerifiedProviderCredential>,
}
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct VerifiedProviderCredential {
    pub audience: String,
    pub encrypted_refresh_token: SealedSecret,
}
impl VerifiedExternalIdentity {
    pub fn apple(
        subject: impl Into<String>,
        authenticated_at_unix: i64,
    ) -> Result<Self, AuthError> {
        let subject = subject.into();
        if subject.is_empty() || subject.len() > 512 || subject.bytes().any(|b| b == 0) {
            return Err(AuthError::InvalidExternalIdentity);
        }
        Ok(Self {
            provider_config_id: ProviderConfigId::new(APPLE_PROVIDER_CONFIG)?,
            exact_issuer: APPLE_ISSUER.into(),
            subject,
            authenticated_at_unix,
            provider_credential: None,
        })
    }
    pub fn validate_apple(&self) -> Result<(), AuthError> {
        if self.provider_config_id.as_str() != APPLE_PROVIDER_CONFIG
            || self.exact_issuer != APPLE_ISSUER
        {
            return Err(AuthError::ProviderNotAllowed);
        }
        if self.subject.is_empty() {
            return Err(AuthError::InvalidExternalIdentity);
        }
        Ok(())
    }
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub struct AuthenticatedPrincipal {
    pub account_id: AccountId,
    pub tenant_id: TenantId,
    pub session_id: SessionId,
    pub account_auth_epoch: i64,
    pub account_fence: Vec<u8>,
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
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub struct SessionGrant {
    pub principal: AuthenticatedPrincipal,
    pub access_token: String,
    pub refresh_token: String,
    pub refresh_generation: i64,
    pub access_expires_at_unix: i64,
    pub refresh_expires_at_unix: i64,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct RefreshRequest {
    pub operation_id: OperationId,
    pub refresh_token: String,
    pub request_digest: [u8; 32],
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct AuthReceipt {
    pub operation_id: OperationId,
    pub command_kind: String,
    pub request_digest: [u8; 32],
    pub response_bytes: Vec<u8>,
    pub status: u16,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct SealedSecret {
    pub key_version: i32,
    pub ciphertext: Vec<u8>,
}

#[async_trait]
pub trait CredentialVault: Send + Sync {
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
    ) -> Result<VerifiedExternalIdentity, AuthError>;
    async fn revoke(
        &self,
        credential_id: &CredentialId,
        audience: &str,
        operation_id: &OperationId,
    ) -> Result<(), AuthError>;
}

pub fn digest_request(bytes: &[u8]) -> [u8; 32] {
    Sha256::digest(bytes).into()
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
