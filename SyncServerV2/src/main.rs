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
    tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env().unwrap_or_else(|_| "info".into()),
        )
        .init();
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
    let browser_service = if std::env::var("FUMINIWA_BROWSER_AUTH_ENABLED").as_deref() == Ok("1") {
        Some(
            fuminiwa_sync_server_v2::auth_browser::BrowserAuthService::new(
                repository.pool.clone(),
                vault.clone(),
                subject_hmac_key,
                token_hmac_key,
                server_instance_id.clone(),
                apple_signer.clone(),
                apple_transport.clone(),
                fuminiwa_sync_server_v2::auth_google::GoogleOAuthProvider::from_environment()?,
            )?,
        )
    } else {
        None
    };
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
    let upload_cleanup = repository.clone();
    tokio::spawn(async move {
        let mut ticker = tokio::time::interval(std::time::Duration::from_secs(30));
        loop {
            ticker.tick().await;
            if fuminiwa_sync_server_v2::account_deletion::sweep(&upload_cleanup.pool)
                .await
                .is_err()
            {
                tracing::warn!("account deletion worker iteration failed");
            }
            if upload_cleanup.purge_expired_works().await.is_err() {
                tracing::warn!("expired work cleanup failed");
            }
            if upload_cleanup.expire_partial_uploads().await.is_err() {
                tracing::warn!("expired upload cleanup failed");
            }
            if let Err(error) = revocation_service.run_apple_validation_batch(16).await {
                tracing::warn!(?error, "apple validation worker iteration failed");
            }
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
    let app = if let Some(service) = browser_service {
        app.merge(fuminiwa_sync_server_v2::auth_browser::router(service))
    } else {
        app
    };
    let bind = std::env::var("FUMINIWA_SYNC_V2_BIND").unwrap_or_else(|_| "127.0.0.1:8092".into());
    let listener = tokio::net::TcpListener::bind(&bind)
        .await
        .map_err(|error| startup_error("HTTP listener", error))?;
    let app = app.layer(axum::middleware::from_fn(request_latency));
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

async fn request_latency(
    request: axum::extract::Request,
    next: axum::middleware::Next,
) -> axum::response::Response {
    let method = request.method().clone();
    // MatchedPath contains the route template, never work IDs, queries or tokens.
    let route = request
        .extensions()
        .get::<axum::extract::MatchedPath>()
        .map(|path| path.as_str().to_owned())
        .unwrap_or_else(|| "unmatched".into());
    let started = std::time::Instant::now();
    let response = next.run(request).await;
    tracing::info!(%method, %route, status = response.status().as_u16(), latency_ms = started.elapsed().as_millis() as u64, "http request");
    response
}

#[cfg(test)]
mod tests {
    use super::request_latency;
    use std::sync::{Arc, Mutex};
    use tower::ServiceExt;
    use tracing::instrument::WithSubscriber;

    #[derive(Clone)]
    struct LogWriter(Arc<Mutex<Vec<u8>>>);
    impl std::io::Write for LogWriter {
        fn write(&mut self, bytes: &[u8]) -> std::io::Result<usize> {
            self.0.lock().unwrap().extend_from_slice(bytes);
            Ok(bytes.len())
        }
        fn flush(&mut self) -> std::io::Result<()> {
            Ok(())
        }
    }

    #[tokio::test]
    async fn latency_log_uses_route_template_without_private_request_data() {
        let log = Arc::new(Mutex::new(Vec::new()));
        let writer = LogWriter(log.clone());
        let subscriber = tracing_subscriber::fmt()
            .without_time()
            .with_ansi(false)
            .with_max_level(tracing::Level::INFO)
            .with_writer(move || writer.clone())
            .finish();
        let app = axum::Router::new()
            .route(
                "/v2/works/{work_id}/download",
                axum::routing::get(|| async { "ok" }),
            )
            .layer(axum::middleware::from_fn(request_latency));
        let request = axum::http::Request::builder()
            .uri("/v2/works/private-work/download?cursor=private-cursor")
            .header("authorization", "Bearer private-token")
            .header("fuminiwa-device-label", "private-device-label")
            .body(axum::body::Body::from("private-manuscript"))
            .unwrap();
        assert_eq!(
            app.oneshot(request)
                .with_subscriber(subscriber)
                .await
                .unwrap()
                .status(),
            200
        );
        let output = String::from_utf8(log.lock().unwrap().clone()).unwrap();
        for expected in [
            "method=GET",
            "/v2/works/{work_id}/download",
            "status=200",
            "latency_ms=",
        ] {
            assert!(output.contains(expected), "missing {expected}: {output}");
        }
        for private in [
            "private-work",
            "private-cursor",
            "private-token",
            "private-manuscript",
            "private-device-label",
        ] {
            assert!(!output.contains(private));
        }
    }
}
