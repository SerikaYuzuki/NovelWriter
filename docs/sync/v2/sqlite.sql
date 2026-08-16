-- FUMINIWA Snapshot Sync v2 local authority. Execute in one transactional migration.
PRAGMA foreign_keys = ON;
PRAGMA journal_mode = WAL;
PRAGMA synchronous = FULL;

CREATE TABLE schema_meta (
  key TEXT PRIMARY KEY,
  value TEXT NOT NULL,
  checksum BLOB NOT NULL
);
CREATE TABLE account_bindings (
  work_id TEXT PRIMARY KEY,
  server_instance_id TEXT NOT NULL,
  protocol_epoch INTEGER NOT NULL CHECK (protocol_epoch > 0),
  account_id TEXT NOT NULL,
  account_fence TEXT NOT NULL,
  state TEXT NOT NULL CHECK (state IN ('bound', 'quarantined', 'parked'))
);
CREATE TABLE works (
  work_id TEXT PRIMARY KEY,
  document_id TEXT NOT NULL,
  document_created_at TEXT NOT NULL,
  current_snapshot_id BLOB,
  local_generation INTEGER NOT NULL CHECK (local_generation > 0),
  acknowledged_head_snapshot_id BLOB,
  acknowledged_head_generation INTEGER
);
CREATE TABLE objects (
  object_id BLOB PRIMARY KEY,
  byte_count INTEGER NOT NULL CHECK (byte_count >= 0),
  bytes BLOB NOT NULL
);
CREATE TABLE snapshots (
  snapshot_id BLOB PRIMARY KEY,
  work_id TEXT NOT NULL REFERENCES works(work_id),
  manifest_bytes BLOB NOT NULL,
  manifest_digest BLOB NOT NULL UNIQUE,
  local_generation INTEGER NOT NULL,
  pinned INTEGER NOT NULL CHECK (pinned IN (0, 1)),
  created_at TEXT NOT NULL
);
CREATE TABLE snapshot_parents (
  snapshot_id BLOB NOT NULL REFERENCES snapshots(snapshot_id),
  parent_snapshot_id BLOB NOT NULL REFERENCES snapshots(snapshot_id),
  PRIMARY KEY (snapshot_id, parent_snapshot_id),
  CHECK (snapshot_id <> parent_snapshot_id)
);
CREATE TABLE snapshot_entries (
  snapshot_id BLOB NOT NULL REFERENCES snapshots(snapshot_id),
  entity_key TEXT NOT NULL,
  object_id BLOB NOT NULL REFERENCES objects(object_id),
  byte_count INTEGER NOT NULL,
  content_type TEXT NOT NULL,
  PRIMARY KEY (snapshot_id, entity_key)
);
CREATE TABLE sealed_commands (
  command_id TEXT PRIMARY KEY,
  work_id TEXT NOT NULL REFERENCES works(work_id),
  account_id TEXT NOT NULL,
  account_fence TEXT NOT NULL,
  command_kind TEXT NOT NULL,
  canonical_bytes BLOB NOT NULL,
  request_digest BLOB NOT NULL,
  source_snapshot_id BLOB,
  source_generation INTEGER,
  status TEXT NOT NULL CHECK (status IN ('sealed', 'sending', 'completed', 'quarantined', 'conflictPending', 'parked')),
  UNIQUE (account_id, command_id, command_kind)
);
CREATE TABLE inbox_snapshots (
  inbox_id TEXT PRIMARY KEY,
  work_id TEXT NOT NULL,
  snapshot_id BLOB NOT NULL,
  account_id TEXT NOT NULL,
  manifest_bytes BLOB NOT NULL,
  verified INTEGER NOT NULL CHECK (verified IN (0, 1)),
  state TEXT NOT NULL CHECK (state IN ('staged', 'verified', 'rejected', 'adopted'))
);
CREATE TABLE history_occurrences (
  occurrence_id TEXT PRIMARY KEY,
  work_id TEXT NOT NULL,
  snapshot_id BLOB NOT NULL,
  reason TEXT NOT NULL,
  pinned INTEGER NOT NULL CHECK (pinned IN (0, 1)),
  created_at TEXT NOT NULL
);
CREATE TABLE active_conflicts (
  conflict_id TEXT PRIMARY KEY,
  work_id TEXT NOT NULL,
  revision INTEGER NOT NULL CHECK (revision > 0),
  base_snapshot_id BLOB,
  local_snapshot_id BLOB NOT NULL,
  remote_snapshot_id BLOB NOT NULL,
  state TEXT NOT NULL CHECK (state IN ('active', 'resolved')),
  created_at TEXT NOT NULL
);
CREATE UNIQUE INDEX one_active_conflict_per_work
  ON active_conflicts(work_id) WHERE state = 'active';
CREATE TABLE conflict_candidates (
  conflict_id TEXT NOT NULL REFERENCES active_conflicts(conflict_id),
  revision INTEGER NOT NULL,
  local_snapshot_id BLOB NOT NULL,
  remote_snapshot_id BLOB NOT NULL,
  PRIMARY KEY (conflict_id, revision)
);
CREATE TABLE restore_records (
  restore_id TEXT PRIMARY KEY,
  work_id TEXT NOT NULL,
  selected_snapshot_id BLOB NOT NULL,
  pre_restore_snapshot_id BLOB NOT NULL,
  result_snapshot_id BLOB NOT NULL,
  command_id TEXT NOT NULL UNIQUE
);
CREATE TABLE migration_ledger (
  migration_id TEXT PRIMARY KEY,
  source_kind TEXT NOT NULL,
  source_digest BLOB NOT NULL,
  evidence_bytes BLOB NOT NULL,
  state TEXT NOT NULL CHECK (state IN ('discovered', 'staged', 'verified', 'committed', 'quarantined')),
  marker TEXT,
  UNIQUE (source_kind, source_digest)
);
CREATE TABLE quarantine_records (
  quarantine_id TEXT PRIMARY KEY,
  work_id TEXT,
  account_id TEXT,
  reason TEXT NOT NULL,
  evidence_bytes BLOB NOT NULL,
  created_at TEXT NOT NULL
);
CREATE INDEX sealed_commands_pending ON sealed_commands(work_id, status);
CREATE INDEX inbox_by_work ON inbox_snapshots(work_id, state);
