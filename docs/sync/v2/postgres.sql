-- FUMINIWA Snapshot Sync v2 server schema. Auth v1 owns accounts; sync stores
-- only opaque account_id and never Apple subject, email, or token material.
CREATE SCHEMA IF NOT EXISTS sync_v2;

CREATE TABLE sync_v2.server_meta (
  key TEXT PRIMARY KEY,
  value TEXT NOT NULL
);
CREATE TABLE sync_v2.works (
  work_id UUID PRIMARY KEY,
  account_id TEXT NOT NULL,
  server_instance_id TEXT NOT NULL,
  protocol_epoch BIGINT NOT NULL CHECK (protocol_epoch > 0),
  account_fence TEXT NOT NULL,
  state TEXT NOT NULL CHECK (state IN ('bound', 'quarantined')),
  head_snapshot_id BYTEA,
  head_generation BIGINT CHECK (head_generation IS NULL OR head_generation > 0)
);
CREATE TABLE sync_v2.global_blobs (
  object_id BYTEA PRIMARY KEY CHECK (octet_length(object_id) = 32),
  byte_count BIGINT NOT NULL CHECK (byte_count >= 0),
  raw_bytes BYTEA NOT NULL
);
CREATE TABLE sync_v2.account_objects (
  account_id TEXT NOT NULL,
  object_id BYTEA NOT NULL REFERENCES sync_v2.global_blobs(object_id),
  state TEXT NOT NULL CHECK (state IN ('available', 'quarantined', 'deleting')),
  PRIMARY KEY (account_id, object_id)
);
CREATE TABLE sync_v2.snapshots (
  snapshot_id BYTEA PRIMARY KEY CHECK (octet_length(snapshot_id) = 32),
  work_id UUID NOT NULL REFERENCES sync_v2.works(work_id),
  account_id TEXT NOT NULL,
  manifest_bytes BYTEA NOT NULL,
  manifest_digest BYTEA NOT NULL UNIQUE,
  created_at TIMESTAMPTZ NOT NULL
);
CREATE TABLE sync_v2.snapshot_parents (
  snapshot_id BYTEA NOT NULL REFERENCES sync_v2.snapshots(snapshot_id),
  parent_snapshot_id BYTEA NOT NULL REFERENCES sync_v2.snapshots(snapshot_id),
  PRIMARY KEY (snapshot_id, parent_snapshot_id),
  CHECK (snapshot_id <> parent_snapshot_id)
);
CREATE TABLE sync_v2.snapshot_entries (
  snapshot_id BYTEA NOT NULL REFERENCES sync_v2.snapshots(snapshot_id),
  entity_key TEXT NOT NULL,
  object_id BYTEA NOT NULL REFERENCES sync_v2.global_blobs(object_id),
  byte_count BIGINT NOT NULL,
  content_type TEXT NOT NULL,
  PRIMARY KEY (snapshot_id, entity_key)
);
CREATE TABLE sync_v2.receipts (
  account_id TEXT NOT NULL,
  command_id UUID NOT NULL,
  command_kind TEXT NOT NULL,
  request_digest BYTEA NOT NULL,
  canonical_request BYTEA NOT NULL,
  response_status INTEGER NOT NULL,
  response_bytes BYTEA NOT NULL,
  PRIMARY KEY (account_id, command_id, command_kind)
);
CREATE TABLE sync_v2.sealed_commands (
  command_id UUID PRIMARY KEY,
  account_id TEXT NOT NULL,
  work_id UUID,
  account_fence TEXT NOT NULL,
  command_kind TEXT NOT NULL,
  request_digest BYTEA NOT NULL,
  source_snapshot_id BYTEA,
  source_generation BIGINT,
  state TEXT NOT NULL CHECK (state IN ('sealed', 'sending', 'completed', 'quarantined', 'conflictPending', 'parked'))
);
CREATE TABLE sync_v2.active_conflicts (
  conflict_id UUID PRIMARY KEY,
  work_id UUID NOT NULL REFERENCES sync_v2.works(work_id),
  account_id TEXT NOT NULL,
  revision BIGINT NOT NULL CHECK (revision > 0),
  base_snapshot_id BYTEA,
  local_snapshot_id BYTEA NOT NULL,
  remote_snapshot_id BYTEA NOT NULL,
  state TEXT NOT NULL CHECK (state IN ('active', 'resolved'))
);
CREATE UNIQUE INDEX one_active_conflict_per_work
  ON sync_v2.active_conflicts(work_id) WHERE state = 'active';
CREATE TABLE sync_v2.conflict_candidates (
  conflict_id UUID NOT NULL REFERENCES sync_v2.active_conflicts(conflict_id),
  revision BIGINT NOT NULL,
  local_snapshot_id BYTEA NOT NULL,
  remote_snapshot_id BYTEA NOT NULL,
  PRIMARY KEY (conflict_id, revision)
);
CREATE TABLE sync_v2.conflict_events (
  event_id BIGSERIAL PRIMARY KEY,
  conflict_id UUID NOT NULL REFERENCES sync_v2.active_conflicts(conflict_id),
  revision BIGINT NOT NULL,
  local_snapshot_id BYTEA NOT NULL,
  remote_snapshot_id BYTEA NOT NULL,
  created_at TIMESTAMPTZ NOT NULL
);
CREATE TABLE sync_v2.history (
  occurrence_id UUID PRIMARY KEY,
  work_id UUID NOT NULL REFERENCES sync_v2.works(work_id),
  snapshot_id BYTEA NOT NULL,
  account_id TEXT NOT NULL,
  reason TEXT NOT NULL,
  pinned BOOLEAN NOT NULL,
  created_at TIMESTAMPTZ NOT NULL
);
CREATE TABLE sync_v2.restore_receipts (
  command_id UUID PRIMARY KEY,
  work_id UUID NOT NULL REFERENCES sync_v2.works(work_id),
  selected_snapshot_id BYTEA NOT NULL,
  pre_restore_snapshot_id BYTEA NOT NULL,
  result_snapshot_id BYTEA NOT NULL
);
CREATE TABLE sync_v2.head_events (
  event_id BIGSERIAL PRIMARY KEY,
  work_id UUID NOT NULL REFERENCES sync_v2.works(work_id),
  account_id TEXT NOT NULL,
  generation BIGINT NOT NULL CHECK (generation > 0),
  snapshot_id BYTEA NOT NULL,
  command_id UUID NOT NULL,
  created_at TIMESTAMPTZ NOT NULL
);
CREATE TABLE sync_v2.quarantine_records (
  quarantine_id UUID PRIMARY KEY,
  work_id UUID,
  account_id TEXT,
  reason TEXT NOT NULL,
  evidence_bytes BYTEA NOT NULL,
  created_at TIMESTAMPTZ NOT NULL
);
CREATE TABLE sync_v2.migration_ledger (
  migration_id UUID PRIMARY KEY,
  account_id TEXT NOT NULL,
  source_kind TEXT NOT NULL,
  source_digest BYTEA NOT NULL,
  evidence_bytes BYTEA NOT NULL,
  state TEXT NOT NULL CHECK (state IN ('discovered', 'staged', 'verified', 'committed', 'quarantined')),
  marker TEXT,
  UNIQUE (account_id, source_kind, source_digest)
);
CREATE INDEX work_catalog_cursor ON sync_v2.works(account_id, work_id);
CREATE INDEX snapshot_history_cursor ON sync_v2.history(account_id, work_id, created_at, occurrence_id);

-- Every route first resolves Auth v1's AuthenticatedPrincipal, then executes
-- account_id + work_id JOIN checks under one transaction. Receipt handlers lock
-- the unique (account_id, command_id, command_kind) row first, then work FOR
-- UPDATE, then head/conflict/history rows. Publish, conflict resolution,
-- restore, history event, and receipt/read-back commit atomically. A missing
-- or foreign row returns the same notFoundInAccount response.
