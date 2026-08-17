//! Opt-in PostgreSQL gate for the fresh v2 role split.
//!
//! This runner never creates or drops a database, volume, schema, or role.
//! The operator provisions three disposable databases (fresh, unknown-object,
//! and legacy-single-role) and supplies only password-file paths. The runner
//! invokes the checked-in one-shot migrator, then verifies the positive DML
//! surface, negative DDL/ACL surface, idempotent repeat, concurrent convergence,
//! and fail-closed unchanged rejection paths.

use fuminiwa_sync_server_v2::postgres::{
    DatabaseIdentity, Repository, BOOTSTRAP_ROLE, MIGRATION_OWNER_ROLE, RUNTIME_ROLE,
};
use sqlx::{
    postgres::{PgConnectOptions, PgPoolOptions},
    PgPool,
};
use std::{
    env,
    error::Error,
    net::IpAddr,
    path::{Path, PathBuf},
    process::Stdio,
    str::FromStr,
};
use tokio::process::Command;
use uuid::Uuid;

type Result<T> = std::result::Result<T, Box<dyn Error>>;

const FRESH_URL: &str = "FUMINIWA_V2_ROLE_SPLIT_TEST_DATABASE_URL";
const UNKNOWN_URL: &str = "FUMINIWA_V2_ROLE_SPLIT_UNKNOWN_DATABASE_URL";
const LEGACY_URL: &str = "FUMINIWA_V2_ROLE_SPLIT_SINGLE_ROLE_DATABASE_URL";
const SERVER_INSTANCE: &str = "FUMINIWA_V2_ROLE_SPLIT_SERVER_INSTANCE_ID";
const BOOTSTRAP_PASSWORD: &str = "FUMINIWA_V2_ROLE_SPLIT_BOOTSTRAP_PASSWORD_FILE";
const MIGRATION_PASSWORD: &str = "FUMINIWA_V2_ROLE_SPLIT_MIGRATION_PASSWORD_FILE";
const RUNTIME_PASSWORD: &str = "FUMINIWA_V2_ROLE_SPLIT_RUNTIME_PASSWORD_FILE";

#[derive(Clone)]
struct Target {
    options: PgConnectOptions,
    identity: String,
}

#[derive(Debug, Eq, PartialEq)]
struct ConnectedTargetIdentity {
    database: String,
    server_address: String,
    server_port: i32,
}

#[derive(Clone)]
struct Config {
    fresh: Target,
    unknown: Target,
    legacy: Target,
    server_instance: String,
    bootstrap_password: String,
    migration_password: String,
    runtime_password: String,
    migrator: PathBuf,
}

#[tokio::main]
async fn main() {
    match run().await {
        Ok(()) => println!("Snapshot Sync v2 role-split PostgreSQL gate passed"),
        Err(error) => {
            eprintln!("NO-GO: {error}");
            std::process::exit(1);
        }
    }
}

async fn run() -> Result<()> {
    let config = match Config::from_environment() {
        Ok(config) => config,
        Err(error) if error.to_string().starts_with("missing ") => {
            eprintln!("NO-GO: {error}");
            std::process::exit(2);
        }
        Err(error) => return Err(error),
    };

    assert_distinct_targets(&config)?;
    let fresh_bootstrap =
        connect_target(&config.fresh, BOOTSTRAP_ROLE, &config.bootstrap_password).await?;
    let unknown_bootstrap =
        connect_target(&config.unknown, BOOTSTRAP_ROLE, &config.bootstrap_password).await?;
    let legacy_bootstrap =
        connect_target(&config.legacy, BOOTSTRAP_ROLE, &config.bootstrap_password).await?;
    assert_distinct_connected_targets(&[&fresh_bootstrap, &unknown_bootstrap, &legacy_bootstrap])
        .await?;
    if Repository::inspect_database_identity(&fresh_bootstrap).await? != DatabaseIdentity::Fresh {
        return Err("fresh role-split test database is not empty".into());
    }

    run_concurrent_migrators(&config, &config.fresh).await?;
    let runtime = connect_target(&config.fresh, RUNTIME_ROLE, &config.runtime_password).await?;
    let migration = connect_target(
        &config.fresh,
        MIGRATION_OWNER_ROLE,
        &config.migration_password,
    )
    .await?;
    Repository::verify_migration_owner_attestation(&migration).await?;
    Repository::verify_runtime_pool(&runtime, &config.server_instance, RUNTIME_ROLE).await?;
    exercise_runtime_dml(&runtime).await?;
    exercise_runtime_denials(&runtime).await?;

    let repeat_before = catalog_fingerprint(&fresh_bootstrap).await?;
    run_migrator(&config, &config.fresh).await?;
    let repeat_after = catalog_fingerprint(&fresh_bootstrap).await?;
    if repeat_before != repeat_after {
        return Err("repeat migrator changed the already-attested v2 database".into());
    }

    verify_unknown_database_rejection(&config, &unknown_bootstrap).await?;
    verify_legacy_database_rejection(&config, &legacy_bootstrap).await?;
    Ok(())
}

impl Config {
    fn from_environment() -> Result<Self> {
        let fresh = target(FRESH_URL)?;
        let unknown = target(UNKNOWN_URL)?;
        let legacy = target(LEGACY_URL)?;
        let server_instance = required(SERVER_INSTANCE)?;
        let bootstrap_password = required(BOOTSTRAP_PASSWORD)?;
        let migration_password = required(MIGRATION_PASSWORD)?;
        let runtime_password = required(RUNTIME_PASSWORD)?;
        let migrator = env::var("FUMINIWA_V2_MIGRATOR_BIN")
            .map(PathBuf::from)
            .unwrap_or_else(|_| {
                env::current_exe()
                    .ok()
                    .and_then(|path| path.parent().map(Path::to_path_buf))
                    .map(|dir| dir.join("sync_v2_migrator"))
                    .unwrap_or_else(|| PathBuf::from("sync_v2_migrator"))
            });
        if !migrator.is_file() {
            return Err(
                "migrator executable is missing: set FUMINIWA_V2_MIGRATOR_BIN or build sync_v2_migrator"
                    .to_string()
                    .into(),
            );
        }
        Ok(Self {
            fresh,
            unknown,
            legacy,
            server_instance,
            bootstrap_password,
            migration_password,
            runtime_password,
            migrator,
        })
    }
}

fn target(name: &str) -> Result<Target> {
    let url = required(name)?;
    parse_target(name, &url)
}

fn parse_target(name: &str, url: &str) -> Result<Target> {
    let options = PgConnectOptions::from_str(url)
        .map_err(|error| format!("{name} is not a valid PostgreSQL URL: {error}"))?;
    let database = options
        .get_database()
        .ok_or_else(|| format!("{name} must include a database name"))?;
    if !database.starts_with("fuminiwa_v2_role_split_test_") {
        return Err(
            format!("{name} must use a disposable fuminiwa_v2_role_split_test_* database").into(),
        );
    }
    let identity = canonical_target_identity(&options)?;
    Ok(Target { options, identity })
}

fn required(name: &str) -> Result<String> {
    env::var(name).map_err(|_| format!("missing {name}").into())
}

fn assert_distinct_targets(config: &Config) -> Result<()> {
    let targets = [&config.fresh, &config.unknown, &config.legacy];
    for (index, left) in targets.iter().enumerate() {
        for right in targets.iter().skip(index + 1) {
            if left.identity == right.identity {
                return Err(
                    "NO-GO: role-split gate targets must use distinct host/port/database endpoints"
                        .into(),
                );
            }
        }
    }
    Ok(())
}

fn canonical_target_identity(options: &PgConnectOptions) -> Result<String> {
    let transport = if let Some(socket) = options.get_socket() {
        format!("unix:{}", socket.to_string_lossy())
    } else {
        let host = options
            .get_host()
            .trim_end_matches('.')
            .to_ascii_lowercase();
        let host = match host.as_str() {
            "localhost" | "localhost.localdomain" => "127.0.0.1".to_owned(),
            _ => host
                .parse::<IpAddr>()
                .map(|address| address.to_string())
                .unwrap_or(host),
        };
        format!("tcp:{host}")
    };
    let database = options
        .get_database()
        .ok_or("role-split target must include a database name")?;
    Ok(format!("{transport}:{}:{database}", options.get_port()))
}

async fn connect_target(target: &Target, role: &str, password_file: &str) -> Result<PgPool> {
    let password = std::fs::read_to_string(password_file)?;
    let password = password.trim_end_matches(['\r', '\n']);
    if password.is_empty() {
        return Err(format!("password file for {role} is empty").into());
    }
    let options = target.options.clone().username(role).password(password);
    Ok(PgPoolOptions::new()
        .max_connections(8)
        .connect_with(options)
        .await?)
}

async fn assert_distinct_connected_targets(pools: &[&PgPool]) -> Result<()> {
    let mut identities = Vec::with_capacity(pools.len());
    for pool in pools {
        identities.push(connected_target_identity(pool).await?);
    }
    for (index, left) in identities.iter().enumerate() {
        if identities.iter().skip(index + 1).any(|right| right == left) {
            return Err(
                "NO-GO: role-split gate targets resolve to the same PostgreSQL database/server"
                    .into(),
            );
        }
    }
    Ok(())
}

async fn connected_target_identity(pool: &PgPool) -> Result<ConnectedTargetIdentity> {
    let row = sqlx::query_as::<_, (String, String, i32)>(
        "SELECT current_database(),
                COALESCE(inet_server_addr()::TEXT, 'unix'),
                COALESCE(inet_server_port(), current_setting('port')::INTEGER)",
    )
    .fetch_one(pool)
    .await?;
    Ok(ConnectedTargetIdentity {
        database: row.0,
        server_address: row.1,
        server_port: row.2,
    })
}

fn child_environment(config: &Config, target: &Target) -> Result<Vec<(String, String)>> {
    let database = target
        .options
        .get_database()
        .ok_or("test target has no database name")?;
    Ok(vec![
        (
            "FUMINIWA_SERVER_INSTANCE_ID".into(),
            config.server_instance.clone(),
        ),
        (
            "FUMINIWA_SYNC_V2_POSTGRES_HOST".into(),
            target
                .options
                .get_socket()
                .map(|socket| socket.to_string_lossy().into_owned())
                .unwrap_or_else(|| target.options.get_host().into()),
        ),
        (
            "FUMINIWA_SYNC_V2_POSTGRES_PORT".into(),
            target.options.get_port().to_string(),
        ),
        ("FUMINIWA_SYNC_V2_POSTGRES_DB".into(), database.into()),
        (
            "FUMINIWA_SYNC_V2_BOOTSTRAP_USER".into(),
            BOOTSTRAP_ROLE.into(),
        ),
        (
            "FUMINIWA_SYNC_V2_BOOTSTRAP_PASSWORD_FILE".into(),
            config.bootstrap_password.clone(),
        ),
        (
            "FUMINIWA_SYNC_V2_MIGRATION_USER".into(),
            MIGRATION_OWNER_ROLE.into(),
        ),
        (
            "FUMINIWA_SYNC_V2_MIGRATION_PASSWORD_FILE".into(),
            config.migration_password.clone(),
        ),
        ("FUMINIWA_SYNC_V2_RUNTIME_USER".into(), RUNTIME_ROLE.into()),
        (
            "FUMINIWA_SYNC_V2_RUNTIME_PASSWORD_FILE".into(),
            config.runtime_password.clone(),
        ),
    ])
}

async fn run_concurrent_migrators(config: &Config, target: &Target) -> Result<()> {
    let left = run_migrator_child(config, target)?;
    let right = run_migrator_child(config, target)?;
    let (left, right) = tokio::join!(left, right);
    let left = left?;
    let right = right?;
    if !left.success() || !right.success() {
        return Err(format!(
            "concurrent migrator processes did not converge: left={left}, right={right}"
        )
        .into());
    }
    Ok(())
}

async fn run_migrator(config: &Config, target: &Target) -> Result<()> {
    let status = run_migrator_child(config, target)?.await?;
    if !status.success() {
        return Err(format!("migrator rejected an expected v2 target: {status}").into());
    }
    Ok(())
}

fn run_migrator_child(
    config: &Config,
    target: &Target,
) -> Result<impl std::future::Future<Output = std::io::Result<std::process::ExitStatus>>> {
    let environment = child_environment(config, target)?;
    let mut command = Command::new(&config.migrator);
    command
        .stdin(Stdio::null())
        .stdout(Stdio::inherit())
        .stderr(Stdio::inherit());
    for (name, value) in environment {
        command.env(name, value);
    }
    Ok(command.status())
}

async fn exercise_runtime_dml(pool: &PgPool) -> Result<()> {
    let account_id = format!("role-split-test-{}", Uuid::new_v4());
    let work_id = Uuid::new_v4();
    let document_id = Uuid::new_v4();
    let mut tx = pool.begin().await?;
    sqlx::query(
        "INSERT INTO sync_v2.account_scopes(
             account_id,server_instance_id,protocol_epoch,account_auth_epoch,account_fence
         ) VALUES($1,'role-split-test',2,1,'role-split-fence')",
    )
    .bind(&account_id)
    .execute(&mut *tx)
    .await?;
    sqlx::query(
        "INSERT INTO sync_v2.works(account_id,work_id,document_id,state)
         VALUES($1,$2,$3,'bound')",
    )
    .bind(&account_id)
    .bind(work_id)
    .bind(document_id)
    .execute(&mut *tx)
    .await?;
    sqlx::query("UPDATE sync_v2.works SET state='quarantined' WHERE account_id=$1 AND work_id=$2")
        .bind(&account_id)
        .bind(work_id)
        .execute(&mut *tx)
        .await?;
    sqlx::query("DELETE FROM sync_v2.works WHERE account_id=$1 AND work_id=$2")
        .bind(&account_id)
        .bind(work_id)
        .execute(&mut *tx)
        .await?;
    sqlx::query("DELETE FROM sync_v2.account_scopes WHERE account_id=$1")
        .bind(&account_id)
        .execute(&mut *tx)
        .await?;
    tx.commit().await?;
    Ok(())
}

async fn exercise_runtime_denials(pool: &PgPool) -> Result<()> {
    for statement in [
        "CREATE SCHEMA role_split_runtime_denied",
        "CREATE TABLE sync_v2.role_split_runtime_denied(id INTEGER)",
        "CREATE TABLE public.role_split_runtime_denied(id INTEGER)",
        "CREATE TEMP TABLE role_split_runtime_denied(id INTEGER)",
        "ALTER TABLE sync_v2.server_meta ADD COLUMN role_split_runtime_denied TEXT",
        "UPDATE sync_v2.server_meta SET value='runtime-denied' WHERE key='namespace'",
        "SELECT migration_id FROM sync_v2.migration_staging_batches",
        "SELECT migration_id FROM sync_v2.migration_staging_objects",
        "SELECT last_value FROM sync_v2.conflict_events_event_id_seq",
        "SELECT setval('sync_v2.conflict_events_event_id_seq', 1)",
    ] {
        expect_permission_denied(pool, statement).await?;
    }
    Ok(())
}

async fn expect_permission_denied(pool: &PgPool, statement: &str) -> Result<()> {
    let error = sqlx::query(statement)
        .execute(pool)
        .await
        .expect_err("runtime operation unexpectedly succeeded");
    let message = error.to_string().to_ascii_lowercase();
    if !message.contains("permission denied") {
        return Err(format!("runtime operation failed for the wrong reason: {statement}").into());
    }
    Ok(())
}

async fn verify_unknown_database_rejection(config: &Config, pool: &PgPool) -> Result<()> {
    if !table_exists(pool, "public.role_split_unknown_marker").await? {
        return Err("unknown gate database must be pre-provisioned with its marker".into());
    }
    let before = catalog_fingerprint(pool).await?;
    let status = run_migrator_child(config, &config.unknown)?.await?;
    if status.success() {
        return Err("migrator accepted an unknown-object database".into());
    }
    let after = catalog_fingerprint(pool).await?;
    if before != after {
        return Err("unknown-object rejection changed the database".into());
    }
    Ok(())
}

async fn verify_legacy_database_rejection(config: &Config, pool: &PgPool) -> Result<()> {
    let legacy_marker: Option<String> =
        sqlx::query_scalar("SELECT value FROM sync_v2.server_meta WHERE key='namespace'")
            .fetch_optional(pool)
            .await
            .map_err(|error| {
                format!(
            "legacy gate database must be pre-provisioned with sync_v2.server_meta: {error}"
        )
            })?;
    if legacy_marker.as_deref() != Some("legacy-single-role") {
        return Err(
            "legacy gate database must contain the pre-provisioned single-role marker".into(),
        );
    }
    let before = catalog_fingerprint(pool).await?;
    let status = run_migrator_child(config, &config.legacy)?.await?;
    if status.success() {
        return Err("migrator accepted a legacy single-role database".into());
    }
    let after = catalog_fingerprint(pool).await?;
    if before != after {
        return Err("legacy single-role rejection changed the database".into());
    }
    Ok(())
}

async fn catalog_fingerprint(pool: &PgPool) -> Result<Vec<String>> {
    let queries = [
        "SELECT COALESCE(string_agg(format('%s|%s|%s',nspname,nspowner,nspacl),E'\\n' ORDER BY nspname),'') FROM pg_namespace WHERE nspname IN ('auth_v1','sync_v2','public')",
        "SELECT COALESCE(string_agg(format('%s|%s|%s|%s',n.nspname,c.relname,c.relowner,c.relacl),E'\\n' ORDER BY n.nspname,c.relname),'') FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname IN ('auth_v1','sync_v2','public')",
        "SELECT COALESCE(string_agg(format('%s|%s|%s',n.nspname,t.typname,t.typowner),E'\\n' ORDER BY n.nspname,t.typname),'') FROM pg_type t JOIN pg_namespace n ON n.oid=t.typnamespace WHERE n.nspname IN ('auth_v1','sync_v2','public')",
        "SELECT COALESCE(string_agg(format('%s|%s|%s',n.nspname,p.proname,p.proowner),E'\\n' ORDER BY n.nspname,p.proname,p.oid),'') FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname IN ('auth_v1','sync_v2','public')",
        "SELECT COALESCE(string_agg(format('%s|%s|%s',n.nspname,c.relname,a.attname),E'\\n' ORDER BY n.nspname,c.relname,a.attnum),'') FROM pg_attribute a JOIN pg_class c ON c.oid=a.attrelid JOIN pg_namespace n ON n.oid=c.relnamespace WHERE a.attnum>0 AND NOT a.attisdropped AND (n.nspname IN ('auth_v1','sync_v2') OR (n.nspname='public' AND c.relname='_sqlx_migrations'))",
        "SELECT COALESCE(string_agg(format('%s|%s|%s|%s|%s|%s|%s',rolname,rolsuper,rolcreaterole,rolcreatedb,rolcanlogin,rolbypassrls,rolpassword),E'\\n' ORDER BY rolname),'') FROM pg_roles WHERE rolname IN ('fuminiwa_sync_v2_bootstrap','fuminiwa_sync_v2_migrator','fuminiwa_sync_v2_runtime')",
        "SELECT COALESCE(string_agg(format('%s|%s',member::regrole,roleid::regrole),E'\\n' ORDER BY member,roleid),'') FROM pg_auth_members WHERE member IN (SELECT oid FROM pg_roles WHERE rolname IN ('fuminiwa_sync_v2_bootstrap','fuminiwa_sync_v2_migrator','fuminiwa_sync_v2_runtime'))",
    ];
    let mut values = Vec::with_capacity(queries.len());
    for query in queries {
        let value: Option<String> = sqlx::query_scalar(query).fetch_one(pool).await?;
        values.push(value.unwrap_or_default());
    }
    values.push(if table_exists(pool, "sync_v2.server_meta").await? {
        sqlx::query_scalar::<_, Option<String>>(
            "SELECT COALESCE(string_agg(format('%s|%s',key,value),E'\\n' ORDER BY key),'')
             FROM sync_v2.server_meta",
        )
        .fetch_one(pool)
        .await?
        .unwrap_or_default()
    } else {
        String::new()
    });
    values.push(if table_exists(pool, "sync_v2.deployment_binding").await? {
        sqlx::query_scalar::<_, Option<String>>(
            "SELECT COALESCE(string_agg(format('%s|%s',singleton,server_instance_id),E'\\n' ORDER BY singleton),'')
             FROM sync_v2.deployment_binding",
        )
        .fetch_one(pool)
        .await?
        .unwrap_or_default()
    } else {
        String::new()
    });
    Ok(values)
}

async fn table_exists(pool: &PgPool, qualified_name: &str) -> Result<bool> {
    Ok(sqlx::query_scalar("SELECT to_regclass($1) IS NOT NULL")
        .bind(qualified_name)
        .fetch_one(pool)
        .await?)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn target_identity_collapses_aliases_and_ignored_url_options() {
        let localhost = parse_target(
            "test",
            "postgres://first:secret@localhost:5432/fuminiwa_v2_role_split_test_same?application_name=one",
        )
        .expect("localhost target");
        let loopback = parse_target(
            "test",
            "postgres://second:other@127.0.0.1:5432/fuminiwa_v2_role_split_test_same?sslmode=disable",
        )
        .expect("loopback target");
        assert_eq!(localhost.identity, loopback.identity);
    }

    #[test]
    fn target_identity_keeps_database_endpoints_distinct() {
        let first = parse_target(
            "test",
            "postgres://first@localhost:5432/fuminiwa_v2_role_split_test_first",
        )
        .expect("first target");
        let second = parse_target(
            "test",
            "postgres://first@localhost:5432/fuminiwa_v2_role_split_test_second",
        )
        .expect("second target");
        assert_ne!(first.identity, second.identity);
    }
}
