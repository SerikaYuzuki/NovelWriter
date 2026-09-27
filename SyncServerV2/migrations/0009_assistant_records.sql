-- AI conversation/prompt data has a separate append-only lane from body snapshots.
CREATE TABLE sync_v2.assistant_records (
  account_id TEXT NOT NULL REFERENCES sync_v2.account_scopes(account_id),
  record_id UUID NOT NULL,
  work_id UUID,
  sequence BIGINT GENERATED ALWAYS AS IDENTITY,
  kind TEXT NOT NULL CHECK (kind IN ('prompt','conversation','message','request','edit')),
  record_key TEXT NOT NULL CHECK (octet_length(record_key) BETWEEN 1 AND 128),
  parent_id UUID,
  conflicted BOOLEAN NOT NULL,
  request_bytes BYTEA NOT NULL CHECK (octet_length(request_bytes) <= 2097152),
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (account_id,record_id),
  FOREIGN KEY (account_id,work_id) REFERENCES sync_v2.works(account_id,work_id),
  CHECK (work_id IS NOT NULL OR kind='prompt')
);
CREATE INDEX assistant_records_cursor ON sync_v2.assistant_records(account_id,work_id,sequence);
CREATE INDEX assistant_prompt_revision ON sync_v2.assistant_records(account_id,work_id,record_key,sequence) WHERE kind='prompt' AND NOT conflicted;

-- A recovery receipt binds the complete source selection and destination IDs.
-- It remains readable after graph expiry; it contains IDs only, not manuscripts.
CREATE TABLE sync_v2.recovery_operations (
  account_id TEXT NOT NULL REFERENCES sync_v2.account_scopes(account_id),
  operation_id UUID NOT NULL,
  request_digest BYTEA NOT NULL CHECK (octet_length(request_digest)=32),
  response_bytes BYTEA NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (account_id,operation_id)
);
