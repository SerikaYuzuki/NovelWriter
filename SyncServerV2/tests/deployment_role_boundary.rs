use std::fs;

#[test]
fn compose_bootstraps_role_split_before_runtime() {
    let compose = fs::read_to_string("docker-compose.yml").expect("v2 compose");
    let provision =
        fs::read_to_string("docker-compose.provision.yml").expect("v2 provision compose");
    assert!(compose.contains("migrator:"));
    assert!(compose.contains("service_completed_successfully"));
    assert!(compose.contains("fuminiwa_sync_v2_migrator"));
    assert!(compose.contains("fuminiwa_sync_v2_runtime"));
    assert!(!compose.contains("bootstrap-admin:"));
    assert!(!compose.contains("postgres-init-password"));
    assert!(!compose.contains("fuminiwa_sync_v2_postgres_init"));
    assert!(!compose
        .lines()
        .any(|line| line.trim_start().starts_with("POSTGRES_USER:")));
    assert!(compose.contains("pg_isready -U fuminiwa_sync_v2_bootstrap -d fuminiwa_sync_v2"));
    assert!(provision.contains("bootstrap-admin:"));
    let bootstrap_admin = provision
        .split("  bootstrap-admin:")
        .nth(1)
        .expect("bootstrap-admin service")
        .split("secrets:")
        .next()
        .expect("bootstrap-admin service body");
    assert!(bootstrap_admin.contains("profiles:") && bootstrap_admin.contains("provision"));
    assert!(bootstrap_admin.contains("user: \"10001:10001\""));
    assert!(bootstrap_admin.contains("postgres_init_password=$$(cat"));
    assert!(bootstrap_admin.contains("postgres init password must use the fixed safe grammar"));
    assert!(bootstrap_admin.contains("PGPASSWORD=\"$$postgres_init_password\""));
    assert!(!bootstrap_admin.contains("PGPASSWORD=$$(cat"));
    assert!(bootstrap_admin
        .contains(r#"printf '%s\n' "\\set bootstrap_admin_password $$admin_password""#));
    assert!(!bootstrap_admin.contains("%s\\n' \"$$admin_password\""));
    let migrator = compose
        .split("  migrator:")
        .nth(1)
        .expect("migrator service")
        .split("  server:")
        .next()
        .expect("migrator service body");
    assert!(!migrator.contains("bootstrap-admin:"));
    assert!(provision.contains("POSTGRES_USER: fuminiwa_sync_v2_postgres_init"));
    assert!(provision.contains("POSTGRES_PASSWORD_FILE: /run/secrets/postgres-init-password"));
    assert!(provision.contains("pg_isready -U fuminiwa_sync_v2_postgres_init -d fuminiwa_sync_v2"));
    assert!(provision.contains("FUMINIWA_SYNC_V2_POSTGRES_INIT_PASSWORD_HOST_PATH"));
    assert!(compose.contains("fuminiwa-sync-v2-role-split-data"));
    assert!(!compose.contains("fuminiwa-sync-v2-data:"));
    assert!(!compose.contains("POSTGRES_USER: fuminiwa_sync_v2\n"));
    assert!(compose.contains("FUMINIWA_SYNC_V2_MIGRATION_PASSWORD_HOST_PATH"));
    assert!(compose.contains("FUMINIWA_SYNC_V2_RUNTIME_PASSWORD_HOST_PATH"));
}

#[test]
fn bootstrap_admin_provisioning_is_transactional_and_fresh_only() {
    let script = fs::read_to_string("scripts/bootstrap-admin.sql").expect("bootstrap-admin SQL");
    let begin = script.find("BEGIN;").expect("transaction begin");
    let lock = script
        .find("pg_advisory_xact_lock")
        .expect("transaction advisory lock");
    let guard = script.find("DO $bootstrap_guard$").expect("fresh guard");
    let create = script
        .find("CREATE ROLE fuminiwa_sync_v2_bootstrap_admin")
        .expect("role creation");
    let commit = script.rfind("COMMIT;").expect("transaction commit");
    assert!(begin < lock && lock < guard && guard < create && create < commit);
    for marker in [
        "current_database() <> 'fuminiwa_sync_v2'",
        "current_user <> 'fuminiwa_sync_v2_postgres_init'",
        "current_setting('is_superuser') <> 'on'",
        "AND oid = 10",
        "FROM pg_database",
        "FROM pg_roles",
        "WHERE oid >= 16384",
        "FROM pg_auth_members",
        "FROM pg_db_role_setting",
        "catalog.relname NOT IN ('pg_database', 'pg_authid')",
        "SELECT count(*) FROM %s WHERE oid >= 16384",
        "FROM pg_replication_origin",
        "FROM pg_seclabel",
        "FROM pg_shseclabel",
        "FROM pg_description",
        "FROM pg_shdescription",
        "FROM pg_namespace",
        "FROM pg_class",
        "FROM pg_type",
        "FROM pg_proc",
        "FROM pg_extension",
        "RAISE EXCEPTION 'bootstrap-admin target database is not fresh'",
        "RAISE EXCEPTION 'bootstrap-admin found an unknown user role'",
        "RAISE EXCEPTION 'bootstrap-admin found an unknown user catalog object'",
        "\\set ON_ERROR_STOP on",
    ] {
        assert!(
            script.contains(marker),
            "missing fresh-only guard: {marker}"
        );
    }
    assert!(!script.contains("WHERE NOT EXISTS"));
    assert!(!script.contains("pg_advisory_unlock"));
}

#[test]
fn production_server_has_no_migration_or_bootstrap_path() {
    let main = fs::read_to_string("src/main.rs").expect("v2 server main");
    assert!(main.contains("connect_from_environment"));
    assert!(!main.contains("sqlx::migrate!"));
    assert!(!main.contains("bootstrap_server_meta"));
    let compose = fs::read_to_string("docker-compose.yml").expect("v2 compose");
    let server = compose
        .split("  server:")
        .nth(1)
        .expect("server service")
        .split("  edge:")
        .next()
        .expect("server service body");
    assert!(server.contains("fuminiwa_sync_v2_runtime"));
    assert!(!server.contains("migration-owner-password"));
    assert!(!server.contains("FUMINIWA_SYNC_V2_MIGRATION"));
    assert!(!server.contains("postgres-init-password"));
    let migrator = compose
        .split("  migrator:")
        .nth(1)
        .expect("migrator service")
        .split("  server:")
        .next()
        .expect("migrator service body");
    assert!(!migrator.contains("postgres-init-password"));
}

#[test]
fn edge_does_not_duplicate_application_cache_contract() {
    let caddy = fs::read_to_string("Caddyfile").expect("v2 Caddyfile");
    assert!(
        !caddy.lines().any(|line| {
            let field = line.split_whitespace().next();
            matches!(field, Some("Cache-Control") | Some("Pragma"))
        }),
        "Caddy must not add cache contract fields already emitted by Axum"
    );
    assert!(caddy.contains("reverse_proxy server:8092"));

    let auth_http = fs::read_to_string("src/auth_http.rs").expect("v2 auth HTTP boundary");
    assert_eq!(
        auth_http
            .matches(".header(\"cache-control\", \"no-store\")")
            .count(),
        1,
        "Axum must remain the single Cache-Control authority"
    );
    assert_eq!(
        auth_http
            .matches(".header(\"pragma\", \"no-cache\")")
            .count(),
        1,
        "Axum must remain the single Pragma authority"
    );
}

#[test]
fn runtime_attestation_forbids_migration_objects_and_ddl() {
    let postgres = fs::read_to_string("src/postgres.rs").expect("v2 postgres");
    for marker in [
        "rolcreaterole",
        "rolcreatedb",
        "rolbypassrls",
        "public._sqlx_migrations",
        "migration_staging_objects",
        "has_database_privilege",
        "has_schema_privilege",
        "has_sequence_privilege",
        "nspowner",
        "typowner",
        "proowner",
        "pg_database",
        "current_database()",
        "verify_migration_owner_attestation",
    ] {
        assert!(
            postgres.contains(marker),
            "missing attestation marker: {marker}"
        );
    }
    assert!(postgres.contains("fuminiwa_sync_v2_runtime"));
    assert!(postgres.contains("MIGRATION_OWNER_ROLE"));
    assert!(postgres.contains("GRANT USAGE ON SEQUENCE"));
    assert!(postgres.contains("runtime sequence privileges are not USAGE-only"));
    assert!(postgres.contains("cardinality(a.attacl)"));
    assert!(postgres.contains("'public','CREATE'"));
}

#[test]
fn opt_in_role_split_gate_covers_positive_negative_and_unchanged_paths() {
    let runner = fs::read_to_string("src/bin/sync_v2_role_split_runner.rs")
        .expect("role-split PostgreSQL runner");
    for marker in [
        "FUMINIWA_V2_ROLE_SPLIT_TEST_DATABASE_URL",
        "run_concurrent_migrators",
        "exercise_runtime_dml",
        "exercise_runtime_denials",
        "verify_unknown_database_rejection",
        "verify_legacy_database_rejection",
        "catalog_fingerprint",
        "canonical_target_identity",
        "assert_distinct_connected_targets",
        "SELECT setval",
        "SELECT last_value",
    ] {
        assert!(
            runner.contains(marker),
            "missing role-split gate marker: {marker}"
        );
    }
    assert!(!runner.contains("CREATE TABLE IF NOT EXISTS public.role_split_unknown_marker"));
    assert!(!runner.contains("CREATE SCHEMA IF NOT EXISTS sync_v2"));
}

#[test]
fn fresh_bootstrap_lock_and_role_inventory_are_scoped() {
    let migrator = fs::read_to_string("src/bin/sync_v2_migrator.rs").expect("v2 migrator");
    assert!(migrator.contains("attest_bootstrap_session"));
    assert!(migrator.contains("attest_bootstrap_provisioning_session"));
    assert!(migrator.contains("harden_role"));
    assert!(migrator.contains("v2 bootstrap role flags are not hardened"));
    assert!(migrator.contains("let mut bootstrap_session = lock.acquire"));
    assert!(migrator.contains("MIGRATION_OWNER_ROLE, RUNTIME_ROLE"));
    assert!(!migrator.contains("migration_lock"));
    assert!(migrator.contains("final v2 role bootstrap identity read-back failed"));
    assert!(migrator.contains("let repeat_identity"));
    assert!(migrator.contains("inspect_database_identity_on_connection(&mut permanent_lock)"));
    assert!(!migrator.contains("if identity != DatabaseIdentity::SnapshotSyncV2"));
}

#[test]
fn migration_names_are_explicit_and_within_postgres_identifier_limit() {
    let sync = fs::read_to_string("migrations/0001_sync_v2.sql").expect("sync migration");
    let auth = fs::read_to_string("migrations/0002_auth_v1.sql").expect("auth migration");
    for name in [
        "conflict_candidates_conflict_revision_generation_key",
        "external_identities_account_provider_issuer_key",
        "provider_credentials_identity_audience_generation_key",
    ] {
        assert!(
            name.len() <= 63,
            "explicit name exceeds PostgreSQL limit: {name}"
        );
        assert!(
            sync.contains(name) || auth.contains(name),
            "missing explicit name: {name}"
        );
    }
    assert!(sync
        .contains("CONSTRAINT conflict_candidates_conflict_revision_generation_key\n    UNIQUE"));
    assert!(
        auth.contains("CONSTRAINT external_identities_account_provider_issuer_key\n        UNIQUE")
    );
    assert!(auth.contains(
        "CONSTRAINT provider_credentials_identity_audience_generation_key\n        UNIQUE"
    ));
}
