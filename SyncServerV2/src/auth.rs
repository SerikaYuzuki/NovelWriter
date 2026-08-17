use crate::{
    auth_domain::AuthError,
    domain::{AuthenticatedPrincipal, SyncError, PROTOCOL_EPOCH},
};
use async_trait::async_trait;
use axum::http::{header::AUTHORIZATION, HeaderMap};
use std::sync::Arc;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum RuntimeMode {
    Production,
    Test,
    Preview,
}

impl RuntimeMode {
    /// The production binary has no environment-controlled fixture fallback.
    pub fn production_from_environment() -> Result<Self, AuthError> {
        match std::env::var("FUMINIWA_RUNTIME_MODE").as_deref() {
            Ok("production") | Err(_) => Ok(Self::Production),
            Ok(_) => Err(AuthError::InvalidRequest),
        }
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct AuthenticatedAccess {
    pub account_id: String,
    pub account_fence: String,
    pub account_auth_epoch: i64,
}

#[async_trait]
pub trait AccessAuthenticator: Send + Sync {
    async fn authenticate_access(&self, token: &str) -> Result<AuthenticatedAccess, AuthError>;
}

#[derive(Clone)]
pub struct FixtureAccessAuthenticator {
    fence: Arc<str>,
}

impl FixtureAccessAuthenticator {
    pub fn new(mode: RuntimeMode, fence: String) -> Result<Self, AuthError> {
        if mode == RuntimeMode::Production {
            return Err(AuthError::InvalidRequest);
        }
        if fence.is_empty() {
            return Err(AuthError::InvalidRequest);
        }
        Ok(Self {
            fence: fence.into(),
        })
    }
}

#[async_trait]
impl AccessAuthenticator for FixtureAccessAuthenticator {
    async fn authenticate_access(&self, token: &str) -> Result<AuthenticatedAccess, AuthError> {
        let account = token
            .strip_prefix("dev:")
            .and_then(|value| value.strip_suffix(":fixture-fence"))
            .filter(|value| !value.is_empty())
            .ok_or(AuthError::AccountNotFound)?;
        Ok(AuthenticatedAccess {
            account_id: account.into(),
            account_fence: self.fence.to_string(),
            account_auth_epoch: 1,
        })
    }
}

/// Authenticate a FUMINIWA access token and project only the sync binding.
/// Apple tokens never implement `AccessAuthenticator`.
pub async fn authenticate(
    headers: &HeaderMap,
    authenticator: &dyn AccessAuthenticator,
    server_instance: &str,
) -> Result<AuthenticatedPrincipal, SyncError> {
    let token = bearer_token(headers).ok_or(SyncError::Unauthorized)?;
    let principal = authenticator
        .authenticate_access(token)
        .await
        .map_err(|_| SyncError::Unauthorized)?;
    if principal.account_fence.is_empty() {
        return Err(SyncError::Unauthorized);
    }
    Ok(AuthenticatedPrincipal {
        account_id: principal.account_id,
        account_fence: principal.account_fence,
        account_auth_epoch: principal.account_auth_epoch,
        server_instance_id: server_instance.to_owned(),
        protocol_epoch: PROTOCOL_EPOCH,
    })
}

pub fn bearer_token(headers: &HeaderMap) -> Option<&str> {
    let mut values = headers.get_all(AUTHORIZATION).iter();
    let value = values.next()?.to_str().ok()?;
    if values.next().is_some() {
        return None;
    }
    let token = value.strip_prefix("Bearer ")?;
    if token.is_empty()
        || token.len() > 1_024
        || token.bytes().any(|byte| {
            !(byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'_' | b'.' | b':'))
        })
    {
        return None;
    }
    Some(token)
}

#[cfg(test)]
mod tests {
    use super::*;
    #[tokio::test]
    async fn production_cannot_construct_fixture_authenticator() {
        assert!(
            FixtureAccessAuthenticator::new(RuntimeMode::Production, "fixture-fence".into())
                .is_err()
        );
    }

    #[test]
    fn bearer_parser_rejects_multiple_or_malformed_values() {
        let mut headers = HeaderMap::new();
        headers.append(AUTHORIZATION, "Bearer valid_token".parse().unwrap());
        assert_eq!(bearer_token(&headers), Some("valid_token"));
        headers.append(AUTHORIZATION, "Bearer second".parse().unwrap());
        assert_eq!(bearer_token(&headers), None);
    }
}
