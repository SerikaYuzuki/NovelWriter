//! Closed, exact-JCS parser for Auth v1 mutation commands.
//!
//! HTTP is intentionally outside this module. Callers pass the exact received
//! bytes and receive a typed command plus the server-computed SHA-256 digest.

use crate::auth_domain::{
    digest_request, AccountId, AuthError, AuthenticatedPrincipal, ChallengeId, OperationId,
    ProviderConfigId, SessionGrant, SessionId, TenantId, CREATE_CHALLENGE_COMMAND,
    EXCHANGE_APPLE_COMMAND, REVOKE_SESSION_COMMAND, ROTATE_REFRESH_COMMAND,
};
use crate::domain::canonical_json;
use crate::domain::PROTOCOL_EPOCH;
use base64::{engine::general_purpose::URL_SAFE_NO_PAD, Engine};
use chrono::{DateTime, SecondsFormat, Utc};
use serde::de::{Error as _, MapAccess, SeqAccess, Visitor};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::{collections::HashSet, fmt};
use uuid::Uuid;

pub const MAX_AUTH_COMMAND_BYTES: usize = 65_536;

#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum ClientPlatform {
    Macos,
    Ios,
    Ipados,
}
impl ClientPlatform {
    pub fn audience(self) -> &'static str {
        match self {
            Self::Macos => "dev.serikayuzuki.fuminiwa",
            Self::Ios | Self::Ipados => "dev.serikayuzuki.fuminiwa.ios",
        }
    }
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Macos => "macos",
            Self::Ios => "ios",
            Self::Ipados => "ipados",
        }
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct CreateChallengeCommand {
    pub operation_id: OperationId,
    pub platform: ClientPlatform,
}
#[derive(Clone, Eq, PartialEq)]
pub struct ExchangeAppleCommand {
    pub operation_id: OperationId,
    pub challenge_id: ChallengeId,
    pub state: String,
    pub authorization_code: String,
    pub identity_token: String,
}
impl fmt::Debug for ExchangeAppleCommand {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("ExchangeAppleCommand")
            .field("operation_id", &self.operation_id)
            .field("challenge_id", &self.challenge_id)
            .field("state", &"<redacted>")
            .field("authorization_code", &"<redacted>")
            .field("identity_token", &"<redacted>")
            .finish()
    }
}
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct RotateRefreshCommand {
    pub operation_id: OperationId,
}
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct RevokeSessionCommand {
    pub operation_id: OperationId,
}
#[derive(Clone, Debug, Eq, PartialEq)]
pub enum AuthCommand {
    CreateChallenge(CreateChallengeCommand),
    ExchangeApple(ExchangeAppleCommand),
    RotateRefresh(RotateRefreshCommand),
    RevokeCurrentSession(RevokeSessionCommand),
}

#[derive(Clone, Eq, PartialEq)]
pub struct ParsedAuthCommand {
    pub command: AuthCommand,
    pub canonical_bytes: Vec<u8>,
    pub digest: [u8; 32],
}
impl fmt::Debug for ParsedAuthCommand {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("ParsedAuthCommand")
            .field("command", &self.command)
            .field("canonical_bytes", &"<redacted>")
            .field("digest", &"<redacted>")
            .finish()
    }
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct OperationReceiptWire {
    command_kind: String,
    operation_id: OperationId,
    replay_until: String,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct RotationReceiptWire {
    command_kind: String,
    replay_until: String,
    rotation_id: OperationId,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct SessionBindingWire {
    account_auth_epoch: i64,
    account_fence: String,
    account_id: AccountId,
    server_instance_id: String,
    session_id: SessionId,
    sync_protocol_epoch: i64,
}

#[derive(Clone, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct SessionTokensWire {
    access_token: String,
    access_token_expires_at: String,
    refresh_generation: i64,
    refresh_token: String,
    refresh_token_expires_at: String,
    token_type: String,
}

#[derive(Clone, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct ExchangeResponseWire {
    binding: SessionBindingWire,
    receipt: OperationReceiptWire,
    tokens: SessionTokensWire,
}

#[derive(Clone, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct RefreshResponseWire {
    binding: SessionBindingWire,
    receipt: RotationReceiptWire,
    tokens: SessionTokensWire,
}

#[derive(Clone, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct ChallengeResponseWire {
    audience: String,
    challenge_id: ChallengeId,
    expires_at: String,
    flow: String,
    nonce: String,
    provider: String,
    provider_configuration_id: ProviderConfigId,
    receipt: OperationReceiptWire,
    requested_scopes: Vec<String>,
    state: String,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct RevokeResponseWire {
    account_auth_epoch: i64,
    account_fence: String,
    fence_changed: bool,
    receipt: OperationReceiptWire,
    revoked_at: String,
    scope: String,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct ContentProtectionWire {
    e2ee: bool,
    profile: String,
    server_can_read_content: bool,
    user_managed_content_key: bool,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct MeResponseWire {
    binding: SessionBindingWire,
    content_protection: ContentProtectionWire,
}

pub fn encode_challenge_response(
    result: &crate::auth_application::ChallengeResult,
    replay_until_unix: i64,
) -> Result<Vec<u8>, AuthError> {
    canonical_value(&ChallengeResponseWire {
        audience: result.audience.clone(),
        challenge_id: result.challenge_id.clone(),
        expires_at: timestamp(result.expires_at_unix)?,
        flow: "native".into(),
        nonce: result.nonce.clone(),
        provider: "apple".into(),
        provider_configuration_id: result.provider_config_id.clone(),
        receipt: OperationReceiptWire {
            command_kind: CREATE_CHALLENGE_COMMAND.into(),
            operation_id: result.operation_id.clone(),
            replay_until: timestamp(replay_until_unix)?,
        },
        requested_scopes: Vec::new(),
        state: result.state.clone(),
    })
}

pub fn decode_challenge_response(
    bytes: &[u8],
) -> Result<crate::auth_application::ChallengeResult, AuthError> {
    let wire: ChallengeResponseWire = decode_canonical(bytes)?;
    if wire.flow != "native"
        || wire.provider != "apple"
        || wire.provider_configuration_id.as_str() != crate::auth_domain::APPLE_PROVIDER_CONFIG
        || !wire.requested_scopes.is_empty()
        || wire.receipt.command_kind != CREATE_CHALLENGE_COMMAND
        || operation(wire.receipt.operation_id.as_str()).is_err()
        || uuid(wire.challenge_id.as_str()).is_err()
        || base64url_256(&wire.state).is_err()
        || base64url_256(&wire.nonce).is_err()
        || !matches!(
            wire.audience.as_str(),
            "dev.serikayuzuki.fuminiwa" | "dev.serikayuzuki.fuminiwa.ios"
        )
    {
        return Err(AuthError::Vault);
    }
    Ok(crate::auth_application::ChallengeResult {
        challenge_id: wire.challenge_id,
        operation_id: wire.receipt.operation_id,
        provider_config_id: wire.provider_configuration_id,
        audience: wire.audience,
        state: wire.state,
        nonce: wire.nonce,
        expires_at_unix: parse_timestamp(&wire.expires_at)?,
    })
}

pub fn encode_exchange_response(
    grant: &SessionGrant,
    server_instance_id: &str,
    operation_id: &OperationId,
) -> Result<Vec<u8>, AuthError> {
    canonical_value(&ExchangeResponseWire {
        binding: binding(grant, server_instance_id)?,
        receipt: OperationReceiptWire {
            command_kind: EXCHANGE_APPLE_COMMAND.into(),
            operation_id: operation_id.clone(),
            replay_until: timestamp(grant.refresh_expires_at_unix)?,
        },
        tokens: tokens(grant)?,
    })
}

pub fn encode_refresh_response(
    grant: &SessionGrant,
    server_instance_id: &str,
    operation_id: &OperationId,
) -> Result<Vec<u8>, AuthError> {
    canonical_value(&RefreshResponseWire {
        binding: binding(grant, server_instance_id)?,
        receipt: RotationReceiptWire {
            command_kind: ROTATE_REFRESH_COMMAND.into(),
            replay_until: timestamp(grant.refresh_expires_at_unix)?,
            rotation_id: operation_id.clone(),
        },
        tokens: tokens(grant)?,
    })
}

pub fn decode_exchange_response(
    bytes: &[u8],
    tenant_id: TenantId,
) -> Result<SessionGrant, AuthError> {
    let wire: ExchangeResponseWire = decode_canonical(bytes)?;
    if wire.receipt.command_kind != EXCHANGE_APPLE_COMMAND
        || operation(wire.receipt.operation_id.as_str()).is_err()
    {
        return Err(AuthError::Vault);
    }
    grant(wire.binding, wire.tokens, tenant_id)
}

pub fn decode_refresh_response(
    bytes: &[u8],
    tenant_id: TenantId,
) -> Result<SessionGrant, AuthError> {
    let wire: RefreshResponseWire = decode_canonical(bytes)?;
    if wire.receipt.command_kind != ROTATE_REFRESH_COMMAND
        || operation(wire.receipt.rotation_id.as_str()).is_err()
    {
        return Err(AuthError::Vault);
    }
    grant(wire.binding, wire.tokens, tenant_id)
}

pub fn session_response_account_id(bytes: &[u8]) -> Result<AccountId, AuthError> {
    let value: Value = serde_json::from_slice(bytes).map_err(|_| AuthError::Vault)?;
    AccountId::new(
        value
            .get("binding")
            .and_then(|binding| binding.get("accountId"))
            .and_then(Value::as_str)
            .ok_or(AuthError::Vault)?,
    )
}

pub fn encode_revoke_response(
    account_auth_epoch: i64,
    account_fence: &[u8],
    operation_id: &OperationId,
    revoked_at_unix: i64,
    replay_until_unix: i64,
) -> Result<Vec<u8>, AuthError> {
    if account_fence.len() != 32 {
        return Err(AuthError::InvalidFence);
    }
    canonical_value(&RevokeResponseWire {
        account_auth_epoch,
        account_fence: URL_SAFE_NO_PAD.encode(account_fence),
        fence_changed: false,
        receipt: OperationReceiptWire {
            command_kind: REVOKE_SESSION_COMMAND.into(),
            operation_id: operation_id.clone(),
            replay_until: timestamp(replay_until_unix)?,
        },
        revoked_at: timestamp(revoked_at_unix)?,
        scope: "currentSession".into(),
    })
}

pub fn encode_me_response(
    principal: &AuthenticatedPrincipal,
    server_instance_id: &str,
) -> Result<Vec<u8>, AuthError> {
    if principal.account_fence.len() != 32 {
        return Err(AuthError::InvalidFence);
    }
    let instance = Uuid::parse_str(server_instance_id).map_err(|_| AuthError::InvalidIdentifier)?;
    if instance.to_string() != server_instance_id {
        return Err(AuthError::InvalidIdentifier);
    }
    canonical_value(&MeResponseWire {
        binding: SessionBindingWire {
            account_auth_epoch: principal.account_auth_epoch,
            account_fence: URL_SAFE_NO_PAD.encode(&principal.account_fence),
            account_id: principal.account_id.clone(),
            server_instance_id: server_instance_id.into(),
            session_id: principal.session_id.clone(),
            sync_protocol_epoch: PROTOCOL_EPOCH,
        },
        content_protection: ContentProtectionWire {
            e2ee: false,
            profile: "serverReadableV1".into(),
            server_can_read_content: true,
            user_managed_content_key: false,
        },
    })
}

fn binding(
    grant: &SessionGrant,
    server_instance_id: &str,
) -> Result<SessionBindingWire, AuthError> {
    let instance = Uuid::parse_str(server_instance_id).map_err(|_| AuthError::InvalidIdentifier)?;
    if instance.to_string() != server_instance_id || grant.principal.account_fence.len() != 32 {
        return Err(AuthError::InvalidIdentifier);
    }
    Ok(SessionBindingWire {
        account_auth_epoch: grant.principal.account_auth_epoch,
        account_fence: URL_SAFE_NO_PAD.encode(&grant.principal.account_fence),
        account_id: grant.principal.account_id.clone(),
        server_instance_id: server_instance_id.into(),
        session_id: grant.principal.session_id.clone(),
        sync_protocol_epoch: PROTOCOL_EPOCH,
    })
}

fn tokens(grant: &SessionGrant) -> Result<SessionTokensWire, AuthError> {
    Ok(SessionTokensWire {
        access_token: grant.access_token.clone(),
        access_token_expires_at: timestamp(grant.access_expires_at_unix)?,
        refresh_generation: grant.refresh_generation,
        refresh_token: grant.refresh_token.clone(),
        refresh_token_expires_at: timestamp(grant.refresh_expires_at_unix)?,
        token_type: "Bearer".into(),
    })
}

fn grant(
    binding: SessionBindingWire,
    tokens: SessionTokensWire,
    tenant_id: TenantId,
) -> Result<SessionGrant, AuthError> {
    if binding.sync_protocol_epoch != PROTOCOL_EPOCH
        || binding.account_auth_epoch < 1
        || opaque_token(binding.account_id.as_str()).is_err()
        || uuid(binding.session_id.as_str()).is_err()
        || uuid(&binding.server_instance_id).is_err()
        || tokens.token_type != "Bearer"
        || tokens.refresh_generation < 1
        || fuminiwa_token(&tokens.access_token, "fma1_").is_err()
        || fuminiwa_token(&tokens.refresh_token, "fmr1_").is_err()
    {
        return Err(AuthError::Vault);
    }
    base64url_256(&binding.account_fence).map_err(|_| AuthError::Vault)?;
    let fence = URL_SAFE_NO_PAD
        .decode(binding.account_fence)
        .map_err(|_| AuthError::Vault)?;
    if fence.len() != 32 {
        return Err(AuthError::Vault);
    }
    Ok(SessionGrant {
        principal: AuthenticatedPrincipal {
            account_id: binding.account_id,
            tenant_id,
            session_id: binding.session_id,
            account_auth_epoch: binding.account_auth_epoch,
            account_fence: fence,
        },
        access_token: tokens.access_token,
        refresh_token: tokens.refresh_token,
        refresh_generation: tokens.refresh_generation,
        access_expires_at_unix: parse_timestamp(&tokens.access_token_expires_at)?,
        refresh_expires_at_unix: parse_timestamp(&tokens.refresh_token_expires_at)?,
    })
}

fn canonical_value<T: Serialize>(value: &T) -> Result<Vec<u8>, AuthError> {
    let value = serde_json::to_value(value).map_err(|_| AuthError::Vault)?;
    canonical_json(&value).map_err(|_| AuthError::Vault)
}

fn decode_canonical<T: for<'de> Deserialize<'de>>(bytes: &[u8]) -> Result<T, AuthError> {
    let value: Value = serde_json::from_slice(bytes).map_err(|_| AuthError::Vault)?;
    if canonical_json(&value).map_err(|_| AuthError::Vault)? != bytes {
        return Err(AuthError::Vault);
    }
    serde_json::from_value(value).map_err(|_| AuthError::Vault)
}

fn timestamp(unix: i64) -> Result<String, AuthError> {
    DateTime::<Utc>::from_timestamp(unix, 0)
        .map(|value| value.to_rfc3339_opts(SecondsFormat::Secs, true))
        .ok_or(AuthError::InvalidRequest)
}

fn parse_timestamp(value: &str) -> Result<i64, AuthError> {
    DateTime::parse_from_rfc3339(value)
        .map(|value| value.timestamp())
        .map_err(|_| AuthError::Vault)
}

pub fn parse_auth_command(kind: &str, bytes: &[u8]) -> Result<ParsedAuthCommand, AuthError> {
    if bytes.is_empty()
        || bytes.len() > MAX_AUTH_COMMAND_BYTES
        || bytes.starts_with(&[0xef, 0xbb, 0xbf])
        || std::str::from_utf8(bytes).is_err()
    {
        return Err(AuthError::InvalidRequest);
    }
    let mut de = serde_json::Deserializer::from_slice(bytes);
    let value = serde::de::Deserializer::deserialize_any(&mut de, StrictVisitor)
        .map_err(|_| AuthError::InvalidRequest)?;
    de.end().map_err(|_| AuthError::InvalidRequest)?;
    let canonical = canonical_json(&value).map_err(|_| AuthError::InvalidRequest)?;
    if canonical != bytes {
        return Err(AuthError::InvalidRequest);
    }
    let command = match kind {
        CREATE_CHALLENGE_COMMAND => parse_create(&value)?,
        EXCHANGE_APPLE_COMMAND => parse_exchange(&value)?,
        ROTATE_REFRESH_COMMAND => parse_refresh(&value)?,
        REVOKE_SESSION_COMMAND => parse_revoke(&value)?,
        _ => return Err(AuthError::InvalidRequest),
    };
    Ok(ParsedAuthCommand {
        command,
        canonical_bytes: bytes.to_vec(),
        digest: digest_request(bytes),
    })
}

fn parse_create(value: &Value) -> Result<AuthCommand, AuthError> {
    closed(
        value,
        &["clientPlatform", "flow", "operationId", "provider"],
    )?;
    if text(value, "provider")? != "apple" || text(value, "flow")? != "native" {
        return Err(AuthError::ProviderNotAllowed);
    }
    let platform = match text(value, "clientPlatform")? {
        "macos" => ClientPlatform::Macos,
        "ios" => ClientPlatform::Ios,
        "ipados" => ClientPlatform::Ipados,
        _ => return Err(AuthError::InvalidRequest),
    };
    Ok(AuthCommand::CreateChallenge(CreateChallengeCommand {
        operation_id: operation(text(value, "operationId")?)?,
        platform,
    }))
}
fn parse_exchange(value: &Value) -> Result<AuthCommand, AuthError> {
    closed(
        value,
        &[
            "authorizationCode",
            "challengeId",
            "identityToken",
            "operationId",
            "provider",
            "state",
        ],
    )?;
    if text(value, "provider")? != "apple" {
        return Err(AuthError::ProviderNotAllowed);
    }
    Ok(AuthCommand::ExchangeApple(ExchangeAppleCommand {
        operation_id: operation(text(value, "operationId")?)?,
        challenge_id: ChallengeId::new(uuid(text(value, "challengeId")?)?.to_string())?,
        state: base64url_256(text(value, "state")?)?,
        authorization_code: bounded(text(value, "authorizationCode")?, 4096)?,
        identity_token: compact_jws(text(value, "identityToken")?)?,
    }))
}
fn parse_refresh(value: &Value) -> Result<AuthCommand, AuthError> {
    closed(value, &["rotationId"])?;
    Ok(AuthCommand::RotateRefresh(RotateRefreshCommand {
        operation_id: operation(text(value, "rotationId")?)?,
    }))
}
fn parse_revoke(value: &Value) -> Result<AuthCommand, AuthError> {
    closed(value, &["operationId", "scope"])?;
    if text(value, "scope")? != "currentSession" {
        return Err(AuthError::InvalidRequest);
    }
    Ok(AuthCommand::RevokeCurrentSession(RevokeSessionCommand {
        operation_id: operation(text(value, "operationId")?)?,
    }))
}
fn closed(value: &Value, fields: &[&str]) -> Result<(), AuthError> {
    let map = value.as_object().ok_or(AuthError::InvalidRequest)?;
    if map.len() != fields.len()
        || map.keys().any(|k| !fields.contains(&k.as_str()))
        || fields.iter().any(|k| !map.contains_key(*k))
    {
        return Err(AuthError::InvalidRequest);
    }
    Ok(())
}
fn text<'a>(value: &'a Value, key: &str) -> Result<&'a str, AuthError> {
    value
        .get(key)
        .and_then(Value::as_str)
        .ok_or(AuthError::InvalidRequest)
}
fn bounded(value: &str, max: usize) -> Result<String, AuthError> {
    if value.is_empty() || value.len() > max {
        return Err(AuthError::InvalidRequest);
    }
    Ok(value.into())
}
fn base64url_256(value: &str) -> Result<String, AuthError> {
    if value.len() != 43 || !value.bytes().all(is_base64url) {
        return Err(AuthError::InvalidRequest);
    }
    let decoded = URL_SAFE_NO_PAD
        .decode(value)
        .map_err(|_| AuthError::InvalidRequest)?;
    if decoded.len() != 32 || URL_SAFE_NO_PAD.encode(decoded) != value {
        return Err(AuthError::InvalidRequest);
    }
    Ok(value.into())
}
fn compact_jws(value: &str) -> Result<String, AuthError> {
    if !(5..=32768).contains(&value.len()) {
        return Err(AuthError::InvalidRequest);
    }
    let segments = value.split('.').collect::<Vec<_>>();
    if segments.len() != 3
        || segments
            .iter()
            .any(|segment| segment.is_empty() || !segment.bytes().all(is_base64url))
    {
        return Err(AuthError::InvalidRequest);
    }
    Ok(value.into())
}
fn opaque_token(value: &str) -> Result<(), AuthError> {
    if !(16..=1024).contains(&value.len()) || !value.bytes().all(is_base64url) {
        return Err(AuthError::InvalidIdentifier);
    }
    Ok(())
}
fn fuminiwa_token(value: &str, prefix: &str) -> Result<(), AuthError> {
    let Some(token) = value.strip_prefix(prefix) else {
        return Err(AuthError::InvalidIdentifier);
    };
    if !(43..=251).contains(&token.len()) || !token.bytes().all(is_base64url) {
        return Err(AuthError::InvalidIdentifier);
    }
    Ok(())
}
fn is_base64url(byte: u8) -> bool {
    byte.is_ascii_alphanumeric() || matches!(byte, b'_' | b'-')
}
fn uuid(value: &str) -> Result<Uuid, AuthError> {
    let id = Uuid::parse_str(value).map_err(|_| AuthError::InvalidIdentifier)?;
    if value.len() != 36 || id.to_string() != value {
        return Err(AuthError::InvalidIdentifier);
    }
    Ok(id)
}
fn operation(value: &str) -> Result<OperationId, AuthError> {
    OperationId::new(uuid(value)?.to_string())
}

struct StrictVisitor;
impl<'de> Visitor<'de> for StrictVisitor {
    type Value = Value;
    fn expecting(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str("closed auth JSON")
    }
    fn visit_bool<E: serde::de::Error>(self, v: bool) -> Result<Value, E> {
        Ok(Value::Bool(v))
    }
    fn visit_i64<E: serde::de::Error>(self, v: i64) -> Result<Value, E> {
        if v.unsigned_abs() > 9_007_199_254_740_991 {
            return Err(E::custom("unsafe integer"));
        }
        Ok(Value::Number(v.into()))
    }
    fn visit_u64<E: serde::de::Error>(self, v: u64) -> Result<Value, E> {
        if v > 9_007_199_254_740_991 {
            return Err(E::custom("unsafe integer"));
        }
        Ok(Value::Number(v.into()))
    }
    fn visit_f64<E: serde::de::Error>(self, _: f64) -> Result<Value, E> {
        Err(E::custom("float"))
    }
    fn visit_str<E: serde::de::Error>(self, v: &str) -> Result<Value, E> {
        Ok(Value::String(v.into()))
    }
    fn visit_string<E: serde::de::Error>(self, v: String) -> Result<Value, E> {
        Ok(Value::String(v))
    }
    fn visit_unit<E: serde::de::Error>(self) -> Result<Value, E> {
        Ok(Value::Null)
    }
    fn visit_seq<A: SeqAccess<'de>>(self, mut seq: A) -> Result<Value, A::Error> {
        let mut out = Vec::new();
        while let Some(v) = seq.next_element_seed(StrictSeed)? {
            out.push(v)
        }
        Ok(Value::Array(out))
    }
    fn visit_map<A: MapAccess<'de>>(self, mut map: A) -> Result<Value, A::Error> {
        let mut out = serde_json::Map::new();
        let mut keys = HashSet::new();
        while let Some(k) = map.next_key::<String>()? {
            if !keys.insert(k.clone()) {
                return Err(A::Error::custom("duplicate key"));
            }
            out.insert(k, map.next_value_seed(StrictSeed)?);
        }
        Ok(Value::Object(out))
    }
}
struct StrictSeed;
impl<'de> serde::de::DeserializeSeed<'de> for StrictSeed {
    type Value = Value;
    fn deserialize<D: serde::Deserializer<'de>>(self, d: D) -> Result<Value, D::Error> {
        d.deserialize_any(StrictVisitor)
    }
}
