//! Transaction-oriented auth application services.
//!
//! The repository trait is intentionally narrower than the sync repository:
//! every method is an auth_v1 transaction and receives typed values only.

use crate::auth_domain::*;
use async_trait::async_trait;
use serde::{Deserialize, Serialize};
use uuid::Uuid;

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct NewChallenge {
    pub operation_id: OperationId,
    pub provider: String,
    pub platform: String,
    pub audience: String,
    pub state: Vec<u8>,
    pub nonce: Vec<u8>,
    pub expires_at_unix: i64,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ChallengeResult {
    pub challenge_id: ChallengeId,
    pub operation_id: OperationId,
    pub provider_config_id: ProviderConfigId,
    pub audience: String,
    pub state: Vec<u8>,
    pub nonce: Vec<u8>,
    pub expires_at_unix: i64,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ExchangeRequest {
    pub challenge_id: ChallengeId,
    pub operation_id: OperationId,
    pub state: Vec<u8>,
    pub authorization_code: Vec<u8>,
    pub identity_token: Vec<u8>,
    pub request_digest: [u8; 32],
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct AccountAuthRecord {
    pub account_id: AccountId,
    pub tenant_id: TenantId,
    pub auth_epoch: i64,
    pub fence: Vec<u8>,
    pub identity_state: IdentityState,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct RefreshOutcome {
    pub grant: Option<SessionGrant>,
    pub receipt: Option<AuthReceipt>,
    pub reused: bool,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SecurityTransition {
    pub account_auth_epoch: i64,
    pub account_fence: Vec<u8>,
    pub sessions_revoked: bool,
}

#[async_trait]
#[allow(clippy::too_many_arguments)]
pub trait AuthRepository: Send + Sync {
    async fn token_verifier(&self, purpose: &str, token: &str) -> Result<Vec<u8>, AuthError>;
    async fn authenticate_access(
        &self,
        token_verifier: Vec<u8>,
    ) -> Result<AuthenticatedPrincipal, AuthError>;
    async fn find_operation_receipt(
        &self,
        operation_id: &OperationId,
        kind: &str,
        digest: &[u8; 32],
    ) -> Result<Option<AuthReceipt>, AuthError>;
    async fn create_challenge(
        &self,
        challenge: &NewChallenge,
        state_hash: Vec<u8>,
        nonce_hash: Vec<u8>,
    ) -> Result<ChallengeResult, AuthError>;
    async fn load_challenge_for_update(
        &self,
        challenge_id: &ChallengeId,
    ) -> Result<ChallengeClaim, AuthError>;
    async fn mark_provider_call_started(&self, challenge_id: &ChallengeId)
        -> Result<(), AuthError>;
    async fn mark_provider_exchange_indeterminate(
        &self,
        challenge_id: &ChallengeId,
    ) -> Result<(), AuthError>;
    async fn mark_provider_result_known(
        &self,
        challenge_id: &ChallengeId,
        identity: &VerifiedExternalIdentity,
        sealed_result: SealedSecret,
    ) -> Result<(), AuthError>;
    async fn finish_exchange(
        &self,
        challenge_id: &ChallengeId,
        operation_id: &OperationId,
        identity: &VerifiedExternalIdentity,
        subject_lookup: Vec<u8>,
        subject_secret: SealedSecret,
        audience: &str,
        request_digest: [u8; 32],
    ) -> Result<(SessionGrant, AuthReceipt), AuthError>;
    async fn refresh(
        &self,
        request: &RefreshRequest,
        token_verifier: Vec<u8>,
    ) -> Result<RefreshOutcome, AuthError>;
    async fn revoke_current_session(
        &self,
        operation_id: &OperationId,
        request_digest: [u8; 32],
        session_id: &SessionId,
    ) -> Result<AuthReceipt, AuthError>;
    async fn rotate_account_fence(
        &self,
        account_id: &AccountId,
    ) -> Result<SecurityTransition, AuthError>;
}

#[derive(Clone)]
pub struct AuthApplication<R> {
    pub repository: R,
    pub provider_config: AppleProviderConfig,
}
impl<R> AuthApplication<R> {
    pub fn new(repository: R) -> Self {
        Self {
            repository,
            provider_config: AppleProviderConfig::default(),
        }
    }
}

impl<R: AuthRepository> AuthApplication<R> {
    pub async fn create_challenge(
        &self,
        request: NewChallenge,
    ) -> Result<ChallengeResult, AuthError> {
        if request.provider != "apple"
            || request.platform.is_empty()
            || !self.provider_config.enabled
            || !self
                .provider_config
                .audiences
                .iter()
                .any(|v| v == &request.audience)
        {
            return Err(AuthError::ProviderNotAllowed);
        }
        let state_hash = digest_request(&request.state).to_vec();
        let nonce_hash = digest_request(&request.nonce).to_vec();
        let digest = digest_request_for_challenge(&request);
        if let Some(receipt) = self
            .repository
            .find_operation_receipt(&request.operation_id, "createChallenge", &digest)
            .await?
        {
            return serde_json::from_slice(&receipt.response_bytes).map_err(|_| AuthError::Vault);
        }
        self.repository
            .create_challenge(&request, state_hash, nonce_hash)
            .await
    }

    pub async fn exchange_apple<P: AppleProvider, H: SecretHasher, V: CredentialVault>(
        &self,
        request: ExchangeRequest,
        provider: &P,
        hasher: &H,
        vault: &V,
        now_unix: i64,
    ) -> Result<SessionGrant, AuthError> {
        if request.authorization_code.is_empty()
            || request.identity_token.is_empty()
            || request.state.is_empty()
        {
            return Err(AuthError::InvalidRequest);
        }
        if let Some(receipt) = self
            .repository
            .find_operation_receipt(
                &request.operation_id,
                "exchangeApple",
                &request.request_digest,
            )
            .await?
        {
            return decode_grant_receipt(&receipt);
        }
        let challenge = self
            .repository
            .load_challenge_for_update(&request.challenge_id)
            .await?;
        if challenge.operation_id != request.operation_id {
            return Err(AuthError::OperationIdReused);
        }
        if challenge.expires_at_unix <= now_unix {
            return Err(AuthError::ChallengeExpired);
        }
        if challenge.phase == ChallengePhase::ProviderCallStarted {
            self.repository
                .mark_provider_exchange_indeterminate(&request.challenge_id)
                .await?;
            return Err(AuthError::ProviderExchangeIndeterminate);
        }
        if challenge.phase == ChallengePhase::Terminal
            || challenge.phase == ChallengePhase::ProviderResultKnown
        {
            return Err(AuthError::ChallengeConsumed);
        }
        if challenge.phase != ChallengePhase::Claimed {
            return Err(AuthError::InvalidChallengePhase);
        }
        if challenge.state_hash != digest_request(&request.state) {
            return Err(AuthError::InvalidRequest);
        }
        self.repository
            .mark_provider_call_started(&request.challenge_id)
            .await?;
        let identity = match provider
            .exchange(
                &challenge,
                &request.authorization_code,
                &request.identity_token,
            )
            .await
        {
            Ok(value) => value,
            Err(AuthError::ProviderExchangeIndeterminate) => {
                self.repository
                    .mark_provider_exchange_indeterminate(&request.challenge_id)
                    .await?;
                return Err(AuthError::ProviderExchangeIndeterminate);
            }
            Err(error) => return Err(error),
        };
        identity.validate_apple()?;
        if now_unix - identity.authenticated_at_unix > 300
            || identity.authenticated_at_unix - now_unix > 300
        {
            return Err(AuthError::InvalidRequest);
        }
        let subject_lookup = hasher
            .subject_lookup(
                &identity.provider_config_id,
                &identity.exact_issuer,
                &identity.subject,
            )
            .await?;
        let mut subject_bytes = b"FUMINIWA-EXTERNAL-IDENTITY-V1".to_vec();
        for value in [
            identity.provider_config_id.as_str(),
            identity.exact_issuer.as_str(),
            identity.subject.as_str(),
        ] {
            let length =
                u32::try_from(value.len()).map_err(|_| AuthError::InvalidExternalIdentity)?;
            subject_bytes.extend_from_slice(&length.to_be_bytes());
            subject_bytes.extend_from_slice(value.as_bytes());
        }
        let subject_secret = vault
            .seal(
                "external_identity_subject_v1",
                &request.challenge_id.to_string(),
                &subject_bytes,
            )
            .await?;
        let result_secret = vault
            .seal(
                "apple_exchange_result_v1",
                &request.challenge_id.to_string(),
                &request.identity_token,
            )
            .await?;
        self.repository
            .mark_provider_result_known(&request.challenge_id, &identity, result_secret)
            .await?;
        let (grant, _) = self
            .repository
            .finish_exchange(
                &request.challenge_id,
                &request.operation_id,
                &identity,
                subject_lookup,
                subject_secret,
                &challenge.audience,
                request.request_digest,
            )
            .await?;
        Ok(grant)
    }

    pub async fn refresh(&self, request: RefreshRequest) -> Result<RefreshOutcome, AuthError> {
        let verifier = self
            .repository
            .token_verifier("refresh", &request.refresh_token)
            .await?;
        self.repository.refresh(&request, verifier).await
    }

    pub async fn authenticate_access(
        &self,
        access_token: &str,
    ) -> Result<AuthenticatedPrincipal, AuthError> {
        let verifier = self
            .repository
            .token_verifier("access", access_token)
            .await?;
        self.repository.authenticate_access(verifier).await
    }

    pub async fn revoke_current_session(
        &self,
        operation_id: OperationId,
        digest: [u8; 32],
        session_id: SessionId,
    ) -> Result<AuthReceipt, AuthError> {
        self.repository
            .revoke_current_session(&operation_id, digest, &session_id)
            .await
    }
}

fn digest_request_for_challenge(request: &NewChallenge) -> [u8; 32] {
    let mut bytes = request.operation_id.to_string().into_bytes();
    bytes.extend_from_slice(request.provider.as_bytes());
    bytes.extend_from_slice(request.platform.as_bytes());
    bytes.extend_from_slice(request.audience.as_bytes());
    digest_request(&bytes)
}

fn decode_grant_receipt(receipt: &AuthReceipt) -> Result<SessionGrant, AuthError> {
    serde_json::from_slice(&receipt.response_bytes).map_err(|_| AuthError::Vault)
}

/// A test-only hasher. Production composition must inject an HMAC-backed
/// implementation; this type is not exported from the HTTP runtime.
#[derive(Clone)]
pub struct FixtureHasher {
    pub subject_lookup_key: [u8; 32],
    pub token_key: [u8; 32],
}
impl Default for FixtureHasher {
    fn default() -> Self {
        Self {
            subject_lookup_key: [0x11; 32],
            token_key: [0x22; 32],
        }
    }
}
#[async_trait]
impl SecretHasher for FixtureHasher {
    async fn subject_lookup(
        &self,
        provider_config: &ProviderConfigId,
        issuer: &str,
        subject: &str,
    ) -> Result<Vec<u8>, AuthError> {
        subject_lookup_hmac(&self.subject_lookup_key, provider_config, issuer, subject)
    }
    async fn token_verifier(&self, purpose: &str, token: &str) -> Result<Vec<u8>, AuthError> {
        token_hmac(&self.token_key, purpose, token)
    }
}

pub fn fixture_ids() -> (AccountId, TenantId, SessionId) {
    (
        AccountId::new("acct_fixture").unwrap(),
        TenantId::new("tenant_fixture").unwrap(),
        SessionId::new(Uuid::new_v4().to_string()).unwrap(),
    )
}
