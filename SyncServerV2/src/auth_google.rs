//! Server-side Google OpenID Connect verification for browser authentication.
//! The OAuth client secret and authorization code never enter an app binary.

use crate::auth_domain::AuthError;
use jsonwebtoken::{decode, decode_header, Algorithm, DecodingKey, Validation};
use serde::Deserialize;
use std::{fs, time::Duration};

const GOOGLE_TOKEN_ENDPOINT: &str = "https://oauth2.googleapis.com/token";
const GOOGLE_JWKS_ENDPOINT: &str = "https://www.googleapis.com/oauth2/v3/certs";
const GOOGLE_CLIENT_ID: &str =
    "560354700432-aq87npqhidi1m4n671m8pb9bugml609d.apps.googleusercontent.com";
const GOOGLE_CALLBACK: &str = "https://sync.serika.work/v2/auth/browser/google/callback";
const MAX_PROVIDER_RESPONSE: usize = 128 * 1024;

#[derive(Clone)]
pub struct GoogleOAuthProvider {
    client: reqwest::Client,
    client_secret: String,
}

#[derive(Debug, Clone, Eq, PartialEq)]
pub struct VerifiedGoogleIdentity {
    pub subject: String,
    pub authenticated_at_unix: i64,
}

#[derive(Deserialize)]
struct TokenResponse {
    id_token: String,
}

#[derive(Deserialize)]
struct GoogleClaims {
    iss: String,
    aud: String,
    sub: String,
    exp: i64,
    iat: i64,
    nonce: Option<String>,
    azp: Option<String>,
}

#[derive(Deserialize)]
struct Jwks {
    keys: Vec<Jwk>,
}

#[derive(Deserialize)]
struct Jwk {
    kid: String,
    kty: String,
    #[serde(rename = "use")]
    key_use: Option<String>,
    alg: Option<String>,
    n: String,
    e: String,
}

impl GoogleOAuthProvider {
    pub fn from_environment() -> Result<Self, AuthError> {
        let path = std::env::var("FUMINIWA_GOOGLE_CLIENT_SECRET_FILE")
            .map_err(|_| AuthError::ProviderNotAllowed)?;
        let secret = fs::read_to_string(path).map_err(|_| AuthError::Vault)?;
        Self::new(secret.trim_end_matches(['\r', '\n']).to_owned())
    }

    pub fn new(client_secret: String) -> Result<Self, AuthError> {
        if client_secret.is_empty() || client_secret.len() > 4096 {
            return Err(AuthError::ProviderNotAllowed);
        }
        let client = reqwest::Client::builder()
            .https_only(true)
            .redirect(reqwest::redirect::Policy::none())
            .connect_timeout(Duration::from_secs(5))
            .timeout(Duration::from_secs(12))
            .user_agent("FUMINIWA-Snapshot-Sync-v2")
            .build()
            .map_err(|_| AuthError::Vault)?;
        Ok(Self {
            client,
            client_secret,
        })
    }

    pub async fn exchange_and_verify(
        &self,
        code: &str,
        expected_nonce: &str,
        now_unix: i64,
    ) -> Result<VerifiedGoogleIdentity, AuthError> {
        if code.is_empty()
            || code.len() > 4096
            || expected_nonce.len() < 32
            || expected_nonce.len() > 256
        {
            return Err(AuthError::InvalidExternalIdentity);
        }
        let response = self
            .client
            .post(GOOGLE_TOKEN_ENDPOINT)
            .form(&[
                ("code", code),
                ("client_id", GOOGLE_CLIENT_ID),
                ("client_secret", self.client_secret.as_str()),
                ("redirect_uri", GOOGLE_CALLBACK),
                ("grant_type", "authorization_code"),
            ])
            .send()
            .await
            .map_err(|_| AuthError::ProviderExchangeIndeterminate)?;
        let body = bounded_body(response).await?;
        let token: TokenResponse =
            serde_json::from_slice(&body).map_err(|_| AuthError::InvalidExternalIdentity)?;
        if token.id_token.is_empty() || token.id_token.len() > 32_768 {
            return Err(AuthError::InvalidExternalIdentity);
        }
        self.verify_id_token(&token.id_token, expected_nonce, now_unix)
            .await
    }

    async fn verify_id_token(
        &self,
        token: &str,
        expected_nonce: &str,
        now_unix: i64,
    ) -> Result<VerifiedGoogleIdentity, AuthError> {
        let jwks_body = bounded_body(
            self.client
                .get(GOOGLE_JWKS_ENDPOINT)
                .send()
                .await
                .map_err(|_| AuthError::ProviderExchangeIndeterminate)?,
        )
        .await?;
        let jwks: Jwks =
            serde_json::from_slice(&jwks_body).map_err(|_| AuthError::InvalidExternalIdentity)?;
        Self::verify_with_keys(token, expected_nonce, now_unix, jwks)
    }

    fn verify_with_keys(
        token: &str,
        expected_nonce: &str,
        now_unix: i64,
        jwks: Jwks,
    ) -> Result<VerifiedGoogleIdentity, AuthError> {
        let header = decode_header(token).map_err(|_| AuthError::InvalidExternalIdentity)?;
        if header.alg != Algorithm::RS256 {
            return Err(AuthError::InvalidExternalIdentity);
        }
        let kid = header.kid.ok_or(AuthError::InvalidExternalIdentity)?;
        let jwk = jwks
            .keys
            .iter()
            .find(|key| key.kid == kid)
            .ok_or(AuthError::InvalidExternalIdentity)?;
        if jwk.kty != "RSA"
            || jwk.key_use.as_deref().is_some_and(|value| value != "sig")
            || jwk.alg.as_deref().is_some_and(|value| value != "RS256")
        {
            return Err(AuthError::InvalidExternalIdentity);
        }
        let key = DecodingKey::from_rsa_components(&jwk.n, &jwk.e)
            .map_err(|_| AuthError::InvalidExternalIdentity)?;
        let mut validation = Validation::new(Algorithm::RS256);
        validation.set_issuer(&["https://accounts.google.com", "accounts.google.com"]);
        validation.set_audience(&[GOOGLE_CLIENT_ID]);
        validation.set_required_spec_claims(&["iss", "aud", "sub", "exp", "iat", "nonce"]);
        validation.leeway = 60;
        let claims = decode::<GoogleClaims>(token, &key, &validation)
            .map_err(|_| AuthError::InvalidExternalIdentity)?
            .claims;
        Self::check_claims(claims, expected_nonce, now_unix)
    }

    fn check_claims(
        claims: GoogleClaims,
        expected_nonce: &str,
        now_unix: i64,
    ) -> Result<VerifiedGoogleIdentity, AuthError> {
        if !matches!(
            claims.iss.as_str(),
            "https://accounts.google.com" | "accounts.google.com"
        ) || claims.aud != GOOGLE_CLIENT_ID
            || claims
                .azp
                .as_deref()
                .is_some_and(|value| value != GOOGLE_CLIENT_ID)
            || claims.sub.is_empty()
            || claims.sub.len() > 512
            || claims.sub.bytes().any(|byte| byte == 0)
            || claims.nonce.as_deref() != Some(expected_nonce)
            || claims.iat > now_unix + 60
            || claims.exp <= now_unix - 60
        {
            return Err(AuthError::InvalidExternalIdentity);
        }
        Ok(VerifiedGoogleIdentity {
            subject: claims.sub,
            authenticated_at_unix: claims.iat,
        })
    }
}

async fn bounded_body(mut response: reqwest::Response) -> Result<Vec<u8>, AuthError> {
    let status = response.status();
    if response
        .content_length()
        .is_some_and(|length| length > MAX_PROVIDER_RESPONSE as u64)
    {
        return Err(AuthError::ProviderExchangeIndeterminate);
    }
    let mut body = Vec::new();
    while let Some(chunk) = response
        .chunk()
        .await
        .map_err(|_| AuthError::ProviderExchangeIndeterminate)?
    {
        if chunk.len() > MAX_PROVIDER_RESPONSE - body.len() {
            return Err(AuthError::ProviderExchangeIndeterminate);
        }
        body.extend_from_slice(&chunk);
    }
    if !status.is_success() {
        return if status.is_server_error() {
            Err(AuthError::ProviderExchangeIndeterminate)
        } else {
            Err(AuthError::InvalidExternalIdentity)
        };
    }
    Ok(body)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn claims() -> GoogleClaims {
        GoogleClaims {
            iss: "https://accounts.google.com".into(),
            aud: GOOGLE_CLIENT_ID.into(),
            sub: "stable-google-subject".into(),
            exp: 2_000,
            iat: 1_000,
            nonce: Some("expected-nonce".into()),
            azp: None,
        }
    }

    #[test]
    fn signed_token_rejects_tampering_and_wrong_nonce() {
        let now = chrono::Utc::now().timestamp();
        let key = jsonwebtoken::EncodingKey::from_rsa_pem(include_bytes!(
            "../tests/support/oidc-test-key.pem"
        ))
        .unwrap();
        let mut header = jsonwebtoken::Header::new(Algorithm::RS256);
        header.kid = Some("fixture-key".into());
        let claims = serde_json::json!({"iss":"https://accounts.google.com","aud":GOOGLE_CLIENT_ID,"sub":"fixture-subject","iat":now,"exp":now+300,"nonce":"fixture-nonce"});
        let token = jsonwebtoken::encode(&header, &claims, &key).unwrap();
        let keys = || {
            serde_json::from_value::<Jwks>(serde_json::json!({"keys":[{"kid":"fixture-key","kty":"RSA","alg":"RS256","use":"sig","e":"AQAB","n":"mqpAlQaF3VYqHO2V2TAERubuvrWVGGWMxuE97pfwyVzwQRBafi0NJ9aVKqqoMnsvP7zS6wI-ZmuBtnS4WX8kq3ARveILBRWcczWbPEr6FEy12lqbSOonUtfvEcz0URUDQ_7GgR1H-XXngQA3u_95Zn1R0oefg-Xx4seSadSCZzWBgkTMwBqBh0gDATO7_nmyabHgh6DpajHhufFM3mUGv3eFTpfzhWWq6hvSZqRZx6PHzop7eEw2ahxjy9jaisMeFohrWur7Ts6MwNKdvyQ88sgi2m-1vlUeDSnUvVWbdmsyInhXfdq7ALwVRNJFPwlDvUMrGr3X2bf0FHGihVsO1Q"}]})).unwrap()
        };
        assert!(
            GoogleOAuthProvider::verify_with_keys(&token, "fixture-nonce", now, keys()).is_ok()
        );
        assert!(GoogleOAuthProvider::verify_with_keys(&token, "other-nonce", now, keys()).is_err());
        let mut parts = token.split('.').map(str::to_owned).collect::<Vec<_>>();
        use base64::Engine;
        parts[1]=base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(serde_json::to_vec(&serde_json::json!({"iss":"https://accounts.google.com","aud":GOOGLE_CLIENT_ID,"sub":"attacker","iat":now,"exp":now+300,"nonce":"fixture-nonce"})).unwrap());
        assert!(GoogleOAuthProvider::verify_with_keys(
            &parts.join("."),
            "fixture-nonce",
            now,
            keys()
        )
        .is_err());
    }

    #[test]
    fn only_verified_subject_identifies_google_account() {
        let identity =
            GoogleOAuthProvider::check_claims(claims(), "expected-nonce", 1_100).unwrap();
        assert_eq!(identity.subject, "stable-google-subject");
        let mut wrong_nonce = claims();
        wrong_nonce.nonce = Some("other-nonce".into());
        assert_eq!(
            GoogleOAuthProvider::check_claims(wrong_nonce, "expected-nonce", 1_100),
            Err(AuthError::InvalidExternalIdentity)
        );
        let mut wrong_audience = claims();
        wrong_audience.aud = "another-client".into();
        assert_eq!(
            GoogleOAuthProvider::check_claims(wrong_audience, "expected-nonce", 1_100),
            Err(AuthError::InvalidExternalIdentity)
        );
    }
}
