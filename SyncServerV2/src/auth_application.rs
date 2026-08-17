//! Transaction-oriented auth application services.
//!
//! The repository trait is intentionally narrower than the sync repository:
//! every method is an auth_v1 transaction and receives typed values only.

use crate::auth_domain::*;
use crate::auth_wire::{AuthCommand, ParsedAuthCommand};
use async_trait::async_trait;
use base64::{engine::general_purpose::URL_SAFE_NO_PAD, Engine};
use serde::{Deserialize, Serialize};
use std::fmt;
use uuid::Uuid;

#[derive(Clone, Eq, PartialEq)]
pub struct NewChallenge {
    pub operation_id: OperationId,
    pub provider: String,
    pub platform: String,
    pub audience: String,
    pub state: String,
    pub nonce: String,
    pub expires_at_unix: i64,
    pub request_digest: [u8; 32],
}
impl fmt::Debug for NewChallenge {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("NewChallenge")
            .field("operation_id", &self.operation_id)
            .field("provider", &self.provider)
            .field("platform", &self.platform)
            .field("audience", &self.audience)
            .field("state", &"<redacted>")
            .field("nonce", &"<redacted>")
            .field("expires_at_unix", &self.expires_at_unix)
            .field("request_digest", &"<redacted>")
            .finish()
    }
}

#[derive(Clone, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct ChallengeResult {
    pub challenge_id: ChallengeId,
    pub operation_id: OperationId,
    pub provider_config_id: ProviderConfigId,
    pub audience: String,
    pub state: String,
    pub nonce: String,
    pub expires_at_unix: i64,
}
impl fmt::Debug for ChallengeResult {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("ChallengeResult")
            .field("challenge_id", &self.challenge_id)
            .field("operation_id", &self.operation_id)
            .field("provider_config_id", &self.provider_config_id)
            .field("audience", &self.audience)
            .field("state", &"<redacted>")
            .field("nonce", &"<redacted>")
            .field("expires_at_unix", &self.expires_at_unix)
            .finish()
    }
}

#[derive(Clone, Eq, PartialEq)]
pub struct ExchangeRequest {
    pub challenge_id: ChallengeId,
    pub operation_id: OperationId,
    pub state: Vec<u8>,
    pub authorization_code: Vec<u8>,
    pub identity_token: Vec<u8>,
    pub request_digest: [u8; 32],
}
impl fmt::Debug for ExchangeRequest {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("ExchangeRequest")
            .field("challenge_id", &self.challenge_id)
            .field("operation_id", &self.operation_id)
            .field("state", &"<redacted>")
            .field("authorization_code", &"<redacted>")
            .field("identity_token", &"<redacted>")
            .field("request_digest", &"<redacted>")
            .finish()
    }
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
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct SecurityTransition {
    pub account_auth_epoch: i64,
    pub account_fence: Vec<u8>,
    pub sessions_reauth_required: bool,
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
    async fn reserve_operation(
        &self,
        operation_id: &OperationId,
        kind: &str,
        digest: &[u8; 32],
    ) -> Result<(), AuthError>;
    async fn create_challenge(
        &self,
        challenge: &NewChallenge,
        state_hash: Vec<u8>,
        nonce_hash: Vec<u8>,
    ) -> Result<ChallengeResult, AuthError>;
    async fn claim_challenge_for_exchange(
        &self,
        challenge_id: &ChallengeId,
        operation_id: &OperationId,
        state_hash: &[u8],
        now_unix: i64,
    ) -> Result<ChallengeClaimResult, AuthError>;
    async fn mark_provider_exchange_indeterminate(
        &self,
        challenge_id: &ChallengeId,
        operation_id: &OperationId,
        request_digest: [u8; 32],
    ) -> Result<(), AuthError>;
    async fn mark_provider_result_known(
        &self,
        challenge_id: &ChallengeId,
        operation_id: &OperationId,
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
        platform: &str,
        now_unix: i64,
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
        operation_id: &OperationId,
        request_digest: [u8; 32],
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
    pub async fn create_challenge_from_wire(
        &self,
        parsed: &ParsedAuthCommand,
        now_unix: i64,
    ) -> Result<ChallengeResult, AuthError> {
        let AuthCommand::CreateChallenge(command) = &parsed.command else {
            return Err(AuthError::InvalidRequest);
        };
        let mut state = [0_u8; 32];
        let mut nonce = [0_u8; 32];
        getrandom::getrandom(&mut state).map_err(|_| AuthError::Vault)?;
        getrandom::getrandom(&mut nonce).map_err(|_| AuthError::Vault)?;
        self.create_challenge(NewChallenge {
            operation_id: command.operation_id.clone(),
            provider: "apple".into(),
            platform: command.platform.as_str().into(),
            audience: command.platform.audience().into(),
            state: URL_SAFE_NO_PAD.encode(state),
            nonce: URL_SAFE_NO_PAD.encode(nonce),
            expires_at_unix: now_unix + CHALLENGE_LIFETIME_SECONDS,
            request_digest: parsed.digest,
        })
        .await
    }

    async fn create_challenge(&self, request: NewChallenge) -> Result<ChallengeResult, AuthError> {
        let expected_audience = match request.platform.as_str() {
            "macos" => "dev.serikayuzuki.fuminiwa",
            "ios" | "ipados" => "dev.serikayuzuki.fuminiwa.ios",
            _ => return Err(AuthError::ProviderNotAllowed),
        };
        if request.provider != "apple"
            || request.audience != expected_audience
            || !self.provider_config.enabled
            || !self
                .provider_config
                .audiences
                .iter()
                .any(|v| v == &request.audience)
        {
            return Err(AuthError::ProviderNotAllowed);
        }
        let state_hash = digest_request(request.state.as_bytes()).to_vec();
        let nonce_hash = digest_request(request.nonce.as_bytes()).to_vec();
        let digest = request.request_digest;
        if let Some(receipt) = self
            .repository
            .find_operation_receipt(&request.operation_id, CREATE_CHALLENGE_COMMAND, &digest)
            .await?
        {
            return crate::auth_wire::decode_challenge_response(&receipt.response_bytes);
        }
        self.repository
            .create_challenge(&request, state_hash, nonce_hash)
            .await
    }

    async fn exchange_apple<P: AppleProvider, H: SecretHasher, V: CredentialVault>(
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
                EXCHANGE_APPLE_COMMAND,
                &request.request_digest,
            )
            .await?
        {
            return decode_exchange_receipt(&receipt);
        }
        self.repository
            .reserve_operation(
                &request.operation_id,
                EXCHANGE_APPLE_COMMAND,
                &request.request_digest,
            )
            .await?;
        if let Some(receipt) = self
            .repository
            .find_operation_receipt(
                &request.operation_id,
                EXCHANGE_APPLE_COMMAND,
                &request.request_digest,
            )
            .await?
        {
            return decode_exchange_receipt(&receipt);
        }
        let claimed = self
            .repository
            .claim_challenge_for_exchange(
                &request.challenge_id,
                &request.operation_id,
                &digest_request(&request.state),
                now_unix,
            )
            .await?;
        let (challenge, identity) = match claimed {
            ChallengeClaimResult::ProviderExchangeIndeterminate => {
                self.repository
                    .mark_provider_exchange_indeterminate(
                        &request.challenge_id,
                        &request.operation_id,
                        request.request_digest,
                    )
                    .await?;
                return Err(AuthError::ProviderExchangeIndeterminate);
            }
            ChallengeClaimResult::ProviderResultKnown(challenge, secret) => {
                let bytes = vault
                    .open(
                        "verified_external_identity_v1",
                        request.challenge_id.as_str(),
                        &secret,
                    )
                    .await?;
                let durable: DurableVerifiedIdentity =
                    serde_json::from_slice(&bytes).map_err(|_| AuthError::Vault)?;
                (challenge, VerifiedExternalIdentity::from(durable))
            }
            ChallengeClaimResult::ProviderCallRequired(challenge) => {
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
                            .mark_provider_exchange_indeterminate(
                                &request.challenge_id,
                                &request.operation_id,
                                request.request_digest,
                            )
                            .await?;
                        return Err(AuthError::ProviderExchangeIndeterminate);
                    }
                    Err(error) => return Err(error),
                };
                identity.validate_apple()?;
                if let Some(credential) = &identity.provider_credential {
                    if credential.audience != challenge.audience {
                        return Err(AuthError::ProviderNotAllowed);
                    }
                }
                let durable = DurableVerifiedIdentity::from(&identity);
                let value = serde_json::to_value(&durable).map_err(|_| AuthError::Vault)?;
                let raw = crate::domain::canonical_json(&value).map_err(|_| AuthError::Vault)?;
                let result_secret = vault
                    .seal(
                        "verified_external_identity_v1",
                        request.challenge_id.as_str(),
                        &raw,
                    )
                    .await?;
                self.repository
                    .mark_provider_result_known(
                        &request.challenge_id,
                        &request.operation_id,
                        &identity,
                        result_secret,
                    )
                    .await?;
                (challenge, identity)
            }
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
        let (grant, _) = self
            .repository
            .finish_exchange(
                &request.challenge_id,
                &request.operation_id,
                &identity,
                subject_lookup,
                subject_secret,
                &challenge.audience,
                &challenge.platform,
                now_unix,
                request.request_digest,
            )
            .await?;
        Ok(grant)
    }

    pub async fn exchange_apple_from_wire<P: AppleProvider, H: SecretHasher, V: CredentialVault>(
        &self,
        parsed: &ParsedAuthCommand,
        provider: &P,
        hasher: &H,
        vault: &V,
        now_unix: i64,
    ) -> Result<SessionGrant, AuthError> {
        let AuthCommand::ExchangeApple(command) = &parsed.command else {
            return Err(AuthError::InvalidRequest);
        };
        self.exchange_apple(
            ExchangeRequest {
                challenge_id: command.challenge_id.clone(),
                operation_id: command.operation_id.clone(),
                state: command.state.as_bytes().to_vec(),
                authorization_code: command.authorization_code.as_bytes().to_vec(),
                identity_token: command.identity_token.as_bytes().to_vec(),
                request_digest: parsed.digest,
            },
            provider,
            hasher,
            vault,
            now_unix,
        )
        .await
    }

    async fn refresh(&self, request: RefreshRequest) -> Result<RefreshOutcome, AuthError> {
        let verifier = self
            .repository
            .token_verifier("refresh", &request.refresh_token)
            .await?;
        self.repository.refresh(&request, verifier).await
    }

    pub async fn refresh_from_wire(
        &self,
        parsed: &ParsedAuthCommand,
        refresh_token: String,
    ) -> Result<RefreshOutcome, AuthError> {
        let AuthCommand::RotateRefresh(command) = &parsed.command else {
            return Err(AuthError::InvalidRequest);
        };
        self.refresh(RefreshRequest {
            operation_id: command.operation_id.clone(),
            refresh_token,
            request_digest: parsed.digest,
        })
        .await
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

    async fn revoke_current_session(
        &self,
        operation_id: OperationId,
        digest: [u8; 32],
        session_id: SessionId,
    ) -> Result<AuthReceipt, AuthError> {
        self.repository
            .revoke_current_session(&operation_id, digest, &session_id)
            .await
    }

    pub async fn revoke_current_session_from_wire(
        &self,
        parsed: &ParsedAuthCommand,
        session_id: SessionId,
    ) -> Result<AuthReceipt, AuthError> {
        let AuthCommand::RevokeCurrentSession(command) = &parsed.command else {
            return Err(AuthError::InvalidRequest);
        };
        self.revoke_current_session(command.operation_id.clone(), parsed.digest, session_id)
            .await
    }
}

fn decode_exchange_receipt(receipt: &AuthReceipt) -> Result<SessionGrant, AuthError> {
    match receipt.status {
        200 => receipt.session_grant.clone().ok_or(AuthError::Vault),
        502 => Err(AuthError::ProviderExchangeIndeterminate),
        _ => Err(AuthError::InvalidRequest),
    }
}

/// Key-backed hasher shared by identity lookup and repository token lookup.
/// There is intentionally no default/dev key: every composition must inject
/// explicit independent 256-bit keys.
#[derive(Clone)]
pub struct HmacSecretHasher {
    subject_lookup_key: [u8; 32],
    token_key: [u8; 32],
}
impl HmacSecretHasher {
    pub fn new(subject_lookup_key: [u8; 32], token_key: [u8; 32]) -> Self {
        Self {
            subject_lookup_key,
            token_key,
        }
    }
    pub fn token_key(&self) -> [u8; 32] {
        self.token_key
    }
}
#[async_trait]
impl SecretHasher for HmacSecretHasher {
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
