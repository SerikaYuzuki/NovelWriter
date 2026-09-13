//! Explicit account deletion, cancellable for exactly 720 hours. Local copies
//! are never addressed by this server-side lifecycle.
use crate::auth_domain::{AuthError, AuthenticatedPrincipal};
use chrono::{DateTime, Utc};
use serde_json::{json, Value};
use sqlx::{PgPool, Row};
use uuid::Uuid;

fn db(error: sqlx::Error) -> AuthError {
    AuthError::Database(error.to_string())
}

pub async fn change(
    pool: &PgPool,
    principal: &AuthenticatedPrincipal,
    action: &str,
    request: Option<Uuid>,
) -> Result<Value, AuthError> {
    let account = principal.account_id.as_str();
    let mut tx = pool.begin().await.map_err(db)?;
    let valid: bool = sqlx::query_scalar("SELECT state='active' AND auth_epoch=$2 AND fence=$3 FROM auth_v1.accounts WHERE account_id=$1 FOR UPDATE")
        .bind(account).bind(principal.account_auth_epoch).bind(&principal.account_fence).fetch_one(&mut *tx).await.map_err(db)?;
    if !valid {
        return Err(AuthError::SessionRevoked);
    }
    match action {
        "request" => {
            let id = request.ok_or(AuthError::InvalidRequest)?;
            let existing: Option<String> = sqlx::query_scalar(
                "SELECT account_id FROM auth_v1.account_deletions WHERE request_id=$1",
            )
            .bind(id)
            .fetch_optional(&mut *tx)
            .await
            .map_err(db)?;
            if existing.as_deref().is_some_and(|owner| owner != account) {
                return Err(AuthError::InvalidRequest);
            }
            // An exact old replay never renews the deadline or revives cancellation.
            if existing.is_none() {
                let pending: bool = sqlx::query_scalar("SELECT EXISTS(SELECT 1 FROM auth_v1.account_deletions WHERE account_id=$1 AND state='pending')")
                    .bind(account).fetch_one(&mut *tx).await.map_err(db)?;
                if pending {
                    return Err(AuthError::InvalidRequest);
                }
                sqlx::query("INSERT INTO auth_v1.account_deletions(request_id,account_id,state,requested_at,delete_after) SELECT $1,$2,'pending',t,t+interval '720 hours' FROM (SELECT clock_timestamp() t) n")
                    .bind(id).bind(account).execute(&mut *tx).await.map_err(db)?;
            }
        }
        "cancel" => {
            let id = request.ok_or(AuthError::InvalidRequest)?;
            let changed = sqlx::query("UPDATE auth_v1.account_deletions SET state='cancelled',cancelled_at=clock_timestamp() WHERE request_id=$1 AND account_id=$2 AND state='pending' AND delete_after>clock_timestamp()")
                .bind(id).bind(account).execute(&mut *tx).await.map_err(db)?.rows_affected();
            if changed == 0 {
                let cancelled: bool = sqlx::query_scalar("SELECT EXISTS(SELECT 1 FROM auth_v1.account_deletions WHERE request_id=$1 AND account_id=$2 AND state='cancelled')")
                    .bind(id).bind(account).fetch_one(&mut *tx).await.map_err(db)?;
                if !cancelled {
                    return Err(AuthError::InvalidRequest);
                }
            }
        }
        "status" => {}
        _ => return Err(AuthError::InvalidRequest),
    }
    let row = if let Some(id) = request {
        sqlx::query("SELECT request_id,state,requested_at,delete_after FROM auth_v1.account_deletions WHERE account_id=$1 AND request_id=$2")
            .bind(account).bind(id).fetch_optional(&mut *tx).await.map_err(db)?
    } else {
        sqlx::query("SELECT request_id,state,requested_at,delete_after FROM auth_v1.account_deletions WHERE account_id=$1 ORDER BY requested_at DESC LIMIT 1")
            .bind(account).fetch_optional(&mut *tx).await.map_err(db)?
    };
    let result = if let Some(row) = row {
        json!({"lifecycleVersion":1,"requestId":row.get::<Uuid,_>("request_id"),"state":row.get::<String,_>("state"),
            "requestedAt":row.get::<DateTime<Utc>,_>("requested_at").to_rfc3339(),"deleteAfter":row.get::<DateTime<Utc>,_>("delete_after").to_rfc3339()})
    } else {
        json!({"lifecycleVersion":1,"state":"none"})
    };
    tx.commit().await.map_err(db)?;
    Ok(result)
}

/// Bounded work, atomic per account. Failed transactions leave the request due
/// for retry after restart; completed tombstones cannot recreate their account.
pub async fn sweep(pool: &PgPool) -> Result<u64, sqlx::Error> {
    let accounts: Vec<String> = sqlx::query_scalar("SELECT d.account_id FROM auth_v1.account_deletions d JOIN auth_v1.accounts a USING(account_id) WHERE d.state='pending' AND d.delete_after<=clock_timestamp() AND a.state<>'deleted' ORDER BY d.delete_after LIMIT 16")
        .fetch_all(pool).await?;
    let mut count = 0;
    for account in accounts {
        let mut tx = pool.begin().await?;
        // Provider login/notification code locks identities before accounts.
        sqlx::query("SELECT identity_id FROM auth_v1.external_identities WHERE account_id=$1 ORDER BY identity_id FOR UPDATE").bind(&account).fetch_all(&mut *tx).await?;
        let current_state: String =
            sqlx::query_scalar("SELECT state FROM auth_v1.accounts WHERE account_id=$1 FOR UPDATE")
                .bind(&account)
                .fetch_one(&mut *tx)
                .await?;
        if current_state == "deleted" {
            continue;
        }
        let due: Option<Uuid> = sqlx::query_scalar("SELECT request_id FROM auth_v1.account_deletions WHERE account_id=$1 AND state='pending' AND delete_after<=clock_timestamp() FOR UPDATE")
            .bind(&account).fetch_optional(&mut *tx).await?;
        let Some(_request) = due else {
            continue;
        };
        sqlx::query("SELECT account_id FROM sync_v2.account_scopes WHERE account_id=$1 FOR UPDATE")
            .bind(&account)
            .fetch_optional(&mut *tx)
            .await?;
        // Reject even an already-authenticated in-flight principal at scope().
        let fence = [
            Uuid::new_v4().as_bytes().as_slice(),
            Uuid::new_v4().as_bytes().as_slice(),
        ]
        .concat();
        sqlx::query("UPDATE auth_v1.accounts SET state='deleted',auth_epoch=auth_epoch+1,fence=$2,updated_at=clock_timestamp() WHERE account_id=$1").bind(&account).bind(&fence).execute(&mut *tx).await?;
        sqlx::query("UPDATE sync_v2.account_scopes SET account_auth_epoch=9223372036854775807,account_fence='deleted' WHERE account_id=$1").bind(&account).execute(&mut *tx).await?;
        sqlx::query("UPDATE auth_v1.auth_sessions SET state='revoked' WHERE account_id=$1")
            .bind(&account)
            .execute(&mut *tx)
            .await?;
        sqlx::query("UPDATE auth_v1.refresh_families SET state='revoked' WHERE account_id=$1")
            .bind(&account)
            .execute(&mut *tx)
            .await?;
        sqlx::query("UPDATE auth_v1.refresh_tokens SET state='revoked' WHERE family_id IN (SELECT family_id FROM auth_v1.refresh_families WHERE account_id=$1)").bind(&account).execute(&mut *tx).await?;
        sqlx::query("UPDATE auth_v1.access_tokens SET revoked_at=clock_timestamp() WHERE account_id=$1 AND revoked_at IS NULL").bind(&account).execute(&mut *tx).await?;
        sqlx::query("UPDATE auth_v1.provider_credentials SET state='revokeRetryPending',validation_event_type=NULL,revoke_lease_until=NULL,revoke_next_attempt_at=NULL WHERE identity_id IN (SELECT identity_id FROM auth_v1.external_identities WHERE account_id=$1) AND state<>'revoked'").bind(&account).execute(&mut *tx).await?;
        sqlx::query("UPDATE auth_v1.external_identities SET state='unlinked',revoked_at=clock_timestamp() WHERE account_id=$1").bind(&account).execute(&mut *tx).await?;
        sqlx::query("DELETE FROM auth_v1.external_identity_secrets WHERE identity_id IN (SELECT identity_id FROM auth_v1.external_identities WHERE account_id=$1)").bind(&account).execute(&mut *tx).await?;
        sqlx::query("UPDATE sync_v2.works SET head_snapshot_id=NULL,head_generation=NULL WHERE account_id=$1").bind(&account).execute(&mut *tx).await?;
        for table in [
            "conflict_events",
            "quarantine_records",
            "catalog_events",
            "head_events",
            "restore_receipts",
            "history",
            "conflict_candidates",
            "active_conflicts",
            "upload_capabilities",
            "receipts",
            "sealed_commands",
            "snapshot_parents",
            "snapshot_entries",
            "snapshots",
            "works",
        ] {
            sqlx::query(&format!("DELETE FROM sync_v2.{table} WHERE account_id=$1"))
                .bind(&account)
                .execute(&mut *tx)
                .await?;
        }
        // Include migration staging and uploads never published to a snapshot.
        sqlx::query("DELETE FROM sync_v2.migration_staging_objects WHERE migration_id IN (SELECT migration_id FROM sync_v2.migration_ledger WHERE account_id=$1 UNION SELECT migration_id FROM sync_v2.migration_staging_batches WHERE verified_account_id=$1)").bind(&account).execute(&mut *tx).await?;
        sqlx::query("DELETE FROM sync_v2.migration_staging_batches WHERE migration_id IN (SELECT migration_id FROM sync_v2.migration_ledger WHERE account_id=$1) OR verified_account_id=$1").bind(&account).execute(&mut *tx).await?;
        sqlx::query("DELETE FROM sync_v2.migration_ledger WHERE account_id=$1")
            .bind(&account)
            .execute(&mut *tx)
            .await?;
        let objects: Vec<Vec<u8>> = sqlx::query_scalar(
            "DELETE FROM sync_v2.account_objects WHERE account_id=$1 RETURNING object_id",
        )
        .bind(&account)
        .fetch_all(&mut *tx)
        .await?;
        for object in objects {
            sqlx::query("DELETE FROM sync_v2.global_blobs b WHERE object_id=$1 AND NOT EXISTS(SELECT 1 FROM sync_v2.account_objects a WHERE a.object_id=b.object_id)").bind(object).execute(&mut *tx).await?;
        }
        // The account state is the atomic remote-erasure marker. Keep the
        // request pending until every Apple revocation has actually succeeded.
        tx.commit().await?;
        count += 1;
    }
    // Remove identity mappings only after Apple revocation has finished. A later
    // Apple sign-in then creates a new account; the old account/scope tombstone
    // remains to reject old credentials and never restores erased manuscripts.
    let mut tx = pool.begin().await?;
    sqlx::query("DELETE FROM auth_v1.provider_credentials WHERE state='revoked' AND identity_id IN (SELECT i.identity_id FROM auth_v1.external_identities i JOIN auth_v1.accounts a USING(account_id) WHERE a.state='deleted')").execute(&mut *tx).await?;
    let finished: Vec<String> = sqlx::query_scalar("SELECT account_id FROM auth_v1.accounts a WHERE state='deleted' AND EXISTS(SELECT 1 FROM auth_v1.external_identities i WHERE i.account_id=a.account_id) AND NOT EXISTS(SELECT 1 FROM auth_v1.provider_credentials c JOIN auth_v1.external_identities i USING(identity_id) WHERE i.account_id=a.account_id) ORDER BY account_id LIMIT 16").fetch_all(&mut *tx).await?;
    for account in finished {
        sqlx::query("SELECT identity_id FROM auth_v1.external_identities WHERE account_id=$1 ORDER BY identity_id FOR UPDATE").bind(&account).fetch_all(&mut *tx).await?;
        for query in [
            "DELETE FROM auth_v1.session_refresh_receipts WHERE family_id IN (SELECT family_id FROM auth_v1.refresh_families WHERE account_id=$1)",
            "DELETE FROM auth_v1.refresh_tokens WHERE family_id IN (SELECT family_id FROM auth_v1.refresh_families WHERE account_id=$1)",
            "DELETE FROM auth_v1.access_tokens WHERE account_id=$1",
            "DELETE FROM auth_v1.refresh_families WHERE account_id=$1",
            "DELETE FROM auth_v1.auth_sessions WHERE account_id=$1",
            "DELETE FROM auth_v1.external_identity_secrets WHERE identity_id IN (SELECT identity_id FROM auth_v1.external_identities WHERE account_id=$1)",
            "DELETE FROM auth_v1.external_identities WHERE account_id=$1",
        ] { sqlx::query(query).bind(&account).execute(&mut *tx).await?; }
    }
    sqlx::query("UPDATE auth_v1.account_deletions d SET state='deleted',deleted_at=clock_timestamp() WHERE d.state='pending' AND EXISTS(SELECT 1 FROM auth_v1.accounts a WHERE a.account_id=d.account_id AND a.state='deleted') AND NOT EXISTS(SELECT 1 FROM auth_v1.external_identities i WHERE i.account_id=d.account_id)").execute(&mut *tx).await?;
    tx.commit().await?;
    Ok(count)
}
