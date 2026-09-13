mod support;
use fuminiwa_sync_server_v2::{
    account_deletion::{change, sweep},
    auth_domain::{AccountId, AuthenticatedPrincipal, SessionId, TenantId},
};
use uuid::Uuid;

#[tokio::test]
async fn explicit_grace_cancel_restart_and_scoped_erasure() {
    let Ok(url) = std::env::var("FUMINIWA_ACCOUNT_DELETION_TEST_URL") else {
        eprintln!("SKIP: dedicated fresh account-deletion test database required");
        return;
    };
    let ctx = support::run_repository_scenarios(&url).await.unwrap();
    let pool = &ctx.repo.pool;
    let account = &ctx.account_a.account_id;
    for id in [account, &ctx.account_b.account_id] {
        sqlx::query("INSERT INTO auth_v1.accounts(account_id,tenant_id,state,auth_epoch,fence) VALUES($1,$2,'active',1,$3)")
            .bind(id).bind(format!("tenant-{id}")).bind(vec![1u8;32]).execute(pool).await.unwrap();
    }
    let p = AuthenticatedPrincipal {
        account_id: AccountId::new(account.clone()).unwrap(),
        tenant_id: TenantId::new(format!("tenant-{account}")).unwrap(),
        session_id: SessionId::new(Uuid::new_v4().to_string()).unwrap(),
        account_auth_epoch: 1,
        account_fence: vec![1u8; 32],
    };
    let identity = Uuid::new_v4();
    sqlx::query("INSERT INTO auth_v1.provider_configs(provider_config_id,provider_kind,exact_issuer,allowed_audiences,enabled,config_version) VALUES('retention-test','apple','https://test.invalid',ARRAY['test'],true,1)").execute(pool).await.unwrap();
    sqlx::query("INSERT INTO auth_v1.external_identities(identity_id,account_id,provider_config_id,exact_issuer,lookup_key_version,subject_lookup_hmac,state) VALUES($1,$2,'retention-test','https://test.invalid',1,$3,'active')").bind(identity).bind(account).bind(vec![2u8;32]).execute(pool).await.unwrap();
    sqlx::query("INSERT INTO auth_v1.provider_credentials(credential_id,identity_id,original_audience,vault_context,credential_generation,key_version,ciphertext,state) VALUES($1,$2,'test','test-context',1,1,$3,'active')").bind(Uuid::new_v4()).bind(identity).bind(vec![3u8;32]).execute(pool).await.unwrap();
    let r = Uuid::new_v4();
    let initial = change(pool, &p, "request", Some(r)).await.unwrap();
    assert_eq!(change(pool, &p, "request", Some(r)).await.unwrap(), initial);
    assert_eq!(sweep(pool).await.unwrap(), 0);
    let mut foreign = p.clone();
    foreign.account_id = AccountId::new(ctx.account_b.account_id.clone()).unwrap();
    assert!(change(pool, &foreign, "cancel", Some(r)).await.is_err());
    assert_eq!(
        change(pool, &p, "cancel", Some(r)).await.unwrap()["state"],
        "cancelled"
    );
    assert_eq!(
        change(pool, &p, "request", Some(r)).await.unwrap()["state"],
        "cancelled"
    );
    let r2 = Uuid::new_v4();
    change(pool, &p, "request", Some(r2)).await.unwrap();
    assert!(change(pool, &p, "request", Some(Uuid::new_v4()))
        .await
        .is_err());
    // Frozen boundary: due equality rejects cancellation, even before the worker.
    sqlx::query("UPDATE auth_v1.account_deletions SET requested_at=now()-interval '720 hours',delete_after=now() WHERE request_id=$1").bind(r2).execute(pool).await.unwrap();
    assert!(change(pool, &p, "cancel", Some(r2)).await.is_err());
    let other: i64 = sqlx::query_scalar("SELECT count(*) FROM sync_v2.works WHERE account_id=$1")
        .bind(&ctx.account_b.account_id)
        .fetch_one(pool)
        .await
        .unwrap();
    sqlx::raw_sql("CREATE FUNCTION public.retention_test_fault() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RAISE EXCEPTION 'synthetic deletion fault'; END $$; CREATE TRIGGER retention_test_fault BEFORE DELETE ON sync_v2.works FOR EACH ROW EXECUTE FUNCTION public.retention_test_fault();").execute(pool).await.unwrap();
    assert!(sweep(pool).await.is_err());
    let preserved: String =
        sqlx::query_scalar("SELECT state FROM auth_v1.accounts WHERE account_id=$1")
            .bind(account)
            .fetch_one(pool)
            .await
            .unwrap();
    assert_eq!(
        preserved, "active",
        "failure rolls back erasure and credential changes together"
    );
    sqlx::raw_sql("DROP TRIGGER retention_test_fault ON sync_v2.works; DROP FUNCTION public.retention_test_fault();").execute(pool).await.unwrap();
    let reconnect = sqlx::PgPool::connect(&url).await.unwrap();
    let (first, second) = tokio::join!(sweep(&reconnect), sweep(&reconnect));
    assert_eq!(first.unwrap() + second.unwrap(), 1);
    assert_eq!(sweep(&reconnect).await.unwrap(), 0);
    let own: i64 = sqlx::query_scalar("SELECT count(*) FROM sync_v2.works WHERE account_id=$1")
        .bind(account)
        .fetch_one(pool)
        .await
        .unwrap();
    assert_eq!(own, 0);
    let after: i64 = sqlx::query_scalar("SELECT count(*) FROM sync_v2.works WHERE account_id=$1")
        .bind(&ctx.account_b.account_id)
        .fetch_one(pool)
        .await
        .unwrap();
    assert_eq!(other, after);
    let blobs: i64=sqlx::query_scalar("SELECT count(*) FROM sync_v2.account_objects a LEFT JOIN sync_v2.global_blobs b USING(object_id) WHERE a.account_id=$1 AND b.object_id IS NULL").bind(&ctx.account_b.account_id).fetch_one(pool).await.unwrap();
    assert_eq!(blobs, 0);
    assert!(change(pool, &p, "request", Some(Uuid::new_v4()))
        .await
        .is_err());
    assert!(ctx
        .repo
        .delete_work(&ctx.account_a, Uuid::new_v4())
        .await
        .is_err());
    let retry: String =
        sqlx::query_scalar("SELECT state FROM auth_v1.provider_credentials WHERE identity_id=$1")
            .bind(identity)
            .fetch_one(pool)
            .await
            .unwrap();
    assert_eq!(retry, "revokeRetryPending");
    let pending: String =
        sqlx::query_scalar("SELECT state FROM auth_v1.account_deletions WHERE request_id=$1")
            .bind(r2)
            .fetch_one(pool)
            .await
            .unwrap();
    assert_eq!(
        pending, "pending",
        "remote erasure alone is not account-deletion completion"
    );
    sqlx::query("UPDATE auth_v1.provider_credentials SET state='revoked' WHERE identity_id=$1")
        .bind(identity)
        .execute(pool)
        .await
        .unwrap();
    sweep(pool).await.unwrap();
    let identities: i64 =
        sqlx::query_scalar("SELECT count(*) FROM auth_v1.external_identities WHERE identity_id=$1")
            .bind(identity)
            .fetch_one(pool)
            .await
            .unwrap();
    assert_eq!(identities, 0);
    let completed: String =
        sqlx::query_scalar("SELECT state FROM auth_v1.account_deletions WHERE request_id=$1")
            .bind(r2)
            .fetch_one(pool)
            .await
            .unwrap();
    assert_eq!(completed, "deleted");
    // Provider-only deletionPending never becomes an explicit deletion request.
    sqlx::query("UPDATE auth_v1.accounts SET state='deletionPending' WHERE account_id=$1")
        .bind(&ctx.account_b.account_id)
        .execute(pool)
        .await
        .unwrap();
    assert_eq!(sweep(pool).await.unwrap(), 0);
}
