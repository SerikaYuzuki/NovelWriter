use std::sync::Arc;

use fuminiwa_sync_server::{router, AppConfig, ServerState};
use tokio::sync::RwLock;
use tracing_subscriber::EnvFilter;

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    tracing_subscriber::fmt()
        .with_env_filter(
            EnvFilter::try_from_default_env().unwrap_or_else(|_| EnvFilter::new("info")),
        )
        .init();
    let bind = std::env::var("FUMINIWA_BIND").unwrap_or_else(|_| "0.0.0.0:8080".into());
    let state = if let Ok(database_url) = std::env::var("DATABASE_URL") {
        ServerState::from_database_url(&database_url).await?
    } else {
        ServerState::default()
    };
    let state = Arc::new(RwLock::new(state));
    let app = router(state, AppConfig::default());
    let listener = tokio::net::TcpListener::bind(&bind).await?;
    tracing::info!(%bind, "fuminiwa sync server listening");
    axum::serve(listener, app).await?;
    Ok(())
}
