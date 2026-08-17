//! PostgreSQL implementation of the auth_v1 transaction boundary.
//!
//! Every public method opens one transaction and locks the aggregate before
//! changing it.  This repository never joins sync_v2 and never returns raw
//! provider credentials or subject material.

use crate::auth_application::{
    AuthRepository, ChallengeResult, NewChallenge, RefreshOutcome, SecurityTransition,
};
use crate::auth_domain::*;
use async_trait::async_trait;
use chrono::{DateTime, Utc};
use serde::Serialize;
use serde_json::to_value;
use sha2::{Digest, Sha256};
use sqlx::{PgPool, Row};
use std::sync::Arc;
use uuid::Uuid;

#[derive(Clone)]
pub struct AuthPostgresRepository {
    pub pool: PgPool,
    vault: Arc<dyn CredentialVault>,
    token_hmac_key: Arc<[u8; 32]>,
}
impl AuthPostgresRepository {
    pub fn new(pool: PgPool, vault: Arc<dyn CredentialVault>, token_hmac_key: [u8; 32]) -> Self {
        Self {
            pool,
            vault,
            token_hmac_key: Arc::new(token_hmac_key),
        }
    }
    fn hmac(&self, purpose: &str, token: &str) -> Result<Vec<u8>, AuthError> {
        token_hmac(self.token_hmac_key.as_ref(), purpose, token)
    }
    fn map_db(error: sqlx::Error) -> AuthError {
        AuthError::Database(error.to_string())
    }
    async fn find_receipt(
        &self,
        operation_id: &OperationId,
        kind: &str,
        digest: &[u8; 32],
    ) -> Result<Option<AuthReceipt>, AuthError> {
        let row = sqlx::query("SELECT command_kind,request_digest,response_status,response_ciphertext,response_key_version,response_purpose,state FROM auth_v1.auth_operations WHERE operation_id=$1")
            .bind(Uuid::parse_str(operation_id.as_str()).map_err(|_| AuthError::InvalidIdentifier)?).fetch_optional(&self.pool).await.map_err(Self::map_db)?;
        let Some(row) = row else { return Ok(None) };
        let existing_kind: String = row.try_get("command_kind").map_err(Self::map_db)?;
        let existing_digest: Vec<u8> = row.try_get("request_digest").map_err(Self::map_db)?;
        if existing_kind != kind || existing_digest.as_slice() != digest {
            return Err(AuthError::OperationIdReused);
        }
        if row.try_get::<String, _>("state").map_err(Self::map_db)? != "completed" {
            return Ok(None);
        }
        let encrypted: Vec<u8> = row.try_get("response_ciphertext").map_err(Self::map_db)?;
        let secret = SealedSecret {
            key_version: row.try_get("response_key_version").map_err(Self::map_db)?,
            ciphertext: encrypted,
        };
        let purpose: String = row.try_get("response_purpose").map_err(Self::map_db)?;
        let bytes = self
            .vault
            .open(&purpose, operation_id.as_str(), &secret)
            .await?;
        Ok(Some(AuthReceipt {
            operation_id: operation_id.clone(),
            command_kind: kind.into(),
            request_digest: *digest,
            response_bytes: bytes,
            status: row
                .try_get::<i32, _>("response_status")
                .map_err(Self::map_db)? as u16,
        }))
    }
    fn uuid(id: &str) -> Result<Uuid, AuthError> {
        Uuid::parse_str(id).map_err(|_| AuthError::InvalidIdentifier)
    }
    fn opaque(prefix: &str) -> String {
        format!("{prefix}_{}", Uuid::new_v4())
    }
    fn fence() -> Vec<u8> {
        Sha256::digest(Uuid::new_v4().as_bytes()).to_vec()
    }
}

#[async_trait]
impl AuthRepository for AuthPostgresRepository {
    async fn token_verifier(&self, purpose: &str, token: &str) -> Result<Vec<u8>, AuthError> {
        self.hmac(purpose, token)
    }

    async fn authenticate_access(
        &self,
        token_verifier: Vec<u8>,
    ) -> Result<AuthenticatedPrincipal, AuthError> {
        let row = sqlx::query("SELECT s.session_id,s.account_id,a.tenant_id,a.auth_epoch,a.fence FROM auth_v1.access_tokens t JOIN auth_v1.auth_sessions s ON s.session_id=t.session_id JOIN auth_v1.accounts a ON a.account_id=t.account_id WHERE t.token_hmac=$1 AND t.revoked_at IS NULL AND t.expires_at>now() AND s.state='active' AND t.auth_epoch=a.auth_epoch AND t.fence=a.fence FOR UPDATE OF t,s,a")
            .bind(token_verifier).fetch_optional(&self.pool).await.map_err(Self::map_db)?.ok_or(AuthError::AccountNotFound)?;
        Ok(AuthenticatedPrincipal {
            account_id: AccountId::new(
                row.try_get::<String, _>("account_id")
                    .map_err(Self::map_db)?,
            )?,
            tenant_id: TenantId::new(
                row.try_get::<String, _>("tenant_id")
                    .map_err(Self::map_db)?,
            )?,
            session_id: SessionId::new(format!(
                "session_{}",
                row.try_get::<Uuid, _>("session_id").map_err(Self::map_db)?
            ))?,
            account_auth_epoch: row.try_get("auth_epoch").map_err(Self::map_db)?,
            account_fence: row.try_get("fence").map_err(Self::map_db)?,
        })
    }

    async fn find_operation_receipt(
        &self,
        operation_id: &OperationId,
        kind: &str,
        digest: &[u8; 32],
    ) -> Result<Option<AuthReceipt>, AuthError> {
        self.find_receipt(operation_id, kind, digest).await
    }

    async fn create_challenge(
        &self,
        challenge: &NewChallenge,
        state_hash: Vec<u8>,
        nonce_hash: Vec<u8>,
    ) -> Result<ChallengeResult, AuthError> {
        let mut tx = self.pool.begin().await.map_err(Self::map_db)?;
        let op = Self::uuid(challenge.operation_id.as_str())?;
        if let Some(row) = sqlx::query(
            "SELECT command_kind FROM auth_v1.auth_operations WHERE operation_id=$1 FOR UPDATE",
        )
        .bind(op)
        .fetch_optional(&mut *tx)
        .await
        .map_err(Self::map_db)?
        {
            if row
                .try_get::<String, _>("command_kind")
                .map_err(Self::map_db)?
                != "createChallenge"
            {
                return Err(AuthError::OperationIdReused);
            }
            return Err(AuthError::OperationIdReused);
        }
        let challenge_id = ChallengeId::random("challenge");
        let challenge_uuid = Self::uuid(challenge_id.as_str().trim_start_matches("challenge_"))?;
        let config = ProviderConfigId::new(APPLE_PROVIDER_CONFIG)?;
        let request_digest = digest_request_for_challenge(challenge);
        let result = ChallengeResult {
            challenge_id: challenge_id.clone(),
            operation_id: challenge.operation_id.clone(),
            provider_config_id: config.clone(),
            audience: challenge.audience.clone(),
            state: challenge.state.clone(),
            nonce: challenge.nonce.clone(),
            expires_at_unix: challenge.expires_at_unix,
        };
        let response = canonical_wire(&result)?;
        let sealed = self
            .vault
            .seal(
                "auth_receipt_v1",
                challenge.operation_id.as_str(),
                &response,
            )
            .await?;
        sqlx::query("INSERT INTO auth_v1.auth_operations(operation_id,command_kind,request_digest,state,response_status,response_ciphertext,response_key_version,response_purpose,completed_at) VALUES($1,'createChallenge',$2,'completed',201,$3,$4,$5,now())")
            .bind(op).bind(&request_digest).bind(sealed.ciphertext).bind(sealed.key_version).bind("auth_receipt_v1").execute(&mut *tx).await.map_err(Self::map_db)?;
        sqlx::query("INSERT INTO auth_v1.auth_challenges(challenge_id,operation_id,provider_config_id,audience,client_platform,state_hash,nonce_hash,phase,lease_until,expires_at) VALUES($1,$2,$3,$4,$5,$6,$7,'claimed',to_timestamp($8),to_timestamp($8))")
            .bind(challenge_uuid).bind(op).bind(config.as_str()).bind(&challenge.audience).bind(&challenge.platform).bind(&state_hash).bind(&nonce_hash).bind(challenge.expires_at_unix).execute(&mut *tx).await.map_err(Self::map_db)?;
        tx.commit().await.map_err(Self::map_db)?;
        Ok(result)
    }

    async fn load_challenge_for_update(
        &self,
        challenge_id: &ChallengeId,
    ) -> Result<ChallengeClaim, AuthError> {
        let uuid = Self::uuid(challenge_id.as_str().trim_start_matches("challenge_"))?;
        let row = sqlx::query("SELECT operation_id,provider_config_id,audience,client_platform,state_hash,nonce_hash,phase,lease_until,expires_at FROM auth_v1.auth_challenges WHERE challenge_id=$1").bind(uuid).fetch_optional(&self.pool).await.map_err(Self::map_db)?.ok_or(AuthError::NotFound)?;
        Ok(ChallengeClaim {
            id: challenge_id.clone(),
            operation_id: OperationId::new(
                row.try_get::<Uuid, _>("operation_id")
                    .map_err(Self::map_db)?
                    .to_string(),
            )?,
            provider_config_id: ProviderConfigId::new(
                row.try_get::<String, _>("provider_config_id")
                    .map_err(Self::map_db)?,
            )?,
            audience: row.try_get("audience").map_err(Self::map_db)?,
            platform: row.try_get("client_platform").map_err(Self::map_db)?,
            state_hash: row.try_get("state_hash").map_err(Self::map_db)?,
            nonce_hash: row.try_get("nonce_hash").map_err(Self::map_db)?,
            phase: parse_phase(&row.try_get::<String, _>("phase").map_err(Self::map_db)?),
            lease_until_unix: row
                .try_get::<DateTime<Utc>, _>("lease_until")
                .map_err(Self::map_db)?
                .timestamp(),
            expires_at_unix: row
                .try_get::<DateTime<Utc>, _>("expires_at")
                .map_err(Self::map_db)?
                .timestamp(),
        })
    }

    async fn mark_provider_call_started(
        &self,
        challenge_id: &ChallengeId,
    ) -> Result<(), AuthError> {
        let id = Self::uuid(challenge_id.as_str().trim_start_matches("challenge_"))?;
        let result = sqlx::query("UPDATE auth_v1.auth_challenges SET phase='providerCallStarted',lease_until=now()+interval '5 minutes' WHERE challenge_id=$1 AND phase='claimed' AND expires_at>now()").bind(id).execute(&self.pool).await.map_err(Self::map_db)?;
        if result.rows_affected() != 1 {
            return Err(AuthError::InvalidChallengePhase);
        }
        Ok(())
    }

    async fn mark_provider_exchange_indeterminate(
        &self,
        challenge_id: &ChallengeId,
    ) -> Result<(), AuthError> {
        let id = Self::uuid(challenge_id.as_str().trim_start_matches("challenge_"))?;
        sqlx::query("UPDATE auth_v1.auth_challenges SET phase='terminal' WHERE challenge_id=$1 AND phase='providerCallStarted'")
            .bind(id).execute(&self.pool).await.map_err(Self::map_db)?;
        Ok(())
    }

    async fn mark_provider_result_known(
        &self,
        challenge_id: &ChallengeId,
        _identity: &VerifiedExternalIdentity,
        sealed_result: SealedSecret,
    ) -> Result<(), AuthError> {
        let id = Self::uuid(challenge_id.as_str().trim_start_matches("challenge_"))?;
        let result = sqlx::query("UPDATE auth_v1.auth_challenges SET phase='providerResultKnown',provider_result_ciphertext=$2,provider_result_key_version=$3,provider_result_purpose='apple_exchange_result_v1' WHERE challenge_id=$1 AND phase='providerCallStarted'").bind(id).bind(sealed_result.ciphertext).bind(sealed_result.key_version).execute(&self.pool).await.map_err(Self::map_db)?;
        if result.rows_affected() != 1 {
            return Err(AuthError::InvalidChallengePhase);
        }
        Ok(())
    }

    async fn finish_exchange(
        &self,
        challenge_id: &ChallengeId,
        operation_id: &OperationId,
        identity: &VerifiedExternalIdentity,
        subject_lookup: Vec<u8>,
        subject_secret: SealedSecret,
        audience: &str,
        request_digest: [u8; 32],
    ) -> Result<(SessionGrant, AuthReceipt), AuthError> {
        if audience.is_empty() {
            return Err(AuthError::ProviderNotAllowed);
        }
        let mut tx = self.pool.begin().await.map_err(Self::map_db)?;
        let challenge_uuid = Self::uuid(challenge_id.as_str().trim_start_matches("challenge_"))?;
        let op = Self::uuid(operation_id.as_str())?;
        sqlx::query("INSERT INTO auth_v1.auth_operations(operation_id,command_kind,request_digest,state) VALUES($1,'exchangeApple',$2,'reserved') ON CONFLICT DO NOTHING")
            .bind(op)
            .bind(request_digest.as_slice())
            .execute(&mut *tx)
            .await
            .map_err(Self::map_db)?;
        let operation = sqlx::query("SELECT command_kind,request_digest FROM auth_v1.auth_operations WHERE operation_id=$1 FOR UPDATE")
            .bind(op)
            .fetch_one(&mut *tx)
            .await
            .map_err(Self::map_db)?;
        if operation
            .try_get::<String, _>("command_kind")
            .map_err(Self::map_db)?
            != "exchangeApple"
            || operation
                .try_get::<Vec<u8>, _>("request_digest")
                .map_err(Self::map_db)?
                .as_slice()
                != request_digest
        {
            return Err(AuthError::OperationIdReused);
        }
        // Serialize first-login races at the provider configuration row. The
        // unique lookup HMAC remains the invariant; the lock lets a loser
        // read back the committed AccountID instead of returning a duplicate
        // key error.
        sqlx::query("INSERT INTO auth_v1.provider_configs(provider_config_id,provider_kind,exact_issuer,allowed_audiences,enabled,config_version) VALUES($1,'apple',$2,$3,true,1) ON CONFLICT(provider_config_id) DO NOTHING")
            .bind(identity.provider_config_id.as_str())
            .bind(&identity.exact_issuer)
            .bind(vec![
                "dev.serikayuzuki.fuminiwa".to_owned(),
                "dev.serikayuzuki.fuminiwa.ios".to_owned(),
            ])
            .execute(&mut *tx).await.map_err(Self::map_db)?;
        let config_row = sqlx::query("SELECT exact_issuer,enabled FROM auth_v1.provider_configs WHERE provider_config_id=$1 FOR UPDATE")
            .bind(identity.provider_config_id.as_str()).fetch_one(&mut *tx).await.map_err(Self::map_db)?;
        if !config_row
            .try_get::<bool, _>("enabled")
            .map_err(Self::map_db)?
            || config_row
                .try_get::<String, _>("exact_issuer")
                .map_err(Self::map_db)?
                != identity.exact_issuer
        {
            return Err(AuthError::ProviderNotAllowed);
        }
        let config = identity.provider_config_id.as_str();
        let row = sqlx::query("SELECT identity_id,account_id FROM auth_v1.external_identities WHERE provider_config_id=$1 AND exact_issuer=$2 AND subject_lookup_hmac=$3 FOR UPDATE").bind(config).bind(&identity.exact_issuer).bind(&subject_lookup).fetch_optional(&mut *tx).await.map_err(Self::map_db)?;
        let (account_id, tenant_id, epoch, fence, identity_id) = if let Some(row) = row {
            let account = row
                .try_get::<String, _>("account_id")
                .map_err(Self::map_db)?;
            let account_row = sqlx::query("SELECT tenant_id,auth_epoch,fence FROM auth_v1.accounts WHERE account_id=$1 FOR UPDATE").bind(&account).fetch_one(&mut *tx).await.map_err(Self::map_db)?;
            (
                AccountId::new(account)?,
                TenantId::new(
                    account_row
                        .try_get::<String, _>("tenant_id")
                        .map_err(Self::map_db)?,
                )?,
                account_row.try_get("auth_epoch").map_err(Self::map_db)?,
                account_row.try_get("fence").map_err(Self::map_db)?,
                row.try_get::<Uuid, _>("identity_id")
                    .map_err(Self::map_db)?,
            )
        } else {
            let account = AccountId::random("acct");
            let tenant = TenantId::random("tenant");
            let fence = Self::fence();
            sqlx::query("INSERT INTO auth_v1.accounts(account_id,tenant_id,state,auth_epoch,fence) VALUES($1,$2,'active',1,$3)").bind(account.as_str()).bind(tenant.as_str()).bind(&fence).execute(&mut *tx).await.map_err(Self::map_db)?;
            let iid = Uuid::new_v4();
            sqlx::query("INSERT INTO auth_v1.external_identities(identity_id,account_id,provider_config_id,exact_issuer,lookup_key_version,subject_lookup_hmac,state) VALUES($1,$2,$3,$4,1,$5,'active')").bind(iid).bind(account.as_str()).bind(config).bind(&identity.exact_issuer).bind(&subject_lookup).execute(&mut *tx).await.map_err(Self::map_db)?;
            sqlx::query("INSERT INTO auth_v1.external_identity_secrets(identity_id,key_version,purpose,ciphertext) VALUES($1,$2,'external_identity_subject_v1',$3)").bind(iid).bind(subject_secret.key_version).bind(subject_secret.ciphertext).execute(&mut *tx).await.map_err(Self::map_db)?;
            (account, tenant, 1, fence, iid)
        };
        if let Some(credential) = &identity.provider_credential {
            let previous = sqlx::query("SELECT COALESCE(MAX(credential_generation),0) AS generation FROM auth_v1.provider_credentials WHERE identity_id=$1 AND original_audience=$2")
                .bind(identity_id)
                .bind(&credential.audience)
                .fetch_one(&mut *tx)
                .await
                .map_err(Self::map_db)?;
            let previous_generation: i64 = previous.try_get("generation").map_err(Self::map_db)?;
            let generation = previous_generation + 1;
            sqlx::query("UPDATE auth_v1.provider_credentials SET state='superseded' WHERE identity_id=$1 AND original_audience=$2 AND state='active'")
                .bind(identity_id)
                .bind(&credential.audience)
                .execute(&mut *tx)
                .await
                .map_err(Self::map_db)?;
            sqlx::query("INSERT INTO auth_v1.provider_credentials(credential_id,identity_id,original_audience,credential_generation,key_version,ciphertext,state) VALUES($1,$2,$3,$4,$5,$6,'active')")
                .bind(Uuid::new_v4())
                .bind(identity_id)
                .bind(&credential.audience)
                .bind(generation)
                .bind(credential.encrypted_refresh_token.key_version)
                .bind(&credential.encrypted_refresh_token.ciphertext)
                .execute(&mut *tx)
                .await
                .map_err(Self::map_db)?;
        }
        let session = SessionId::random("session");
        let family = SessionFamilyId::random("family");
        let access = Self::opaque("fma1");
        let refresh = Self::opaque("fmr1");
        let sid = Self::uuid(session.as_str().trim_start_matches("session_"))?;
        let fid = Self::uuid(family.as_str().trim_start_matches("family_"));
        let fid = fid?;
        sqlx::query("INSERT INTO auth_v1.auth_sessions(session_id,account_id,identity_id,family_id,auth_epoch,state,client_platform,expires_at) VALUES($1,$2,$3,$4,$5,'active','macos',now()+interval '90 days')").bind(sid).bind(account_id.as_str()).bind(identity_id).bind(fid).bind(epoch).execute(&mut *tx).await.map_err(Self::map_db)?;
        let access_hash = self.hmac("access", &access)?;
        sqlx::query("INSERT INTO auth_v1.access_tokens(token_id,session_id,account_id,token_hmac,auth_epoch,fence,expires_at) VALUES($1,$2,$3,$4,$5,$6,now()+interval '15 minutes')")
            .bind(Uuid::new_v4()).bind(sid).bind(account_id.as_str()).bind(access_hash).bind(epoch).bind(&fence)
            .execute(&mut *tx).await.map_err(Self::map_db)?;
        sqlx::query("INSERT INTO auth_v1.refresh_families(family_id,session_id,account_id,state,current_generation,expires_at) VALUES($1,$2,$3,'active',1,now()+interval '90 days')").bind(fid).bind(sid).bind(account_id.as_str()).execute(&mut *tx).await.map_err(Self::map_db)?;
        let token_hash = self.hmac("refresh", &refresh)?;
        sqlx::query("INSERT INTO auth_v1.refresh_tokens(family_id,generation,token_hmac,state) VALUES($1,1,$2,'active')").bind(fid).bind(&token_hash).execute(&mut *tx).await.map_err(Self::map_db)?;
        let grant = SessionGrant {
            principal: AuthenticatedPrincipal {
                account_id: account_id.clone(),
                tenant_id,
                session_id: session.clone(),
                account_auth_epoch: epoch,
                account_fence: fence,
            },
            access_token: access,
            refresh_token: refresh,
            refresh_generation: 1,
            access_expires_at_unix: identity.authenticated_at_unix + ACCESS_TOKEN_LIFETIME_SECONDS,
            refresh_expires_at_unix: identity.authenticated_at_unix
                + REFRESH_TOKEN_LIFETIME_SECONDS,
        };
        let response = canonical_wire(&grant)?;
        let sealed = self
            .vault
            .seal("auth_receipt_v1", operation_id.as_str(), &response)
            .await?;
        sqlx::query("UPDATE auth_v1.auth_operations SET state='completed',response_status=200,response_ciphertext=$2,response_key_version=$3,response_purpose='auth_receipt_v1',completed_at=now() WHERE operation_id=$1 AND command_kind='exchangeApple'").bind(op).bind(sealed.ciphertext).bind(sealed.key_version).execute(&mut *tx).await.map_err(Self::map_db)?;
        sqlx::query("UPDATE auth_v1.auth_challenges SET phase='terminal' WHERE challenge_id=$1")
            .bind(challenge_uuid)
            .execute(&mut *tx)
            .await
            .map_err(Self::map_db)?;
        tx.commit().await.map_err(Self::map_db)?;
        Ok((
            grant,
            AuthReceipt {
                operation_id: operation_id.clone(),
                command_kind: "exchangeApple".into(),
                request_digest,
                response_bytes: response,
                status: 200,
            },
        ))
    }

    async fn refresh(
        &self,
        request: &RefreshRequest,
        token_verifier: Vec<u8>,
    ) -> Result<RefreshOutcome, AuthError> {
        let mut tx = self.pool.begin().await.map_err(Self::map_db)?;
        let op = Self::uuid(request.operation_id.as_str())?;
        if let Some(row) = sqlx::query("SELECT response_ciphertext,response_status,response_key_version,response_purpose,request_digest FROM auth_v1.session_refresh_receipts WHERE operation_id=$1 FOR UPDATE").bind(op).fetch_optional(&mut *tx).await.map_err(Self::map_db)? {
            let digest: Vec<u8> = row.try_get("request_digest").map_err(Self::map_db)?; if digest.as_slice()!=request.request_digest { return Err(AuthError::OperationIdReused); }
            let encrypted: Vec<u8> = row.try_get("response_ciphertext").map_err(Self::map_db)?; let purpose: String = row.try_get("response_purpose").map_err(Self::map_db)?; let key_version: i32 = row.try_get("response_key_version").map_err(Self::map_db)?; let bytes=self.vault.open(&purpose,request.operation_id.as_str(),&SealedSecret{key_version,ciphertext:encrypted}).await?; let grant: SessionGrant=serde_json::from_slice(&bytes).map_err(|_|AuthError::Vault)?; tx.commit().await.map_err(Self::map_db)?; return Ok(RefreshOutcome{grant:Some(grant),receipt:None,reused:false});
        }
        let row=sqlx::query("SELECT family_id,generation,state FROM auth_v1.refresh_tokens WHERE token_hmac=$1 FOR UPDATE").bind(token_verifier).fetch_optional(&mut *tx).await.map_err(Self::map_db)?.ok_or(AuthError::NotFound)?;
        if row.try_get::<String, _>("state").map_err(Self::map_db)? != "active" {
            sqlx::query(
                "UPDATE auth_v1.refresh_families SET state='reuseDetected' WHERE family_id=$1",
            )
            .bind(row.try_get::<Uuid, _>("family_id").map_err(Self::map_db)?)
            .execute(&mut *tx)
            .await
            .map_err(Self::map_db)?;
            sqlx::query("UPDATE auth_v1.refresh_tokens SET state='revoked' WHERE family_id=$1 AND state='active'")
                .bind(row.try_get::<Uuid, _>("family_id").map_err(Self::map_db)?)
                .execute(&mut *tx).await.map_err(Self::map_db)?;
            sqlx::query("UPDATE auth_v1.auth_sessions SET state='revoked' WHERE family_id=$1 AND state='active'")
                .bind(row.try_get::<Uuid, _>("family_id").map_err(Self::map_db)?)
                .execute(&mut *tx).await.map_err(Self::map_db)?;
            tx.commit().await.map_err(Self::map_db)?;
            return Err(AuthError::RefreshTokenReused);
        }
        let family: Uuid = row.try_get("family_id").map_err(Self::map_db)?;
        let generation: i64 = row.try_get("generation").map_err(Self::map_db)?;
        let session=sqlx::query("SELECT s.session_id,s.account_id,a.tenant_id,a.auth_epoch,a.fence FROM auth_v1.auth_sessions s JOIN auth_v1.accounts a ON a.account_id=s.account_id WHERE s.family_id=$1 AND s.state='active' FOR UPDATE").bind(family).fetch_one(&mut *tx).await.map_err(Self::map_db)?;
        sqlx::query("UPDATE auth_v1.refresh_tokens SET state='consumed' WHERE family_id=$1 AND generation=$2").bind(family).bind(generation).execute(&mut *tx).await.map_err(Self::map_db)?;
        let next = generation + 1;
        let access = Self::opaque("fma1");
        let refresh = Self::opaque("fmr1");
        let rotated_access_hash = self.hmac("access", &access)?;
        sqlx::query("INSERT INTO auth_v1.access_tokens(token_id,session_id,account_id,token_hmac,auth_epoch,fence,expires_at) VALUES($1,$2,$3,$4,$5,$6,now()+interval '15 minutes')")
            .bind(Uuid::new_v4())
            .bind(session.try_get::<Uuid, _>("session_id").map_err(Self::map_db)?)
            .bind(session.try_get::<String, _>("account_id").map_err(Self::map_db)?)
            .bind(rotated_access_hash)
            .bind(session.try_get::<i64, _>("auth_epoch").map_err(Self::map_db)?)
            .bind(session.try_get::<Vec<u8>, _>("fence").map_err(Self::map_db)?)
            .execute(&mut *tx).await.map_err(Self::map_db)?;
        sqlx::query("INSERT INTO auth_v1.refresh_tokens(family_id,generation,token_hmac,state) VALUES($1,$2,$3,'active')").bind(family).bind(next).bind(self.hmac("refresh",&refresh)?).execute(&mut *tx).await.map_err(Self::map_db)?;
        sqlx::query("UPDATE auth_v1.refresh_families SET current_generation=$2 WHERE family_id=$1")
            .bind(family)
            .bind(next)
            .execute(&mut *tx)
            .await
            .map_err(Self::map_db)?;
        let grant = SessionGrant {
            principal: AuthenticatedPrincipal {
                account_id: AccountId::new(
                    session
                        .try_get::<String, _>("account_id")
                        .map_err(Self::map_db)?,
                )?,
                tenant_id: TenantId::new(
                    session
                        .try_get::<String, _>("tenant_id")
                        .map_err(Self::map_db)?,
                )?,
                session_id: SessionId::new(format!(
                    "session_{}",
                    session
                        .try_get::<Uuid, _>("session_id")
                        .map_err(Self::map_db)?
                ))?,
                account_auth_epoch: session.try_get("auth_epoch").map_err(Self::map_db)?,
                account_fence: session.try_get("fence").map_err(Self::map_db)?,
            },
            access_token: access,
            refresh_token: refresh,
            refresh_generation: next,
            access_expires_at_unix: 0,
            refresh_expires_at_unix: 0,
        };
        let response = canonical_wire(&grant)?;
        let sealed = self
            .vault
            .seal("auth_receipt_v1", request.operation_id.as_str(), &response)
            .await?;
        sqlx::query("INSERT INTO auth_v1.session_refresh_receipts(operation_id,family_id,presented_token_hmac,request_digest,response_ciphertext,response_key_version,response_purpose,response_status,expires_at) VALUES($1,$2,$3,$4,$5,$6,'auth_receipt_v1',200,now()+interval '90 days')").bind(op).bind(family).bind(self.hmac("refresh",&request.refresh_token)?).bind(request.request_digest.as_slice()).bind(sealed.ciphertext).bind(sealed.key_version).execute(&mut *tx).await.map_err(Self::map_db)?;
        tx.commit().await.map_err(Self::map_db)?;
        Ok(RefreshOutcome {
            grant: Some(grant),
            receipt: None,
            reused: false,
        })
    }

    async fn revoke_current_session(
        &self,
        operation_id: &OperationId,
        request_digest: [u8; 32],
        session_id: &SessionId,
    ) -> Result<AuthReceipt, AuthError> {
        let mut tx = self.pool.begin().await.map_err(Self::map_db)?;
        let sid = Self::uuid(session_id.as_str().trim_start_matches("session_"))?;
        let op = Self::uuid(operation_id.as_str())?;
        if let Some(row) = sqlx::query("SELECT command_kind,request_digest,response_status,response_ciphertext,response_key_version,response_purpose,state FROM auth_v1.auth_operations WHERE operation_id=$1 FOR UPDATE")
            .bind(op).fetch_optional(&mut *tx).await.map_err(Self::map_db)? {
            if row.try_get::<String, _>("command_kind").map_err(Self::map_db)? != "revokeCurrentSession"
                || row.try_get::<Vec<u8>, _>("request_digest").map_err(Self::map_db)?.as_slice() != request_digest { return Err(AuthError::OperationIdReused); }
            if row.try_get::<String, _>("state").map_err(Self::map_db)? == "completed" {
                let response = self.vault.open(
                    &row.try_get::<String, _>("response_purpose").map_err(Self::map_db)?, operation_id.as_str(),
                    &SealedSecret { key_version: row.try_get("response_key_version").map_err(Self::map_db)?, ciphertext: row.try_get("response_ciphertext").map_err(Self::map_db)? },
                ).await?;
                tx.commit().await.map_err(Self::map_db)?;
                return Ok(AuthReceipt { operation_id: operation_id.clone(), command_kind: "revokeCurrentSession".into(), request_digest, response_bytes: response, status: row.try_get::<i32, _>("response_status").map_err(Self::map_db)? as u16 });
            }
        } else {
            sqlx::query("INSERT INTO auth_v1.auth_operations(operation_id,command_kind,request_digest,state) VALUES($1,'revokeCurrentSession',$2,'reserved')")
                .bind(op).bind(request_digest.as_slice()).execute(&mut *tx).await.map_err(Self::map_db)?;
        }
        sqlx::query("UPDATE auth_v1.auth_sessions SET state='revoked' WHERE session_id=$1 AND state='active'").bind(sid).execute(&mut *tx).await.map_err(Self::map_db)?;
        let response = b"{\"scope\":\"currentSession\",\"fenceChanged\":false}".to_vec();
        let sealed = self
            .vault
            .seal("auth_receipt_v1", operation_id.as_str(), &response)
            .await?;
        sqlx::query("UPDATE auth_v1.auth_operations SET state='completed',response_status=200,response_ciphertext=$2,response_key_version=$3,response_purpose='auth_receipt_v1',completed_at=now() WHERE operation_id=$1").bind(op).bind(sealed.ciphertext).bind(sealed.key_version).execute(&mut *tx).await.map_err(Self::map_db)?;
        tx.commit().await.map_err(Self::map_db)?;
        Ok(AuthReceipt {
            operation_id: operation_id.clone(),
            command_kind: "revokeCurrentSession".into(),
            request_digest,
            response_bytes: response,
            status: 200,
        })
    }

    async fn rotate_account_fence(
        &self,
        account_id: &AccountId,
    ) -> Result<SecurityTransition, AuthError> {
        let mut tx = self.pool.begin().await.map_err(Self::map_db)?;
        let fence = Self::fence();
        let row=sqlx::query("UPDATE auth_v1.accounts SET auth_epoch=auth_epoch+1,fence=$2,updated_at=now() WHERE account_id=$1 RETURNING auth_epoch,fence").bind(account_id.as_str()).bind(&fence).fetch_one(&mut *tx).await.map_err(Self::map_db)?;
        sqlx::query("UPDATE auth_v1.auth_sessions SET state='reauthRequired' WHERE account_id=$1 AND state='active'").bind(account_id.as_str()).execute(&mut *tx).await.map_err(Self::map_db)?;
        tx.commit().await.map_err(Self::map_db)?;
        Ok(SecurityTransition {
            account_auth_epoch: row.try_get("auth_epoch").map_err(Self::map_db)?,
            account_fence: row.try_get("fence").map_err(Self::map_db)?,
            sessions_revoked: true,
        })
    }
}

fn parse_phase(value: &str) -> ChallengePhase {
    match value {
        "claimed" => ChallengePhase::Claimed,
        "providerCallStarted" => ChallengePhase::ProviderCallStarted,
        "providerResultKnown" => ChallengePhase::ProviderResultKnown,
        _ => ChallengePhase::Terminal,
    }
}
fn digest_request_for_challenge(challenge: &NewChallenge) -> Vec<u8> {
    let mut bytes = challenge.operation_id.to_string().into_bytes();
    bytes.extend_from_slice(challenge.provider.as_bytes());
    bytes.extend_from_slice(challenge.platform.as_bytes());
    bytes.extend_from_slice(challenge.audience.as_bytes());
    crate::domain::sha256(&bytes).to_vec()
}

fn canonical_wire<T: Serialize>(value: &T) -> Result<Vec<u8>, AuthError> {
    let value = to_value(value).map_err(|_| AuthError::Vault)?;
    crate::domain::canonical_json(&value).map_err(|_| AuthError::Vault)
}
