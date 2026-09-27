-- A verified provider authentication is an ordering watermark, never backfilled
-- from server time. Pending validation preserves sessions and credential bytes.
ALTER TABLE auth_v1.external_identities ADD COLUMN last_provider_auth_at BIGINT;
ALTER TABLE auth_v1.provider_credentials
  DROP CONSTRAINT provider_credentials_state_check,
  ADD CONSTRAINT provider_credentials_state_check CHECK (state IN
    ('active','superseded','revokeRetryPending','revoked','providerValidationPending')),
  ADD COLUMN validation_event_type TEXT CHECK (validation_event_type IN ('consent-revoked','account-deleted'));
