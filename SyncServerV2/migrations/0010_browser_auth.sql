-- Browser entry points share the existing account and session authority.
ALTER TABLE auth_v1.provider_configs DROP CONSTRAINT provider_configs_provider_kind_check;
ALTER TABLE auth_v1.provider_configs ADD CONSTRAINT provider_configs_provider_kind_check
    CHECK (provider_kind IN ('apple','google'));
INSERT INTO auth_v1.provider_configs(provider_config_id,provider_kind,exact_issuer,allowed_audiences,enabled,config_version)
VALUES ('google-fuminiwa-v2','google','https://accounts.google.com',
    ARRAY['560354700432-aq87npqhidi1m4n671m8pb9bugml609d.apps.googleusercontent.com'],true,1);
CREATE UNIQUE INDEX external_identities_one_active_account
    ON auth_v1.external_identities(account_id) WHERE state='active';
CREATE TABLE auth_v1.browser_attempts (
    attempt_id UUID PRIMARY KEY,
    provider TEXT NOT NULL CHECK(provider IN ('apple','google')),
    client_platform TEXT NOT NULL CHECK(client_platform IN ('macos','ios','ipados')),
    state_hash BYTEA NOT NULL UNIQUE CHECK(octet_length(state_hash)=32),
    claim_hash BYTEA NOT NULL CHECK(octet_length(claim_hash)=32),
    nonce TEXT NOT NULL,
    phase TEXT NOT NULL CHECK(phase IN ('pending','exchanging','ready','failed')),
    expires_at TIMESTAMPTZ NOT NULL,
    response_ciphertext BYTEA,
    response_key_version INTEGER,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    CHECK ((phase='ready') = (response_ciphertext IS NOT NULL AND response_key_version IS NOT NULL))
);
CREATE INDEX browser_attempts_expiry ON auth_v1.browser_attempts(expires_at);
