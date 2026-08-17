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
        "verify_migration_owner_attestation",
    ] {
        assert!(
            postgres.contains(marker),
            "missing attestation marker: {marker}"
        );
    }
    assert!(postgres.contains("fuminiwa_sync_v2_runtime"));
    assert!(postgres.contains("MIGRATION_OWNER_ROLE"));
}
