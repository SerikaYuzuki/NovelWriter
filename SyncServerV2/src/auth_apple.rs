//! Production Sign in with Apple adapter.
//!
//! HTTP is fixed to Apple's documented endpoints. Provider credentials and
//! identity tokens are redacted by type and never reach application logging.

use crate::auth_domain::{
    digest_request, AppleIdentityEvidence, AppleProvider, AuthError, ChallengeClaim,
    CredentialVault, OperationId, ProviderConfigId, VerifiedProviderCredential, APPLE_ISSUER,
    APPLE_PROVIDER_CONFIG,
};
use async_trait::async_trait;
use base64::{engine::general_purpose::URL_SAFE_NO_PAD, Engine};
use chrono::Utc;
use jsonwebtoken::{
    decode, decode_header, encode, Algorithm, DecodingKey, EncodingKey, Header, Validation,
};
use serde::{Deserialize, Serialize};
use std::{fs, path::Path, sync::Arc, time::Duration};
use tokio::sync::RwLock;

const APPLE_JWKS_ENDPOINT: &str = "https://appleid.apple.com/auth/keys";
const APPLE_TOKEN_ENDPOINT: &str = "https://appleid.apple.com/auth/token";
const APPLE_TOKEN_AUDIENCE: &str = "https://appleid.apple.com";
const MAC_AUDIENCE: &str = "dev.serikayuzuki.fuminiwa";
const IOS_AUDIENCE: &str = "dev.serikayuzuki.fuminiwa.ios";
const MAX_PROVIDER_BODY_BYTES: usize = 128 * 1024;
const MAX_CLOCK_SKEW_SECONDS: i64 = 300;

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct AppleS2SNotification {
    pub notification_type: String,
    pub subject: String,
    pub jti: String,
    pub audience: String,
    pub issued_at_unix: i64,
    pub event_time_unix: i64,
}

#[derive(Clone)]
pub struct AppleClientSecretSigner {
    team_id: Arc<str>,
    key_id: Arc<str>,
    mac_client_id: Arc<str>,
    ios_client_id: Arc<str>,
    encoding_key: Arc<EncodingKey>,
}

impl AppleClientSecretSigner {
    pub fn new(
        team_id: String,
        key_id: String,
        mac_client_id: String,
        ios_client_id: String,
        private_key_pem: &[u8],
    ) -> Result<Self, AuthError> {
        if !valid_identifier(&team_id, 64)
            || !valid_identifier(&key_id, 64)
            || mac_client_id != MAC_AUDIENCE
            || ios_client_id != IOS_AUDIENCE
        {
            return Err(AuthError::ProviderNotAllowed);
        }
        let encoding_key =
            EncodingKey::from_ec_pem(private_key_pem).map_err(|_| AuthError::Vault)?;
        Ok(Self {
            team_id: team_id.into(),
            key_id: key_id.into(),
            mac_client_id: mac_client_id.into(),
            ios_client_id: ios_client_id.into(),
            encoding_key: Arc::new(encoding_key),
        })
    }

    pub fn from_environment() -> Result<Self, AuthError> {
        let private_key = secret_text_from_environment("FUMINIWA_APPLE_PRIVATE_KEY")?;
        Self::new(
            required_environment("FUMINIWA_APPLE_TEAM_ID")?,
            required_environment("FUMINIWA_APPLE_KEY_ID")?,
            required_environment("FUMINIWA_APPLE_MAC_CLIENT_ID")?,
            required_environment("FUMINIWA_APPLE_IOS_CLIENT_ID")?,
            private_key.as_bytes(),
        )
    }

    fn client_id(&self, audience: &str) -> Result<&str, AuthError> {
        match audience {
            MAC_AUDIENCE => Ok(&self.mac_client_id),
            IOS_AUDIENCE => Ok(&self.ios_client_id),
            _ => Err(AuthError::ProviderNotAllowed),
        }
    }

    fn sign(&self, audience: &str, now_unix: i64) -> Result<String, AuthError> {
        let client_id = self.client_id(audience)?;
        let claims = AppleClientSecretClaims {
            iss: &self.team_id,
            iat: now_unix,
            exp: now_unix + 300,
            aud: APPLE_TOKEN_AUDIENCE,
            sub: client_id,
        };
        let mut header = Header::new(Algorithm::ES256);
        header.kid = Some(self.key_id.to_string());
        encode(&header, &claims, &self.encoding_key).map_err(|_| AuthError::Vault)
    }
}

#[derive(Serialize)]
struct AppleClientSecretClaims<'a> {
    iss: &'a str,
    iat: i64,
    exp: i64,
    aud: &'a str,
    sub: &'a str,
}

#[derive(Clone, Eq, PartialEq)]
pub struct AppleTokenRequest {
    client_id: String,
    client_secret: String,
    authorization_code: String,
}

impl std::fmt::Debug for AppleTokenRequest {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("AppleTokenRequest")
            .field("client_id", &self.client_id)
            .field("client_secret", &"<redacted>")
            .field("authorization_code", &"<redacted>")
            .finish()
    }
}

#[derive(Clone, Eq, PartialEq)]
pub struct AppleTokenResponse {
    pub identity_token: String,
    pub refresh_token: String,
}

#[derive(Clone, Eq, PartialEq)]
pub struct AppleRevokeRequest {
    pub client_id: String,
    pub client_secret: String,
    pub token: String,
}
impl std::fmt::Debug for AppleRevokeRequest {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("AppleRevokeRequest")
            .field("client_id", &self.client_id)
            .field("client_secret", &"<redacted>")
            .field("token", &"<redacted>")
            .finish()
    }
}

impl std::fmt::Debug for AppleTokenResponse {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("AppleTokenResponse")
            .field("identity_token", &"<redacted>")
            .field("refresh_token", &"<redacted>")
            .finish()
    }
}

#[async_trait]
pub trait AppleTransport: Send + Sync {
    async fn fetch_jwks(&self) -> Result<Vec<u8>, AuthError>;
    async fn exchange_code(
        &self,
        request: &AppleTokenRequest,
    ) -> Result<AppleTokenResponse, AuthError>;
    async fn revoke_credential(&self, request: &AppleRevokeRequest) -> Result<(), AuthError>;
}

#[derive(Clone)]
pub struct ProductionAppleTransport {
    client: reqwest::Client,
}

impl ProductionAppleTransport {
    pub fn new() -> Result<Self, AuthError> {
        let client = reqwest::Client::builder()
            .https_only(true)
            .redirect(reqwest::redirect::Policy::none())
            .connect_timeout(Duration::from_secs(5))
            .timeout(Duration::from_secs(12))
            .user_agent("FUMINIWA-Snapshot-Sync-v2")
            .build()
            .map_err(|_| AuthError::Vault)?;
        Ok(Self { client })
    }
}

#[async_trait]
impl AppleTransport for ProductionAppleTransport {
    async fn fetch_jwks(&self) -> Result<Vec<u8>, AuthError> {
        bounded_success_body(self.client.get(APPLE_JWKS_ENDPOINT).send().await?).await
    }

    async fn exchange_code(
        &self,
        request: &AppleTokenRequest,
    ) -> Result<AppleTokenResponse, AuthError> {
        let response = self
            .client
            .post(APPLE_TOKEN_ENDPOINT)
            .form(&[
                ("client_id", request.client_id.as_str()),
                ("client_secret", request.client_secret.as_str()),
                ("code", request.authorization_code.as_str()),
                ("grant_type", "authorization_code"),
            ])
            .send()
            .await
            .map_err(|_| AuthError::ProviderExchangeIndeterminate)?;
        let status = response.status();
        let body = bounded_body(response).await?;
        if !status.is_success() {
            return if status.is_server_error() {
                Err(AuthError::ProviderExchangeIndeterminate)
            } else {
                Err(AuthError::InvalidExternalIdentity)
            };
        }
        let wire: AppleTokenResponseWire =
            serde_json::from_slice(&body).map_err(|_| AuthError::InvalidExternalIdentity)?;
        if wire.id_token.len() > 32_768
            || wire.refresh_token.is_empty()
            || wire.refresh_token.len() > 4_096
        {
            return Err(AuthError::InvalidExternalIdentity);
        }
        Ok(AppleTokenResponse {
            identity_token: wire.id_token,
            refresh_token: wire.refresh_token,
        })
    }

    async fn revoke_credential(&self, request: &AppleRevokeRequest) -> Result<(), AuthError> {
        let response = self
            .client
            .post("https://appleid.apple.com/auth/revoke")
            .form(&[
                ("client_id", request.client_id.as_str()),
                ("client_secret", request.client_secret.as_str()),
                ("token", request.token.as_str()),
                ("token_type_hint", "refresh_token"),
            ])
            .send()
            .await
            .map_err(|_| AuthError::ProviderExchangeIndeterminate)?;
        let status = response.status();
        let _ = bounded_body(response).await?;
        if status.is_success() {
            Ok(())
        } else if status.is_server_error() {
            Err(AuthError::ProviderExchangeIndeterminate)
        } else {
            Err(AuthError::InvalidExternalIdentity)
        }
    }
}

#[derive(Deserialize)]
struct AppleTokenResponseWire {
    id_token: String,
    refresh_token: String,
}

#[derive(Clone)]
pub struct ProductionAppleProvider<T, V> {
    transport: T,
    signer: AppleClientSecretSigner,
    vault: V,
    jwks: Arc<RwLock<Option<AppleJwks>>>,
}

impl<T, V> ProductionAppleProvider<T, V> {
    pub fn new(transport: T, signer: AppleClientSecretSigner, vault: V) -> Self {
        Self {
            transport,
            signer,
            vault,
            jwks: Arc::new(RwLock::new(None)),
        }
    }

    pub async fn verify_s2s_notification(
        &self,
        token: &str,
        now_unix: i64,
    ) -> Result<AppleS2SNotification, AuthError>
    where
        T: AppleTransport,
    {
        if token.is_empty() || token.len() > 65_536 {
            return Err(AuthError::InvalidExternalIdentity);
        }
        let header = decode_header(token).map_err(|_| AuthError::InvalidExternalIdentity)?;
        if header.alg != Algorithm::RS256 {
            return Err(AuthError::InvalidExternalIdentity);
        }
        let kid = header.kid.ok_or(AuthError::InvalidExternalIdentity)?;
        let key = self.decoding_key(&kid).await?;
        let mut validation = Validation::new(Algorithm::RS256);
        validation.set_issuer(&[APPLE_ISSUER]);
        validation.set_audience(&[MAC_AUDIENCE, IOS_AUDIENCE]);
        validation.leeway = MAX_CLOCK_SKEW_SECONDS as u64;
        validation.set_required_spec_claims(&["iss", "aud", "iat", "jti", "events"]);
        let claims = decode::<AppleS2SNotificationClaims>(token, &key, &validation)
            .map_err(|_| AuthError::InvalidExternalIdentity)?
            .claims;
        if claims.iss != APPLE_ISSUER
            || claims.jti.is_empty()
            || claims.jti.len() > 512
            || claims.issued_at > now_unix + MAX_CLOCK_SKEW_SECONDS
            || claims.events.sub.is_empty()
            || claims.events.sub.len() > 512
            || claims.events.event_time <= 0
            || claims.events.event_time > now_unix + MAX_CLOCK_SKEW_SECONDS
            || !matches!(
                claims.events.notification_type.as_str(),
                "email-enabled" | "email-disabled" | "consent-revoked" | "account-deleted"
            )
        {
            return Err(AuthError::InvalidExternalIdentity);
        }
        Ok(AppleS2SNotification {
            notification_type: claims.events.notification_type,
            subject: claims.events.sub,
            jti: claims.jti,
            audience: claims.aud,
            issued_at_unix: claims.issued_at,
            event_time_unix: claims.events.event_time,
        })
    }
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct AppleS2SNotificationClaims {
    jti: String,
    aud: String,
    iss: String,
    #[serde(rename = "iat")]
    issued_at: i64,
    events: AppleS2SEvent,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
#[allow(dead_code)]
struct AppleS2SEvent {
    #[serde(rename = "type")]
    notification_type: String,
    sub: String,
    event_time: i64,
    #[serde(default)]
    email: Option<String>,
    #[serde(default)]
    is_private_email: Option<bool>,
}

#[async_trait]
impl<T: AppleTransport, V: CredentialVault + Clone> AppleProvider
    for ProductionAppleProvider<T, V>
{
    async fn exchange(
        &self,
        challenge: &ChallengeClaim,
        authorization_code: &[u8],
        identity_token: &[u8],
    ) -> Result<AppleIdentityEvidence, AuthError> {
        let now = Utc::now().timestamp();
        let client_token =
            std::str::from_utf8(identity_token).map_err(|_| AuthError::InvalidExternalIdentity)?;
        let first = self
            .verify_identity_token(client_token, &challenge.audience, true, challenge, now)
            .await?;
        let authorization_code = std::str::from_utf8(authorization_code)
            .map_err(|_| AuthError::InvalidExternalIdentity)?;
        if authorization_code.is_empty() || authorization_code.len() > 4_096 {
            return Err(AuthError::InvalidExternalIdentity);
        }
        let response = self
            .transport
            .exchange_code(&AppleTokenRequest {
                client_id: self.signer.client_id(&challenge.audience)?.into(),
                client_secret: self.signer.sign(&challenge.audience, now)?,
                authorization_code: authorization_code.into(),
            })
            .await?;
        let second = self
            .verify_identity_token(
                &response.identity_token,
                &challenge.audience,
                false,
                challenge,
                now,
            )
            .await?;
        if first.iss != second.iss || first.sub != second.sub || first.aud != second.aud {
            return Err(AuthError::InvalidExternalIdentity);
        }
        let vault_context = random_context(&challenge.audience)?;
        let encrypted_refresh_token = self
            .vault
            .seal(
                "apple_provider_refresh_v1",
                &vault_context,
                response.refresh_token.as_bytes(),
            )
            .await?;
        AppleIdentityEvidence::from_verified_claims(
            ProviderConfigId::new(APPLE_PROVIDER_CONFIG)?,
            first.iss,
            first.sub,
            first.aud,
            challenge.nonce_hash.clone(),
            first.iat,
            Some(VerifiedProviderCredential {
                audience: challenge.audience.clone(),
                vault_context,
                encrypted_refresh_token,
            }),
        )
    }

    async fn revoke(
        &self,
        credential: &VerifiedProviderCredential,
        _operation_id: &OperationId,
    ) -> Result<(), AuthError> {
        let token = self
            .vault
            .open(
                "apple_provider_refresh_v1",
                &credential.vault_context,
                &credential.encrypted_refresh_token,
            )
            .await?;
        let token = std::str::from_utf8(&token).map_err(|_| AuthError::Vault)?;
        if token.is_empty() || token.len() > 4096 {
            return Err(AuthError::Vault);
        }
        let now = Utc::now().timestamp();
        self.transport
            .revoke_credential(&AppleRevokeRequest {
                client_id: self.signer.client_id(&credential.audience)?.into(),
                client_secret: self.signer.sign(&credential.audience, now)?,
                token: token.into(),
            })
            .await
    }
}

impl<T: AppleTransport, V> ProductionAppleProvider<T, V> {
    async fn verify_identity_token(
        &self,
        token: &str,
        audience: &str,
        nonce_required: bool,
        challenge: &ChallengeClaim,
        now_unix: i64,
    ) -> Result<AppleIdentityClaims, AuthError> {
        if !matches!(audience, MAC_AUDIENCE | IOS_AUDIENCE) {
            return Err(AuthError::ProviderNotAllowed);
        }
        let header = decode_header(token).map_err(|_| AuthError::InvalidExternalIdentity)?;
        if header.alg != Algorithm::RS256 {
            return Err(AuthError::InvalidExternalIdentity);
        }
        let kid = header.kid.ok_or(AuthError::InvalidExternalIdentity)?;
        let key = self.decoding_key(&kid).await?;
        let mut validation = Validation::new(Algorithm::RS256);
        validation.set_issuer(&[APPLE_ISSUER]);
        validation.set_audience(&[audience]);
        validation.leeway = MAX_CLOCK_SKEW_SECONDS as u64;
        validation.set_required_spec_claims(&["exp", "iat", "iss", "aud", "sub"]);
        let claims = decode::<AppleIdentityClaims>(token, &key, &validation)
            .map_err(|_| AuthError::InvalidExternalIdentity)?
            .claims;
        if claims.iss != APPLE_ISSUER
            || claims.aud != audience
            || claims.sub.is_empty()
            || claims.sub.len() > 512
            || claims.iat > now_unix + MAX_CLOCK_SKEW_SECONDS
            || claims.iat < now_unix - MAX_CLOCK_SKEW_SECONDS
            || claims.exp <= now_unix - MAX_CLOCK_SKEW_SECONDS
        {
            return Err(AuthError::InvalidExternalIdentity);
        }
        match claims.nonce.as_deref() {
            Some(nonce) if digest_request(nonce.as_bytes()) == challenge.nonce_hash.as_slice() => {}
            Some(_) | None if nonce_required => return Err(AuthError::InvalidExternalIdentity),
            Some(_) => return Err(AuthError::InvalidExternalIdentity),
            None => {}
        }
        Ok(claims)
    }

    async fn decoding_key(&self, kid: &str) -> Result<DecodingKey, AuthError> {
        if let Some(key) = self
            .jwks
            .read()
            .await
            .as_ref()
            .and_then(|set| set.decoding_key(kid))
        {
            return key;
        }
        let refreshed = self.fetch_jwks().await?;
        let key = refreshed
            .decoding_key(kid)
            .ok_or(AuthError::InvalidExternalIdentity)?;
        *self.jwks.write().await = Some(refreshed);
        key
    }

    async fn fetch_jwks(&self) -> Result<AppleJwks, AuthError> {
        let raw = self.transport.fetch_jwks().await?;
        if raw.len() > MAX_PROVIDER_BODY_BYTES {
            return Err(AuthError::ProviderExchangeIndeterminate);
        }
        serde_json::from_slice(&raw).map_err(|_| AuthError::InvalidExternalIdentity)
    }
}

#[derive(Clone, Deserialize)]
struct AppleJwks {
    keys: Vec<AppleJwk>,
}

impl AppleJwks {
    fn decoding_key(&self, kid: &str) -> Option<Result<DecodingKey, AuthError>> {
        self.keys.iter().find(|key| key.kid == kid).map(|key| {
            if key.kty != "RSA" || key.alg != "RS256" || key.key_use != "sig" {
                return Err(AuthError::InvalidExternalIdentity);
            }
            DecodingKey::from_rsa_components(&key.n, &key.e)
                .map_err(|_| AuthError::InvalidExternalIdentity)
        })
    }
}

#[derive(Clone, Deserialize)]
struct AppleJwk {
    kty: String,
    kid: String,
    #[serde(rename = "use")]
    key_use: String,
    alg: String,
    n: String,
    e: String,
}

#[derive(Clone, Debug, Deserialize)]
struct AppleIdentityClaims {
    iss: String,
    sub: String,
    aud: String,
    exp: i64,
    iat: i64,
    nonce: Option<String>,
}

async fn bounded_success_body(response: reqwest::Response) -> Result<Vec<u8>, AuthError> {
    if !response.status().is_success() {
        return Err(AuthError::ProviderExchangeIndeterminate);
    }
    bounded_body(response).await
}

async fn bounded_body(response: reqwest::Response) -> Result<Vec<u8>, AuthError> {
    if response
        .content_length()
        .is_some_and(|length| length > MAX_PROVIDER_BODY_BYTES as u64)
    {
        return Err(AuthError::ProviderExchangeIndeterminate);
    }
    let bytes = response
        .bytes()
        .await
        .map_err(|_| AuthError::ProviderExchangeIndeterminate)?;
    if bytes.len() > MAX_PROVIDER_BODY_BYTES {
        return Err(AuthError::ProviderExchangeIndeterminate);
    }
    Ok(bytes.to_vec())
}

fn random_context(audience: &str) -> Result<String, AuthError> {
    if !matches!(audience, MAC_AUDIENCE | IOS_AUDIENCE) {
        return Err(AuthError::ProviderNotAllowed);
    }
    let mut bytes = [0_u8; 32];
    getrandom::getrandom(&mut bytes).map_err(|_| AuthError::Vault)?;
    Ok(format!(
        "{APPLE_PROVIDER_CONFIG}:{audience}:apcr1_{}",
        URL_SAFE_NO_PAD.encode(bytes)
    ))
}

fn required_environment(name: &str) -> Result<String, AuthError> {
    let value = std::env::var(name).map_err(|_| AuthError::Vault)?;
    if !valid_identifier(&value, 255) {
        return Err(AuthError::Vault);
    }
    Ok(value)
}

fn secret_text_from_environment(prefix: &str) -> Result<String, AuthError> {
    let inline = std::env::var_os(prefix);
    let file = std::env::var_os(format!("{prefix}_FILE"));
    match (inline, file) {
        (Some(value), None) => value.into_string().map_err(|_| AuthError::Vault),
        (None, Some(path)) => {
            let path = Path::new(&path);
            if !path.is_absolute() {
                return Err(AuthError::Vault);
            }
            fs::read_to_string(path).map_err(|_| AuthError::Vault)
        }
        _ => Err(AuthError::Vault),
    }
}

fn valid_identifier(value: &str, max: usize) -> bool {
    !value.is_empty()
        && value.len() <= max
        && value
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'.' | b'-' | b'_'))
}

impl From<reqwest::Error> for AuthError {
    fn from(_: reqwest::Error) -> Self {
        Self::ProviderExchangeIndeterminate
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::auth_vault::AesGcmCredentialVault;
    use std::sync::atomic::{AtomicUsize, Ordering};

    #[derive(Clone)]
    struct FakeTransport {
        calls: Arc<AtomicUsize>,
        jwks: Vec<u8>,
    }

    #[async_trait]
    impl AppleTransport for FakeTransport {
        async fn fetch_jwks(&self) -> Result<Vec<u8>, AuthError> {
            self.calls.fetch_add(1, Ordering::SeqCst);
            Ok(self.jwks.clone())
        }

        async fn exchange_code(
            &self,
            _request: &AppleTokenRequest,
        ) -> Result<AppleTokenResponse, AuthError> {
            panic!("token endpoint must not be called by a JWKS test")
        }

        async fn revoke_credential(&self, _request: &AppleRevokeRequest) -> Result<(), AuthError> {
            panic!("revoke endpoint must not be called by a JWKS test")
        }
    }

    fn dummy_signer() -> AppleClientSecretSigner {
        AppleClientSecretSigner {
            team_id: "TESTTEAM".into(),
            key_id: "TESTKEY".into(),
            mac_client_id: MAC_AUDIENCE.into(),
            ios_client_id: IOS_AUDIENCE.into(),
            encoding_key: Arc::new(EncodingKey::from_secret(b"test-only-not-apple")),
        }
    }

    #[test]
    fn production_configuration_rejects_unregistered_audience() {
        let invalid = AppleClientSecretSigner::new(
            "TEAM123".into(),
            "KEY123".into(),
            "attacker.example".into(),
            IOS_AUDIENCE.into(),
            b"not a key",
        );
        assert!(matches!(invalid, Err(AuthError::ProviderNotAllowed)));
    }

    #[test]
    fn jwks_rejects_non_rs256_keys() {
        let set: AppleJwks = serde_json::from_value(serde_json::json!({"keys":[{
            "kty":"RSA","kid":"kid","use":"sig","alg":"none","n":"x","e":"AQAB"
        }]}))
        .unwrap();
        assert!(matches!(
            set.decoding_key("kid"),
            Some(Err(AuthError::InvalidExternalIdentity))
        ));
    }

    #[tokio::test]
    async fn injectable_transport_loads_an_rs256_jwk_without_provider_secrets() {
        let calls = Arc::new(AtomicUsize::new(0));
        let modulus = "v1Svd_SM577TRGCQQgUxfLriUNXmHgLL_2FyXMmooFneWzRSTTx2Sfb0UOti5fuwhIvEH8CkOyiwynVfyceHil1221PyxiHI9Tc51F8GEbW5ZnfwPhzREoHnHlHhmSbSglbug136v_Uf0UFUyOPAyatxNz8Cm9U5oLaEGoJ-nlAhbHjKsnlF7m5noZJVU4M6xBKwvqdHdSS18Ng76GvpseeItXsNzdzI8LyXhncTzAxgfKX2Ladk8Cs5HsOO8nU8w2zVvVnRDsjSHCLSlHUMCCAsr_PE1-WYlnZkcsF8uPagDYJ56DzEFx39iLE9C7Dn4WL4dlQ6c5aMJHycdK1tmw";
        let transport = FakeTransport {
            calls: calls.clone(),
            jwks: serde_json::to_vec(&serde_json::json!({"keys":[{
                "kty":"RSA","kid":"fixture-kid","use":"sig","alg":"RS256",
                "n":modulus,"e":"AQAB"
            }]}))
            .unwrap(),
        };
        let provider = ProductionAppleProvider::new(
            transport,
            dummy_signer(),
            AesGcmCredentialVault::new(1, [7; 32]).unwrap(),
        );
        let set = provider.fetch_jwks().await.unwrap();
        assert!(matches!(set.decoding_key("fixture-kid"), Some(Ok(_))));
        assert_eq!(calls.load(Ordering::SeqCst), 1);
    }

    #[tokio::test]
    async fn verifies_official_nested_apple_notification_shape_and_signature() {
        let now = 1_700_000_000_i64;
        let private_key = EncodingKey::from_rsa_pem(
            br"-----BEGIN RSA PRIVATE KEY-----
MIIEowIBAAKCAQEAmqpAlQaF3VYqHO2V2TAERubuvrWVGGWMxuE97pfwyVzwQRBa
fi0NJ9aVKqqoMnsvP7zS6wI+ZmuBtnS4WX8kq3ARveILBRWcczWbPEr6FEy12lqb
SOonUtfvEcz0URUDQ/7GgR1H+XXngQA3u/95Zn1R0oefg+Xx4seSadSCZzWBgkTM
wBqBh0gDATO7/nmyabHgh6DpajHhufFM3mUGv3eFTpfzhWWq6hvSZqRZx6PHzop7
eEw2ahxjy9jaisMeFohrWur7Ts6MwNKdvyQ88sgi2m+1vlUeDSnUvVWbdmsyInhX
fdq7ALwVRNJFPwlDvUMrGr3X2bf0FHGihVsO1QIDAQABAoIBAC3ul+VqHYFBIJqc
uF7a0rpXxNlgRdoL9oXtyJ2+A+VZM4SvHaDRMlH9eSlFq1Pqn3qXUjA25181WD1e
Zo01pCdBzhMNOWaWJ3NTnTmHrsMukOc691jtKSaCOF6Z9ojJ68FavYsEriZYrJrz
/JlZYq1cVFtoqafbNz25NTM2yE9r70ysgzreiezPLySTFHoZlUQ7eWhv+xU2G3I/
U/D4hf2wsbcCFvXMw3wozOOHGwJq3euxrnfQJqShYvn/Dd8BNLDmrgTICqJ8h1o0
PJP4W4+TF9HklukhsOtSKqL09PqNF2PvQCDqqlQ8perCGFgxq6Foi0+bRXzbF4FT
F+7da3UCgYEAx9+JkErZ6EqcMR7XS0yqC0GmGgkZvvohT2XWYYDSxxCj0UdllkeL
wRNMbB2oLRj2T/9umcR56RKhJeL18Hvarz1KTix+DtHklQjE7G2eS7mGgX4JaWqg
twb39cXpLPO/lKmrfcUqz+6OlcdOHMsnzQv5tjFo0vp7KUBjpJODodsCgYEAxhjL
8SNTB2PhGpx5tJABuOOqho7R1FWp8SUgAdcgb1jgDHlQ7r5LpSQiQ4sUbAIH5Dx+
75yp7dboqwyzuPTqkVxwx/FaxFZpmEvZCxzESAJVVBzTMh3LjSRT2/qmxE1Eghzq
u88W+FSnc7064WHftBPJ5qhz+vdM1ZvDr7XRqQ8CgYAiqSQs7p4NR2sApa2GNFxE
qXTJjQx27t956lob/IAQ31TZRP1b6zpUGCmnkhkJAQwt4Ujnx4ewoHdrn4kw0/mf
bAyHs/WEUmfGZIfpzDSoQxsNN7MgIcqPEtlLOK/wCLEPccD4hYmgF2mIldB4884K
I+qA6t6Xv7I9/BmLf71TAwKBgQCtUrLV6D9UPvqMqw39guZO27uvAbTroIwRdpcb
pRs28T8PCvJaAVv0QLpN+JlEqz42Xwv9IEi51Yg7aOCy2m+GAaiX+D+fe6/mVa6w
f1npW0lHT/Ula1ZWxssstJFHPgfMA/sJmfcSDhd5N78VxenSCGJmE0tu8QNj/mZo
DaBE1wKBgCDwK0X00kYOgEnoYx2dAEofLVNvAYUGrzvrNS2OTBivm1g5JXnQ7nHf
3tXa3o+7AhBVlbPuo4t5sV8Y0qWWd/w2vvnWlt0FT6hOqG/9ApoFmjCtxS43nEYI
gqqk1jbuKa8PdCy5+vf1bBAcHTFcM/W9njhLTvM2bp3g1fFwkcsm
-----END RSA PRIVATE KEY-----
",
        )
        .unwrap();
        let mut header = Header::new(Algorithm::RS256);
        header.kid = Some("fixture-notification-kid".into());
        let claims = serde_json::json!({
            "iss": APPLE_ISSUER,
            "aud": MAC_AUDIENCE,
            "iat": now,
            "jti": "fixture-jti-1",
            "events": {"type":"consent-revoked","sub":"apple-sub-1","event_time":now}
        });
        let token = encode(&header, &claims, &private_key).unwrap();
        let transport = FakeTransport {
            calls: Arc::new(AtomicUsize::new(0)),
            jwks: serde_json::to_vec(&serde_json::json!({"keys":[{
                "kty":"RSA","kid":"fixture-notification-kid","use":"sig","alg":"RS256",
                "n":"mqpAlQaF3VYqHO2V2TAERubuvrWVGGWMxuE97pfwyVzwQRBafi0NJ9aVKqqoMnsvP7zS6wI-ZmuBtnS4WX8kq3ARveILBRWcczWbPEr6FEy12lqbSOonUtfvEcz0URUDQ_7GgR1H-XXngQA3u_95Zn1R0oefg-Xx4seSadSCZzWBgkTMwBqBh0gDATO7_nmyabHgh6DpajHhufFM3mUGv3eFTpfzhWWq6hvSZqRZx6PHzop7eEw2ahxjy9jaisMeFohrWur7Ts6MwNKdvyQ88sgi2m-1vlUeDSnUvVWbdmsyInhXfdq7ALwVRNJFPwlDvUMrGr3X2bf0FHGihVsO1Q",
                "e":"AQAB"}]})).unwrap(),
        };
        let provider = ProductionAppleProvider::new(
            transport,
            dummy_signer(),
            AesGcmCredentialVault::new(1, [7; 32]).unwrap(),
        );
        let notification = provider.verify_s2s_notification(&token, now).await.unwrap();
        assert_eq!(notification.notification_type, "consent-revoked");
        assert_eq!(notification.subject, "apple-sub-1");
        assert_eq!(notification.event_time_unix, now);
        let invalid = encode(
            &header,
            &serde_json::json!({
                "iss": APPLE_ISSUER,
                "aud": MAC_AUDIENCE,
                "iat": now,
                "jti": "fixture-jti-2",
                "events": {"type":"CONSENT_REVOKED","sub":"apple-sub-1","event_time":now}
            }),
            &private_key,
        )
        .unwrap();
        assert_eq!(
            provider.verify_s2s_notification(&invalid, now).await,
            Err(AuthError::InvalidExternalIdentity)
        );
    }

    #[test]
    fn debug_output_redacts_provider_secrets() {
        let request = AppleTokenRequest {
            client_id: MAC_AUDIENCE.into(),
            client_secret: "secret-value".into(),
            authorization_code: "code-value".into(),
        };
        let debug = format!("{request:?}");
        assert!(!debug.contains("secret-value"));
        assert!(!debug.contains("code-value"));
    }
}
