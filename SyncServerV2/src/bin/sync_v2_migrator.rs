//! Fresh-only v2 database bootstrap.
//!
//! This binary is intentionally a separate Compose one-shot service. The
//! bootstrap role is used only to create the two application roles and revoke
//! PUBLIC defaults. All schema DDL, SQLx bookkeeping, server_meta bootstrap,
//! and runtime grants run through the migration-owner role. An existing v2
//! database is read back without ALTER/GRANT; a missing or mismatched role
//! contract fails closed and requires an operator-managed upgrade.

use fuminiwa_sync_server_v2::postgres::{
    DatabaseIdentity, Repository, BOOTSTRAP_ROLE, DATABASE_IDENTITY_LOCK_KEY_1,
    DATABASE_IDENTITY_LOCK_KEY_2, MIGRATION_OWNER_ROLE, RUNTIME_ROLE,
};
use sqlx::{
    postgres::{PgConnectOptions, PgPoolOptions},
    PgPool,
};
use std::{env, error::Error, fs};

type Result<T> = std::result::Result<T, Box<dyn Error>>;

#[tokio::main]
async fn main() -> Result<()> {
    tracing_subscriber::fmt::init();
    let server_instance_id = required("FUMINIWA_SERVER_INSTANCE_ID")?;
    let bootstrap_user = required("FUMINIWA_SYNC_V2_BOOTSTRAP_USER")?;
    let migration_user = required("FUMINIWA_SYNC_V2_MIGRATION_USER")?;
    let runtime_user = required("FUMINIWA_SYNC_V2_RUNTIME_USER")?;
    if bootstrap_user != BOOTSTRAP_ROLE
        || migration_user != MIGRATION_OWNER_ROLE
        || runtime_user != RUNTIME_ROLE
    {
        return Err("v2 role names are fixed and must not be overridden".into());
    }

    let admin_pool = connect(
        &bootstrap_user,
        &required("FUMINIWA_SYNC_V2_BOOTSTRAP_PASSWORD_FILE")?,
    )
    .await?;
    let current_user: String = sqlx::query_scalar("SELECT current_user")
        .fetch_one(&admin_pool)
        .await?;
    if current_user != BOOTSTRAP_ROLE {
        return Err("database bootstrap connection is not the v2 bootstrap role".into());
    }
    let identity = Repository::inspect_database_identity(&admin_pool).await?;
    match identity {
        DatabaseIdentity::SnapshotSyncV2 => {
            // Never repair an existing volume implicitly. The only permitted
            // repeat is a pure read-back of the already-attested contract.
            let runtime_pool = connect(
                &runtime_user,
                &required("FUMINIWA_SYNC_V2_RUNTIME_PASSWORD_FILE")?,
            )
            .await?;
            let migration_pool = connect(
                &migration_user,
                &required("FUMINIWA_SYNC_V2_MIGRATION_PASSWORD_FILE")?,
            )
            .await?;
            Repository::verify_migration_owner_attestation(&migration_pool).await?;
            Repository::verify_runtime_pool(&runtime_pool, &server_instance_id, RUNTIME_ROLE)
                .await?;
            println!("Snapshot Sync v2 role bootstrap already attested; no changes made");
            return Ok(());
        }
        DatabaseIdentity::Fresh => {}
    }

    let role_count: i64 =
        sqlx::query_scalar("SELECT COUNT(*) FROM pg_roles WHERE rolname = ANY($1::text[])")
            .bind(vec![MIGRATION_OWNER_ROLE, RUNTIME_ROLE])
            .fetch_one(&admin_pool)
            .await?;
    if role_count != 0 {
        return Err("fresh v2 database has a partial role bootstrap; refusing repair".into());
    }
    let migration_password = read_secret("FUMINIWA_SYNC_V2_MIGRATION_PASSWORD_FILE")?;
    let runtime_password = read_secret("FUMINIWA_SYNC_V2_RUNTIME_PASSWORD_FILE")?;

    let mut admin = admin_pool.acquire().await?;
    let lock =
        sqlx::postgres::PgAdvisoryLock::with_key(sqlx::postgres::PgAdvisoryLockKey::IntPair(
            DATABASE_IDENTITY_LOCK_KEY_1,
            DATABASE_IDENTITY_LOCK_KEY_2,
        ));
    let _lock_guard = lock.acquire(&mut admin).await?;
    // Re-check under the deployment-wide lock before creating either role.
    if Repository::inspect_database_identity(&admin_pool).await? != DatabaseIdentity::Fresh {
        return Err("v2 database changed during bootstrap preflight".into());
    }
    let database = required("FUMINIWA_SYNC_V2_POSTGRES_DB")?;
    if database != "fuminiwa_sync_v2" {
        return Err("v2 bootstrap refuses a database outside fuminiwa_sync_v2".into());
    }
    let mut role_tx = admin_pool.begin().await?;
    create_login_role(&mut role_tx, MIGRATION_OWNER_ROLE, &migration_password).await?;
    create_login_role(&mut role_tx, RUNTIME_ROLE, &runtime_password).await?;
    sqlx::query("REVOKE CREATE, TEMPORARY ON DATABASE \"fuminiwa_sync_v2\" FROM PUBLIC")
        .execute(&mut *role_tx)
        .await?;
    let revoke_database =
        format!("REVOKE CREATE, TEMPORARY ON DATABASE \"{database}\" FROM {runtime_user}");
    sqlx::query(&revoke_database).execute(&mut *role_tx).await?;
    let grant_migration_database =
        format!("GRANT CONNECT, CREATE ON DATABASE \"{database}\" TO {migration_user}");
    sqlx::query(&grant_migration_database)
        .execute(&mut *role_tx)
        .await?;
    let grant_runtime_database =
        format!("GRANT CONNECT ON DATABASE \"{database}\" TO {runtime_user}");
    sqlx::query(&grant_runtime_database)
        .execute(&mut *role_tx)
        .await?;
    sqlx::query("REVOKE CREATE ON SCHEMA public FROM PUBLIC")
        .execute(&mut *role_tx)
        .await?;
    sqlx::query("GRANT USAGE, CREATE ON SCHEMA public TO fuminiwa_sync_v2_migrator")
        .execute(&mut *role_tx)
        .await?;
    role_tx.commit().await?;
    drop(_lock_guard);
    drop(admin);
    drop(admin_pool);

    let migration_pool = connect(
        MIGRATION_OWNER_ROLE,
        &required("FUMINIWA_SYNC_V2_MIGRATION_PASSWORD_FILE")?,
    )
    .await?;
    let mut migration_connection = migration_pool.acquire().await?;
    let migration_lock =
        sqlx::postgres::PgAdvisoryLock::with_key(sqlx::postgres::PgAdvisoryLockKey::IntPair(
            DATABASE_IDENTITY_LOCK_KEY_1,
            DATABASE_IDENTITY_LOCK_KEY_2,
        ));
    let _migration_lock = migration_lock.acquire(&mut migration_connection).await?;
    sqlx::migrate!("./migrations").run(&migration_pool).await?;
    Repository::bootstrap_server_meta(&migration_pool, &server_instance_id).await?;
    Repository::apply_runtime_grants(&migration_pool, RUNTIME_ROLE).await?;
    Repository::verify_migration_owner_attestation(&migration_pool).await?;
    if Repository::inspect_database_identity(&migration_pool).await?
        != DatabaseIdentity::SnapshotSyncV2
    {
        return Err("migration owner did not produce the exact v2 database contract".into());
    }
    drop(_migration_lock);
    drop(migration_connection);
    drop(migration_pool);

    let runtime_pool = connect(
        RUNTIME_ROLE,
        &required("FUMINIWA_SYNC_V2_RUNTIME_PASSWORD_FILE")?,
    )
    .await?;
    Repository::verify_runtime_pool(&runtime_pool, &server_instance_id, RUNTIME_ROLE).await?;
    println!("Snapshot Sync v2 fresh bootstrap and runtime ACL attestation passed");
    Ok(())
}

async fn create_login_role(
    tx: &mut sqlx::Transaction<'_, sqlx::Postgres>,
    role: &str,
    password: &str,
) -> Result<()> {
    let statement: String =
        sqlx::query_scalar("SELECT format('CREATE ROLE %I LOGIN PASSWORD %L', $1, $2)")
            .bind(role)
            .bind(password)
            .fetch_one(&mut **tx)
            .await?;
    sqlx::query(&statement).execute(&mut **tx).await?;
    Ok(())
}

async fn connect(role: &str, password_file: &str) -> Result<PgPool> {
    let password = read_secret_path(password_file)?;
    let host = env::var("FUMINIWA_SYNC_V2_POSTGRES_HOST").unwrap_or_else(|_| "postgres".into());
    let port = env::var("FUMINIWA_SYNC_V2_POSTGRES_PORT")
        .unwrap_or_else(|_| "5432".into())
        .parse::<u16>()?;
    let database = required("FUMINIWA_SYNC_V2_POSTGRES_DB")?;
    let options = PgConnectOptions::new()
        .host(&host)
        .port(port)
        .database(&database)
        .username(role)
        .password(&password);
    Ok(PgPoolOptions::new()
        .max_connections(4)
        .connect_with(options)
        .await?)
}

fn required(name: &str) -> Result<String> {
    env::var(name).map_err(|_| format!("{name} is required").into())
}

fn read_secret(name: &str) -> Result<String> {
    read_secret_path(&required(name)?)
}

fn read_secret_path(path: &str) -> Result<String> {
    let value = fs::read_to_string(path)?
        .trim_end_matches(['\r', '\n'])
        .to_string();
    if value.is_empty() {
        return Err("v2 database secret file is empty".into());
    }
    Ok(value)
}
