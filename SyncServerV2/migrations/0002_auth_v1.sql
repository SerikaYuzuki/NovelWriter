-- Snapshot Sync v2 authentication authority.  This schema is intentionally
-- separate from sync_v2 and contains no manuscript/object foreign keys.
CREATE SCHEMA IF NOT EXISTS auth_v1;

CREATE TABLE auth_v1.accounts (
    account_id TEXT PRIMARY KEY,
    tenant_id TEXT NOT NULL UNIQUE,
    state TEXT NOT NULL CHECK (state IN ('active','locked','deletionPending','deleted')),
    auth_epoch BIGINT NOT NULL CHECK (auth_epoch > 0),
    fence BYTEA NOT NULL CHECK (octet_length(fence)=32),
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE TABLE auth_v1.provider_configs (
    provider_config_id TEXT PRIMARY KEY,
    provider_kind TEXT NOT NULL CHECK (provider_kind='apple'),
    exact_issuer TEXT NOT NULL,
    allowed_audiences TEXT[] NOT NULL,
    enabled BOOLEAN NOT NULL,
    config_version INTEGER NOT NULL CHECK (config_version > 0),
    UNIQUE(provider_kind, exact_issuer)
);
CREATE TABLE auth_v1.external_identities (
    identity_id UUID PRIMARY KEY,
    account_id TEXT NOT NULL REFERENCES auth_v1.accounts(account_id),
    provider_config_id TEXT NOT NULL REFERENCES auth_v1.provider_configs(provider_config_id),
    exact_issuer TEXT NOT NULL,
    lookup_key_version INTEGER NOT NULL CHECK (lookup_key_version > 0),
    subject_lookup_hmac BYTEA NOT NULL CHECK (octet_length(subject_lookup_hmac)=32),
    state TEXT NOT NULL CHECK (state IN ('pending','active','revoked','unlinked','providerDeleted')),
    linked_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    revoked_at TIMESTAMPTZ,
    UNIQUE(lookup_key_version, subject_lookup_hmac),
    UNIQUE(account_id, provider_config_id, exact_issuer)
);
CREATE TABLE auth_v1.external_identity_secrets (
    identity_id UUID PRIMARY KEY REFERENCES auth_v1.external_identities(identity_id),
    key_version INTEGER NOT NULL CHECK (key_version > 0),
    ciphertext BYTEA NOT NULL,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE TABLE auth_v1.provider_credentials (
    credential_id UUID PRIMARY KEY,
    identity_id UUID NOT NULL REFERENCES auth_v1.external_identities(identity_id),
    original_audience TEXT NOT NULL,
    credential_generation BIGINT NOT NULL CHECK (credential_generation > 0),
    key_version INTEGER NOT NULL CHECK (key_version > 0),
    ciphertext BYTEA NOT NULL,
    state TEXT NOT NULL CHECK (state IN ('active','superseded','revokeRetryPending','revoked')),
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    revoked_at TIMESTAMPTZ,
    UNIQUE(identity_id, original_audience, credential_generation)
);
CREATE UNIQUE INDEX provider_credentials_one_active_audience
    ON auth_v1.provider_credentials(identity_id, original_audience) WHERE state='active';
CREATE TABLE auth_v1.auth_operations (
    operation_id UUID PRIMARY KEY,
    command_kind TEXT NOT NULL,
    request_digest BYTEA NOT NULL CHECK (octet_length(request_digest)=32),
    state TEXT NOT NULL CHECK (state IN ('reserved','completed','failed')),
    response_status INTEGER,
    response_ciphertext BYTEA,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    completed_at TIMESTAMPTZ,
    UNIQUE(operation_id, command_kind, request_digest)
);
CREATE TABLE auth_v1.auth_challenges (
    challenge_id UUID PRIMARY KEY,
    operation_id UUID NOT NULL REFERENCES auth_v1.auth_operations(operation_id),
    provider_config_id TEXT NOT NULL REFERENCES auth_v1.provider_configs(provider_config_id),
    audience TEXT NOT NULL,
    client_platform TEXT NOT NULL CHECK (client_platform IN ('macos','ios','ipados')),
    state_hash BYTEA NOT NULL CHECK (octet_length(state_hash)=32),
    nonce_hash BYTEA NOT NULL CHECK (octet_length(nonce_hash)=32),
    phase TEXT NOT NULL CHECK (phase IN ('claimed','providerCallStarted','providerResultKnown','terminal')),
    lease_until TIMESTAMPTZ NOT NULL,
    expires_at TIMESTAMPTZ NOT NULL,
    provider_result_ciphertext BYTEA,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE TABLE auth_v1.auth_sessions (
    session_id UUID PRIMARY KEY,
    account_id TEXT NOT NULL REFERENCES auth_v1.accounts(account_id),
    identity_id UUID NOT NULL REFERENCES auth_v1.external_identities(identity_id),
    family_id UUID NOT NULL,
    auth_epoch BIGINT NOT NULL,
    state TEXT NOT NULL CHECK (state IN ('active','reauthRequired','revoked','expired')),
    client_platform TEXT NOT NULL CHECK (client_platform IN ('macos','ios','ipados')),
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    expires_at TIMESTAMPTZ NOT NULL
);
CREATE TABLE auth_v1.refresh_families (
    family_id UUID PRIMARY KEY,
    session_id UUID NOT NULL REFERENCES auth_v1.auth_sessions(session_id),
    account_id TEXT NOT NULL REFERENCES auth_v1.accounts(account_id),
    state TEXT NOT NULL CHECK (state IN ('active','rotated','reuseDetected','revoked','expired')),
    current_generation BIGINT NOT NULL CHECK (current_generation > 0),
    expires_at TIMESTAMPTZ NOT NULL
);
CREATE TABLE auth_v1.refresh_tokens (
    family_id UUID NOT NULL REFERENCES auth_v1.refresh_families(family_id),
    generation BIGINT NOT NULL CHECK (generation > 0),
    token_hmac BYTEA NOT NULL CHECK (octet_length(token_hmac)=32),
    state TEXT NOT NULL CHECK (state IN ('active','consumed','revoked')),
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY(family_id,generation),
    UNIQUE(family_id,token_hmac)
);
CREATE TABLE auth_v1.session_refresh_receipts (
    operation_id UUID PRIMARY KEY,
    family_id UUID NOT NULL REFERENCES auth_v1.refresh_families(family_id),
    presented_token_hmac BYTEA NOT NULL CHECK (octet_length(presented_token_hmac)=32),
    request_digest BYTEA NOT NULL CHECK (octet_length(request_digest)=32),
    response_ciphertext BYTEA NOT NULL,
    response_status INTEGER NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    expires_at TIMESTAMPTZ NOT NULL
);
CREATE TABLE auth_v1.provider_notification_receipts (
    provider TEXT NOT NULL CHECK(provider='apple'),
    event_key BYTEA NOT NULL CHECK(octet_length(event_key)=32),
    event_kind TEXT NOT NULL,
    received_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY(provider,event_key)
);
CREATE TABLE auth_v1.auth_events (
    event_id BIGSERIAL PRIMARY KEY,
    account_id TEXT REFERENCES auth_v1.accounts(account_id),
    event_kind TEXT NOT NULL,
    opaque_subject_id UUID,
    request_id UUID,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX auth_sessions_account_idx ON auth_v1.auth_sessions(account_id);
CREATE INDEX external_identities_account_idx ON auth_v1.external_identities(account_id);
CREATE INDEX provider_credentials_identity_audience_idx ON auth_v1.provider_credentials(identity_id,original_audience);
