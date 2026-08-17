use std::fs;

#[test]
fn compose_bootstraps_role_split_before_runtime() {
    let compose = fs::read_to_string("docker-compose.yml").expect("v2 compose");
    assert!(compose.contains("migrator:"));
    assert!(compose.contains("service_completed_successfully"));
    assert!(compose.contains("fuminiwa_sync_v2_migrator"));
    assert!(compose.contains("fuminiwa_sync_v2_runtime"));
    assert!(compose.contains("fuminiwa-sync-v2-role-split-data"));
    assert!(!compose.contains("fuminiwa-sync-v2-data:"));
    assert!(!compose.contains("POSTGRES_USER: fuminiwa_sync_v2\n"));
    assert!(compose.contains("FUMINIWA_SYNC_V2_MIGRATION_PASSWORD_HOST_PATH"));
    assert!(compose.contains("FUMINIWA_SYNC_V2_RUNTIME_PASSWORD_HOST_PATH"));
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
    assert!(migrator.contains("harden_bootstrap_role"));
    assert!(migrator.contains("v2 bootstrap role flags are not hardened"));
    assert!(migrator.contains("let mut bootstrap_session = lock.acquire"));
    assert!(migrator.contains("MIGRATION_OWNER_ROLE, RUNTIME_ROLE"));
    assert!(!migrator.contains("migration_lock"));
    assert!(migrator.contains("final v2 role bootstrap identity read-back failed"));
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
