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
    Acquire, PgConnection, PgPool, Row,
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
    let mut admin = admin_pool.acquire().await?;
    let current_user: String = sqlx::query_scalar("SELECT current_user")
        .fetch_one(&mut *admin)
        .await?;
    if current_user != BOOTSTRAP_ROLE {
        return Err("database bootstrap connection is not the v2 bootstrap role".into());
    }
    let lock =
        sqlx::postgres::PgAdvisoryLock::with_key(sqlx::postgres::PgAdvisoryLockKey::IntPair(
            DATABASE_IDENTITY_LOCK_KEY_1,
            DATABASE_IDENTITY_LOCK_KEY_2,
        ));
    // Keep this bootstrap session and lock alive through role creation,
    // migration-owner DDL, runtime grants, and both final attestations. The
    // migration connection deliberately does not acquire this lock: the
    // bootstrap session is the single deployment-wide serialization point.
    let mut bootstrap_session = lock.acquire(&mut admin).await?;
    let identity =
        Repository::inspect_database_identity_on_connection(&mut bootstrap_session).await?;
    match identity {
        DatabaseIdentity::SnapshotSyncV2 => {
            // Never repair an existing volume implicitly. The only permitted
            // repeat is a pure read-back of the already-attested contract.
            attest_bootstrap_session(&mut bootstrap_session).await?;
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
            if Repository::inspect_database_identity_on_connection(&mut bootstrap_session).await?
                != DatabaseIdentity::SnapshotSyncV2
            {
                return Err("v2 role bootstrap read-back changed the database identity".into());
            }
            println!("Snapshot Sync v2 role bootstrap already attested; no changes made");
            return Ok(());
        }
        DatabaseIdentity::Fresh => {
            // The official PostgreSQL image creates POSTGRES_USER as a
            // temporary superuser administrator. Accept that shape only for
            // this fresh, locked provisioning phase; it is hardened before
            // the process exits.
            attest_bootstrap_provisioning_session(&mut bootstrap_session).await?;
        }
    }

    let role_count: i64 =
        sqlx::query_scalar("SELECT COUNT(*) FROM pg_roles WHERE rolname = ANY($1::text[])")
            .bind(vec![MIGRATION_OWNER_ROLE, RUNTIME_ROLE])
            .fetch_one(&mut *bootstrap_session)
            .await?;
    if role_count != 0 {
        return Err("fresh v2 database has a partial role bootstrap; refusing repair".into());
    }
    let migration_password = read_secret("FUMINIWA_SYNC_V2_MIGRATION_PASSWORD_FILE")?;
    let runtime_password = read_secret("FUMINIWA_SYNC_V2_RUNTIME_PASSWORD_FILE")?;

    // Re-check under the same locked bootstrap session before creating either
    // role; no pool checkout can bypass this TOCTOU boundary.
    if Repository::inspect_database_identity_on_connection(&mut bootstrap_session).await?
        != DatabaseIdentity::Fresh
    {
        return Err("v2 database changed during bootstrap preflight".into());
    }
    let database = required("FUMINIWA_SYNC_V2_POSTGRES_DB")?;
    validate_database_name(&database)?;
    let mut role_tx = (&mut *bootstrap_session).begin().await?;
    create_login_role(&mut role_tx, MIGRATION_OWNER_ROLE, &migration_password).await?;
    create_login_role(&mut role_tx, RUNTIME_ROLE, &runtime_password).await?;
    let revoke_public_database =
        format!("REVOKE CREATE, TEMPORARY ON DATABASE \"{database}\" FROM PUBLIC");
    sqlx::query(&revoke_public_database)
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
    let revoke_public_runtime = format!("REVOKE CREATE ON SCHEMA public FROM {runtime_user}");
    sqlx::query(&revoke_public_runtime)
        .execute(&mut *role_tx)
        .await?;
    sqlx::query("GRANT USAGE, CREATE ON SCHEMA public TO fuminiwa_sync_v2_migrator")
        .execute(&mut *role_tx)
        .await?;
    role_tx.commit().await?;

    let migration_pool = connect(
        MIGRATION_OWNER_ROLE,
        &required("FUMINIWA_SYNC_V2_MIGRATION_PASSWORD_FILE")?,
    )
    .await?;
    sqlx::migrate!("./migrations").run(&migration_pool).await?;
    Repository::bootstrap_server_meta(&migration_pool, &server_instance_id).await?;
    Repository::apply_runtime_grants(&migration_pool, RUNTIME_ROLE).await?;
    Repository::verify_migration_owner_attestation(&migration_pool).await?;
    if Repository::inspect_database_identity_on_connection(&mut bootstrap_session).await?
        != DatabaseIdentity::SnapshotSyncV2
    {
        return Err("migration owner did not produce the exact v2 database contract".into());
    }

    let runtime_pool = connect(
        RUNTIME_ROLE,
        &required("FUMINIWA_SYNC_V2_RUNTIME_PASSWORD_FILE")?,
    )
    .await?;
    Repository::verify_runtime_pool(&runtime_pool, &server_instance_id, RUNTIME_ROLE).await?;
    harden_bootstrap_role(&mut bootstrap_session).await?;
    attest_bootstrap_session(&mut bootstrap_session).await?;
    if Repository::inspect_database_identity_on_connection(&mut bootstrap_session).await?
        != DatabaseIdentity::SnapshotSyncV2
    {
        return Err("final v2 role bootstrap identity read-back failed".into());
    }
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

async fn attest_bootstrap_provisioning_session(connection: &mut PgConnection) -> Result<()> {
    let role = sqlx::query(
        "SELECT current_user, r.rolsuper, r.rolcreaterole, r.rolcreatedb,
                r.rolcanlogin, r.rolinherit, r.rolreplication, r.rolbypassrls
         FROM pg_roles r WHERE r.rolname=current_user",
    )
    .fetch_one(&mut *connection)
    .await?;
    let current_user: String = role.try_get("current_user")?;
    if current_user != BOOTSTRAP_ROLE
        || !role.try_get::<bool, _>("rolsuper")?
        || !role.try_get::<bool, _>("rolcreaterole")?
        || !role.try_get::<bool, _>("rolcreatedb")?
        || !role.try_get::<bool, _>("rolcanlogin")?
        || !role.try_get::<bool, _>("rolinherit")?
        || !role.try_get::<bool, _>("rolreplication")?
        || !role.try_get::<bool, _>("rolbypassrls")?
    {
        return Err("v2 bootstrap role flags are not exact".into());
    }
    let is_database_owner: bool = sqlx::query_scalar(
        "SELECT d.datdba = r.oid
         FROM pg_database d
         JOIN pg_roles r ON r.oid=d.datdba
         WHERE d.datname=current_database() AND r.rolname=current_user",
    )
    .fetch_optional(&mut *connection)
    .await?
    .unwrap_or(false);
    if !is_database_owner {
        return Err("v2 bootstrap role must own the target database".into());
    }
    for privilege in ["CONNECT", "CREATE"] {
        let allowed: bool =
            sqlx::query_scalar("SELECT has_database_privilege(current_user,current_database(),$1)")
                .bind(privilege)
                .fetch_one(&mut *connection)
                .await?;
        if !allowed {
            return Err(format!("v2 bootstrap role lacks database {privilege}").into());
        }
    }
    Ok(())
}

async fn harden_bootstrap_role(connection: &mut PgConnection) -> Result<()> {
    sqlx::query(
        "ALTER ROLE fuminiwa_sync_v2_bootstrap
         NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT NOREPLICATION NOBYPASSRLS",
    )
    .execute(&mut *connection)
    .await?;
    Ok(())
}

async fn attest_bootstrap_session(connection: &mut PgConnection) -> Result<()> {
    let role = sqlx::query(
        "SELECT current_user, r.rolsuper, r.rolcreaterole, r.rolcreatedb,
                r.rolcanlogin, r.rolinherit, r.rolreplication, r.rolbypassrls
         FROM pg_roles r WHERE r.rolname=current_user",
    )
    .fetch_one(&mut *connection)
    .await?;
    let current_user: String = role.try_get("current_user")?;
    if current_user != BOOTSTRAP_ROLE
        || role.try_get::<bool, _>("rolsuper")?
        || role.try_get::<bool, _>("rolcreaterole")?
        || role.try_get::<bool, _>("rolcreatedb")?
        || !role.try_get::<bool, _>("rolcanlogin")?
        || role.try_get::<bool, _>("rolinherit")?
        || role.try_get::<bool, _>("rolreplication")?
        || role.try_get::<bool, _>("rolbypassrls")?
    {
        return Err("v2 bootstrap role flags are not hardened".into());
    }
    let is_database_owner: bool = sqlx::query_scalar(
        "SELECT d.datdba = r.oid
         FROM pg_database d
         JOIN pg_roles r ON r.oid=d.datdba
         WHERE d.datname=current_database() AND r.rolname=current_user",
    )
    .fetch_optional(&mut *connection)
    .await?
    .unwrap_or(false);
    if !is_database_owner {
        return Err("v2 bootstrap role must own the target database".into());
    }
    for privilege in ["CONNECT", "CREATE"] {
        let allowed: bool =
            sqlx::query_scalar("SELECT has_database_privilege(current_user,current_database(),$1)")
                .bind(privilege)
                .fetch_one(&mut *connection)
                .await?;
        if !allowed {
            return Err(format!("v2 bootstrap role lacks database {privilege}").into());
        }
    }
    Ok(())
}

fn validate_database_name(database: &str) -> Result<()> {
    if database.is_empty()
        || database.len() > 63
        || !database.bytes().all(|byte| {
            byte.is_ascii_lowercase() || byte.is_ascii_digit() || byte == b'_' || byte == b'-'
        })
    {
        return Err("v2 database name must be a lowercase PostgreSQL identifier".into());
    }
    Ok(())
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
