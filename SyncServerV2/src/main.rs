use fuminiwa_sync_server_v2::{
    auth::{AccessAuthenticator, RuntimeMode},
    auth_apple::{AppleClientSecretSigner, ProductionAppleTransport},
    auth_http::{self, AuthHttpService, AuthHttpState},
    auth_service::ProductionAuthService,
    auth_vault::{secret_key_from_environment, AesGcmCredentialVault},
    router, AppState, Repository,
};
use std::sync::Arc;
use uuid::Uuid;

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    tracing_subscriber::fmt::init();
    let _mode = RuntimeMode::production_from_environment()
        .map_err(|error| startup_error("runtime mode", error))?;
    let server_instance_id =
        production_server_instance().map_err(|error| startup_error("server instance", error))?;

    // Parse every Production auth dependency before opening PostgreSQL. A
    // missing key or Apple configuration therefore cannot partially start or
    // migrate a deployment with authentication disabled.
    let vault = AesGcmCredentialVault::from_environment()
        .map_err(|error| startup_error("vault configuration", error))?;
    let subject_hmac_key = secret_key_from_environment("FUMINIWA_AUTH_SUBJECT_HMAC_KEY")
        .map_err(|error| startup_error("subject HMAC configuration", error))?;
    let token_hmac_key = secret_key_from_environment("FUMINIWA_AUTH_TOKEN_HMAC_KEY")
        .map_err(|error| startup_error("token HMAC configuration", error))?;
    let apple_signer = AppleClientSecretSigner::from_environment()
        .map_err(|error| startup_error("Apple signer configuration", error))?;
    let apple_transport = ProductionAppleTransport::new()
        .map_err(|error| startup_error("Apple transport configuration", error))?;

    let repository = Repository::connect_from_environment(server_instance_id.clone())
        .await
        .map_err(|error| startup_error("PostgreSQL connection", error))?;
    let auth_repository = fuminiwa_sync_server_v2::auth_postgres::AuthPostgresRepository::new(
        repository.pool.clone(),
        Arc::new(vault.clone()),
        token_hmac_key,
        server_instance_id.clone(),
    )
    .map_err(|error| startup_error("auth repository", error))?;
    auth_repository
        .rewrap_vault()
        .await
        .map_err(|error| startup_error("vault rewrap", error))?;
    ProductionAuthService::ensure_apple_provider_config(&repository.pool)
        .await
        .map_err(|error| startup_error("Apple provider configuration", error))?;
    let auth_service = Arc::new(
        ProductionAuthService::new(
            repository.pool.clone(),
            vault,
            subject_hmac_key,
            token_hmac_key,
            server_instance_id.clone(),
            apple_signer,
            apple_transport,
        )
        .map_err(|error| startup_error("auth service", error))?,
    );
    let revocation_service = auth_service.clone();
    tokio::spawn(async move {
        let mut ticker = tokio::time::interval(std::time::Duration::from_secs(30));
        loop {
            ticker.tick().await;
            if let Err(error) = revocation_service.run_apple_revocation_batch(16).await {
                tracing::warn!(?error, "apple revocation worker iteration failed");
            }
        }
    });
    let access_authenticator: Arc<dyn AccessAuthenticator> = auth_service.clone();
    let auth_http_service: Arc<dyn AuthHttpService> = auth_service;
    let app = router(AppState {
        repo: Arc::new(repository),
        access_authenticator,
    })
    .merge(auth_http::router(AuthHttpState::new(
        auth_http_service,
        server_instance_id,
    )));
    let bind = std::env::var("FUMINIWA_SYNC_V2_BIND").unwrap_or_else(|_| "127.0.0.1:8092".into());
    let listener = tokio::net::TcpListener::bind(&bind)
        .await
        .map_err(|error| startup_error("HTTP listener", error))?;
    axum::serve(listener, app).await?;
    Ok(())
}

fn startup_error(label: &str, error: impl std::fmt::Display) -> Box<dyn std::error::Error> {
    format!("startup {label} failed: {error}").into()
}

fn production_server_instance() -> Result<String, Box<dyn std::error::Error>> {
    let value = std::env::var("FUMINIWA_SERVER_INSTANCE_ID")?;
    let parsed = Uuid::parse_str(&value)?;
    if parsed.to_string() != value {
        return Err("FUMINIWA_SERVER_INSTANCE_ID must be a lowercase UUID".into());
    }
    Ok(value)
}
