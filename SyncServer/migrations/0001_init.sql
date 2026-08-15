CREATE TABLE IF NOT EXISTS works (
  work_id UUID PRIMARY KEY,
  head_generation BIGINT,
  head_snapshot_id TEXT
);

CREATE TABLE IF NOT EXISTS objects (
  object_id TEXT PRIMARY KEY,
  byte_count BIGINT NOT NULL,
  bytes BYTEA NOT NULL
);

CREATE TABLE IF NOT EXISTS snapshots (
  snapshot_id TEXT PRIMARY KEY,
  work_id UUID NOT NULL,
  manifest JSONB NOT NULL
);

CREATE TABLE IF NOT EXISTS operations (
  operation_id UUID PRIMARY KEY,
  kind TEXT NOT NULL,
  request_sha256 TEXT NOT NULL,
  result JSONB NOT NULL,
  created_at TIMESTAMPTZ NOT NULL
);

CREATE TABLE IF NOT EXISTS conflicts (
  conflict_id UUID PRIMARY KEY,
  work_id UUID NOT NULL,
  base_snapshot_id TEXT,
  local_snapshot_id TEXT NOT NULL,
  remote_snapshot_id TEXT NOT NULL,
  state TEXT NOT NULL,
  created_at TIMESTAMPTZ NOT NULL
);

CREATE TABLE IF NOT EXISTS auth_challenges (
  challenge_id UUID PRIMARY KEY,
  state TEXT NOT NULL,
  nonce TEXT NOT NULL,
  expires_at TIMESTAMPTZ NOT NULL,
  consumed BOOLEAN NOT NULL
);

CREATE TABLE IF NOT EXISTS accounts (
  account_id TEXT PRIMARY KEY,
  issuer TEXT NOT NULL,
  subject_hash TEXT NOT NULL,
  auth_epoch BIGINT NOT NULL,
  fence TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS provider_credentials (
  account_id TEXT NOT NULL,
  client_id TEXT NOT NULL,
  refresh_token_ciphertext TEXT NOT NULL,
  created_at TIMESTAMPTZ NOT NULL,
  PRIMARY KEY (account_id, client_id),
  FOREIGN KEY (account_id) REFERENCES accounts(account_id) ON DELETE CASCADE
);
