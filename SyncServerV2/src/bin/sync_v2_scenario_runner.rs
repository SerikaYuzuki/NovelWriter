#[path = "../../tests/support/mod.rs"]
mod support;

#[tokio::main]
async fn main() {
    let url = match std::env::var("FUMINIWA_V2_TEST_DATABASE_URL") {
        Ok(value) => value,
        Err(_) => {
            eprintln!(
                "NO-GO: FUMINIWA_V2_TEST_DATABASE_URL must name an externally provisioned, newly-created empty fuminiwa_v2_test PostgreSQL database"
            );
            std::process::exit(2);
        }
    };
    match support::run_repository_scenarios(&url).await {
        Ok(context) => {
            context.repo.pool.close().await;
            println!("Snapshot Sync v2 PostgreSQL scenario gate passed");
        }
        Err(error) => {
            eprintln!("NO-GO: {error}");
            std::process::exit(1);
        }
    }
}
