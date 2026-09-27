use async_trait::async_trait;
use base64::Engine;
use fuminiwa_sync_server_v2::auth_application::*;
use fuminiwa_sync_server_v2::auth_domain::*;
use fuminiwa_sync_server_v2::auth_wire::{parse_auth_command, ParsedAuthCommand};
use std::collections::{HashMap, HashSet};
use std::sync::{
    atomic::{AtomicUsize, Ordering},
    Arc, Mutex,
};

type SealedTrace = Vec<(String, String, Vec<u8>)>;

fn fixture_hasher() -> HmacSecretHasher {
    HmacSecretHasher::new([0x11; 32], [0x22; 32])
}

#[derive(Clone, Default)]
struct FakeVault {
    sealed: Arc<Mutex<SealedTrace>>,
    values: Arc<Mutex<HashMap<Vec<u8>, Vec<u8>>>>,
    next: Arc<AtomicUsize>,
}
#[async_trait]
impl CredentialVault for FakeVault {
    fn active_key_version(&self) -> i32 {
        7
    }

    async fn seal(
        &self,
        purpose: &str,
        row_id: &str,
        plaintext: &[u8],
    ) -> Result<SealedSecret, AuthError> {
        self.sealed
            .lock()
            .unwrap()
            .push((purpose.into(), row_id.into(), plaintext.to_vec()));
        let ciphertext = format!(
            "fixture-ciphertext-{}",
            self.next.fetch_add(1, Ordering::SeqCst)
        )
        .into_bytes();
        self.values
            .lock()
            .unwrap()
            .insert(ciphertext.clone(), plaintext.to_vec());
        Ok(SealedSecret {
            key_version: 7,
            ciphertext,
        })
    }
    async fn open(
        &self,
        _purpose: &str,
        _row_id: &str,
        secret: &SealedSecret,
    ) -> Result<Vec<u8>, AuthError> {
        self.values
            .lock()
            .unwrap()
            .get(&secret.ciphertext)
            .cloned()
            .ok_or(AuthError::Vault)
    }
}

#[derive(Clone)]
struct FakeProvider {
    indeterminate: bool,
    subject: String,
    calls: Arc<AtomicUsize>,
    audience_override: Option<String>,
    nonce_override: Option<Vec<u8>>,
}
impl FakeProvider {
    fn valid(subject: &str) -> Self {
        Self {
            indeterminate: false,
            subject: subject.into(),
            calls: Arc::new(AtomicUsize::new(0)),
            audience_override: None,
            nonce_override: None,
        }
    }
}
#[async_trait]
impl AppleProvider for FakeProvider {
    async fn exchange(
        &self,
        challenge: &ChallengeClaim,
        _code: &[u8],
        _token: &[u8],
    ) -> Result<AppleIdentityEvidence, AuthError> {
        self.calls.fetch_add(1, Ordering::SeqCst);
        if self.indeterminate {
            return Err(AuthError::ProviderExchangeIndeterminate);
        }
        AppleIdentityEvidence::from_verified_claims(
            ProviderConfigId::new(APPLE_PROVIDER_CONFIG)?,
            APPLE_ISSUER,
            self.subject.clone(),
            self.audience_override
                .clone()
                .unwrap_or_else(|| challenge.audience.clone()),
            self.nonce_override
                .clone()
                .unwrap_or_else(|| challenge.nonce_hash.clone()),
            1_000,
            None,
        )
    }
    async fn revoke(
        &self,
        _credential: &VerifiedProviderCredential,
        _operation_id: &OperationId,
    ) -> Result<(), AuthError> {
        Ok(())
    }
}

#[derive(Default)]
struct FakeState {
    challenge: Option<ChallengeClaim>,
    receipts: HashMap<String, AuthReceipt>,
    phase: Option<ChallengePhase>,
    account: Option<(AccountId, TenantId, Vec<u8>, i64)>,
    consumed_refresh: HashSet<String>,
    refresh_receipts: HashMap<String, (String, [u8; 32], RefreshOutcome)>,
    operations: HashMap<String, (String, [u8; 32])>,
    sessions_revoked: HashSet<String>,
    access_valid: bool,
    provider_result: Option<SealedSecret>,
    exchange_operation: Option<String>,
    fail_finish_once: bool,
}
#[derive(Clone, Default)]
struct FakeRepo(Arc<Mutex<FakeState>>);
impl FakeRepo {
    fn principal(&self) -> AuthenticatedPrincipal {
        let state = self.0.lock().unwrap();
        let (account_id, tenant_id, fence, epoch) = state.account.clone().unwrap_or_else(|| {
            (
                AccountId::new("acct_fake").unwrap(),
                TenantId::new("tenant_fake").unwrap(),
                vec![1; 32],
                1,
            )
        });
        AuthenticatedPrincipal {
            account_id,
            tenant_id,
            session_id: SessionId::new("session_fake").unwrap(),
            account_auth_epoch: epoch,
            account_fence: fence,
        }
    }
}
#[async_trait]
impl AuthRepository for FakeRepo {
    async fn token_verifier(&self, purpose: &str, token: &str) -> Result<Vec<u8>, AuthError> {
        fixture_hasher().token_verifier(purpose, token).await
    }
    async fn authenticate_access(
        &self,
        verifier: Vec<u8>,
    ) -> Result<AuthenticatedPrincipal, AuthError> {
        let expected = fixture_hasher()
            .token_verifier("access", "access_fake")
            .await?;
        if verifier == expected && self.0.lock().unwrap().access_valid {
            Ok(self.principal())
        } else {
            Err(AuthError::AccountNotFound)
        }
    }
    async fn resolve_refresh_session(&self, _verifier: Vec<u8>) -> Result<SessionId, AuthError> {
        Ok(self.principal().session_id)
    }
    async fn find_operation_receipt(
        &self,
        operation_id: &OperationId,
        kind: &str,
        digest: &[u8; 32],
    ) -> Result<Option<AuthReceipt>, AuthError> {
        let state = self.0.lock().unwrap();
        match state.receipts.get(operation_id.as_str()) {
            Some(receipt) if receipt.command_kind == kind && &receipt.request_digest == digest => {
                Ok(Some(receipt.clone()))
            }
            Some(_) => Err(AuthError::OperationIdReused),
            None => Ok(None),
        }
    }
    async fn create_challenge(
        &self,
        request: &NewChallenge,
        state_hash: Vec<u8>,
        nonce_hash: Vec<u8>,
    ) -> Result<ChallengeResult, AuthError> {
        let id = ChallengeId::new("20000000-0000-4000-8000-000000000001")?;
        let claim = ChallengeClaim {
            id: id.clone(),
            operation_id: request.operation_id.clone(),
            provider_config_id: ProviderConfigId::new(APPLE_PROVIDER_CONFIG)?,
            audience: request.audience.clone(),
            platform: request.platform.clone(),
            state_hash,
            nonce_hash,
            phase: ChallengePhase::Claimed,
            lease_until_unix: request.expires_at_unix,
            expires_at_unix: request.expires_at_unix,
        };
        let mut state = self.0.lock().unwrap();
        state.phase = Some(ChallengePhase::Claimed);
        state.challenge = Some(claim);
        state.operations.insert(
            request.operation_id.to_string(),
            (CREATE_CHALLENGE_COMMAND.into(), request.request_digest),
        );
        let result = ChallengeResult {
            challenge_id: id,
            operation_id: request.operation_id.clone(),
            provider_config_id: ProviderConfigId::new(APPLE_PROVIDER_CONFIG)?,
            audience: request.audience.clone(),
            state: request.state.clone(),
            nonce: request.nonce.clone(),
            expires_at_unix: request.expires_at_unix,
        };
        state.receipts.insert(
            request.operation_id.to_string(),
            AuthReceipt {
                operation_id: request.operation_id.clone(),
                command_kind: CREATE_CHALLENGE_COMMAND.into(),
                request_digest: request.request_digest,
                response_bytes: fuminiwa_sync_server_v2::auth_wire::encode_challenge_response(
                    &result,
                    request.expires_at_unix + REFRESH_TOKEN_LIFETIME_SECONDS,
                )
                .unwrap(),
                status: 201,
                session_grant: None,
            },
        );
        Ok(result)
    }
    async fn claim_challenge_for_exchange(
        &self,
        _id: &ChallengeId,
        operation_id: &OperationId,
        request_digest: [u8; 32],
        state_hash: &[u8],
        now_unix: i64,
    ) -> Result<ChallengeClaimResult, AuthError> {
        let mut s = self.0.lock().unwrap();
        let mut challenge = s.challenge.clone().ok_or(AuthError::NotFound)?;
        if challenge.state_hash != state_hash {
            return Err(AuthError::InvalidRequest);
        }
        if matches!(challenge.phase, ChallengePhase::Claimed)
            && challenge.expires_at_unix <= now_unix
        {
            return Err(AuthError::ChallengeExpired);
        }
        if !matches!(challenge.phase, ChallengePhase::Claimed)
            && s.exchange_operation.as_deref() != Some(operation_id.as_str())
        {
            return Err(AuthError::ChallengeConsumed);
        }
        match s.operations.get(operation_id.as_str()) {
            Some((kind, digest)) if kind == EXCHANGE_APPLE_COMMAND && digest == &request_digest => {
            }
            Some(_) => return Err(AuthError::OperationIdReused),
            None => {
                s.operations.insert(
                    operation_id.to_string(),
                    (EXCHANGE_APPLE_COMMAND.into(), request_digest),
                );
            }
        }
        match challenge.phase {
            ChallengePhase::Claimed => {
                challenge.phase = ChallengePhase::ProviderCallStarted;
                challenge.lease_until_unix = now_unix + 300;
                s.phase = Some(ChallengePhase::ProviderCallStarted);
                s.exchange_operation = Some(operation_id.to_string());
                s.challenge = Some(challenge.clone());
                Ok(ChallengeClaimResult::ProviderCallRequired(challenge))
            }
            ChallengePhase::ProviderCallStarted => {
                if challenge.lease_until_unix > now_unix {
                    return Err(AuthError::InvalidChallengePhase);
                }
                s.phase = Some(ChallengePhase::Terminal);
                s.challenge.as_mut().unwrap().phase = ChallengePhase::Terminal;
                Ok(ChallengeClaimResult::ProviderExchangeIndeterminate)
            }
            ChallengePhase::ProviderResultKnown => Ok(ChallengeClaimResult::ProviderResultKnown(
                challenge,
                s.provider_result.clone().ok_or(AuthError::Vault)?,
            )),
            ChallengePhase::Terminal => Ok(ChallengeClaimResult::ProviderExchangeIndeterminate),
        }
    }
    async fn mark_provider_exchange_indeterminate(
        &self,
        _id: &ChallengeId,
        operation_id: &OperationId,
        digest: [u8; 32],
    ) -> Result<(), AuthError> {
        let mut s = self.0.lock().unwrap();
        s.phase = Some(ChallengePhase::Terminal);
        s.challenge.as_mut().unwrap().phase = ChallengePhase::Terminal;
        s.receipts.insert(
            operation_id.to_string(),
            AuthReceipt {
                operation_id: operation_id.clone(),
                command_kind: EXCHANGE_APPLE_COMMAND.into(),
                request_digest: digest,
                response_bytes: b"{\"code\":\"providerExchangeIndeterminate\"}".to_vec(),
                status: 502,
                session_grant: None,
            },
        );
        Ok(())
    }
    async fn mark_provider_exchange_terminal(
        &self,
        id: &ChallengeId,
        operation_id: &OperationId,
        digest: [u8; 32],
        code: &str,
        status: u16,
    ) -> Result<(), AuthError> {
        let mut s = self.0.lock().unwrap();
        s.phase = Some(ChallengePhase::Terminal);
        s.challenge.as_mut().unwrap().phase = ChallengePhase::Terminal;
        s.receipts.insert(
            operation_id.to_string(),
            AuthReceipt {
                operation_id: operation_id.clone(),
                command_kind: EXCHANGE_APPLE_COMMAND.into(),
                request_digest: digest,
                response_bytes: format!("{{\"challengeId\":\"{}\",\"code\":\"{}\"}}", id, code)
                    .into_bytes(),
                status,
                session_grant: None,
            },
        );
        Ok(())
    }
    async fn mark_provider_result_known(
        &self,
        _id: &ChallengeId,
        _operation_id: &OperationId,
        _identity: &VerifiedExternalIdentity,
        secret: SealedSecret,
    ) -> Result<(), AuthError> {
        let mut s = self.0.lock().unwrap();
        s.phase = Some(ChallengePhase::ProviderResultKnown);
        s.challenge.as_mut().unwrap().phase = ChallengePhase::ProviderResultKnown;
        s.provider_result = Some(secret);
        Ok(())
    }
    async fn finish_exchange(
        &self,
        _challenge_id: &ChallengeId,
        operation_id: &OperationId,
        _identity: &VerifiedExternalIdentity,
        _lookup: Vec<u8>,
        _secret: SealedSecret,
        _audience: &str,
        _platform: &str,
        _now_unix: i64,
        digest: [u8; 32],
    ) -> Result<(SessionGrant, AuthReceipt), AuthError> {
        let mut state = self.0.lock().unwrap();
        if state.fail_finish_once {
            state.fail_finish_once = false;
            return Err(AuthError::Database("fixture crash".into()));
        }
        let (account, tenant, fence, epoch) = state.account.clone().unwrap_or_else(|| {
            (
                AccountId::new("acct_fake").unwrap(),
                TenantId::new("tenant_fake").unwrap(),
                vec![1; 32],
                1,
            )
        });
        state.account = Some((account.clone(), tenant.clone(), fence.clone(), epoch));
        state.access_valid = true;
        let grant = SessionGrant {
            principal: AuthenticatedPrincipal {
                account_id: account,
                tenant_id: tenant,
                session_id: SessionId::new("session_fake").unwrap(),
                account_auth_epoch: epoch,
                account_fence: fence,
            },
            access_token: "access_fake".into(),
            refresh_token: format!("refresh_{}", state.receipts.len()),
            refresh_generation: 1,
            access_expires_at_unix: 1900,
            refresh_expires_at_unix: 9000,
        };
        let receipt = AuthReceipt {
            operation_id: operation_id.clone(),
            command_kind: "exchangeApple".into(),
            request_digest: digest,
            response_bytes: serde_json::to_vec(&grant).unwrap(),
            status: 200,
            session_grant: Some(grant.clone()),
        };
        state
            .receipts
            .insert(operation_id.to_string(), receipt.clone());
        state.operations.insert(
            operation_id.to_string(),
            (EXCHANGE_APPLE_COMMAND.into(), digest),
        );
        state.phase = Some(ChallengePhase::Terminal);
        if let Some(challenge) = state.challenge.as_mut() {
            challenge.phase = ChallengePhase::Terminal;
        }
        Ok((grant, receipt))
    }
    async fn refresh(
        &self,
        request: &RefreshRequest,
        _verifier: Vec<u8>,
    ) -> Result<RefreshOutcome, AuthError> {
        let mut s = self.0.lock().unwrap();
        if let Some((token, digest, outcome)) =
            s.refresh_receipts.get(request.operation_id.as_str())
        {
            if token == &request.refresh_token && digest == &request.request_digest {
                return Ok(outcome.clone());
            }
            return Err(AuthError::OperationIdReused);
        }
        if s.consumed_refresh.contains(&request.refresh_token) {
            s.sessions_revoked.insert("session_fake".into());
            let outcome = RefreshOutcome {
                grant: None,
                receipt: Some(AuthReceipt {
                    operation_id: request.operation_id.clone(),
                    command_kind: ROTATE_REFRESH_COMMAND.into(),
                    request_digest: request.request_digest,
                    response_bytes: b"{\"code\":\"refreshTokenReused\"}".to_vec(),
                    status: 401,
                    session_grant: None,
                }),
                reused: true,
            };
            s.refresh_receipts.insert(
                request.operation_id.to_string(),
                (
                    request.refresh_token.clone(),
                    request.request_digest,
                    outcome.clone(),
                ),
            );
            return Ok(outcome);
        }
        s.consumed_refresh.insert(request.refresh_token.clone());
        let (account_id, tenant_id, fence, epoch) = s.account.clone().unwrap();
        let principal = AuthenticatedPrincipal {
            account_id,
            tenant_id,
            session_id: SessionId::new("session_fake").unwrap(),
            account_auth_epoch: epoch,
            account_fence: fence,
        };
        let next = 2;
        let grant = SessionGrant {
            principal,
            access_token: "access_rotated".into(),
            refresh_token: "refresh_rotated".into(),
            refresh_generation: next,
            access_expires_at_unix: 1900,
            refresh_expires_at_unix: 9000,
        };
        let outcome = RefreshOutcome {
            grant: Some(grant.clone()),
            receipt: Some(AuthReceipt {
                operation_id: request.operation_id.clone(),
                command_kind: ROTATE_REFRESH_COMMAND.into(),
                request_digest: request.request_digest,
                response_bytes: b"{\"refreshGeneration\":2}".to_vec(),
                status: 200,
                session_grant: Some(grant.clone()),
            }),
            reused: false,
        };
        s.refresh_receipts.insert(
            request.operation_id.to_string(),
            (
                request.refresh_token.clone(),
                request.request_digest,
                outcome.clone(),
            ),
        );
        Ok(outcome)
    }
    async fn revoke_current_session(
        &self,
        operation_id: &OperationId,
        digest: [u8; 32],
        _session_id: &SessionId,
    ) -> Result<AuthReceipt, AuthError> {
        let mut s = self.0.lock().unwrap();
        if let Some(r) = s.receipts.get(operation_id.as_str()) {
            if r.request_digest != digest || r.command_kind != REVOKE_SESSION_COMMAND {
                return Err(AuthError::OperationIdReused);
            }
            return Ok(r.clone());
        }
        s.sessions_revoked.insert("session_fake".into());
        let r = AuthReceipt {
            operation_id: operation_id.clone(),
            command_kind: "revokeCurrentSession".into(),
            request_digest: digest,
            response_bytes: b"{\"fenceChanged\":false}".to_vec(),
            status: 200,
            session_grant: None,
        };
        s.receipts.insert(operation_id.to_string(), r.clone());
        s.operations.insert(
            operation_id.to_string(),
            (REVOKE_SESSION_COMMAND.into(), digest),
        );
        Ok(r)
    }
    async fn rotate_account_fence(
        &self,
        operation_id: &OperationId,
        digest: [u8; 32],
        account_id: &AccountId,
    ) -> Result<SecurityTransition, AuthError> {
        let mut s = self.0.lock().unwrap();
        let (_, _, _, epoch) = s.account.clone().ok_or(AuthError::AccountNotFound)?;
        let transition = SecurityTransition {
            account_auth_epoch: epoch + 1,
            account_fence: vec![2; 32],
            sessions_reauth_required: true,
        };
        s.account = Some((
            account_id.clone(),
            TenantId::new("tenant_fake").unwrap(),
            vec![2; 32],
            epoch + 1,
        ));
        s.operations.insert(
            operation_id.to_string(),
            (ROTATE_ACCOUNT_FENCE_COMMAND.into(), digest),
        );
        Ok(transition)
    }
}

fn request(operation: &str, challenge: &str) -> (NewChallenge, ExchangeRequest) {
    let operation_id = OperationId::new(operation).unwrap();
    let create_operation_id = OperationId::new(format!("{operation}_create")).unwrap();
    let challenge_id = ChallengeId::new(challenge).unwrap();
    let request = NewChallenge {
        operation_id: create_operation_id,
        provider: "apple".into(),
        platform: "ios".into(),
        audience: "dev.serikayuzuki.fuminiwa.ios".into(),
        state: "state".into(),
        nonce: "nonce".into(),
        expires_at_unix: 2_000,
        request_digest: digest_request(b"create"),
    };
    let exchange = ExchangeRequest {
        challenge_id,
        operation_id,
        state: b"state".to_vec(),
        authorization_code: b"code".to_vec(),
        identity_token: b"token".to_vec(),
        request_digest: digest_request(b"exchange"),
    };
    (request, exchange)
}

fn bound_identity(subject: &str, audience: &str, nonce_hash: Vec<u8>) -> VerifiedExternalIdentity {
    let challenge = ChallengeClaim {
        id: ChallengeId::new("20000000-0000-4000-8000-000000000099").unwrap(),
        operation_id: OperationId::new("10000000-0000-4000-8000-000000000099").unwrap(),
        provider_config_id: ProviderConfigId::new(APPLE_PROVIDER_CONFIG).unwrap(),
        audience: audience.into(),
        platform: "macos".into(),
        state_hash: vec![0x22; 32],
        nonce_hash: nonce_hash.clone(),
        phase: ChallengePhase::ProviderResultKnown,
        lease_until_unix: 1_300,
        expires_at_unix: 1_300,
    };
    let evidence = AppleIdentityEvidence::from_verified_claims(
        ProviderConfigId::new(APPLE_PROVIDER_CONFIG).unwrap(),
        APPLE_ISSUER,
        subject,
        audience,
        nonce_hash,
        1_000,
        None,
    )
    .unwrap();
    VerifiedExternalIdentity::bind_apple(evidence, &challenge, 1_000).unwrap()
}

fn create_wire(operation_id: &str, platform: &str) -> ParsedAuthCommand {
    let raw = format!(
        "{{\"clientPlatform\":\"{platform}\",\"flow\":\"native\",\"operationId\":\"{operation_id}\",\"provider\":\"apple\"}}"
    );
    parse_auth_command(CREATE_CHALLENGE_COMMAND, raw.as_bytes()).unwrap()
}

fn exchange_wire(operation_id: &str, challenge_id: &ChallengeId, state: &str) -> ParsedAuthCommand {
    let raw = format!(
        "{{\"authorizationCode\":\"fixture-code\",\"challengeId\":\"{}\",\"identityToken\":\"fixture.token.signature\",\"operationId\":\"{operation_id}\",\"provider\":\"apple\",\"state\":\"{state}\"}}",
        challenge_id.as_str()
    );
    parse_auth_command(EXCHANGE_APPLE_COMMAND, raw.as_bytes()).unwrap()
}

fn refresh_wire(operation_id: &str) -> ParsedAuthCommand {
    let raw = format!("{{\"rotationId\":\"{operation_id}\"}}");
    parse_auth_command(ROTATE_REFRESH_COMMAND, raw.as_bytes()).unwrap()
}

fn revoke_wire(operation_id: &str) -> ParsedAuthCommand {
    let raw = format!("{{\"operationId\":\"{operation_id}\",\"scope\":\"currentSession\"}}");
    parse_auth_command(REVOKE_SESSION_COMMAND, raw.as_bytes()).unwrap()
}

#[tokio::test]
async fn same_identity_reuses_account_and_hmac_is_shared() {
    let repo = FakeRepo::default();
    let app = AuthApplication::new(repo.clone());
    let result = app
        .create_challenge_from_wire(
            &create_wire("10000000-0000-4000-8000-000000000011", "ios"),
            1_000,
        )
        .await
        .unwrap();
    let exchange = exchange_wire(
        "30000000-0000-4000-8000-000000000011",
        &result.challenge_id,
        &result.state,
    );
    assert_eq!(
        result.challenge_id.as_str(),
        "20000000-0000-4000-8000-000000000001"
    );
    let provider = FakeProvider::valid("same");
    let vault = FakeVault::default();
    let first = app
        .exchange_apple_from_wire(&exchange, &provider, &fixture_hasher(), &vault, 1_000)
        .await
        .unwrap();
    assert_eq!(
        app.authenticate_access(&first.access_token)
            .await
            .unwrap()
            .account_id,
        first.principal.account_id
    );
    repo.0.lock().unwrap().access_valid = false;
    assert_eq!(
        app.authenticate_access(&first.access_token)
            .await
            .unwrap_err(),
        AuthError::AccountNotFound
    );
    repo.0.lock().unwrap().access_valid = true;
    assert_eq!(first.principal.account_id.as_str(), "acct_fake");
    assert_eq!(
        repo.token_verifier("refresh", &first.refresh_token)
            .await
            .unwrap(),
        fixture_hasher()
            .token_verifier("refresh", &first.refresh_token)
            .await
            .unwrap()
    );
}

#[tokio::test]
async fn concurrent_same_subject_finishes_to_one_account() {
    let repo = FakeRepo::default();
    let identity = bound_identity("same-subject", "dev.serikayuzuki.fuminiwa", vec![0x33; 32]);
    let challenge = ChallengeId::new("challenge_fake").unwrap();
    let op_a = OperationId::new("op_concurrent_a").unwrap();
    let op_b = OperationId::new("op_concurrent_b").unwrap();
    let (left, right) = tokio::join!(
        repo.finish_exchange(
            &challenge,
            &op_a,
            &identity,
            vec![1; 32],
            SealedSecret {
                key_version: 1,
                ciphertext: vec![1]
            },
            "dev.serikayuzuki.fuminiwa",
            "macos",
            1_000,
            digest_request(b"a")
        ),
        repo.finish_exchange(
            &challenge,
            &op_b,
            &identity,
            vec![1; 32],
            SealedSecret {
                key_version: 1,
                ciphertext: vec![1]
            },
            "dev.serikayuzuki.fuminiwa",
            "macos",
            1_000,
            digest_request(b"b")
        ),
    );
    assert_eq!(
        left.unwrap().0.principal.account_id,
        right.unwrap().0.principal.account_id
    );
    assert_eq!(
        repo.0.lock().unwrap().account.as_ref().unwrap().0.as_str(),
        "acct_fake"
    );
}

#[tokio::test]
async fn refresh_lost_ack_replay_and_reuse_revoke_are_distinct() {
    let repo = FakeRepo::default();
    let app = AuthApplication::new(repo.clone());
    let challenge = app
        .create_challenge_from_wire(
            &create_wire("10000000-0000-4000-8000-000000000012", "ios"),
            1_000,
        )
        .await
        .unwrap();
    let exchange = exchange_wire(
        "30000000-0000-4000-8000-000000000012",
        &challenge.challenge_id,
        &challenge.state,
    );
    let provider = FakeProvider::valid("same");
    let vault = FakeVault::default();
    let grant = app
        .exchange_apple_from_wire(&exchange, &provider, &fixture_hasher(), &vault, 1_000)
        .await
        .unwrap();
    let first = app
        .refresh_from_wire(
            &refresh_wire("50000000-0000-4000-8000-000000000011"),
            grant.refresh_token.clone(),
        )
        .await
        .unwrap();
    let replay = app
        .refresh_from_wire(
            &refresh_wire("50000000-0000-4000-8000-000000000011"),
            grant.refresh_token.clone(),
        )
        .await
        .unwrap();
    assert_eq!(first, replay);
    let rotated = first.grant.clone().unwrap();
    assert_eq!(rotated.principal.account_id, grant.principal.account_id);
    assert_eq!(
        rotated.principal.account_auth_epoch,
        grant.principal.account_auth_epoch
    );
    assert_eq!(
        rotated.principal.account_fence,
        grant.principal.account_fence
    );
    let reused = app
        .refresh_from_wire(
            &refresh_wire("50000000-0000-4000-8000-000000000012"),
            grant.refresh_token,
        )
        .await;
    let reused = reused.unwrap();
    assert!(reused.reused);
    assert_eq!(reused.receipt.as_ref().unwrap().status, 401);
    assert!(repo
        .0
        .lock()
        .unwrap()
        .sessions_revoked
        .contains("session_fake"));
}

#[tokio::test]
async fn provider_call_indeterminate_is_terminal_and_revoke_is_idempotent() {
    let repo = FakeRepo::default();
    let app = AuthApplication::new(repo.clone());
    let challenge = app
        .create_challenge_from_wire(
            &create_wire("10000000-0000-4000-8000-000000000013", "ios"),
            1_000,
        )
        .await
        .unwrap();
    let exchange = exchange_wire(
        "30000000-0000-4000-8000-000000000013",
        &challenge.challenge_id,
        &challenge.state,
    );
    let mut provider = FakeProvider::valid("same");
    provider.indeterminate = true;
    let vault = FakeVault::default();
    assert_eq!(
        app.exchange_apple_from_wire(&exchange, &provider, &fixture_hasher(), &vault, 1_000)
            .await
            .unwrap_err(),
        AuthError::ProviderExchangeIndeterminate
    );
    assert_eq!(repo.0.lock().unwrap().phase, Some(ChallengePhase::Terminal));
    assert_eq!(provider.calls.load(Ordering::SeqCst), 1);
    assert_eq!(
        app.exchange_apple_from_wire(&exchange, &provider, &fixture_hasher(), &vault, 1_000)
            .await
            .unwrap_err(),
        AuthError::ProviderExchangeIndeterminate
    );
    assert_eq!(provider.calls.load(Ordering::SeqCst), 1);
    let first = app
        .revoke_current_session_from_wire(
            &revoke_wire("60000000-0000-4000-8000-000000000011"),
            SessionId::new("session_fake").unwrap(),
        )
        .await
        .unwrap();
    let replay = app
        .revoke_current_session_from_wire(
            &revoke_wire("60000000-0000-4000-8000-000000000011"),
            SessionId::new("session_fake").unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(first, replay);
}

#[tokio::test]
async fn challenge_material_is_server_generated_256_bit_and_platform_scoped() {
    let repo = FakeRepo::default();
    let app = AuthApplication::new(repo.clone());
    let raw = br#"{"clientPlatform":"macos","flow":"native","operationId":"10000000-0000-4000-8000-000000000001","provider":"apple"}"#;
    let parsed = parse_auth_command(CREATE_CHALLENGE_COMMAND, raw).unwrap();
    let result = app
        .create_challenge_from_wire(&parsed, 1_000)
        .await
        .unwrap();
    let exact_replay = app
        .create_challenge_from_wire(&parsed, 1_000)
        .await
        .unwrap();
    assert_eq!(result, exact_replay);
    let state = base64::engine::general_purpose::URL_SAFE_NO_PAD
        .decode(&result.state)
        .unwrap();
    let nonce = base64::engine::general_purpose::URL_SAFE_NO_PAD
        .decode(&result.nonce)
        .unwrap();
    assert_eq!(state.len(), 32);
    assert_eq!(nonce.len(), 32);
    assert_ne!(state, nonce);
    assert_eq!(result.audience, "dev.serikayuzuki.fuminiwa");
    let challenge = repo.0.lock().unwrap().challenge.clone().unwrap();
    assert_eq!(challenge.platform, "macos");
    assert_eq!(challenge.audience, "dev.serikayuzuki.fuminiwa");

    let second_raw = br#"{"clientPlatform":"macos","flow":"native","operationId":"10000000-0000-4000-8000-000000000002","provider":"apple"}"#;
    let second = app
        .create_challenge_from_wire(
            &parse_auth_command(CREATE_CHALLENGE_COMMAND, second_raw).unwrap(),
            1_000,
        )
        .await
        .unwrap();
    assert_ne!(result.state, second.state);
    assert_ne!(result.nonce, second.nonce);
}

#[tokio::test]
async fn provider_evidence_must_match_exact_audience_and_nonce_without_credential() {
    for mismatch in ["audience", "nonce"] {
        let repo = FakeRepo::default();
        let app = AuthApplication::new(repo.clone());
        let challenge = app
            .create_challenge_from_wire(
                &create_wire(
                    if mismatch == "audience" {
                        "10000000-0000-4000-8000-000000000021"
                    } else {
                        "10000000-0000-4000-8000-000000000022"
                    },
                    "ios",
                ),
                1_000,
            )
            .await
            .unwrap();
        let exchange = exchange_wire(
            if mismatch == "audience" {
                "30000000-0000-4000-8000-000000000021"
            } else {
                "30000000-0000-4000-8000-000000000022"
            },
            &challenge.challenge_id,
            &challenge.state,
        );
        let mut provider = FakeProvider::valid("proof-mismatch-subject");
        if mismatch == "audience" {
            provider.audience_override = Some("dev.serikayuzuki.fuminiwa".into());
        } else {
            provider.nonce_override = Some(vec![0x77; 32]);
        }
        let expected_error = if mismatch == "audience" {
            AuthError::ProviderNotAllowed
        } else {
            AuthError::InvalidRequest
        };
        assert_eq!(
            app.exchange_apple_from_wire(
                &exchange,
                &provider,
                &fixture_hasher(),
                &FakeVault::default(),
                1_000,
            )
            .await
            .unwrap_err(),
            expected_error
        );
        let state = repo.0.lock().unwrap();
        assert!(state.account.is_none());
        assert_eq!(state.phase, Some(ChallengePhase::Terminal));
        assert_eq!(provider.calls.load(Ordering::SeqCst), 1);
    }
}

#[tokio::test]
async fn invalid_exchange_state_does_not_reserve_an_operation() {
    let repo = FakeRepo::default();
    let app = AuthApplication::new(repo.clone());
    let challenge = app
        .create_challenge_from_wire(
            &create_wire("10000000-0000-4000-8000-000000000023", "ios"),
            1_000,
        )
        .await
        .unwrap();
    let exchange = exchange_wire(
        "30000000-0000-4000-8000-000000000023",
        &challenge.challenge_id,
        "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
    );
    let operation_count_before = repo.0.lock().unwrap().operations.len();
    let provider = FakeProvider::valid("unused-subject");
    assert_eq!(
        app.exchange_apple_from_wire(
            &exchange,
            &provider,
            &fixture_hasher(),
            &FakeVault::default(),
            1_000,
        )
        .await
        .unwrap_err(),
        AuthError::InvalidRequest
    );
    let state = repo.0.lock().unwrap();
    assert_eq!(state.operations.len(), operation_count_before);
    assert!(!state
        .operations
        .contains_key("30000000-0000-4000-8000-000000000023"));
    assert_eq!(provider.calls.load(Ordering::SeqCst), 0);
}

#[tokio::test]
async fn provider_result_known_resumes_without_calling_apple_again() {
    let repo = FakeRepo::default();
    let app = AuthApplication::new(repo.clone());
    let challenge = app
        .create_challenge_from_wire(
            &create_wire("10000000-0000-4000-8000-000000000014", "ios"),
            1_000,
        )
        .await
        .unwrap();
    let exchange = exchange_wire(
        "30000000-0000-4000-8000-000000000014",
        &challenge.challenge_id,
        &challenge.state,
    );
    repo.0.lock().unwrap().fail_finish_once = true;
    let provider = FakeProvider::valid("crash-resume-subject");
    let vault = FakeVault::default();
    assert!(matches!(
        app.exchange_apple_from_wire(&exchange, &provider, &fixture_hasher(), &vault, 1_000)
            .await,
        Err(AuthError::Database(_))
    ));
    assert_eq!(
        repo.0.lock().unwrap().phase,
        Some(ChallengePhase::ProviderResultKnown)
    );
    assert_eq!(provider.calls.load(Ordering::SeqCst), 1);

    let restarted_app = AuthApplication::new(repo.clone());
    let grant = restarted_app
        .exchange_apple_from_wire(&exchange, &provider, &fixture_hasher(), &vault, 1_301)
        .await
        .unwrap();
    assert_eq!(grant.principal.account_id.as_str(), "acct_fake");
    assert_eq!(provider.calls.load(Ordering::SeqCst), 1);
    assert_eq!(repo.0.lock().unwrap().phase, Some(ChallengePhase::Terminal));
}

#[tokio::test]
async fn challenge_expiry_and_provider_call_lease_fail_closed() {
    let repo = FakeRepo::default();
    let (challenge, exchange) = request("op_lease", "challenge_fake");
    repo.create_challenge(
        &challenge,
        digest_request(challenge.state.as_bytes()).to_vec(),
        digest_request(challenge.nonce.as_bytes()).to_vec(),
    )
    .await
    .unwrap();
    assert!(matches!(
        repo.claim_challenge_for_exchange(
            &exchange.challenge_id,
            &exchange.operation_id,
            exchange.request_digest,
            &digest_request(&exchange.state),
            1_000,
        )
        .await
        .unwrap(),
        ChallengeClaimResult::ProviderCallRequired(_)
    ));
    assert_eq!(
        repo.claim_challenge_for_exchange(
            &exchange.challenge_id,
            &exchange.operation_id,
            exchange.request_digest,
            &digest_request(&exchange.state),
            1_001,
        )
        .await
        .unwrap_err(),
        AuthError::InvalidChallengePhase
    );
    assert_eq!(
        repo.claim_challenge_for_exchange(
            &exchange.challenge_id,
            &exchange.operation_id,
            exchange.request_digest,
            &digest_request(&exchange.state),
            1_300,
        )
        .await
        .unwrap(),
        ChallengeClaimResult::ProviderExchangeIndeterminate
    );
    assert_eq!(
        repo.claim_challenge_for_exchange(
            &exchange.challenge_id,
            &exchange.operation_id,
            exchange.request_digest,
            &digest_request(&exchange.state),
            1_301,
        )
        .await
        .unwrap(),
        ChallengeClaimResult::ProviderExchangeIndeterminate
    );

    let expired_repo = FakeRepo::default();
    expired_repo
        .create_challenge(
            &challenge,
            digest_request(challenge.state.as_bytes()).to_vec(),
            digest_request(challenge.nonce.as_bytes()).to_vec(),
        )
        .await
        .unwrap();
    assert_eq!(
        expired_repo
            .claim_challenge_for_exchange(
                &exchange.challenge_id,
                &exchange.operation_id,
                exchange.request_digest,
                &digest_request(&exchange.state),
                challenge.expires_at_unix,
            )
            .await
            .unwrap_err(),
        AuthError::ChallengeExpired
    );
}
