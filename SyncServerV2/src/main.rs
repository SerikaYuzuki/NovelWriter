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
    let _mode = RuntimeMode::production_from_environment()?;
    let server_instance_id = production_server_instance()?;

    // Parse every Production auth dependency before opening PostgreSQL. A
    // missing key or Apple configuration therefore cannot partially start or
    // migrate a deployment with authentication disabled.
    let vault = AesGcmCredentialVault::from_environment()?;
    let subject_hmac_key = secret_key_from_environment("FUMINIWA_AUTH_SUBJECT_HMAC_KEY")?;
    let token_hmac_key = secret_key_from_environment("FUMINIWA_AUTH_TOKEN_HMAC_KEY")?;
    let apple_signer = AppleClientSecretSigner::from_environment()?;
    let apple_transport = ProductionAppleTransport::new()?;

    let repository = Repository::connect_from_environment(server_instance_id.clone()).await?;
    let auth_repository = fuminiwa_sync_server_v2::auth_postgres::AuthPostgresRepository::new(
        repository.pool.clone(),
        Arc::new(vault.clone()),
        token_hmac_key,
        server_instance_id.clone(),
    )?;
    auth_repository.rewrap_vault().await?;
    ProductionAuthService::ensure_apple_provider_config(&repository.pool).await?;
    let auth_service = Arc::new(ProductionAuthService::new(
        repository.pool.clone(),
        vault,
        subject_hmac_key,
        token_hmac_key,
        server_instance_id.clone(),
        apple_signer,
        apple_transport,
    )?);
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
    let listener = tokio::net::TcpListener::bind(&bind).await?;
    axum::serve(listener, app).await?;
    Ok(())
}

fn production_server_instance() -> Result<String, Box<dyn std::error::Error>> {
    let value = std::env::var("FUMINIWA_SERVER_INSTANCE_ID")?;
    let parsed = Uuid::parse_str(&value)?;
    if parsed.to_string() != value {
        return Err("FUMINIWA_SERVER_INSTANCE_ID must be a lowercase UUID".into());
    }
    Ok(value)
}
