CREATE TABLE IF NOT EXISTS auth_sessions (
  access_token_hash TEXT PRIMARY KEY,
  account_id TEXT NOT NULL,
  auth_epoch BIGINT NOT NULL,
  fence TEXT NOT NULL,
  refresh_family_id UUID NOT NULL,
  expires_at TIMESTAMPTZ NOT NULL,
  revoked BOOLEAN NOT NULL DEFAULT FALSE,
  FOREIGN KEY (account_id) REFERENCES accounts(account_id) ON DELETE CASCADE
);

CREATE TABLE IF NOT EXISTS refresh_token_families (
  family_id UUID PRIMARY KEY,
  account_id TEXT NOT NULL,
  current_token_hash TEXT NOT NULL,
  generation BIGINT NOT NULL,
  last_rotation_id UUID,
  last_response JSONB,
  revoked BOOLEAN NOT NULL DEFAULT FALSE,
  FOREIGN KEY (account_id) REFERENCES accounts(account_id) ON DELETE CASCADE
);
