//! Fresh-only v2 database bootstrap.
//!
//! This binary is intentionally a separate Compose one-shot service. The
//! bootstrap role is used only to create the two application roles and revoke
//! PUBLIC defaults. All schema DDL, SQLx bookkeeping, server_meta bootstrap,
//! and runtime grants run through the migration-owner role. An existing v2
//! database is read back without ALTER/GRANT; a missing or mismatched role
//! contract fails closed and requires an operator-managed upgrade.

use fuminiwa_sync_server_v2::postgres::{
    DatabaseIdentity, Repository, BOOTSTRAP_ADMIN_ROLE, BOOTSTRAP_ROLE,
    DATABASE_IDENTITY_LOCK_KEY_1, DATABASE_IDENTITY_LOCK_KEY_2, MIGRATION_OWNER_ROLE, RUNTIME_ROLE,
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
    for attempt in 0..2 {
        match run_once().await {
            Ok(()) => return Ok(()),
            Err(error)
                if attempt == 0
                    && error.to_string()
                        == "v2 temporary bootstrap authority was demoted; retrying permanent bootstrap" =>
            {
                continue;
            }
            Err(error) => return Err(error),
        }
    }
    unreachable!("the bounded migrator retry loop always returns");
}

async fn run_once() -> Result<()> {
    let server_instance_id = required("FUMINIWA_SERVER_INSTANCE_ID")?;
    let bootstrap_admin_user = required("FUMINIWA_SYNC_V2_BOOTSTRAP_ADMIN_USER")?;
    let bootstrap_user = required("FUMINIWA_SYNC_V2_BOOTSTRAP_USER")?;
    let migration_user = required("FUMINIWA_SYNC_V2_MIGRATION_USER")?;
    let runtime_user = required("FUMINIWA_SYNC_V2_RUNTIME_USER")?;
    if bootstrap_admin_user != BOOTSTRAP_ADMIN_ROLE
        || bootstrap_user != BOOTSTRAP_ROLE
        || migration_user != MIGRATION_OWNER_ROLE
        || runtime_user != RUNTIME_ROLE
    {
        return Err("v2 role names are fixed and must not be overridden".into());
    }

    let bootstrap_password_file = required("FUMINIWA_SYNC_V2_BOOTSTRAP_PASSWORD_FILE")?;
    let (authority_pool, authority_is_admin) =
        match connect(&bootstrap_user, &bootstrap_password_file).await {
            Ok(pool) => (pool, false),
            Err(_) => (
                connect(
                    &bootstrap_admin_user,
                    &required("FUMINIWA_SYNC_V2_BOOTSTRAP_ADMIN_PASSWORD_FILE")?,
                )
                .await?,
                true,
            ),
        };
    let mut authority = authority_pool.acquire().await?;
    let current_user: String = sqlx::query_scalar("SELECT current_user")
        .fetch_one(&mut *authority)
        .await?;
    if (authority_is_admin && current_user != bootstrap_admin_user)
        || (!authority_is_admin && current_user != bootstrap_user)
    {
        return Err("database authority connection has an unexpected role".into());
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
    let mut bootstrap_session = lock.acquire(&mut authority).await?;
    if authority_is_admin
        && !sqlx::query_scalar::<_, bool>(
            "SELECT current_setting('is_superuser') = 'on'
             AND COALESCE((SELECT rolsuper FROM pg_roles WHERE rolname=current_user), false)",
        )
        .fetch_one(&mut *bootstrap_session)
        .await?
    {
        // A loser can authenticate the temporary admin before the winner
        // hardens it while this connection waits on the lock. Never inspect
        // or mutate through that demoted backend; close it and let the
        // bounded outer retry reconnect as permanent bootstrap.
        drop(bootstrap_session);
        drop(authority);
        authority_pool.close().await;
        return Err(
            "v2 temporary bootstrap authority was demoted; retrying permanent bootstrap".into(),
        );
    }
    let identity =
        Repository::inspect_database_identity_on_connection(&mut bootstrap_session).await?;
    match identity {
        DatabaseIdentity::SnapshotSyncV2 => {
            // Never repair an existing volume implicitly. The only permitted
            // repeat is a pure read-back of the already-attested contract.
            if authority_is_admin {
                // A concurrent fresh migrator may have authenticated its
                // temporary-admin backend before the winner created and
                // hardened the permanent bootstrap role. PostgreSQL keeps
                // the authenticated superuser state on that backend, so do
                // not use it for any read-back after the lock is released.
                // Close the admin pool and establish a new non-superuser
                // bootstrap session before re-acquiring the deployment lock.
                drop(bootstrap_session);
                drop(authority);
                authority_pool.close().await;

                let permanent_pool = connect(&bootstrap_user, &bootstrap_password_file).await?;
                let mut permanent = permanent_pool.acquire().await?;
                let permanent_lock = lock.acquire(&mut permanent).await?;
                // The first permanent connection may have been established
                // while the winner was still changing the catalog. Close it
                // after taking the lock and reacquire a fresh backend so the
                // loser observes the committed role and ACL state only.
                drop(permanent_lock);
                drop(permanent);
                permanent_pool.close().await;
                let permanent_pool = connect(&bootstrap_user, &bootstrap_password_file).await?;
                let mut permanent = permanent_pool.acquire().await?;
                let mut permanent_lock = lock.acquire(&mut permanent).await?;
                let repeat_identity =
                    Repository::inspect_database_identity_on_connection(&mut permanent_lock)
                        .await?;
                if repeat_identity != DatabaseIdentity::SnapshotSyncV2 {
                    return Err("v2 database identity changed during repeat read-back".into());
                }
                attest_bootstrap_session(&mut permanent_lock).await?;
                attest_hardened_admin(&mut permanent_lock).await?;
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
            attest_bootstrap_session(&mut bootstrap_session).await?;
            attest_hardened_admin(&mut bootstrap_session).await?;
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
            if !authority_is_admin {
                return Err(
                    "fresh database has no permanent bootstrap authority; refusing repair".into(),
                );
            }
            // The official PostgreSQL image creates POSTGRES_USER as a
            // temporary superuser administrator. Accept that shape only for
            // this fresh, locked provisioning phase; it is hardened before
            // the process exits.
            attest_bootstrap_provisioning_session(&mut bootstrap_session, &bootstrap_admin_user)
                .await?;
        }
    }

    let role_count: i64 =
        sqlx::query_scalar("SELECT COUNT(*) FROM pg_roles WHERE rolname = ANY($1::text[])")
            .bind(vec![BOOTSTRAP_ROLE, MIGRATION_OWNER_ROLE, RUNTIME_ROLE])
            .fetch_one(&mut *bootstrap_session)
            .await?;
    if role_count != 0 {
        return Err("fresh v2 database has a partial role bootstrap; refusing repair".into());
    }
    let migration_password = read_secret("FUMINIWA_SYNC_V2_MIGRATION_PASSWORD_FILE")?;
    let runtime_password = read_secret("FUMINIWA_SYNC_V2_RUNTIME_PASSWORD_FILE")?;
    let bootstrap_password = read_secret("FUMINIWA_SYNC_V2_BOOTSTRAP_PASSWORD_FILE")?;

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
    create_login_role(&mut role_tx, BOOTSTRAP_ROLE, &bootstrap_password).await?;
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
    let alter_database_owner = format!("ALTER DATABASE \"{database}\" OWNER TO {bootstrap_user}");
    sqlx::query(&alter_database_owner)
        .execute(&mut *bootstrap_session)
        .await?;
    let owner_after_transfer: String = sqlx::query_scalar(
        "SELECT r.rolname
         FROM pg_database d
         JOIN pg_roles r ON r.oid=d.datdba
         WHERE d.datname=current_database()",
    )
    .fetch_one(&mut *bootstrap_session)
    .await?;
    if owner_after_transfer != bootstrap_user {
        return Err(format!(
            "v2 database owner transfer read-back mismatch: expected {bootstrap_user}, got {owner_after_transfer}"
        )
        .into());
    }
    let migration_pool = connect(
        MIGRATION_OWNER_ROLE,
        &required("FUMINIWA_SYNC_V2_MIGRATION_PASSWORD_FILE")?,
    )
    .await?;
    println!("v2 bootstrap stage=migrations");
    sqlx::migrate!("./migrations").run(&migration_pool).await?;
    println!("v2 bootstrap stage=server-meta");
    Repository::bootstrap_server_meta(&migration_pool, &server_instance_id).await?;
    println!("v2 bootstrap stage=runtime-grants");
    Repository::apply_runtime_grants(&migration_pool, RUNTIME_ROLE).await?;
    println!("v2 bootstrap stage=bootstrap-readback-grants");
    grant_bootstrap_readback(&migration_pool).await?;
    println!("v2 bootstrap stage=migration-attestation");
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
    println!("v2 bootstrap stage=runtime-attestation");
    Repository::verify_runtime_pool(&runtime_pool, &server_instance_id, RUNTIME_ROLE).await?;
    println!("v2 bootstrap stage=role-hardening");
    println!("v2 bootstrap stage=role-hardening-bootstrap-begin");
    // Keep the permanent bootstrap credential: it must be able to reconnect
    // after this session is closed and prove the hardened, non-superuser
    // contract.  Only the one-shot temporary administrator loses its
    // credential when it is disabled.
    harden_role(&mut bootstrap_session, BOOTSTRAP_ROLE, true, false).await?;
    println!("v2 bootstrap stage=role-hardening-bootstrap-done");
    harden_role(&mut bootstrap_session, BOOTSTRAP_ADMIN_ROLE, false, true).await?;
    println!("v2 bootstrap stage=role-hardening-admin-done");
    assert_temporary_admin_login_rejected(
        &bootstrap_admin_user,
        &required("FUMINIWA_SYNC_V2_BOOTSTRAP_ADMIN_PASSWORD_FILE")?,
    )
    .await?;
    drop(bootstrap_session);
    drop(authority);
    authority_pool.close().await;
    // Do not retain a pool that authenticated before role hardening: an
    // already-open PostgreSQL backend may retain superuser session state.
    let bootstrap_pool = connect(&bootstrap_user, &bootstrap_password_file).await?;
    let mut bootstrap = bootstrap_pool.acquire().await?;
    let mut bootstrap_lock = lock.acquire(&mut bootstrap).await?;
    println!("v2 bootstrap stage=final-bootstrap-attestation");
    attest_bootstrap_session(&mut bootstrap_lock).await?;
    println!("v2 bootstrap stage=final-admin-attestation");
    attest_hardened_admin(&mut bootstrap_lock).await?;
    println!("v2 bootstrap stage=final-identity-attestation");
    if Repository::inspect_database_identity_on_connection(&mut bootstrap_lock).await?
        != DatabaseIdentity::SnapshotSyncV2
    {
        return Err("final v2 role bootstrap identity read-back failed".into());
    }
    drop(bootstrap_lock);
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

async fn attest_bootstrap_provisioning_session(
    connection: &mut PgConnection,
    expected_user: &str,
) -> Result<()> {
    let role = sqlx::query(
        "SELECT current_user, r.rolsuper, r.rolcreaterole, r.rolcreatedb,
                r.rolcanlogin, r.rolinherit, r.rolreplication, r.rolbypassrls
         FROM pg_roles r WHERE r.rolname=current_user",
    )
    .fetch_one(&mut *connection)
    .await?;
    let current_user: String = role.try_get("current_user")?;
    if current_user != expected_user
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
    // The official OID-10 role owns a fresh database. The temporary admin is
    // intentionally a separate role; ownership is transferred to the
    // permanent bootstrap role after role creation and is attested there.
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

async fn harden_role(
    connection: &mut PgConnection,
    role: &str,
    login: bool,
    clear_password: bool,
) -> Result<()> {
    let login_clause = if login { "LOGIN" } else { "NOLOGIN" };
    let password_clause = if clear_password { " PASSWORD NULL" } else { "" };
    let statement: String = sqlx::query_scalar(
        "SELECT format(
            'ALTER ROLE %I NOSUPERUSER NOCREATEDB NOCREATEROLE %s NOINHERIT NOREPLICATION NOBYPASSRLS%s',
            $1, $2, $3
        )",
    )
    .bind(role)
    .bind(login_clause)
    .bind(password_clause)
    .fetch_one(&mut *connection)
    .await?;
    sqlx::query(&statement).execute(&mut *connection).await?;
    if clear_password {
        let clear_statement: String =
            sqlx::query_scalar("SELECT format('ALTER ROLE %I PASSWORD NULL', $1)")
                .bind(role)
                .fetch_one(&mut *connection)
                .await?;
        sqlx::query(&clear_statement)
            .execute(&mut *connection)
            .await?;
    }
    Ok(())
}

async fn grant_bootstrap_readback(pool: &PgPool) -> Result<()> {
    for schema in ["auth_v1", "sync_v2"] {
        let revoke = format!("REVOKE ALL ON SCHEMA {schema} FROM {BOOTSTRAP_ROLE}");
        sqlx::query(&revoke).execute(pool).await?;
        let grant = format!("GRANT USAGE ON SCHEMA {schema} TO {BOOTSTRAP_ROLE}");
        sqlx::query(&grant).execute(pool).await?;
    }
    for table in [
        "sync_v2.server_meta",
        "sync_v2.deployment_binding",
        "auth_v1.accounts",
        "auth_v1.external_identities",
        "auth_v1.auth_sessions",
    ] {
        let revoke = format!("REVOKE ALL ON TABLE {table} FROM {BOOTSTRAP_ROLE}");
        sqlx::query(&revoke).execute(pool).await?;
        let grant = format!("GRANT SELECT ON TABLE {table} TO {BOOTSTRAP_ROLE}");
        sqlx::query(&grant).execute(pool).await?;
    }
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
    for schema in ["auth_v1", "sync_v2"] {
        let allowed: bool =
            sqlx::query_scalar("SELECT has_schema_privilege(current_user,$1,'USAGE')")
                .bind(schema)
                .fetch_one(&mut *connection)
                .await?;
        if !allowed {
            let current_user: String = sqlx::query_scalar("SELECT current_user")
                .fetch_one(&mut *connection)
                .await?;
            return Err(format!(
                "v2 bootstrap role lacks schema USAGE: {schema} (current_user={current_user})"
            )
            .into());
        }
    }
    for table in [
        "sync_v2.server_meta",
        "sync_v2.deployment_binding",
        "auth_v1.accounts",
        "auth_v1.external_identities",
        "auth_v1.auth_sessions",
    ] {
        let allowed: bool =
            sqlx::query_scalar("SELECT has_table_privilege(current_user,$1,'SELECT')")
                .bind(table)
                .fetch_one(&mut *connection)
                .await?;
        if !allowed {
            return Err(format!("v2 bootstrap role lacks metadata SELECT: {table}").into());
        }
    }
    Ok(())
}

async fn attest_hardened_admin(connection: &mut PgConnection) -> Result<()> {
    let row = sqlx::query(
        "SELECT rolsuper, rolcreatedb, rolcreaterole, rolcanlogin,
                rolinherit, rolreplication, rolbypassrls
         FROM pg_roles WHERE rolname=$1",
    )
    .bind(BOOTSTRAP_ADMIN_ROLE)
    .fetch_one(&mut *connection)
    .await?;
    let superuser = row.try_get::<bool, _>("rolsuper")?;
    let createdb = row.try_get::<bool, _>("rolcreatedb")?;
    let createrole = row.try_get::<bool, _>("rolcreaterole")?;
    let can_login = row.try_get::<bool, _>("rolcanlogin")?;
    let inherit = row.try_get::<bool, _>("rolinherit")?;
    let replication = row.try_get::<bool, _>("rolreplication")?;
    let bypass_rls = row.try_get::<bool, _>("rolbypassrls")?;
    if superuser || createdb || createrole || can_login || inherit || replication || bypass_rls {
        return Err(format!(
            "v2 bootstrap admin role flags are not hardened: superuser={superuser} createdb={createdb} createrole={createrole} login={can_login} inherit={inherit} replication={replication} bypassrls={bypass_rls}"
        ).into());
    }
    Ok(())
}

async fn assert_temporary_admin_login_rejected(role: &str, password_file: &str) -> Result<()> {
    if let Ok(pool) = connect(role, password_file).await {
        pool.close().await;
        return Err("v2 bootstrap admin login remained possible after hardening".into());
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
