//! PostgreSQL implementation of the auth_v1 transaction boundary.
//!
//! Every public method opens one transaction and locks the aggregate before
//! changing it.  This repository never joins sync_v2 and never returns raw
//! provider credentials or subject material.

use crate::auth_apple::AppleS2SNotification;
use crate::auth_application::{
    AuthRepository, ChallengeResult, NewChallenge, RefreshOutcome, SecurityTransition,
};
use crate::auth_domain::*;
use async_trait::async_trait;
use base64::{engine::general_purpose::URL_SAFE_NO_PAD, Engine};
use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use serde_json::to_value;
use sqlx::{PgPool, Row};
use std::sync::Arc;
use uuid::Uuid;

fn random_fence() -> Result<[u8; 32], AuthError> {
    let mut value = [0_u8; 32];
    getrandom::getrandom(&mut value).map_err(|_| AuthError::Vault)?;
    Ok(value)
}

#[derive(Clone)]
pub struct AuthPostgresRepository {
    pub pool: PgPool,
    vault: Arc<dyn CredentialVault>,
    token_hmac_key: Arc<[u8; 32]>,
    server_instance_id: Arc<str>,
}

#[derive(Clone, Debug)]
pub struct PendingAppleRevocation {
    pub credential_id: Uuid,
    pub audience: String,
    pub vault_context: String,
    pub secret: SealedSecret,
    pub attempt: i32,
}

impl AuthPostgresRepository {
    pub fn new(
        pool: PgPool,
        vault: Arc<dyn CredentialVault>,
        token_hmac_key: [u8; 32],
        server_instance_id: String,
    ) -> Result<Self, AuthError> {
        let parsed =
            Uuid::parse_str(&server_instance_id).map_err(|_| AuthError::InvalidIdentifier)?;
        if parsed.to_string() != server_instance_id {
            return Err(AuthError::InvalidIdentifier);
        }
        Ok(Self {
            pool,
            vault,
            token_hmac_key: Arc::new(token_hmac_key),
            server_instance_id: server_instance_id.into(),
        })
    }

    pub async fn record_apple_notification(
        &self,
        notification: &AppleS2SNotification,
        subject_lookup: &[u8],
        request_digest: [u8; 32],
    ) -> Result<(), AuthError> {
        let event_key = token_hmac(
            self.token_hmac_key.as_ref(),
            "apple-s2s-jti-v1",
            &notification.jti,
        )?;
        let mut tx = self.pool.begin().await.map_err(Self::map_db)?;
        let existing = sqlx::query("SELECT request_digest FROM auth_v1.provider_notification_receipts WHERE provider_config_id=$1 AND event_key_version=1 AND event_key_hmac=$2 FOR UPDATE")
            .bind(APPLE_PROVIDER_CONFIG)
            .bind(&event_key)
            .fetch_optional(&mut *tx)
            .await
            .map_err(Self::map_db)?;
        if let Some(row) = existing {
            let stored: Vec<u8> = row.try_get("request_digest").map_err(Self::map_db)?;
            if stored.as_slice() != request_digest {
                return Err(AuthError::OperationIdReused);
            }
            tx.commit().await.map_err(Self::map_db)?;
            return Ok(());
        }
        let identity = sqlx::query("SELECT identity_id,account_id FROM auth_v1.external_identities WHERE provider_config_id=$1 AND exact_issuer=$2 AND subject_lookup_hmac=$3 AND state='active' FOR UPDATE")
            .bind(APPLE_PROVIDER_CONFIG)
            .bind(APPLE_ISSUER)
            .bind(subject_lookup)
            .fetch_optional(&mut *tx)
            .await
            .map_err(Self::map_db)?;
        let (account_id, outcome) = if let Some(identity) = identity {
            let identity_id: Uuid = identity.try_get("identity_id").map_err(Self::map_db)?;
            let account_id: String = identity.try_get("account_id").map_err(Self::map_db)?;
            let account = sqlx::query(
                "SELECT account_id FROM auth_v1.accounts WHERE account_id=$1 FOR UPDATE",
            )
            .bind(&account_id)
            .fetch_one(&mut *tx)
            .await
            .map_err(Self::map_db)?;
            let account_id: String = account.try_get("account_id").map_err(Self::map_db)?;
            let latest: Option<i64> = sqlx::query_scalar("SELECT max(event_issued_at) FROM auth_v1.provider_notification_receipts WHERE provider_config_id=$1 AND account_id=$2")
                .bind(APPLE_PROVIDER_CONFIG)
                .bind(&account_id)
                .fetch_one(&mut *tx)
                .await
                .map_err(Self::map_db)?;
            if latest.is_some_and(|value| value >= notification.event_time_unix) {
                (Some(account_id), "staleAfterReauthentication")
            } else {
                let destructive = matches!(
                    notification.notification_type.as_str(),
                    "consent-revoked" | "account-deleted"
                );
                if destructive {
                    let fence = random_fence()?;
                    sqlx::query("UPDATE auth_v1.accounts SET auth_epoch=auth_epoch+1,fence=$2,state=CASE WHEN $3 THEN 'deletionPending' ELSE state END,updated_at=now() WHERE account_id=$1")
                    .bind(&account_id).bind(fence).bind(notification.notification_type == "account-deleted")
                    .execute(&mut *tx).await.map_err(Self::map_db)?;
                    sqlx::query("UPDATE auth_v1.auth_sessions SET state='reauthRequired' WHERE account_id=$1 AND state='active'")
                    .bind(&account_id).execute(&mut *tx).await.map_err(Self::map_db)?;
                    sqlx::query("UPDATE auth_v1.provider_credentials SET state='revokeRetryPending' WHERE identity_id=$1 AND state='active'")
                    .bind(identity_id).execute(&mut *tx).await.map_err(Self::map_db)?;
                }
                let outcome = if matches!(
                    notification.notification_type.as_str(),
                    "email-enabled" | "email-disabled"
                ) {
                    "emailStateOnly"
                } else {
                    "applied"
                };
                (Some(account_id), outcome)
            }
        } else {
            (None, "unknownIdentity")
        };
        sqlx::query("INSERT INTO auth_v1.provider_notification_receipts(provider_config_id,event_key_version,event_key_hmac,request_digest,event_kind,event_issued_at,outcome,account_id) VALUES($1,1,$2,$3,$4,$5,$6,$7)")
            .bind(APPLE_PROVIDER_CONFIG).bind(&event_key).bind(request_digest.as_slice())
            .bind(&notification.notification_type).bind(notification.event_time_unix).bind(outcome)
            .bind(account_id)
            .execute(&mut *tx).await.map_err(Self::map_db)?;
        tx.commit().await.map_err(Self::map_db)
    }

    /// Claims a bounded batch of provider revocations. The lease and attempt
    /// increment are durable before the Apple call, so a crash or lost ACK can
    /// safely resume without sending a different credential generation.
    pub async fn claim_apple_revocations(
        &self,
        now: DateTime<Utc>,
        limit: i64,
    ) -> Result<Vec<PendingAppleRevocation>, AuthError> {
        if !(1..=64).contains(&limit) {
            return Err(AuthError::InvalidRequest);
        }
        let lease_until = now + chrono::Duration::seconds(60);
        let mut tx = self.pool.begin().await.map_err(Self::map_db)?;
        let rows = sqlx::query(
            "SELECT credential_id,original_audience,vault_context,key_version,ciphertext,revoke_attempts
               FROM auth_v1.provider_credentials
              WHERE state='revokeRetryPending'
                AND (revoke_next_attempt_at IS NULL OR revoke_next_attempt_at <= $1)
                AND (revoke_lease_until IS NULL OR revoke_lease_until <= $1)
              ORDER BY created_at,credential_id
              FOR UPDATE SKIP LOCKED
              LIMIT $2",
        )
        .bind(now)
        .bind(limit)
        .fetch_all(&mut *tx)
        .await
        .map_err(Self::map_db)?;
        let mut claimed = Vec::with_capacity(rows.len());
        for row in rows {
            let id: Uuid = row.try_get("credential_id").map_err(Self::map_db)?;
            let attempt: i32 = row.try_get("revoke_attempts").map_err(Self::map_db)?;
            sqlx::query(
                "UPDATE auth_v1.provider_credentials
                    SET revoke_attempts=revoke_attempts+1,revoke_lease_until=$2,
                        revoke_last_error=NULL
                  WHERE credential_id=$1 AND state='revokeRetryPending'",
            )
            .bind(id)
            .bind(lease_until)
            .execute(&mut *tx)
            .await
            .map_err(Self::map_db)?;
            claimed.push(PendingAppleRevocation {
                credential_id: id,
                audience: row.try_get("original_audience").map_err(Self::map_db)?,
                vault_context: row.try_get("vault_context").map_err(Self::map_db)?,
                secret: SealedSecret {
                    key_version: row.try_get("key_version").map_err(Self::map_db)?,
                    ciphertext: row.try_get("ciphertext").map_err(Self::map_db)?,
                },
                attempt: attempt + 1,
            });
        }
        tx.commit().await.map_err(Self::map_db)?;
        Ok(claimed)
    }

    pub async fn finish_apple_revocation(
        &self,
        credential_id: Uuid,
        outcome: Result<(), &AuthError>,
        now: DateTime<Utc>,
        attempt: i32,
    ) -> Result<(), AuthError> {
        let mut tx = self.pool.begin().await.map_err(Self::map_db)?;
        match outcome {
            Ok(()) | Err(AuthError::InvalidExternalIdentity) => {
                sqlx::query(
                    "UPDATE auth_v1.provider_credentials
                        SET state='revoked',revoked_at=COALESCE(revoked_at,$2),
                            revoke_lease_until=NULL,revoke_next_attempt_at=NULL,
                            revoke_last_error=NULL
                      WHERE credential_id=$1 AND state='revokeRetryPending'",
                )
                .bind(credential_id)
                .bind(now)
                .execute(&mut *tx)
                .await
                .map_err(Self::map_db)?;
            }
            Err(error) => {
                let shift = attempt.clamp(0, 10) as u32;
                let delay = 2_i64.saturating_pow(shift).min(3600);
                let message = match error {
                    AuthError::ProviderExchangeIndeterminate => "providerIndeterminate",
                    AuthError::Database(_) => "database",
                    AuthError::Vault => "vault",
                    _ => "retryable",
                };
                sqlx::query(
                    "UPDATE auth_v1.provider_credentials
                        SET revoke_lease_until=NULL,
                            revoke_next_attempt_at=$2,
                            revoke_last_error=$3
                      WHERE credential_id=$1 AND state='revokeRetryPending'",
                )
                .bind(credential_id)
                .bind(now + chrono::Duration::seconds(delay))
                .bind(message)
                .execute(&mut *tx)
                .await
                .map_err(Self::map_db)?;
            }
        }
        tx.commit().await.map_err(Self::map_db)
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
        let row = sqlx::query("SELECT command_kind,request_digest,response_status,response_digest,response_ciphertext,response_key_version,response_purpose,state FROM auth_v1.auth_operations WHERE operation_id=$1")
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
        verify_response_digest(
            &bytes,
            &row.try_get::<Vec<u8>, _>("response_digest")
                .map_err(Self::map_db)?,
        )?;
        let status = row
            .try_get::<i32, _>("response_status")
            .map_err(Self::map_db)? as u16;
        let session_grant = if kind == EXCHANGE_APPLE_COMMAND && status == 200 {
            let account_id = crate::auth_wire::session_response_account_id(&bytes)?;
            let tenant = sqlx::query("SELECT tenant_id FROM auth_v1.accounts WHERE account_id=$1")
                .bind(account_id.as_str())
                .fetch_optional(&self.pool)
                .await
                .map_err(Self::map_db)?
                .ok_or(AuthError::AccountNotFound)?
                .try_get::<String, _>("tenant_id")
                .map_err(Self::map_db)?;
            Some(crate::auth_wire::decode_exchange_response(
                &bytes,
                TenantId::new(tenant)?,
            )?)
        } else {
            None
        };
        Ok(Some(AuthReceipt {
            operation_id: operation_id.clone(),
            command_kind: kind.into(),
            request_digest: *digest,
            response_bytes: bytes,
            status,
            session_grant,
        }))
    }
    fn uuid(id: &str) -> Result<Uuid, AuthError> {
        Uuid::parse_str(id).map_err(|_| AuthError::InvalidIdentifier)
    }
    fn random_bytes_32() -> Result<[u8; 32], AuthError> {
        let mut value = [0_u8; 32];
        getrandom::getrandom(&mut value).map_err(|_| AuthError::Vault)?;
        Ok(value)
    }
    fn opaque(prefix: &str) -> Result<String, AuthError> {
        Ok(format!(
            "{prefix}_{}",
            URL_SAFE_NO_PAD.encode(Self::random_bytes_32()?)
        ))
    }
    fn fence() -> Result<Vec<u8>, AuthError> {
        Ok(Self::random_bytes_32()?.to_vec())
    }

    /// Rewrap every encrypted auth row with the active vault key. The ledger is
    /// deliberately updated in the same transaction as each ciphertext write,
    /// so a process kill leaves a pending row that can be resumed safely.
    pub async fn rewrap_vault(&self) -> Result<(), AuthError> {
        let active = self.vault.active_key_version();
        let rows = sqlx::query(
            "SELECT 'auth_operations' AS source_table, o.operation_id::text AS entity_id, o.operation_id::text AS row_id,
                    o.response_key_version AS key_version, o.response_purpose AS purpose,
                    o.response_ciphertext AS ciphertext
               FROM auth_v1.auth_operations o
               LEFT JOIN auth_v1.vault_rewrap_ledger l ON l.table_name='auth_operations' AND l.row_id=o.operation_id::text
              WHERE o.response_ciphertext IS NOT NULL AND (o.response_key_version<>$1 OR l.state='pending')
             UNION ALL
             SELECT 'auth_challenges', c.challenge_id::text, c.challenge_id::text, c.provider_result_key_version,
                    c.provider_result_purpose, c.provider_result_ciphertext
               FROM auth_v1.auth_challenges c
               LEFT JOIN auth_v1.vault_rewrap_ledger l ON l.table_name='auth_challenges' AND l.row_id=c.challenge_id::text
              WHERE c.provider_result_ciphertext IS NOT NULL AND (c.provider_result_key_version<>$1 OR l.state='pending')
             UNION ALL
             SELECT 'external_identity_secrets', s.identity_id::text, s.vault_context, s.key_version,
                    s.purpose, s.ciphertext
               FROM auth_v1.external_identity_secrets s
               LEFT JOIN auth_v1.vault_rewrap_ledger l ON l.table_name='external_identity_secrets' AND l.row_id=s.vault_context
              WHERE s.key_version<>$1 OR l.state='pending'
             UNION ALL
             SELECT 'provider_credentials', p.credential_id::text, p.vault_context, p.key_version,
                    p.purpose, p.ciphertext
               FROM auth_v1.provider_credentials p
               LEFT JOIN auth_v1.vault_rewrap_ledger l ON l.table_name='provider_credentials' AND l.row_id=p.vault_context
              WHERE p.key_version<>$1 OR l.state='pending'
             UNION ALL
             SELECT 'session_refresh_receipts', r.operation_id::text, r.operation_id::text, r.response_key_version,
                    r.response_purpose, r.response_ciphertext
               FROM auth_v1.session_refresh_receipts r
               LEFT JOIN auth_v1.vault_rewrap_ledger l ON l.table_name='session_refresh_receipts' AND l.row_id=r.operation_id::text
              WHERE r.response_key_version<>$1 OR l.state='pending'",
        )
        .bind(active)
        .fetch_all(&self.pool)
        .await
        .map_err(Self::map_db)?;
        for row in rows {
            let source_table: String = row.try_get("source_table").map_err(Self::map_db)?;
            let entity_id: String = row.try_get("entity_id").map_err(Self::map_db)?;
            let row_id: String = row.try_get("row_id").map_err(Self::map_db)?;
            let old_version: i32 = row.try_get("key_version").map_err(Self::map_db)?;
            let purpose: String = row.try_get("purpose").map_err(Self::map_db)?;
            let ciphertext: Vec<u8> = row.try_get("ciphertext").map_err(Self::map_db)?;
            let old_secret = SealedSecret {
                key_version: old_version,
                ciphertext,
            };
            let plaintext = self.vault.open(&purpose, &row_id, &old_secret).await?;
            let replacement = if old_version == active {
                old_secret
            } else {
                let replacement = self.vault.seal(&purpose, &row_id, &plaintext).await?;
                self.vault.open(&purpose, &row_id, &replacement).await?;
                SealedSecret {
                    key_version: replacement.key_version,
                    ciphertext: replacement.ciphertext,
                }
            };
            let mut tx = self.pool.begin().await.map_err(Self::map_db)?;
            sqlx::query(
                "INSERT INTO auth_v1.vault_rewrap_ledger(table_name,row_id,old_key_version,new_key_version,state,attempts,last_error)
                 VALUES($1,$2,$3,$4,'pending',1,NULL)
                 ON CONFLICT(table_name,row_id) DO UPDATE SET old_key_version=EXCLUDED.old_key_version,new_key_version=EXCLUDED.new_key_version,state='pending',attempts=auth_v1.vault_rewrap_ledger.attempts+1,last_error=NULL,updated_at=now()",
            )
            .bind(&source_table)
            .bind(&row_id)
            .bind(old_version)
            .bind(active)
            .execute(&mut *tx)
            .await
            .map_err(Self::map_db)?;
            let changed = match source_table.as_str() {
                "auth_operations" => sqlx::query("UPDATE auth_v1.auth_operations SET response_ciphertext=$2,response_key_version=$3 WHERE operation_id=$1")
                    .bind(Self::uuid(&entity_id)?).bind(&replacement.ciphertext).bind(replacement.key_version).execute(&mut *tx).await.map_err(Self::map_db)?,
                "auth_challenges" => sqlx::query("UPDATE auth_v1.auth_challenges SET provider_result_ciphertext=$2,provider_result_key_version=$3 WHERE challenge_id=$1")
                    .bind(Self::uuid(&entity_id)?).bind(&replacement.ciphertext).bind(replacement.key_version).execute(&mut *tx).await.map_err(Self::map_db)?,
                "external_identity_secrets" => sqlx::query("UPDATE auth_v1.external_identity_secrets SET ciphertext=$2,key_version=$3,updated_at=now() WHERE identity_id=$1")
                    .bind(Self::uuid(&entity_id)?).bind(&replacement.ciphertext).bind(replacement.key_version).execute(&mut *tx).await.map_err(Self::map_db)?,
                "provider_credentials" => sqlx::query("UPDATE auth_v1.provider_credentials SET ciphertext=$2,key_version=$3 WHERE credential_id=$1")
                    .bind(Self::uuid(&entity_id)?).bind(&replacement.ciphertext).bind(replacement.key_version).execute(&mut *tx).await.map_err(Self::map_db)?,
                "session_refresh_receipts" => sqlx::query("UPDATE auth_v1.session_refresh_receipts SET response_ciphertext=$2,response_key_version=$3 WHERE operation_id=$1")
                    .bind(Self::uuid(&entity_id)?).bind(&replacement.ciphertext).bind(replacement.key_version).execute(&mut *tx).await.map_err(Self::map_db)?,
                _ => return Err(AuthError::Vault),
            };
            if changed.rows_affected() != 1 {
                return Err(AuthError::Vault);
            }
            let readback = match source_table.as_str() {
                "auth_operations" => sqlx::query("SELECT response_ciphertext AS ciphertext,response_key_version AS key_version FROM auth_v1.auth_operations WHERE operation_id=$1")
                    .bind(Self::uuid(&entity_id)?).fetch_one(&mut *tx).await.map_err(Self::map_db)?,
                "auth_challenges" => sqlx::query("SELECT provider_result_ciphertext AS ciphertext,provider_result_key_version AS key_version FROM auth_v1.auth_challenges WHERE challenge_id=$1")
                    .bind(Self::uuid(&entity_id)?).fetch_one(&mut *tx).await.map_err(Self::map_db)?,
                "external_identity_secrets" => sqlx::query("SELECT ciphertext,key_version FROM auth_v1.external_identity_secrets WHERE identity_id=$1")
                    .bind(Self::uuid(&entity_id)?).fetch_one(&mut *tx).await.map_err(Self::map_db)?,
                "provider_credentials" => sqlx::query("SELECT ciphertext,key_version FROM auth_v1.provider_credentials WHERE credential_id=$1")
                    .bind(Self::uuid(&entity_id)?).fetch_one(&mut *tx).await.map_err(Self::map_db)?,
                "session_refresh_receipts" => sqlx::query("SELECT response_ciphertext AS ciphertext,response_key_version AS key_version FROM auth_v1.session_refresh_receipts WHERE operation_id=$1")
                    .bind(Self::uuid(&entity_id)?).fetch_one(&mut *tx).await.map_err(Self::map_db)?,
                _ => return Err(AuthError::Vault),
            };
            let readback_secret = SealedSecret {
                ciphertext: readback.try_get("ciphertext").map_err(Self::map_db)?,
                key_version: readback.try_get("key_version").map_err(Self::map_db)?,
            };
            self.vault.open(&purpose, &row_id, &readback_secret).await?;
            sqlx::query("UPDATE auth_v1.vault_rewrap_ledger SET state='completed',updated_at=now(),last_error=NULL WHERE table_name=$1 AND row_id=$2")
                .bind(&source_table).bind(&row_id).execute(&mut *tx).await.map_err(Self::map_db)?;
            tx.commit().await.map_err(Self::map_db)?;
        }
        Ok(())
    }
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct ExchangeFailureReceipt {
    challenge_id: ChallengeId,
    code: String,
    operation_id: OperationId,
    recovery_action: String,
    request_id: String,
    retryability: String,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct RefreshFailureReceipt {
    code: String,
    recovery_action: String,
    request_id: String,
    retryability: String,
    rotation_id: OperationId,
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
        let mut tx = self.pool.begin().await.map_err(Self::map_db)?;
        let row = sqlx::query("SELECT s.session_id,s.account_id,a.tenant_id,a.auth_epoch,a.fence FROM auth_v1.access_tokens t JOIN auth_v1.auth_sessions s ON s.session_id=t.session_id JOIN auth_v1.refresh_families f ON f.family_id=s.family_id JOIN auth_v1.accounts a ON a.account_id=t.account_id JOIN auth_v1.external_identities i ON i.identity_id=s.identity_id WHERE t.token_hmac=$1 AND t.token_hmac_key_version=$2 AND t.revoked_at IS NULL AND t.expires_at>now() AND s.state='active' AND s.expires_at>now() AND f.state='active' AND f.expires_at>now() AND a.state='active' AND i.state='active' AND s.auth_epoch=a.auth_epoch AND s.account_fence=a.fence AND t.auth_epoch=a.auth_epoch AND t.fence=a.fence FOR UPDATE OF t,s,f,a,i")
            .bind(token_verifier).bind(TOKEN_HMAC_KEY_VERSION).fetch_optional(&mut *tx).await.map_err(Self::map_db)?.ok_or(AuthError::AccountNotFound)?;
        let principal = AuthenticatedPrincipal {
            account_id: AccountId::new(
                row.try_get::<String, _>("account_id")
                    .map_err(Self::map_db)?,
            )?,
            tenant_id: TenantId::new(
                row.try_get::<String, _>("tenant_id")
                    .map_err(Self::map_db)?,
            )?,
            session_id: SessionId::new(
                row.try_get::<Uuid, _>("session_id")
                    .map_err(Self::map_db)?
                    .to_string(),
            )?,
            account_auth_epoch: row.try_get("auth_epoch").map_err(Self::map_db)?,
            account_fence: row.try_get("fence").map_err(Self::map_db)?,
        };
        tx.commit().await.map_err(Self::map_db)?;
        Ok(principal)
    }

    async fn resolve_refresh_session(
        &self,
        token_verifier: Vec<u8>,
    ) -> Result<SessionId, AuthError> {
        let row = sqlx::query(
            "SELECT s.session_id FROM auth_v1.refresh_tokens t \
             JOIN auth_v1.refresh_families f ON f.family_id=t.family_id \
             JOIN auth_v1.auth_sessions s ON s.family_id=f.family_id \
             WHERE t.token_hmac=$1 AND t.token_hmac_key_version=$2",
        )
        .bind(token_verifier)
        .bind(TOKEN_HMAC_KEY_VERSION)
        .fetch_optional(&self.pool)
        .await
        .map_err(Self::map_db)?
        .ok_or(AuthError::AccountNotFound)?;
        SessionId::new(
            row.try_get::<Uuid, _>("session_id")
                .map_err(Self::map_db)?
                .to_string(),
        )
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
        sqlx::query("INSERT INTO auth_v1.auth_operations(operation_id,command_kind,request_digest,state) VALUES($1,'createChallenge',$2,'reserved') ON CONFLICT DO NOTHING")
            .bind(op)
            .bind(challenge.request_digest.as_slice())
            .execute(&mut *tx)
            .await
            .map_err(Self::map_db)?;
        let row = sqlx::query(
            "SELECT command_kind,request_digest,state,response_digest,response_ciphertext,response_key_version,response_purpose FROM auth_v1.auth_operations WHERE operation_id=$1 FOR UPDATE",
        )
        .bind(op)
        .fetch_one(&mut *tx)
        .await
        .map_err(Self::map_db)?;
        if row
            .try_get::<String, _>("command_kind")
            .map_err(Self::map_db)?
            != CREATE_CHALLENGE_COMMAND
            || row
                .try_get::<Vec<u8>, _>("request_digest")
                .map_err(Self::map_db)?
                .as_slice()
                != challenge.request_digest
        {
            return Err(AuthError::OperationIdReused);
        }
        let operation_state = row.try_get::<String, _>("state").map_err(Self::map_db)?;
        if operation_state == "completed" {
            let response = self
                .vault
                .open(
                    &row.try_get::<String, _>("response_purpose")
                        .map_err(Self::map_db)?,
                    challenge.operation_id.as_str(),
                    &SealedSecret {
                        key_version: row.try_get("response_key_version").map_err(Self::map_db)?,
                        ciphertext: row.try_get("response_ciphertext").map_err(Self::map_db)?,
                    },
                )
                .await?;
            verify_response_digest(
                &response,
                &row.try_get::<Vec<u8>, _>("response_digest")
                    .map_err(Self::map_db)?,
            )?;
            let replay = crate::auth_wire::decode_challenge_response(&response)?;
            tx.commit().await.map_err(Self::map_db)?;
            return Ok(replay);
        }
        if operation_state != "reserved" {
            return Err(AuthError::InvalidChallengePhase);
        }
        let challenge_uuid = Uuid::new_v4();
        let challenge_id = ChallengeId::new(challenge_uuid.to_string())?;
        let config = ProviderConfigId::new(APPLE_PROVIDER_CONFIG)?;
        let provider = sqlx::query("SELECT provider_kind,exact_issuer,allowed_audiences,enabled FROM auth_v1.provider_configs WHERE provider_config_id=$1 FOR SHARE")
            .bind(config.as_str())
            .fetch_optional(&mut *tx)
            .await
            .map_err(Self::map_db)?
            .ok_or(AuthError::ProviderNotAllowed)?;
        if provider
            .try_get::<String, _>("provider_kind")
            .map_err(Self::map_db)?
            != "apple"
            || provider
                .try_get::<String, _>("exact_issuer")
                .map_err(Self::map_db)?
                != APPLE_ISSUER
            || !provider
                .try_get::<bool, _>("enabled")
                .map_err(Self::map_db)?
            || !provider
                .try_get::<Vec<String>, _>("allowed_audiences")
                .map_err(Self::map_db)?
                .iter()
                .any(|value| value == &challenge.audience)
            || match challenge.platform.as_str() {
                "macos" => challenge.audience != "dev.serikayuzuki.fuminiwa",
                "ios" | "ipados" => challenge.audience != "dev.serikayuzuki.fuminiwa.ios",
                _ => true,
            }
        {
            return Err(AuthError::ProviderNotAllowed);
        }
        let result = ChallengeResult {
            challenge_id: challenge_id.clone(),
            operation_id: challenge.operation_id.clone(),
            provider_config_id: config.clone(),
            audience: challenge.audience.clone(),
            state: challenge.state.clone(),
            nonce: challenge.nonce.clone(),
            expires_at_unix: challenge.expires_at_unix,
        };
        let replay_until =
            challenge.expires_at_unix - CHALLENGE_LIFETIME_SECONDS + REFRESH_TOKEN_LIFETIME_SECONDS;
        let response = crate::auth_wire::encode_challenge_response(&result, replay_until)?;
        let response_digest = digest_request(&response);
        let sealed = self
            .vault
            .seal(
                "auth_receipt_v1",
                challenge.operation_id.as_str(),
                &response,
            )
            .await?;
        sqlx::query("UPDATE auth_v1.auth_operations SET state='completed',response_status=201,response_digest=$2,response_ciphertext=$3,response_key_version=$4,response_purpose=$5,completed_at=now() WHERE operation_id=$1 AND state='reserved'")
            .bind(op).bind(response_digest.as_slice()).bind(sealed.ciphertext).bind(sealed.key_version).bind("auth_receipt_v1").execute(&mut *tx).await.map_err(Self::map_db)?;
        sqlx::query("INSERT INTO auth_v1.auth_challenges(challenge_id,operation_id,provider_config_id,audience,client_platform,state_hash,nonce_hash,phase,lease_until,expires_at) VALUES($1,$2,$3,$4,$5,$6,$7,'claimed',to_timestamp($8),to_timestamp($8))")
            .bind(challenge_uuid).bind(op).bind(config.as_str()).bind(&challenge.audience).bind(&challenge.platform).bind(&state_hash).bind(&nonce_hash).bind(challenge.expires_at_unix).execute(&mut *tx).await.map_err(Self::map_db)?;
        tx.commit().await.map_err(Self::map_db)?;
        Ok(result)
    }

    async fn claim_challenge_for_exchange(
        &self,
        challenge_id: &ChallengeId,
        operation_id: &OperationId,
        request_digest: [u8; 32],
        state_hash: &[u8],
        now_unix: i64,
    ) -> Result<ChallengeClaimResult, AuthError> {
        let id = Self::uuid(challenge_id.as_str().trim_start_matches("challenge_"))?;
        let exchange_operation = Self::uuid(operation_id.as_str())?;
        // Reject malformed, expired, or already-owned challenges before an
        // operation row can be reserved. The same predicates are repeated
        // under row lock below; a race therefore rolls the reservation back.
        let preliminary = sqlx::query("SELECT exchange_operation_id,state_hash,phase,expires_at FROM auth_v1.auth_challenges WHERE challenge_id=$1")
            .bind(id)
            .fetch_optional(&self.pool)
            .await
            .map_err(Self::map_db)?
            .ok_or(AuthError::NotFound)?;
        if preliminary
            .try_get::<Vec<u8>, _>("state_hash")
            .map_err(Self::map_db)?
            .as_slice()
            != state_hash
        {
            return Err(AuthError::InvalidRequest);
        }
        let preliminary_phase = parse_phase(
            &preliminary
                .try_get::<String, _>("phase")
                .map_err(Self::map_db)?,
        );
        if matches!(preliminary_phase, ChallengePhase::Claimed)
            && preliminary
                .try_get::<DateTime<Utc>, _>("expires_at")
                .map_err(Self::map_db)?
                .timestamp()
                <= now_unix
        {
            return Err(AuthError::ChallengeExpired);
        }
        if !matches!(preliminary_phase, ChallengePhase::Claimed)
            && preliminary
                .try_get::<Option<Uuid>, _>("exchange_operation_id")
                .map_err(Self::map_db)?
                != Some(exchange_operation)
        {
            return Err(AuthError::ChallengeConsumed);
        }

        let mut tx = self.pool.begin().await.map_err(Self::map_db)?;
        sqlx::query("INSERT INTO auth_v1.auth_operations(operation_id,command_kind,request_digest,state) VALUES($1,'exchangeAppleNativeCredential',$2,'reserved') ON CONFLICT DO NOTHING")
            .bind(exchange_operation)
            .bind(request_digest.as_slice())
            .execute(&mut *tx)
            .await
            .map_err(Self::map_db)?;
        let operation = sqlx::query("SELECT command_kind,request_digest,state FROM auth_v1.auth_operations WHERE operation_id=$1 FOR UPDATE")
            .bind(exchange_operation)
            .fetch_one(&mut *tx)
            .await
            .map_err(Self::map_db)?;
        if operation
            .try_get::<String, _>("command_kind")
            .map_err(Self::map_db)?
            != EXCHANGE_APPLE_COMMAND
            || operation
                .try_get::<Vec<u8>, _>("request_digest")
                .map_err(Self::map_db)?
                .as_slice()
                != request_digest
        {
            return Err(AuthError::OperationIdReused);
        }
        if operation
            .try_get::<String, _>("state")
            .map_err(Self::map_db)?
            != "reserved"
        {
            return Err(AuthError::InvalidChallengePhase);
        }
        let row = sqlx::query("SELECT operation_id,exchange_operation_id,provider_config_id,audience,client_platform,state_hash,nonce_hash,phase,lease_until,expires_at,provider_result_ciphertext,provider_result_key_version,provider_result_purpose FROM auth_v1.auth_challenges WHERE challenge_id=$1 FOR UPDATE")
            .bind(id).fetch_optional(&mut *tx).await.map_err(Self::map_db)?.ok_or(AuthError::NotFound)?;
        let expires = row
            .try_get::<DateTime<Utc>, _>("expires_at")
            .map_err(Self::map_db)?
            .timestamp();
        if row
            .try_get::<Vec<u8>, _>("state_hash")
            .map_err(Self::map_db)?
            .as_slice()
            != state_hash
        {
            return Err(AuthError::InvalidRequest);
        }
        let phase = parse_phase(&row.try_get::<String, _>("phase").map_err(Self::map_db)?);
        if matches!(phase, ChallengePhase::Claimed) && expires <= now_unix {
            return Err(AuthError::ChallengeExpired);
        }
        let claimed_operation = row
            .try_get::<Option<Uuid>, _>("exchange_operation_id")
            .map_err(Self::map_db)?;
        if !matches!(phase, ChallengePhase::Claimed)
            && claimed_operation != Some(exchange_operation)
        {
            return Err(AuthError::ChallengeConsumed);
        }
        let claim = ChallengeClaim {
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
            phase: phase.clone(),
            lease_until_unix: row
                .try_get::<DateTime<Utc>, _>("lease_until")
                .map_err(Self::map_db)?
                .timestamp(),
            expires_at_unix: expires,
        };
        let provider = sqlx::query("SELECT provider_kind,exact_issuer,allowed_audiences,enabled FROM auth_v1.provider_configs WHERE provider_config_id=$1 FOR SHARE")
            .bind(claim.provider_config_id.as_str())
            .fetch_optional(&mut *tx)
            .await
            .map_err(Self::map_db)?
            .ok_or(AuthError::ProviderNotAllowed)?;
        if provider
            .try_get::<String, _>("provider_kind")
            .map_err(Self::map_db)?
            != "apple"
            || provider
                .try_get::<String, _>("exact_issuer")
                .map_err(Self::map_db)?
                != APPLE_ISSUER
            || !provider
                .try_get::<bool, _>("enabled")
                .map_err(Self::map_db)?
            || !provider
                .try_get::<Vec<String>, _>("allowed_audiences")
                .map_err(Self::map_db)?
                .iter()
                .any(|allowed| allowed == &claim.audience)
            || match claim.platform.as_str() {
                "macos" => claim.audience != "dev.serikayuzuki.fuminiwa",
                "ios" | "ipados" => claim.audience != "dev.serikayuzuki.fuminiwa.ios",
                _ => true,
            }
        {
            return Err(AuthError::ProviderNotAllowed);
        }
        let result = match phase {
            ChallengePhase::Claimed => {
                let changed = sqlx::query("UPDATE auth_v1.auth_challenges SET phase='providerCallStarted',lease_until=to_timestamp($2),exchange_operation_id=$3 WHERE challenge_id=$1 AND phase='claimed' AND exchange_operation_id IS NULL")
                    .bind(id).bind(now_unix + 300).bind(exchange_operation).execute(&mut *tx).await.map_err(Self::map_db)?;
                if changed.rows_affected() != 1 {
                    return Err(AuthError::InvalidChallengePhase);
                }
                let mut started = claim;
                started.phase = ChallengePhase::ProviderCallStarted;
                started.lease_until_unix = now_unix + 300;
                ChallengeClaimResult::ProviderCallRequired(started)
            }
            ChallengePhase::ProviderCallStarted if claim.lease_until_unix <= now_unix => {
                sqlx::query("UPDATE auth_v1.auth_challenges SET phase='terminal' WHERE challenge_id=$1 AND phase='providerCallStarted'").bind(id).execute(&mut *tx).await.map_err(Self::map_db)?;
                ChallengeClaimResult::ProviderExchangeIndeterminate
            }
            ChallengePhase::ProviderCallStarted => return Err(AuthError::InvalidChallengePhase),
            ChallengePhase::ProviderResultKnown => {
                let purpose: String = row
                    .try_get("provider_result_purpose")
                    .map_err(Self::map_db)?;
                if purpose != "verified_external_identity_v1" {
                    return Err(AuthError::Vault);
                }
                ChallengeClaimResult::ProviderResultKnown(
                    claim,
                    SealedSecret {
                        key_version: row
                            .try_get("provider_result_key_version")
                            .map_err(Self::map_db)?,
                        ciphertext: row
                            .try_get("provider_result_ciphertext")
                            .map_err(Self::map_db)?,
                    },
                )
            }
            // A terminal challenge paired with a still-reserved exchange
            // operation is an orphaned indeterminate transition (for example,
            // process death after the phase CAS but before receipt commit).
            // Converge by letting the application seal the same terminal
            // receipt; a successful exchange commits the operation and phase
            // in one transaction and cannot reach this branch.
            ChallengePhase::Terminal => ChallengeClaimResult::ProviderExchangeIndeterminate,
        };
        tx.commit().await.map_err(Self::map_db)?;
        Ok(result)
    }

    async fn mark_provider_failure(
        &self,
        challenge_id: &ChallengeId,
        operation_id: &OperationId,
        request_digest: [u8; 32],
        code: &str,
        status: u16,
    ) -> Result<(), AuthError> {
        let id = Self::uuid(challenge_id.as_str().trim_start_matches("challenge_"))?;
        let op = Self::uuid(operation_id.as_str())?;
        let mut tx = self.pool.begin().await.map_err(Self::map_db)?;
        let operation = sqlx::query(
            "SELECT command_kind,request_digest,state FROM auth_v1.auth_operations WHERE operation_id=$1 FOR UPDATE",
        )
        .bind(op)
        .fetch_one(&mut *tx)
        .await
        .map_err(Self::map_db)?;
        if operation
            .try_get::<String, _>("command_kind")
            .map_err(Self::map_db)?
            != EXCHANGE_APPLE_COMMAND
            || operation
                .try_get::<Vec<u8>, _>("request_digest")
                .map_err(Self::map_db)?
                .as_slice()
                != request_digest
        {
            return Err(AuthError::OperationIdReused);
        }
        if operation
            .try_get::<String, _>("state")
            .map_err(Self::map_db)?
            == "completed"
        {
            tx.commit().await.map_err(Self::map_db)?;
            return Ok(());
        }
        let changed = sqlx::query("UPDATE auth_v1.auth_challenges SET phase='terminal',provider_result_ciphertext=NULL,provider_result_key_version=NULL,provider_result_purpose=NULL WHERE challenge_id=$1 AND exchange_operation_id=$2 AND phase IN ('providerCallStarted','providerResultKnown','terminal')")
            .bind(id).bind(op).execute(&mut *tx).await.map_err(Self::map_db)?;
        if changed.rows_affected() != 1 {
            return Err(AuthError::InvalidChallengePhase);
        }
        let response = canonical_wire(&ExchangeFailureReceipt {
            challenge_id: challenge_id.clone(),
            code: code.into(),
            operation_id: operation_id.clone(),
            recovery_action: "interactiveAppleSignIn".into(),
            request_id: Uuid::new_v4().to_string(),
            retryability: "afterInteractiveAuthentication".into(),
        })?;
        let response_digest = digest_request(&response);
        let sealed = self
            .vault
            .seal("auth_receipt_v1", operation_id.as_str(), &response)
            .await?;
        sqlx::query("UPDATE auth_v1.auth_operations SET state='completed',response_status=$5,response_digest=$2,response_ciphertext=$3,response_key_version=$4,response_purpose='auth_receipt_v1',completed_at=now() WHERE operation_id=$1")
            .bind(op)
            .bind(response_digest.as_slice())
            .bind(sealed.ciphertext)
            .bind(sealed.key_version)
            .bind(i32::from(status))
            .execute(&mut *tx)
            .await
            .map_err(Self::map_db)?;
        tx.commit().await.map_err(Self::map_db)?;
        Ok(())
    }

    async fn mark_provider_exchange_indeterminate(
        &self,
        challenge_id: &ChallengeId,
        operation_id: &OperationId,
        request_digest: [u8; 32],
    ) -> Result<(), AuthError> {
        self.mark_provider_failure(
            challenge_id,
            operation_id,
            request_digest,
            "providerExchangeIndeterminate",
            502,
        )
        .await
    }

    async fn mark_provider_exchange_terminal(
        &self,
        challenge_id: &ChallengeId,
        operation_id: &OperationId,
        request_digest: [u8; 32],
        code: &str,
        status: u16,
    ) -> Result<(), AuthError> {
        if code.is_empty() || code.len() > 64 || !(400..500).contains(&status) {
            return Err(AuthError::InvalidRequest);
        }
        self.mark_provider_failure(challenge_id, operation_id, request_digest, code, status)
            .await
    }

    async fn mark_provider_result_known(
        &self,
        challenge_id: &ChallengeId,
        operation_id: &OperationId,
        _identity: &VerifiedExternalIdentity,
        sealed_result: SealedSecret,
    ) -> Result<(), AuthError> {
        let id = Self::uuid(challenge_id.as_str().trim_start_matches("challenge_"))?;
        let op = Self::uuid(operation_id.as_str())?;
        let mut tx = self.pool.begin().await.map_err(Self::map_db)?;
        let operation = sqlx::query(
            "SELECT command_kind,state FROM auth_v1.auth_operations WHERE operation_id=$1 FOR UPDATE",
        )
            .bind(op)
            .fetch_optional(&mut *tx)
            .await
            .map_err(Self::map_db)?
            .ok_or(AuthError::NotFound)?;
        if operation
            .try_get::<String, _>("command_kind")
            .map_err(Self::map_db)?
            != EXCHANGE_APPLE_COMMAND
            || operation
                .try_get::<String, _>("state")
                .map_err(Self::map_db)?
                != "reserved"
        {
            return Err(AuthError::InvalidChallengePhase);
        }
        let claimed = sqlx::query("SELECT phase,exchange_operation_id FROM auth_v1.auth_challenges WHERE challenge_id=$1 FOR UPDATE")
            .bind(id)
            .fetch_optional(&mut *tx)
            .await
            .map_err(Self::map_db)?
            .ok_or(AuthError::NotFound)?;
        if claimed
            .try_get::<Option<Uuid>, _>("exchange_operation_id")
            .map_err(Self::map_db)?
            != Some(op)
            || claimed
                .try_get::<String, _>("phase")
                .map_err(Self::map_db)?
                != "providerCallStarted"
        {
            return Err(AuthError::InvalidChallengePhase);
        }
        let result = sqlx::query("UPDATE auth_v1.auth_challenges SET phase='providerResultKnown',provider_result_ciphertext=$2,provider_result_key_version=$3,provider_result_purpose='verified_external_identity_v1' WHERE challenge_id=$1 AND exchange_operation_id=$4 AND phase='providerCallStarted'").bind(id).bind(sealed_result.ciphertext).bind(sealed_result.key_version).bind(op).execute(&mut *tx).await.map_err(Self::map_db)?;
        if result.rows_affected() != 1 {
            return Err(AuthError::InvalidChallengePhase);
        }
        tx.commit().await.map_err(Self::map_db)?;
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
        platform: &str,
        now_unix: i64,
        request_digest: [u8; 32],
    ) -> Result<(SessionGrant, AuthReceipt), AuthError> {
        if match platform {
            "macos" => audience != "dev.serikayuzuki.fuminiwa",
            "ios" | "ipados" => audience != "dev.serikayuzuki.fuminiwa.ios",
            _ => true,
        } {
            return Err(AuthError::ProviderNotAllowed);
        }
        let mut tx = self.pool.begin().await.map_err(Self::map_db)?;
        let challenge_uuid = Self::uuid(challenge_id.as_str().trim_start_matches("challenge_"))?;
        let op = Self::uuid(operation_id.as_str())?;
        sqlx::query("INSERT INTO auth_v1.auth_operations(operation_id,command_kind,request_digest,state) VALUES($1,'exchangeAppleNativeCredential',$2,'reserved') ON CONFLICT DO NOTHING")
            .bind(op)
            .bind(request_digest.as_slice())
            .execute(&mut *tx)
            .await
            .map_err(Self::map_db)?;
        let operation = sqlx::query("SELECT command_kind,request_digest,state,response_status,response_digest,response_ciphertext,response_key_version,response_purpose FROM auth_v1.auth_operations WHERE operation_id=$1 FOR UPDATE")
            .bind(op)
            .fetch_one(&mut *tx)
            .await
            .map_err(Self::map_db)?;
        if operation
            .try_get::<String, _>("command_kind")
            .map_err(Self::map_db)?
            != EXCHANGE_APPLE_COMMAND
            || operation
                .try_get::<Vec<u8>, _>("request_digest")
                .map_err(Self::map_db)?
                .as_slice()
                != request_digest
        {
            return Err(AuthError::OperationIdReused);
        }
        if operation
            .try_get::<String, _>("state")
            .map_err(Self::map_db)?
            == "completed"
        {
            let response = self
                .vault
                .open(
                    &operation
                        .try_get::<String, _>("response_purpose")
                        .map_err(Self::map_db)?,
                    operation_id.as_str(),
                    &SealedSecret {
                        key_version: operation
                            .try_get("response_key_version")
                            .map_err(Self::map_db)?,
                        ciphertext: operation
                            .try_get("response_ciphertext")
                            .map_err(Self::map_db)?,
                    },
                )
                .await?;
            verify_response_digest(
                &response,
                &operation
                    .try_get::<Vec<u8>, _>("response_digest")
                    .map_err(Self::map_db)?,
            )?;
            let status = operation
                .try_get::<i32, _>("response_status")
                .map_err(Self::map_db)? as u16;
            if status != 200 {
                return Err(AuthError::ProviderExchangeIndeterminate);
            }
            let account_id = crate::auth_wire::session_response_account_id(&response)?;
            let tenant = sqlx::query("SELECT tenant_id FROM auth_v1.accounts WHERE account_id=$1")
                .bind(account_id.as_str())
                .fetch_one(&mut *tx)
                .await
                .map_err(Self::map_db)?
                .try_get::<String, _>("tenant_id")
                .map_err(Self::map_db)?;
            let grant =
                crate::auth_wire::decode_exchange_response(&response, TenantId::new(tenant)?)?;
            tx.commit().await.map_err(Self::map_db)?;
            return Ok((
                grant.clone(),
                AuthReceipt {
                    operation_id: operation_id.clone(),
                    command_kind: EXCHANGE_APPLE_COMMAND.into(),
                    request_digest,
                    response_bytes: response,
                    status,
                    session_grant: Some(grant.clone()),
                },
            ));
        }
        let challenge = sqlx::query("SELECT exchange_operation_id,provider_config_id,audience,client_platform,phase FROM auth_v1.auth_challenges WHERE challenge_id=$1 FOR UPDATE")
            .bind(challenge_uuid)
            .fetch_optional(&mut *tx)
            .await
            .map_err(Self::map_db)?
            .ok_or(AuthError::NotFound)?;
        if challenge
            .try_get::<Option<Uuid>, _>("exchange_operation_id")
            .map_err(Self::map_db)?
            != Some(op)
            || challenge
                .try_get::<String, _>("provider_config_id")
                .map_err(Self::map_db)?
                != identity.provider_config_id().as_str()
            || challenge
                .try_get::<String, _>("audience")
                .map_err(Self::map_db)?
                != audience
            || challenge
                .try_get::<String, _>("client_platform")
                .map_err(Self::map_db)?
                != platform
            || challenge
                .try_get::<String, _>("phase")
                .map_err(Self::map_db)?
                != "providerResultKnown"
        {
            return Err(AuthError::InvalidChallengePhase);
        }
        // Serialize first-login races at the provider configuration row. The
        // unique lookup HMAC remains the invariant; the lock lets a loser
        // read back the committed AccountID instead of returning a duplicate
        // key error.
        let config_row = sqlx::query("SELECT provider_kind,exact_issuer,allowed_audiences,enabled FROM auth_v1.provider_configs WHERE provider_config_id=$1 FOR UPDATE")
            .bind(identity.provider_config_id().as_str()).fetch_optional(&mut *tx).await.map_err(Self::map_db)?.ok_or(AuthError::ProviderNotAllowed)?;
        if !config_row
            .try_get::<bool, _>("enabled")
            .map_err(Self::map_db)?
            || config_row
                .try_get::<String, _>("provider_kind")
                .map_err(Self::map_db)?
                != "apple"
            || config_row
                .try_get::<String, _>("exact_issuer")
                .map_err(Self::map_db)?
                != identity.exact_issuer()
            || !config_row
                .try_get::<Vec<String>, _>("allowed_audiences")
                .map_err(Self::map_db)?
                .iter()
                .any(|allowed| allowed == audience)
        {
            return Err(AuthError::ProviderNotAllowed);
        }
        let config = identity.provider_config_id().as_str();
        let row = sqlx::query("SELECT identity_id,account_id,state FROM auth_v1.external_identities WHERE provider_config_id=$1 AND exact_issuer=$2 AND subject_lookup_hmac=$3 FOR UPDATE").bind(config).bind(identity.exact_issuer()).bind(&subject_lookup).fetch_optional(&mut *tx).await.map_err(Self::map_db)?;
        let (account_id, tenant_id, epoch, fence, identity_id) = if let Some(row) = row {
            if row.try_get::<String, _>("state").map_err(Self::map_db)? != "active" {
                return Err(AuthError::SessionRevoked);
            }
            let account = row
                .try_get::<String, _>("account_id")
                .map_err(Self::map_db)?;
            let account_row = sqlx::query("SELECT tenant_id,auth_epoch,fence,state FROM auth_v1.accounts WHERE account_id=$1 FOR UPDATE").bind(&account).fetch_one(&mut *tx).await.map_err(Self::map_db)?;
            if account_row
                .try_get::<String, _>("state")
                .map_err(Self::map_db)?
                != "active"
            {
                return Err(AuthError::SessionRevoked);
            }
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
            let account = AccountId::new(Self::opaque("acct")?)?;
            let tenant = TenantId::new(Self::opaque("tenant")?)?;
            let fence = Self::fence()?;
            sqlx::query("INSERT INTO auth_v1.accounts(account_id,tenant_id,state,auth_epoch,fence) VALUES($1,$2,'active',1,$3)").bind(account.as_str()).bind(tenant.as_str()).bind(&fence).execute(&mut *tx).await.map_err(Self::map_db)?;
            let iid = Uuid::new_v4();
            sqlx::query("INSERT INTO auth_v1.external_identities(identity_id,account_id,provider_config_id,exact_issuer,lookup_key_version,subject_lookup_hmac,state) VALUES($1,$2,$3,$4,1,$5,'active')").bind(iid).bind(account.as_str()).bind(config).bind(identity.exact_issuer()).bind(&subject_lookup).execute(&mut *tx).await.map_err(Self::map_db)?;
            let subject_plaintext = self
                .vault
                .open(
                    "external_identity_subject_v1",
                    challenge_id.as_str(),
                    &subject_secret,
                )
                .await?;
            let subject_context = crate::auth_vault::canonical_row_context(
                "external_identity_secrets",
                &iid.to_string(),
                account.as_str(),
                &iid.to_string(),
                config,
                audience,
            )?;
            let sealed_subject = self
                .vault
                .seal(
                    "external_identity_subject_v1",
                    &subject_context,
                    &subject_plaintext,
                )
                .await?;
            sqlx::query("INSERT INTO auth_v1.external_identity_secrets(identity_id,key_version,purpose,ciphertext,vault_context) VALUES($1,$2,'external_identity_subject_v1',$3,$4)")
                .bind(iid)
                .bind(sealed_subject.key_version)
                .bind(sealed_subject.ciphertext)
                .bind(subject_context)
                .execute(&mut *tx)
                .await
                .map_err(Self::map_db)?;
            (account, tenant, 1, fence, iid)
        };
        if let Some(credential) = identity.provider_credential() {
            if credential.audience != audience {
                return Err(AuthError::ProviderNotAllowed);
            }
            let previous = sqlx::query("SELECT COALESCE(MAX(credential_generation),0) AS generation FROM auth_v1.provider_credentials WHERE identity_id=$1 AND original_audience=$2")
                .bind(identity_id)
                .bind(&credential.audience)
                .fetch_one(&mut *tx)
                .await
                .map_err(Self::map_db)?;
            let previous_generation: i64 = previous.try_get("generation").map_err(Self::map_db)?;
            let generation = previous_generation + 1;
            let credential_id = Uuid::new_v4();
            let credential_plaintext = self
                .vault
                .open(
                    "apple_provider_refresh_v1",
                    &credential.vault_context,
                    &credential.encrypted_refresh_token,
                )
                .await?;
            let credential_context = crate::auth_vault::canonical_row_context(
                "provider_credentials",
                &credential_id.to_string(),
                account_id.as_str(),
                &identity_id.to_string(),
                config,
                &credential.audience,
            )?;
            let sealed_credential = self
                .vault
                .seal(
                    "apple_provider_refresh_v1",
                    &credential_context,
                    &credential_plaintext,
                )
                .await?;
            sqlx::query("UPDATE auth_v1.provider_credentials SET state='superseded' WHERE identity_id=$1 AND original_audience=$2 AND state='active'")
                .bind(identity_id)
                .bind(&credential.audience)
                .execute(&mut *tx)
                .await
                .map_err(Self::map_db)?;
            sqlx::query("INSERT INTO auth_v1.provider_credentials(credential_id,identity_id,original_audience,vault_context,credential_generation,key_version,ciphertext,state) VALUES($1,$2,$3,$4,$5,$6,$7,'active')")
                .bind(credential_id)
                .bind(identity_id)
                .bind(&credential.audience)
                .bind(&credential_context)
                .bind(generation)
                .bind(sealed_credential.key_version)
                .bind(&sealed_credential.ciphertext)
                .execute(&mut *tx)
                .await
                .map_err(Self::map_db)?;
        }
        let sid = Uuid::new_v4();
        let fid = Uuid::new_v4();
        let session = SessionId::new(sid.to_string())?;
        let access = Self::opaque("fma1")?;
        let refresh = Self::opaque("fmr1")?;
        sqlx::query("INSERT INTO auth_v1.auth_sessions(session_id,account_id,identity_id,family_id,auth_epoch,account_fence,state,client_platform,expires_at) VALUES($1,$2,$3,$4,$5,$6,'active',$7,to_timestamp($8))").bind(sid).bind(account_id.as_str()).bind(identity_id).bind(fid).bind(epoch).bind(&fence).bind(platform).bind(now_unix + REFRESH_TOKEN_LIFETIME_SECONDS).execute(&mut *tx).await.map_err(Self::map_db)?;
        let access_hash = self.hmac("access", &access)?;
        sqlx::query("INSERT INTO auth_v1.access_tokens(token_id,session_id,account_id,token_hmac,token_hmac_key_version,auth_epoch,fence,expires_at) VALUES($1,$2,$3,$4,$5,$6,$7,to_timestamp($8))")
            .bind(Uuid::new_v4()).bind(sid).bind(account_id.as_str()).bind(access_hash).bind(TOKEN_HMAC_KEY_VERSION).bind(epoch).bind(&fence).bind(now_unix + ACCESS_TOKEN_LIFETIME_SECONDS)
            .execute(&mut *tx).await.map_err(Self::map_db)?;
        sqlx::query("INSERT INTO auth_v1.refresh_families(family_id,session_id,account_id,state,current_generation,expires_at) VALUES($1,$2,$3,'active',1,to_timestamp($4))").bind(fid).bind(sid).bind(account_id.as_str()).bind(now_unix + REFRESH_TOKEN_LIFETIME_SECONDS).execute(&mut *tx).await.map_err(Self::map_db)?;
        let token_hash = self.hmac("refresh", &refresh)?;
        sqlx::query("INSERT INTO auth_v1.refresh_tokens(family_id,generation,token_hmac,token_hmac_key_version,state) VALUES($1,1,$2,$3,'active')").bind(fid).bind(&token_hash).bind(TOKEN_HMAC_KEY_VERSION).execute(&mut *tx).await.map_err(Self::map_db)?;
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
            access_expires_at_unix: now_unix + ACCESS_TOKEN_LIFETIME_SECONDS,
            refresh_expires_at_unix: now_unix + REFRESH_TOKEN_LIFETIME_SECONDS,
        };
        let response = crate::auth_wire::encode_exchange_response(
            &grant,
            &self.server_instance_id,
            operation_id,
        )?;
        let response_digest = digest_request(&response);
        sqlx::query("INSERT INTO auth_v1.auth_events(account_id,event_kind,opaque_subject_id,request_id) VALUES($1,'sessionIssued',$2,$3)")
            .bind(account_id.as_str())
            .bind(identity_id)
            .bind(op)
            .execute(&mut *tx)
            .await
            .map_err(Self::map_db)?;
        let sealed = self
            .vault
            .seal("auth_receipt_v1", operation_id.as_str(), &response)
            .await?;
        sqlx::query("UPDATE auth_v1.auth_operations SET state='completed',response_status=200,response_digest=$2,response_ciphertext=$3,response_key_version=$4,response_purpose='auth_receipt_v1',completed_at=now() WHERE operation_id=$1 AND command_kind='exchangeAppleNativeCredential'").bind(op).bind(response_digest.as_slice()).bind(sealed.ciphertext).bind(sealed.key_version).execute(&mut *tx).await.map_err(Self::map_db)?;
        sqlx::query("UPDATE auth_v1.auth_challenges SET phase='terminal',provider_result_ciphertext=NULL,provider_result_key_version=NULL,provider_result_purpose=NULL WHERE challenge_id=$1")
            .bind(challenge_uuid)
            .execute(&mut *tx)
            .await
            .map_err(Self::map_db)?;
        tx.commit().await.map_err(Self::map_db)?;
        Ok((
            grant.clone(),
            AuthReceipt {
                operation_id: operation_id.clone(),
                command_kind: EXCHANGE_APPLE_COMMAND.into(),
                request_digest,
                response_bytes: response,
                status: 200,
                session_grant: Some(grant.clone()),
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
        sqlx::query("INSERT INTO auth_v1.auth_operations(operation_id,command_kind,request_digest,state) VALUES($1,'rotateRefreshToken',$2,'reserved') ON CONFLICT DO NOTHING")
            .bind(op)
            .bind(request.request_digest.as_slice())
            .execute(&mut *tx)
            .await
            .map_err(Self::map_db)?;
        let operation = sqlx::query("SELECT command_kind,request_digest,state,response_digest FROM auth_v1.auth_operations WHERE operation_id=$1 FOR UPDATE")
            .bind(op)
            .fetch_one(&mut *tx)
            .await
            .map_err(Self::map_db)?;
        if operation
            .try_get::<String, _>("command_kind")
            .map_err(Self::map_db)?
            != ROTATE_REFRESH_COMMAND
            || operation
                .try_get::<Vec<u8>, _>("request_digest")
                .map_err(Self::map_db)?
                .as_slice()
                != request.request_digest
        {
            return Err(AuthError::OperationIdReused);
        }
        let token = sqlx::query("SELECT family_id,generation,state FROM auth_v1.refresh_tokens WHERE token_hmac=$1 AND token_hmac_key_version=$2 FOR UPDATE")
            .bind(&token_verifier)
            .bind(TOKEN_HMAC_KEY_VERSION)
            .fetch_optional(&mut *tx)
            .await
            .map_err(Self::map_db)?
            .ok_or(AuthError::NotFound)?;
        let family: Uuid = token.try_get("family_id").map_err(Self::map_db)?;
        let generation: i64 = token.try_get("generation").map_err(Self::map_db)?;

        if operation
            .try_get::<String, _>("state")
            .map_err(Self::map_db)?
            == "completed"
        {
            let row = sqlx::query("SELECT family_id,presented_token_hmac,presented_generation,request_digest,response_digest,response_ciphertext,response_status,response_key_version,response_purpose FROM auth_v1.session_refresh_receipts WHERE operation_id=$1 FOR UPDATE")
                .bind(op)
                .fetch_one(&mut *tx)
                .await
                .map_err(Self::map_db)?;
            if row.try_get::<Uuid, _>("family_id").map_err(Self::map_db)? != family
                || row
                    .try_get::<Vec<u8>, _>("presented_token_hmac")
                    .map_err(Self::map_db)?
                    != token_verifier
                || row
                    .try_get::<i64, _>("presented_generation")
                    .map_err(Self::map_db)?
                    != generation
                || row
                    .try_get::<Vec<u8>, _>("request_digest")
                    .map_err(Self::map_db)?
                    .as_slice()
                    != request.request_digest
            {
                return Err(AuthError::OperationIdReused);
            }
            let status = row
                .try_get::<i32, _>("response_status")
                .map_err(Self::map_db)? as u16;
            let bytes = self
                .vault
                .open(
                    &row.try_get::<String, _>("response_purpose")
                        .map_err(Self::map_db)?,
                    request.operation_id.as_str(),
                    &SealedSecret {
                        key_version: row.try_get("response_key_version").map_err(Self::map_db)?,
                        ciphertext: row.try_get("response_ciphertext").map_err(Self::map_db)?,
                    },
                )
                .await?;
            let receipt_response_digest = row
                .try_get::<Vec<u8>, _>("response_digest")
                .map_err(Self::map_db)?;
            if operation
                .try_get::<Vec<u8>, _>("response_digest")
                .map_err(Self::map_db)?
                != receipt_response_digest
            {
                return Err(AuthError::Vault);
            }
            verify_response_digest(&bytes, &receipt_response_digest)?;
            let grant = if status == 200 {
                let tenant = sqlx::query("SELECT a.tenant_id FROM auth_v1.refresh_families f JOIN auth_v1.accounts a ON a.account_id=f.account_id WHERE f.family_id=$1")
                    .bind(family)
                    .fetch_one(&mut *tx)
                    .await
                    .map_err(Self::map_db)?
                    .try_get::<String, _>("tenant_id")
                    .map_err(Self::map_db)?;
                Some(crate::auth_wire::decode_refresh_response(
                    &bytes,
                    TenantId::new(tenant)?,
                )?)
            } else {
                None
            };
            let receipt = AuthReceipt {
                operation_id: request.operation_id.clone(),
                command_kind: ROTATE_REFRESH_COMMAND.into(),
                request_digest: request.request_digest,
                response_bytes: bytes.clone(),
                status,
                session_grant: grant.clone(),
            };
            tx.commit().await.map_err(Self::map_db)?;
            return Ok(RefreshOutcome {
                grant,
                receipt: Some(receipt),
                reused: status == 401,
            });
        }

        let token_state: String = token.try_get("state").map_err(Self::map_db)?;
        if token_state != "active" {
            let family_guard = sqlx::query("SELECT f.state AS family_state,s.state AS session_state,a.state AS account_state,i.state AS identity_state,(f.expires_at>now()) AS family_unexpired,(s.expires_at>now()) AS session_unexpired,(s.auth_epoch=a.auth_epoch AND s.account_fence=a.fence) AS binding_matches FROM auth_v1.refresh_families f JOIN auth_v1.auth_sessions s ON s.session_id=f.session_id JOIN auth_v1.accounts a ON a.account_id=f.account_id JOIN auth_v1.external_identities i ON i.identity_id=s.identity_id WHERE f.family_id=$1 FOR UPDATE OF f,s,a,i")
            .bind(family)
            .fetch_one(&mut *tx)
            .await
            .map_err(Self::map_db)?;
            if token_state != "consumed"
                || family_guard
                    .try_get::<String, _>("family_state")
                    .map_err(Self::map_db)?
                    != "active"
                || family_guard
                    .try_get::<String, _>("session_state")
                    .map_err(Self::map_db)?
                    != "active"
                || family_guard
                    .try_get::<String, _>("account_state")
                    .map_err(Self::map_db)?
                    != "active"
                || family_guard
                    .try_get::<String, _>("identity_state")
                    .map_err(Self::map_db)?
                    != "active"
                || !family_guard
                    .try_get::<bool, _>("family_unexpired")
                    .map_err(Self::map_db)?
                || !family_guard
                    .try_get::<bool, _>("session_unexpired")
                    .map_err(Self::map_db)?
                || !family_guard
                    .try_get::<bool, _>("binding_matches")
                    .map_err(Self::map_db)?
            {
                return Err(AuthError::SessionRevoked);
            }
            sqlx::query("UPDATE auth_v1.refresh_families SET state='reuseDetected' WHERE family_id=$1 AND state='active'")
                .bind(family)
                .execute(&mut *tx)
                .await
                .map_err(Self::map_db)?;
            sqlx::query("UPDATE auth_v1.refresh_tokens SET state='revoked' WHERE family_id=$1 AND state='active'")
                .bind(family)
                .execute(&mut *tx)
                .await
                .map_err(Self::map_db)?;
            sqlx::query("UPDATE auth_v1.auth_sessions SET state='revoked' WHERE family_id=$1 AND state='active'")
                .bind(family)
                .execute(&mut *tx)
                .await
                .map_err(Self::map_db)?;
            sqlx::query("UPDATE auth_v1.access_tokens SET revoked_at=now() WHERE session_id=(SELECT session_id FROM auth_v1.refresh_families WHERE family_id=$1) AND revoked_at IS NULL")
                .bind(family)
                .execute(&mut *tx)
                .await
                .map_err(Self::map_db)?;
            let response = canonical_wire(&RefreshFailureReceipt {
                code: "refreshTokenReused".into(),
                recovery_action: "interactiveAppleSignIn".into(),
                request_id: Uuid::new_v4().to_string(),
                retryability: "afterInteractiveAuthentication".into(),
                rotation_id: request.operation_id.clone(),
            })?;
            let response_digest = digest_request(&response);
            let sealed = self
                .vault
                .seal("auth_receipt_v1", request.operation_id.as_str(), &response)
                .await?;
            sqlx::query("INSERT INTO auth_v1.auth_events(account_id,event_kind,request_id) SELECT account_id,'refreshReuseDetected',$2 FROM auth_v1.refresh_families WHERE family_id=$1")
                .bind(family)
                .bind(op)
                .execute(&mut *tx)
                .await
                .map_err(Self::map_db)?;
            sqlx::query("INSERT INTO auth_v1.session_refresh_receipts(operation_id,family_id,presented_token_hmac,presented_generation,request_digest,response_digest,response_ciphertext,response_key_version,response_purpose,response_status,expires_at) VALUES($1,$2,$3,$4,$5,$6,$7,$8,'auth_receipt_v1',401,now()+interval '90 days')")
                .bind(op)
                .bind(family)
                .bind(&token_verifier)
                .bind(generation)
                .bind(request.request_digest.as_slice())
                .bind(response_digest.as_slice())
                .bind(&sealed.ciphertext)
                .bind(sealed.key_version)
                .execute(&mut *tx)
                .await
                .map_err(Self::map_db)?;
            sqlx::query("UPDATE auth_v1.auth_operations SET state='completed',response_status=401,response_digest=$2,response_ciphertext=$3,response_key_version=$4,response_purpose='auth_receipt_v1',completed_at=now() WHERE operation_id=$1")
                .bind(op)
                .bind(response_digest.as_slice())
                .bind(sealed.ciphertext)
                .bind(sealed.key_version)
                .execute(&mut *tx)
                .await
                .map_err(Self::map_db)?;
            tx.commit().await.map_err(Self::map_db)?;
            return Ok(RefreshOutcome {
                grant: None,
                receipt: Some(AuthReceipt {
                    operation_id: request.operation_id.clone(),
                    command_kind: ROTATE_REFRESH_COMMAND.into(),
                    request_digest: request.request_digest,
                    response_bytes: response,
                    status: 401,
                    session_grant: None,
                }),
                reused: true,
            });
        }
        let session = sqlx::query("SELECT s.session_id,s.account_id,a.tenant_id,a.auth_epoch,a.fence,f.expires_at AS family_expires_at FROM auth_v1.auth_sessions s JOIN auth_v1.accounts a ON a.account_id=s.account_id JOIN auth_v1.external_identities i ON i.identity_id=s.identity_id JOIN auth_v1.refresh_families f ON f.family_id=s.family_id WHERE s.family_id=$1 AND s.state='active' AND s.expires_at>now() AND f.state='active' AND f.expires_at>now() AND f.current_generation=$2 AND a.state='active' AND i.state='active' AND s.auth_epoch=a.auth_epoch AND s.account_fence=a.fence FOR UPDATE OF s,a,i,f")
            .bind(family)
            .bind(generation)
            .fetch_optional(&mut *tx)
            .await
            .map_err(Self::map_db)?
            .ok_or(AuthError::SessionRevoked)?;
        let consumed = sqlx::query("UPDATE auth_v1.refresh_tokens SET state='consumed' WHERE family_id=$1 AND generation=$2 AND state='active'")
            .bind(family)
            .bind(generation)
            .execute(&mut *tx)
            .await
            .map_err(Self::map_db)?;
        if consumed.rows_affected() != 1 {
            return Err(AuthError::RefreshTokenReused);
        }
        let next = generation + 1;
        let access = Self::opaque("fma1")?;
        let refresh = Self::opaque("fmr1")?;
        let now_unix = Utc::now().timestamp();
        let rotated_access_hash = self.hmac("access", &access)?;
        sqlx::query("INSERT INTO auth_v1.access_tokens(token_id,session_id,account_id,token_hmac,token_hmac_key_version,auth_epoch,fence,expires_at) VALUES($1,$2,$3,$4,$5,$6,$7,to_timestamp($8))")
            .bind(Uuid::new_v4())
            .bind(session.try_get::<Uuid, _>("session_id").map_err(Self::map_db)?)
            .bind(session.try_get::<String, _>("account_id").map_err(Self::map_db)?)
            .bind(rotated_access_hash)
            .bind(TOKEN_HMAC_KEY_VERSION)
            .bind(session.try_get::<i64, _>("auth_epoch").map_err(Self::map_db)?)
            .bind(session.try_get::<Vec<u8>, _>("fence").map_err(Self::map_db)?)
            .bind(now_unix + ACCESS_TOKEN_LIFETIME_SECONDS)
            .execute(&mut *tx).await.map_err(Self::map_db)?;
        sqlx::query("INSERT INTO auth_v1.refresh_tokens(family_id,generation,token_hmac,token_hmac_key_version,state) VALUES($1,$2,$3,$4,'active')").bind(family).bind(next).bind(self.hmac("refresh",&refresh)?).bind(TOKEN_HMAC_KEY_VERSION).execute(&mut *tx).await.map_err(Self::map_db)?;
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
                session_id: SessionId::new(
                    session
                        .try_get::<Uuid, _>("session_id")
                        .map_err(Self::map_db)?
                        .to_string(),
                )?,
                account_auth_epoch: session.try_get("auth_epoch").map_err(Self::map_db)?,
                account_fence: session.try_get("fence").map_err(Self::map_db)?,
            },
            access_token: access,
            refresh_token: refresh,
            refresh_generation: next,
            access_expires_at_unix: now_unix + ACCESS_TOKEN_LIFETIME_SECONDS,
            refresh_expires_at_unix: session
                .try_get::<DateTime<Utc>, _>("family_expires_at")
                .map_err(Self::map_db)?
                .timestamp(),
        };
        let response = crate::auth_wire::encode_refresh_response(
            &grant,
            &self.server_instance_id,
            &request.operation_id,
        )?;
        let response_digest = digest_request(&response);
        sqlx::query("INSERT INTO auth_v1.auth_events(account_id,event_kind,request_id) VALUES($1,'sessionRefreshed',$2)")
            .bind(session.try_get::<String, _>("account_id").map_err(Self::map_db)?)
            .bind(op)
            .execute(&mut *tx)
            .await
            .map_err(Self::map_db)?;
        let sealed = self
            .vault
            .seal("auth_receipt_v1", request.operation_id.as_str(), &response)
            .await?;
        sqlx::query("INSERT INTO auth_v1.session_refresh_receipts(operation_id,family_id,presented_token_hmac,presented_generation,request_digest,response_digest,response_ciphertext,response_key_version,response_purpose,response_status,expires_at) VALUES($1,$2,$3,$4,$5,$6,$7,$8,'auth_receipt_v1',200,now()+interval '90 days')").bind(op).bind(family).bind(&token_verifier).bind(generation).bind(request.request_digest.as_slice()).bind(response_digest.as_slice()).bind(&sealed.ciphertext).bind(sealed.key_version).execute(&mut *tx).await.map_err(Self::map_db)?;
        sqlx::query("UPDATE auth_v1.auth_operations SET state='completed',response_status=200,response_digest=$2,response_ciphertext=$3,response_key_version=$4,response_purpose='auth_receipt_v1',completed_at=now() WHERE operation_id=$1")
            .bind(op)
            .bind(response_digest.as_slice())
            .bind(sealed.ciphertext)
            .bind(sealed.key_version)
            .execute(&mut *tx)
            .await
            .map_err(Self::map_db)?;
        tx.commit().await.map_err(Self::map_db)?;
        Ok(RefreshOutcome {
            grant: Some(grant.clone()),
            receipt: Some(AuthReceipt {
                operation_id: request.operation_id.clone(),
                command_kind: ROTATE_REFRESH_COMMAND.into(),
                request_digest: request.request_digest,
                response_bytes: response,
                status: 200,
                session_grant: Some(grant.clone()),
            }),
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
        if let Some(row) = sqlx::query("SELECT command_kind,request_digest,response_status,response_digest,response_ciphertext,response_key_version,response_purpose,state FROM auth_v1.auth_operations WHERE operation_id=$1 FOR UPDATE")
            .bind(op).fetch_optional(&mut *tx).await.map_err(Self::map_db)? {
            if row.try_get::<String, _>("command_kind").map_err(Self::map_db)? != REVOKE_SESSION_COMMAND
                || row.try_get::<Vec<u8>, _>("request_digest").map_err(Self::map_db)?.as_slice() != request_digest { return Err(AuthError::OperationIdReused); }
            if row.try_get::<String, _>("state").map_err(Self::map_db)? == "completed" {
                let response = self.vault.open(
                    &row.try_get::<String, _>("response_purpose").map_err(Self::map_db)?, operation_id.as_str(),
                    &SealedSecret { key_version: row.try_get("response_key_version").map_err(Self::map_db)?, ciphertext: row.try_get("response_ciphertext").map_err(Self::map_db)? },
                ).await?;
                verify_response_digest(
                    &response,
                    &row.try_get::<Vec<u8>, _>("response_digest")
                        .map_err(Self::map_db)?,
                )?;
                tx.commit().await.map_err(Self::map_db)?;
                return Ok(AuthReceipt { operation_id: operation_id.clone(), command_kind: REVOKE_SESSION_COMMAND.into(), request_digest, response_bytes: response, status: row.try_get::<i32, _>("response_status").map_err(Self::map_db)? as u16, session_grant: None });
            }
        } else {
            sqlx::query("INSERT INTO auth_v1.auth_operations(operation_id,command_kind,request_digest,state) VALUES($1,'revokeCurrentSession',$2,'reserved')")
                .bind(op).bind(request_digest.as_slice()).execute(&mut *tx).await.map_err(Self::map_db)?;
        }
        let active = sqlx::query("SELECT s.session_id,s.family_id,a.auth_epoch,a.fence,f.expires_at AS family_expires_at FROM auth_v1.auth_sessions s JOIN auth_v1.accounts a ON a.account_id=s.account_id JOIN auth_v1.external_identities i ON i.identity_id=s.identity_id JOIN auth_v1.refresh_families f ON f.family_id=s.family_id WHERE s.session_id=$1 AND s.state='active' AND s.expires_at>now() AND a.state='active' AND i.state='active' AND f.state='active' AND f.expires_at>now() AND s.auth_epoch=a.auth_epoch AND s.account_fence=a.fence FOR UPDATE OF s,a,i,f")
            .bind(sid)
            .fetch_optional(&mut *tx)
            .await
            .map_err(Self::map_db)?;
        let active = active.ok_or(AuthError::SessionRevoked)?;
        let family_id = active
            .try_get::<Uuid, _>("family_id")
            .map_err(Self::map_db)?;
        sqlx::query("UPDATE auth_v1.auth_sessions SET state='revoked' WHERE session_id=$1 AND state='active'").bind(sid).execute(&mut *tx).await.map_err(Self::map_db)?;
        sqlx::query("UPDATE auth_v1.refresh_families SET state='revoked' WHERE family_id=$1 AND state='active'")
            .bind(family_id)
            .execute(&mut *tx)
            .await
            .map_err(Self::map_db)?;
        sqlx::query("UPDATE auth_v1.refresh_tokens SET state='revoked' WHERE family_id=$1 AND state='active'")
            .bind(family_id)
            .execute(&mut *tx)
            .await
            .map_err(Self::map_db)?;
        sqlx::query("UPDATE auth_v1.access_tokens SET revoked_at=now() WHERE session_id=$1 AND revoked_at IS NULL")
            .bind(sid)
            .execute(&mut *tx)
            .await
            .map_err(Self::map_db)?;
        sqlx::query("INSERT INTO auth_v1.auth_events(account_id,event_kind,request_id) SELECT account_id,'sessionRevoked',$2 FROM auth_v1.auth_sessions WHERE session_id=$1")
            .bind(sid)
            .bind(op)
            .execute(&mut *tx)
            .await
            .map_err(Self::map_db)?;
        let now_unix = Utc::now().timestamp();
        let response = crate::auth_wire::encode_revoke_response(
            active.try_get("auth_epoch").map_err(Self::map_db)?,
            &active
                .try_get::<Vec<u8>, _>("fence")
                .map_err(Self::map_db)?,
            operation_id,
            now_unix,
            active
                .try_get::<DateTime<Utc>, _>("family_expires_at")
                .map_err(Self::map_db)?
                .timestamp(),
        )?;
        let response_digest = digest_request(&response);
        let sealed = self
            .vault
            .seal("auth_receipt_v1", operation_id.as_str(), &response)
            .await?;
        sqlx::query("UPDATE auth_v1.auth_operations SET state='completed',response_status=200,response_digest=$2,response_ciphertext=$3,response_key_version=$4,response_purpose='auth_receipt_v1',completed_at=now() WHERE operation_id=$1").bind(op).bind(response_digest.as_slice()).bind(sealed.ciphertext).bind(sealed.key_version).execute(&mut *tx).await.map_err(Self::map_db)?;
        tx.commit().await.map_err(Self::map_db)?;
        Ok(AuthReceipt {
            operation_id: operation_id.clone(),
            command_kind: REVOKE_SESSION_COMMAND.into(),
            request_digest,
            response_bytes: response,
            status: 200,
            session_grant: None,
        })
    }

    async fn rotate_account_fence(
        &self,
        operation_id: &OperationId,
        request_digest: [u8; 32],
        account_id: &AccountId,
    ) -> Result<SecurityTransition, AuthError> {
        let mut tx = self.pool.begin().await.map_err(Self::map_db)?;
        let op = Self::uuid(operation_id.as_str())?;
        sqlx::query("INSERT INTO auth_v1.auth_operations(operation_id,command_kind,request_digest,state) VALUES($1,'rotateAccountFence',$2,'reserved') ON CONFLICT DO NOTHING")
            .bind(op)
            .bind(request_digest.as_slice())
            .execute(&mut *tx)
            .await
            .map_err(Self::map_db)?;
        let operation = sqlx::query("SELECT command_kind,request_digest,state,response_digest,response_ciphertext,response_key_version,response_purpose FROM auth_v1.auth_operations WHERE operation_id=$1 FOR UPDATE")
            .bind(op)
            .fetch_one(&mut *tx)
            .await
            .map_err(Self::map_db)?;
        if operation
            .try_get::<String, _>("command_kind")
            .map_err(Self::map_db)?
            != ROTATE_ACCOUNT_FENCE_COMMAND
            || operation
                .try_get::<Vec<u8>, _>("request_digest")
                .map_err(Self::map_db)?
                .as_slice()
                != request_digest
        {
            return Err(AuthError::OperationIdReused);
        }
        if operation
            .try_get::<String, _>("state")
            .map_err(Self::map_db)?
            == "completed"
        {
            let response = self
                .vault
                .open(
                    &operation
                        .try_get::<String, _>("response_purpose")
                        .map_err(Self::map_db)?,
                    operation_id.as_str(),
                    &SealedSecret {
                        key_version: operation
                            .try_get("response_key_version")
                            .map_err(Self::map_db)?,
                        ciphertext: operation
                            .try_get("response_ciphertext")
                            .map_err(Self::map_db)?,
                    },
                )
                .await?;
            verify_response_digest(
                &response,
                &operation
                    .try_get::<Vec<u8>, _>("response_digest")
                    .map_err(Self::map_db)?,
            )?;
            let replay = serde_json::from_slice(&response).map_err(|_| AuthError::Vault)?;
            tx.commit().await.map_err(Self::map_db)?;
            return Ok(replay);
        }
        let fence = Self::fence()?;
        let row=sqlx::query("UPDATE auth_v1.accounts SET auth_epoch=auth_epoch+1,fence=$2,updated_at=now() WHERE account_id=$1 AND state='active' RETURNING auth_epoch,fence").bind(account_id.as_str()).bind(&fence).fetch_optional(&mut *tx).await.map_err(Self::map_db)?.ok_or(AuthError::AccountNotFound)?;
        sqlx::query("UPDATE auth_v1.auth_sessions SET state='reauthRequired' WHERE account_id=$1 AND state='active'").bind(account_id.as_str()).execute(&mut *tx).await.map_err(Self::map_db)?;
        sqlx::query("INSERT INTO auth_v1.auth_events(account_id,event_kind,request_id) VALUES($1,'accountFenceRotated',$2)")
            .bind(account_id.as_str())
            .bind(op)
            .execute(&mut *tx)
            .await
            .map_err(Self::map_db)?;
        let transition = SecurityTransition {
            account_auth_epoch: row.try_get("auth_epoch").map_err(Self::map_db)?,
            account_fence: row.try_get("fence").map_err(Self::map_db)?,
            sessions_reauth_required: true,
        };
        let response = canonical_wire(&transition)?;
        let response_digest = digest_request(&response);
        let sealed = self
            .vault
            .seal("auth_receipt_v1", operation_id.as_str(), &response)
            .await?;
        sqlx::query("UPDATE auth_v1.auth_operations SET state='completed',response_status=200,response_digest=$2,response_ciphertext=$3,response_key_version=$4,response_purpose='auth_receipt_v1',completed_at=now() WHERE operation_id=$1")
            .bind(op)
            .bind(response_digest.as_slice())
            .bind(sealed.ciphertext)
            .bind(sealed.key_version)
            .execute(&mut *tx)
            .await
            .map_err(Self::map_db)?;
        tx.commit().await.map_err(Self::map_db)?;
        Ok(transition)
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
fn canonical_wire<T: Serialize>(value: &T) -> Result<Vec<u8>, AuthError> {
    let value = to_value(value).map_err(|_| AuthError::Vault)?;
    crate::domain::canonical_json(&value).map_err(|_| AuthError::Vault)
}

fn verify_response_digest(bytes: &[u8], expected: &[u8]) -> Result<(), AuthError> {
    if digest_request(bytes).as_slice() != expected {
        return Err(AuthError::Vault);
    }
    Ok(())
}
