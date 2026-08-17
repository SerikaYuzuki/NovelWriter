use crate::domain::{AuthenticatedPrincipal, SyncError, PROTOCOL_EPOCH};
use axum::http::HeaderMap;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum RuntimeMode {
    Production,
    Test,
    Preview,
}
impl RuntimeMode {
    pub fn from_env() -> Self {
        match std::env::var("FUMINIWA_RUNTIME_MODE").as_deref() {
            Ok("test") => Self::Test,
            Ok("preview") => Self::Preview,
            _ => Self::Production,
        }
    }
}

/// Auth v1 owns Apple verification. Sync v2 receives only this opaque boundary.
/// Development fixture authentication is deliberately impossible in production.
pub fn authenticate(
    headers: &HeaderMap,
    mode: RuntimeMode,
    server_instance: &str,
    fence: &str,
) -> Result<AuthenticatedPrincipal, SyncError> {
    let Some(value) = headers
        .get(axum::http::header::AUTHORIZATION)
        .and_then(|v| v.to_str().ok())
    else {
        return Err(SyncError::Unauthorized);
    };
    let Some(token) = value.strip_prefix("Bearer ") else {
        return Err(SyncError::Unauthorized);
    };
    if mode == RuntimeMode::Production {
        return Err(SyncError::Unauthorized);
    }
    let (account, token_fence) = token
        .strip_prefix("dev:")
        .and_then(|v| v.split_once(':'))
        .ok_or(SyncError::Unauthorized)?;
    if account.is_empty() || token_fence.is_empty() || token_fence != fence {
        return Err(SyncError::Unauthorized);
    }
    Ok(AuthenticatedPrincipal {
        account_id: account.to_owned(),
        account_fence: token_fence.to_owned(),
        server_instance_id: server_instance.to_owned(),
        protocol_epoch: PROTOCOL_EPOCH,
    })
}
