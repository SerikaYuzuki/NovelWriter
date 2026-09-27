//! Production credential encryption for Auth v1.
//!
//! The database receives only a versioned envelope. A random data-encryption
//! key protects each value and is itself wrapped by the configured KEK.

use crate::auth_domain::{AuthError, CredentialVault, SealedSecret};
use aes_gcm::{
    aead::{Aead, Payload},
    Aes256Gcm, KeyInit, Nonce,
};
use async_trait::async_trait;
use base64::{engine::general_purpose::URL_SAFE_NO_PAD, Engine};
use std::{collections::BTreeMap, fs, path::Path, sync::Arc};
use zeroize::Zeroizing;

const MAGIC: &[u8; 8] = b"FMAEV001";
const NONCE_BYTES: usize = 12;
const WRAPPED_DEK_BYTES: usize = 48;
const HEADER_BYTES: usize = MAGIC.len() + NONCE_BYTES * 2 + WRAPPED_DEK_BYTES;

#[derive(Clone)]
pub struct AesGcmCredentialVault {
    key_version: i32,
    kek: [u8; 32],
    keyring: Arc<BTreeMap<i32, [u8; 32]>>,
}

impl AesGcmCredentialVault {
    pub fn new(key_version: i32, kek: [u8; 32]) -> Result<Self, AuthError> {
        if key_version < 1 {
            return Err(AuthError::Vault);
        }
        Ok(Self {
            key_version,
            kek,
            keyring: Arc::new(BTreeMap::from([(key_version, kek)])),
        })
    }

    pub fn with_keyring(
        key_version: i32,
        kek: [u8; 32],
        mut keyring: BTreeMap<i32, [u8; 32]>,
    ) -> Result<Self, AuthError> {
        if key_version < 1 {
            return Err(AuthError::Vault);
        }
        keyring.insert(key_version, kek);
        Ok(Self {
            key_version,
            kek,
            keyring: Arc::new(keyring),
        })
    }

    pub fn from_environment() -> Result<Self, AuthError> {
        let version = std::env::var("FUMINIWA_AUTH_VAULT_KEY_VERSION")
            .map_err(|_| AuthError::Vault)?
            .parse::<i32>()
            .map_err(|_| AuthError::Vault)?;
        let active = secret_key_from_environment("FUMINIWA_AUTH_VAULT_KEY")?;
        let mut keyring = BTreeMap::new();
        if let Some(path) = std::env::var_os("FUMINIWA_AUTH_VAULT_KEYRING_FILE") {
            let raw = fs::read(path).map_err(|_| AuthError::Vault)?;
            let values: serde_json::Map<String, serde_json::Value> =
                serde_json::from_slice(&raw).map_err(|_| AuthError::Vault)?;
            for (version_text, encoded) in values {
                let version = version_text.parse::<i32>().map_err(|_| AuthError::Vault)?;
                let encoded = encoded.as_str().ok_or(AuthError::Vault)?;
                let bytes = URL_SAFE_NO_PAD
                    .decode(encoded)
                    .map_err(|_| AuthError::Vault)?;
                keyring.insert(version, bytes.try_into().map_err(|_| AuthError::Vault)?);
            }
        }
        Self::with_keyring(version, active, keyring)
    }
}

#[async_trait]
impl CredentialVault for AesGcmCredentialVault {
    fn active_key_version(&self) -> i32 {
        self.key_version
    }

    async fn seal(
        &self,
        purpose: &str,
        row_id: &str,
        plaintext: &[u8],
    ) -> Result<SealedSecret, AuthError> {
        validate_context(purpose, row_id)?;
        let mut dek = Zeroizing::new([0_u8; 32]);
        let mut wrap_nonce = [0_u8; NONCE_BYTES];
        let mut payload_nonce = [0_u8; NONCE_BYTES];
        getrandom::getrandom(&mut *dek).map_err(|_| AuthError::Vault)?;
        getrandom::getrandom(&mut wrap_nonce).map_err(|_| AuthError::Vault)?;
        getrandom::getrandom(&mut payload_nonce).map_err(|_| AuthError::Vault)?;

        let wrap_aad = aad(b"FUMINIWA-AUTH-VAULT-WRAP-V1", purpose, row_id)?;
        let wrapped = cipher(&self.kek)?.encrypt(
            Nonce::from_slice(&wrap_nonce),
            Payload {
                msg: dek.as_slice(),
                aad: &wrap_aad,
            },
        )?;
        if wrapped.len() != WRAPPED_DEK_BYTES {
            return Err(AuthError::Vault);
        }
        let payload_aad = aad(b"FUMINIWA-AUTH-VAULT-PAYLOAD-V1", purpose, row_id)?;
        let encrypted = cipher(&dek)?.encrypt(
            Nonce::from_slice(&payload_nonce),
            Payload {
                msg: plaintext,
                aad: &payload_aad,
            },
        )?;

        let mut envelope = Vec::with_capacity(HEADER_BYTES + encrypted.len());
        envelope.extend_from_slice(MAGIC);
        envelope.extend_from_slice(&wrap_nonce);
        envelope.extend_from_slice(&payload_nonce);
        envelope.extend_from_slice(&wrapped);
        envelope.extend_from_slice(&encrypted);
        Ok(SealedSecret {
            key_version: self.key_version,
            ciphertext: envelope,
        })
    }

    async fn open(
        &self,
        purpose: &str,
        row_id: &str,
        secret: &SealedSecret,
    ) -> Result<Vec<u8>, AuthError> {
        validate_context(purpose, row_id)?;
        let Some(kek) = self.keyring.get(&secret.key_version) else {
            return Err(AuthError::Vault);
        };
        if secret.ciphertext.len() < HEADER_BYTES + 16 || &secret.ciphertext[..MAGIC.len()] != MAGIC
        {
            return Err(AuthError::Vault);
        }
        let wrap_start = MAGIC.len();
        let payload_start = wrap_start + NONCE_BYTES;
        let dek_start = payload_start + NONCE_BYTES;
        let body_start = dek_start + WRAPPED_DEK_BYTES;
        let wrap_nonce = &secret.ciphertext[wrap_start..payload_start];
        let payload_nonce = &secret.ciphertext[payload_start..dek_start];
        let wrapped = &secret.ciphertext[dek_start..body_start];
        let encrypted = &secret.ciphertext[body_start..];

        let wrap_aad = aad(b"FUMINIWA-AUTH-VAULT-WRAP-V1", purpose, row_id)?;
        let dek_bytes = cipher(kek)?.decrypt(
            Nonce::from_slice(wrap_nonce),
            Payload {
                msg: wrapped,
                aad: &wrap_aad,
            },
        )?;
        let dek: Zeroizing<[u8; 32]> =
            Zeroizing::new(dek_bytes.try_into().map_err(|_| AuthError::Vault)?);
        let payload_aad = aad(b"FUMINIWA-AUTH-VAULT-PAYLOAD-V1", purpose, row_id)?;
        cipher(&dek)?
            .decrypt(
                Nonce::from_slice(payload_nonce),
                Payload {
                    msg: encrypted,
                    aad: &payload_aad,
                },
            )
            .map_err(|_| AuthError::Vault)
    }
}

fn cipher(key: &[u8; 32]) -> Result<Aes256Gcm, AuthError> {
    Aes256Gcm::new_from_slice(key).map_err(|_| AuthError::Vault)
}

fn aad(domain: &[u8], purpose: &str, row_id: &str) -> Result<Vec<u8>, AuthError> {
    let mut result = domain.to_vec();
    for part in [purpose.as_bytes(), row_id.as_bytes()] {
        let length = u32::try_from(part.len()).map_err(|_| AuthError::Vault)?;
        result.extend_from_slice(&length.to_be_bytes());
        result.extend_from_slice(part);
    }
    Ok(result)
}

fn validate_context(purpose: &str, row_id: &str) -> Result<(), AuthError> {
    if purpose.is_empty()
        || purpose.len() > 128
        || row_id.is_empty()
        || row_id.len() > 512
        || purpose.bytes().any(|byte| byte < 0x21 || byte == 0x7f)
        || row_id.bytes().any(|byte| byte < 0x21 || byte == 0x7f)
    {
        return Err(AuthError::Vault);
    }
    Ok(())
}

pub fn secret_key_from_environment(prefix: &str) -> Result<[u8; 32], AuthError> {
    let inline_name = format!("{prefix}_BASE64URL");
    let file_name = format!("{prefix}_FILE");
    let inline = std::env::var_os(&inline_name);
    let file = std::env::var_os(&file_name);
    let encoded = match (inline, file) {
        (Some(value), None) => value.into_string().map_err(|_| AuthError::Vault)?,
        (None, Some(path)) => read_secret_file(Path::new(&path))?,
        _ => return Err(AuthError::Vault),
    };
    let decoded = URL_SAFE_NO_PAD
        .decode(encoded.trim())
        .map_err(|_| AuthError::Vault)?;
    decoded.try_into().map_err(|_| AuthError::Vault)
}

/// Builds the closed, length-prefixed context used as the vault row binding.
/// The encoded value is opaque to callers but authenticates table kind, row
/// identity and the provider/account scope that owns the secret.
pub fn canonical_row_context(
    table: &str,
    row_id: &str,
    account_id: &str,
    identity_id: &str,
    provider_config_id: &str,
    audience: &str,
) -> Result<String, AuthError> {
    let mut bytes = b"FUMINIWA-AUTH-ROW-CONTEXT-V1".to_vec();
    for part in [
        table,
        row_id,
        account_id,
        identity_id,
        provider_config_id,
        audience,
    ] {
        let length = u32::try_from(part.len()).map_err(|_| AuthError::Vault)?;
        bytes.extend_from_slice(&length.to_be_bytes());
        bytes.extend_from_slice(part.as_bytes());
    }
    Ok(URL_SAFE_NO_PAD.encode(bytes))
}

fn read_secret_file(path: &Path) -> Result<String, AuthError> {
    if !path.is_absolute() {
        return Err(AuthError::Vault);
    }
    fs::read_to_string(path).map_err(|_| AuthError::Vault)
}

impl From<aes_gcm::Error> for AuthError {
    fn from(_: aes_gcm::Error) -> Self {
        Self::Vault
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn round_trip_is_random_and_context_bound() {
        let vault = AesGcmCredentialVault::new(3, [7; 32]).unwrap();
        let first = vault.seal("receipt", "row-a", b"secret").await.unwrap();
        let second = vault.seal("receipt", "row-a", b"secret").await.unwrap();
        assert_ne!(first.ciphertext, second.ciphertext);
        assert_eq!(
            vault.open("receipt", "row-a", &first).await.unwrap(),
            b"secret"
        );
        assert_eq!(
            vault.open("receipt", "row-b", &first).await,
            Err(AuthError::Vault)
        );
        assert_eq!(
            vault.open("other", "row-a", &first).await,
            Err(AuthError::Vault)
        );
    }

    #[tokio::test]
    async fn rejects_tampering_and_wrong_key_version() {
        let vault = AesGcmCredentialVault::new(1, [9; 32]).unwrap();
        let mut sealed = vault.seal("receipt", "row", b"secret").await.unwrap();
        let last = sealed.ciphertext.len() - 1;
        sealed.ciphertext[last] ^= 1;
        assert_eq!(
            vault.open("receipt", "row", &sealed).await,
            Err(AuthError::Vault)
        );
        sealed.key_version = 2;
        assert_eq!(
            vault.open("receipt", "row", &sealed).await,
            Err(AuthError::Vault)
        );
    }

    #[tokio::test]
    async fn dual_decrypts_old_version_and_writes_active_version() {
        let old = AesGcmCredentialVault::new(1, [1; 32]).unwrap();
        let old_secret = old.seal("receipt", "row", b"secret").await.unwrap();
        let mut old_keys = BTreeMap::new();
        old_keys.insert(1, [1; 32]);
        let rotated = AesGcmCredentialVault::with_keyring(2, [2; 32], old_keys).unwrap();
        assert_eq!(rotated.active_key_version(), 2);
        assert_eq!(
            rotated.open("receipt", "row", &old_secret).await.unwrap(),
            b"secret"
        );
        let fresh = rotated.seal("receipt", "row", b"secret").await.unwrap();
        assert_eq!(fresh.key_version, 2);
        assert_eq!(
            rotated.open("receipt", "row", &fresh).await.unwrap(),
            b"secret"
        );
    }

    #[tokio::test]
    async fn canonical_row_context_rejects_identity_or_audience_swap() {
        let vault = AesGcmCredentialVault::new(1, [3; 32]).unwrap();
        let first = canonical_row_context(
            "provider_credentials",
            "credential-a",
            "account-a",
            "identity-a",
            "apple-primary-fuminiwa-v1",
            "dev.serikayuzuki.fuminiwa",
        )
        .unwrap();
        let second = canonical_row_context(
            "provider_credentials",
            "credential-b",
            "account-a",
            "identity-a",
            "apple-primary-fuminiwa-v1",
            "dev.serikayuzuki.fuminiwa.ios",
        )
        .unwrap();
        let secret = vault
            .seal("apple_provider_refresh_v1", &first, b"provider-refresh")
            .await
            .unwrap();
        assert_eq!(
            vault
                .open("apple_provider_refresh_v1", &second, &secret)
                .await,
            Err(AuthError::Vault)
        );
    }
}
