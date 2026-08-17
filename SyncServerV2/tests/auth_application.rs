use async_trait::async_trait;
use fuminiwa_sync_server_v2::auth_application::*;
use fuminiwa_sync_server_v2::auth_domain::*;
use std::collections::{HashMap, HashSet};
use std::sync::{Arc, Mutex};

type SealedTrace = Vec<(String, String, Vec<u8>)>;

#[derive(Clone, Default)]
struct FakeVault {
    sealed: Arc<Mutex<SealedTrace>>,
}
#[async_trait]
impl CredentialVault for FakeVault {
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
        Ok(SealedSecret {
            key_version: 7,
            ciphertext: format!("sealed:{purpose}:{row_id}").into_bytes(),
        })
    }
    async fn open(
        &self,
        _purpose: &str,
        _row_id: &str,
        secret: &SealedSecret,
    ) -> Result<Vec<u8>, AuthError> {
        Ok(secret.ciphertext.clone())
    }
}

#[derive(Clone)]
struct FakeProvider {
    indeterminate: bool,
    subject: String,
}
#[async_trait]
impl AppleProvider for FakeProvider {
    async fn exchange(
        &self,
        _challenge: &ChallengeClaim,
        _code: &[u8],
        _token: &[u8],
    ) -> Result<VerifiedExternalIdentity, AuthError> {
        if self.indeterminate {
            return Err(AuthError::ProviderExchangeIndeterminate);
        }
        VerifiedExternalIdentity::apple(self.subject.clone(), 1_000)
    }
    async fn revoke(
        &self,
        _credential_id: &CredentialId,
        _audience: &str,
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
    refresh_receipts: HashMap<String, (String, RefreshOutcome)>,
    sessions_revoked: HashSet<String>,
    access_valid: bool,
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
        FixtureHasher::default()
            .token_verifier(purpose, token)
            .await
    }
    async fn authenticate_access(
        &self,
        verifier: Vec<u8>,
    ) -> Result<AuthenticatedPrincipal, AuthError> {
        let expected = FixtureHasher::default()
            .token_verifier("access", "access_fake")
            .await?;
        if verifier == expected && self.0.lock().unwrap().access_valid {
            Ok(self.principal())
        } else {
            Err(AuthError::AccountNotFound)
        }
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
        let id = ChallengeId::new("challenge_fake")?;
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
        Ok(ChallengeResult {
            challenge_id: id,
            operation_id: request.operation_id.clone(),
            provider_config_id: ProviderConfigId::new(APPLE_PROVIDER_CONFIG)?,
            audience: request.audience.clone(),
            state: request.state.clone(),
            nonce: request.nonce.clone(),
            expires_at_unix: request.expires_at_unix,
        })
    }
    async fn load_challenge_for_update(
        &self,
        _id: &ChallengeId,
    ) -> Result<ChallengeClaim, AuthError> {
        self.0
            .lock()
            .unwrap()
            .challenge
            .clone()
            .ok_or(AuthError::NotFound)
    }
    async fn mark_provider_call_started(&self, _id: &ChallengeId) -> Result<(), AuthError> {
        let mut s = self.0.lock().unwrap();
        if s.phase != Some(ChallengePhase::Claimed) {
            return Err(AuthError::InvalidChallengePhase);
        }
        s.phase = Some(ChallengePhase::ProviderCallStarted);
        s.challenge.as_mut().unwrap().phase = ChallengePhase::ProviderCallStarted;
        Ok(())
    }
    async fn mark_provider_exchange_indeterminate(
        &self,
        _id: &ChallengeId,
    ) -> Result<(), AuthError> {
        let mut s = self.0.lock().unwrap();
        s.phase = Some(ChallengePhase::Terminal);
        s.challenge.as_mut().unwrap().phase = ChallengePhase::Terminal;
        Ok(())
    }
    async fn mark_provider_result_known(
        &self,
        _id: &ChallengeId,
        _identity: &VerifiedExternalIdentity,
        _secret: SealedSecret,
    ) -> Result<(), AuthError> {
        let mut s = self.0.lock().unwrap();
        s.phase = Some(ChallengePhase::ProviderResultKnown);
        s.challenge.as_mut().unwrap().phase = ChallengePhase::ProviderResultKnown;
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
        digest: [u8; 32],
    ) -> Result<(SessionGrant, AuthReceipt), AuthError> {
        let mut state = self.0.lock().unwrap();
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
        };
        state
            .receipts
            .insert(operation_id.to_string(), receipt.clone());
        Ok((grant, receipt))
    }
    async fn refresh(
        &self,
        request: &RefreshRequest,
        _verifier: Vec<u8>,
    ) -> Result<RefreshOutcome, AuthError> {
        let mut s = self.0.lock().unwrap();
        if let Some((token, outcome)) = s.refresh_receipts.get(request.operation_id.as_str()) {
            if token == &request.refresh_token {
                return Ok(outcome.clone());
            }
            return Err(AuthError::OperationIdReused);
        }
        if s.consumed_refresh.contains(&request.refresh_token) {
            s.sessions_revoked.insert("session_fake".into());
            return Err(AuthError::RefreshTokenReused);
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
            grant: Some(grant),
            receipt: None,
            reused: false,
        };
        s.refresh_receipts.insert(
            request.operation_id.to_string(),
            (request.refresh_token.clone(), outcome.clone()),
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
            if r.request_digest != digest {
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
        };
        s.receipts.insert(operation_id.to_string(), r.clone());
        Ok(r)
    }
    async fn rotate_account_fence(
        &self,
        account_id: &AccountId,
    ) -> Result<SecurityTransition, AuthError> {
        let mut s = self.0.lock().unwrap();
        let (_, _, _, epoch) = s.account.clone().ok_or(AuthError::AccountNotFound)?;
        let transition = SecurityTransition {
            account_auth_epoch: epoch + 1,
            account_fence: vec![2; 32],
            sessions_revoked: true,
        };
        s.account = Some((
            account_id.clone(),
            TenantId::new("tenant_fake").unwrap(),
            vec![2; 32],
            epoch + 1,
        ));
        Ok(transition)
    }
}

fn request(operation: &str, challenge: &str) -> (NewChallenge, ExchangeRequest) {
    let operation_id = OperationId::new(operation).unwrap();
    let challenge_id = ChallengeId::new(challenge).unwrap();
    let request = NewChallenge {
        operation_id: operation_id.clone(),
        provider: "apple".into(),
        platform: "ios".into(),
        audience: "dev.serikayuzuki.fuminiwa.ios".into(),
        state: b"state".to_vec(),
        nonce: b"nonce".to_vec(),
        expires_at_unix: 2_000,
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

#[tokio::test]
async fn same_identity_reuses_account_and_hmac_is_shared() {
    let repo = FakeRepo::default();
    let app = AuthApplication::new(repo.clone());
    let (challenge, exchange) = request("op_1", "challenge_fake");
    let result = app.create_challenge(challenge).await.unwrap();
    assert_eq!(result.challenge_id.as_str(), "challenge_fake");
    let provider = FakeProvider {
        indeterminate: false,
        subject: "same".into(),
    };
    let vault = FakeVault::default();
    let first = app
        .exchange_apple(
            exchange.clone(),
            &provider,
            &FixtureHasher::default(),
            &vault,
            1_000,
        )
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
        FixtureHasher::default()
            .token_verifier("refresh", &first.refresh_token)
            .await
            .unwrap()
    );
}

#[tokio::test]
async fn concurrent_same_subject_finishes_to_one_account() {
    let repo = FakeRepo::default();
    let identity = VerifiedExternalIdentity::apple("same-subject", 1_000).unwrap();
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
    let (challenge, exchange) = request("op_2", "challenge_fake");
    app.create_challenge(challenge).await.unwrap();
    let provider = FakeProvider {
        indeterminate: false,
        subject: "same".into(),
    };
    let vault = FakeVault::default();
    let grant = app
        .exchange_apple(
            exchange,
            &provider,
            &FixtureHasher::default(),
            &vault,
            1_000,
        )
        .await
        .unwrap();
    let first = app
        .refresh(RefreshRequest {
            operation_id: OperationId::new("refresh_op_1").unwrap(),
            refresh_token: grant.refresh_token.clone(),
            request_digest: digest_request(b"r"),
        })
        .await
        .unwrap();
    let replay = app
        .refresh(RefreshRequest {
            operation_id: OperationId::new("refresh_op_1").unwrap(),
            refresh_token: grant.refresh_token.clone(),
            request_digest: digest_request(b"r"),
        })
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
        .refresh(RefreshRequest {
            operation_id: OperationId::new("refresh_op_2").unwrap(),
            refresh_token: grant.refresh_token,
            request_digest: digest_request(b"r2"),
        })
        .await;
    assert_eq!(reused.unwrap_err(), AuthError::RefreshTokenReused);
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
    let (challenge, exchange) = request("op_3", "challenge_fake");
    app.create_challenge(challenge).await.unwrap();
    let provider = FakeProvider {
        indeterminate: true,
        subject: "same".into(),
    };
    let vault = FakeVault::default();
    assert_eq!(
        app.exchange_apple(
            exchange,
            &provider,
            &FixtureHasher::default(),
            &vault,
            1_000
        )
        .await
        .unwrap_err(),
        AuthError::ProviderExchangeIndeterminate
    );
    assert_eq!(repo.0.lock().unwrap().phase, Some(ChallengePhase::Terminal));
    let op = OperationId::new("revoke").unwrap();
    let digest = digest_request(b"revoke");
    let first = app
        .revoke_current_session(op.clone(), digest, SessionId::new("session_fake").unwrap())
        .await
        .unwrap();
    let replay = app
        .revoke_current_session(op, digest, SessionId::new("session_fake").unwrap())
        .await
        .unwrap();
    assert_eq!(first, replay);
}
