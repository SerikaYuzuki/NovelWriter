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
use std::{fs, path::Path};
use zeroize::Zeroizing;

const MAGIC: &[u8; 8] = b"FMAEV001";
const NONCE_BYTES: usize = 12;
const WRAPPED_DEK_BYTES: usize = 48;
const HEADER_BYTES: usize = MAGIC.len() + NONCE_BYTES * 2 + WRAPPED_DEK_BYTES;

#[derive(Clone)]
pub struct AesGcmCredentialVault {
    key_version: i32,
    kek: [u8; 32],
}

impl AesGcmCredentialVault {
    pub fn new(key_version: i32, kek: [u8; 32]) -> Result<Self, AuthError> {
        if key_version < 1 {
            return Err(AuthError::Vault);
        }
        Ok(Self { key_version, kek })
    }

    pub fn from_environment() -> Result<Self, AuthError> {
        let version = std::env::var("FUMINIWA_AUTH_VAULT_KEY_VERSION")
            .map_err(|_| AuthError::Vault)?
            .parse::<i32>()
            .map_err(|_| AuthError::Vault)?;
        Self::new(
            version,
            secret_key_from_environment("FUMINIWA_AUTH_VAULT_KEY")?,
        )
    }
}

#[async_trait]
impl CredentialVault for AesGcmCredentialVault {
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
        if secret.key_version != self.key_version
            || secret.ciphertext.len() < HEADER_BYTES + 16
            || &secret.ciphertext[..MAGIC.len()] != MAGIC
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
        let dek_bytes = cipher(&self.kek)?.decrypt(
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
}
