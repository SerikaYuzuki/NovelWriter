use fuminiwa_sync_server_v2::{router, AppState, Repository, RuntimeMode};
use std::sync::Arc;

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    tracing_subscriber::fmt::init();
    if RuntimeMode::from_env() == RuntimeMode::Production && std::env::var("DATABASE_URL").is_err()
    {
        return Err("DATABASE_URL is required in production".into());
    }
    let url = std::env::var("DATABASE_URL")?;
    let instance =
        std::env::var("FUMINIWA_SERVER_INSTANCE_ID").unwrap_or_else(|_| "fuminiwa-sync-v2".into());
    let repo = Repository::connect(&url, instance).await?;
    let app = router(AppState {
        repo: Arc::new(repo),
        runtime_mode: RuntimeMode::from_env(),
    });
    let bind = std::env::var("FUMINIWA_SYNC_V2_BIND").unwrap_or_else(|_| "127.0.0.1:8092".into());
    let listener = tokio::net::TcpListener::bind(&bind).await?;
    axum::serve(listener, app).await?;
    Ok(())
}
