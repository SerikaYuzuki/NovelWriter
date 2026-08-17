//! The PG gate is intentionally opt-in. CI and local unit runs never connect
//! to a fixed LAN server or to the v1 database.
use sqlx::{postgres::PgPoolOptions, Executor};
use uuid::Uuid;

#[tokio::test]
async fn postgres_gate_is_opt_in_and_uses_a_unique_schema() {
    let url = std::env::var("FUMINIWA_V2_TEST_DATABASE_URL").expect(
        "NO-GO: FUMINIWA_V2_TEST_DATABASE_URL is required for Snapshot Sync v2 PostgreSQL integration tests",
    );
    assert!(
        !url.contains("192.168."),
        "integration must not use a LAN fixed URL"
    );
    assert!(
        !url.contains("SyncServer"),
        "integration must not use the v1 database"
    );
    let pool = PgPoolOptions::new()
        .max_connections(2)
        .connect(&url)
        .await
        .unwrap();
    let schema = format!("sync_v2_test_{}", Uuid::new_v4().simple());
    pool.execute(format!("CREATE SCHEMA {schema}").as_str())
        .await
        .unwrap();
    let exists: bool =
        sqlx::query_scalar("SELECT EXISTS (SELECT 1 FROM pg_namespace WHERE nspname=$1)")
            .bind(&schema)
            .fetch_one(&pool)
            .await
            .unwrap();
    assert!(exists);
    pool.execute(format!("DROP SCHEMA {schema} CASCADE").as_str())
        .await
        .unwrap();
    pool.close().await;
}
