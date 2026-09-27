//! Session issuance shared with the browser entry point. No sync data is touched.
use super::*;
use crate::auth_browser::BrowserIdentity;

impl AuthPostgresRepository {
    pub(crate) async fn issue_browser_session(
        &self,
        tx: &mut sqlx::Transaction<'_, sqlx::Postgres>,
        identity: &BrowserIdentity,
        provider: &str,
        platform: &str,
        subject_lookup: Vec<u8>,
        now_unix: i64,
    ) -> Result<SessionGrant, AuthError> {
        let (config, issuer, audience) = crate::auth_browser::provider_binding(provider)?;
        let provider_row = sqlx::query("SELECT enabled,provider_kind,exact_issuer FROM auth_v1.provider_configs WHERE provider_config_id=$1 FOR UPDATE")
            .bind(config).fetch_one(&mut **tx).await.map_err(Self::map_db)?;
        if !provider_row
            .try_get::<bool, _>("enabled")
            .map_err(Self::map_db)?
            || provider_row
                .try_get::<String, _>("provider_kind")
                .map_err(Self::map_db)?
                != provider
            || provider_row
                .try_get::<String, _>("exact_issuer")
                .map_err(Self::map_db)?
                != issuer
        {
            return Err(AuthError::ProviderNotAllowed);
        }
        let row = sqlx::query("SELECT identity_id,account_id,state FROM auth_v1.external_identities WHERE provider_config_id=$1 AND exact_issuer=$2 AND subject_lookup_hmac=$3 FOR UPDATE").bind(config).bind(issuer).bind(&subject_lookup).fetch_optional(&mut **tx).await.map_err(Self::map_db)?;
        let (account_id, tenant_id, epoch, fence, identity_id) = if let Some(row) = row {
            if row.try_get::<String, _>("state").map_err(Self::map_db)? != "active" {
                return Err(AuthError::SessionRevoked);
            }
            let account = row
                .try_get::<String, _>("account_id")
                .map_err(Self::map_db)?;
            let account_row = sqlx::query("SELECT tenant_id,auth_epoch,fence,state FROM auth_v1.accounts WHERE account_id=$1 FOR UPDATE").bind(&account).fetch_one(&mut **tx).await.map_err(Self::map_db)?;
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
            sqlx::query("INSERT INTO auth_v1.accounts(account_id,tenant_id,state,auth_epoch,fence) VALUES($1,$2,'active',1,$3)").bind(account.as_str()).bind(tenant.as_str()).bind(&fence).execute(&mut **tx).await.map_err(Self::map_db)?;
            let iid = Uuid::new_v4();
            sqlx::query("INSERT INTO auth_v1.external_identities(identity_id,account_id,provider_config_id,exact_issuer,lookup_key_version,subject_lookup_hmac,state) VALUES($1,$2,$3,$4,1,$5,'active')").bind(iid).bind(account.as_str()).bind(config).bind(issuer).bind(&subject_lookup).execute(&mut **tx).await.map_err(Self::map_db)?;
            let subject_plaintext = identity.subject.as_bytes();
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
                    subject_plaintext,
                )
                .await?;
            sqlx::query("INSERT INTO auth_v1.external_identity_secrets(identity_id,key_version,purpose,ciphertext,vault_context) VALUES($1,$2,'external_identity_subject_v1',$3,$4)")
                .bind(iid)
                .bind(sealed_subject.key_version)
                .bind(sealed_subject.ciphertext)
                .bind(subject_context)
                .execute(&mut **tx)
                .await
                .map_err(Self::map_db)?;
            (account, tenant, 1, fence, iid)
        };
        sqlx::query("UPDATE auth_v1.external_identities SET last_provider_auth_at=GREATEST(last_provider_auth_at,$2) WHERE identity_id=$1")
            .bind(identity_id).bind(identity.authenticated_at)
            .execute(&mut **tx).await.map_err(Self::map_db)?;
        // A verified login supersedes outstanding notification checks for this
        // identity across all audiences. Completion holds this same identity lock
        // and requires pending state, so an old device's result cannot revoke the
        // newly authenticated session (including a same-second login).
        sqlx::query("UPDATE auth_v1.provider_credentials SET state='superseded',validation_event_type=NULL,revoke_lease_until=NULL,revoke_next_attempt_at=NULL WHERE identity_id=$1 AND state='providerValidationPending'")
            .bind(identity_id).execute(&mut **tx).await.map_err(Self::map_db)?;
        if let Some(credential) = identity.credential.as_ref() {
            if credential.audience != audience {
                return Err(AuthError::ProviderNotAllowed);
            }
            let previous = sqlx::query("SELECT COALESCE(MAX(credential_generation),0) AS generation FROM auth_v1.provider_credentials WHERE identity_id=$1 AND original_audience=$2")
                .bind(identity_id)
                .bind(&credential.audience)
                .fetch_one(&mut **tx)
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
            sqlx::query("UPDATE auth_v1.provider_credentials SET state='superseded' WHERE identity_id=$1 AND original_audience=$2 AND state IN ('active','providerValidationPending')")
                .bind(identity_id)
                .bind(&credential.audience)
                .execute(&mut **tx)
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
                .execute(&mut **tx)
                .await
                .map_err(Self::map_db)?;
        }
        let sid = Uuid::new_v4();
        let fid = Uuid::new_v4();
        let session = SessionId::new(sid.to_string())?;
        let access = Self::opaque("fma1")?;
        let refresh = Self::opaque("fmr1")?;
        sqlx::query("INSERT INTO auth_v1.auth_sessions(session_id,account_id,identity_id,family_id,auth_epoch,account_fence,state,client_platform,expires_at) VALUES($1,$2,$3,$4,$5,$6,'active',$7,to_timestamp($8))").bind(sid).bind(account_id.as_str()).bind(identity_id).bind(fid).bind(epoch).bind(&fence).bind(platform).bind(now_unix + REFRESH_TOKEN_LIFETIME_SECONDS).execute(&mut **tx).await.map_err(Self::map_db)?;
        let access_hash = self.hmac("access", &access)?;
        sqlx::query("INSERT INTO auth_v1.access_tokens(token_id,session_id,account_id,token_hmac,token_hmac_key_version,auth_epoch,fence,expires_at) VALUES($1,$2,$3,$4,$5,$6,$7,to_timestamp($8))")
            .bind(Uuid::new_v4()).bind(sid).bind(account_id.as_str()).bind(access_hash).bind(TOKEN_HMAC_KEY_VERSION).bind(epoch).bind(&fence).bind(now_unix + ACCESS_TOKEN_LIFETIME_SECONDS)
            .execute(&mut **tx).await.map_err(Self::map_db)?;
        sqlx::query("INSERT INTO auth_v1.refresh_families(family_id,session_id,account_id,state,current_generation,expires_at) VALUES($1,$2,$3,'active',1,to_timestamp($4))").bind(fid).bind(sid).bind(account_id.as_str()).bind(now_unix + REFRESH_TOKEN_LIFETIME_SECONDS).execute(&mut **tx).await.map_err(Self::map_db)?;
        let token_hash = self.hmac("refresh", &refresh)?;
        sqlx::query("INSERT INTO auth_v1.refresh_tokens(family_id,generation,token_hmac,token_hmac_key_version,state) VALUES($1,1,$2,$3,'active')").bind(fid).bind(&token_hash).bind(TOKEN_HMAC_KEY_VERSION).execute(&mut **tx).await.map_err(Self::map_db)?;
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
        Ok(grant)
    }
}
