-- FUMINIWA Snapshot Sync v2 local authority.
PRAGMA foreign_keys = ON;
PRAGMA journal_mode = WAL;
PRAGMA synchronous = FULL;

CREATE TABLE schema_meta (
  key TEXT PRIMARY KEY,
  value TEXT NOT NULL,
  checksum BLOB NOT NULL
);
CREATE TABLE works (
  work_id TEXT PRIMARY KEY,
  document_id TEXT NOT NULL,
  document_created_at TEXT NOT NULL,
  current_snapshot_id BLOB,
  local_generation INTEGER NOT NULL DEFAULT 0 CHECK (local_generation >= 0),
  acknowledged_head_snapshot_id BLOB,
  acknowledged_head_generation INTEGER CHECK (acknowledged_head_generation IS NULL OR acknowledged_head_generation > 0),
  remote_equivalent_local_snapshot_id BLOB,
  CHECK (
    (local_generation = 0 AND current_snapshot_id IS NULL) OR
    (local_generation > 0 AND current_snapshot_id IS NOT NULL)
  ),
  FOREIGN KEY (work_id, current_snapshot_id)
    REFERENCES snapshots(work_id, snapshot_id)
    DEFERRABLE INITIALLY DEFERRED,
  FOREIGN KEY (work_id, remote_equivalent_local_snapshot_id)
    REFERENCES snapshots(work_id, snapshot_id)
    DEFERRABLE INITIALLY DEFERRED
);
CREATE TABLE account_bindings (
  work_id TEXT PRIMARY KEY REFERENCES works(work_id),
  server_instance_id TEXT NOT NULL,
  protocol_epoch INTEGER NOT NULL CHECK (protocol_epoch > 0),
  account_id TEXT NOT NULL,
  account_fence TEXT NOT NULL,
  state TEXT NOT NULL CHECK (state IN ('bound', 'quarantined', 'parked')),
  UNIQUE (work_id, account_id)
);
CREATE TABLE objects (
  object_id BLOB PRIMARY KEY CHECK (length(object_id) = 32),
  byte_count INTEGER NOT NULL CHECK (byte_count BETWEEN 0 AND 262144000),
  bytes BLOB NOT NULL,
  CHECK (length(bytes) = byte_count)
);
CREATE TABLE snapshots (
  snapshot_id BLOB PRIMARY KEY CHECK (length(snapshot_id) = 32),
  work_id TEXT NOT NULL REFERENCES works(work_id),
  manifest_bytes BLOB NOT NULL CHECK (length(manifest_bytes) <= 16777216),
  manifest_digest BLOB NOT NULL CHECK (length(manifest_digest) = 32),
  created_at TEXT NOT NULL,
  UNIQUE (work_id, snapshot_id),
  CHECK (manifest_digest = snapshot_id)
);
CREATE TABLE snapshot_parents (
  work_id TEXT NOT NULL,
  snapshot_id BLOB NOT NULL,
  parent_snapshot_id BLOB NOT NULL,
  PRIMARY KEY (snapshot_id, parent_snapshot_id),
  CHECK (snapshot_id <> parent_snapshot_id),
  FOREIGN KEY (work_id, snapshot_id) REFERENCES snapshots(work_id, snapshot_id),
  FOREIGN KEY (work_id, parent_snapshot_id) REFERENCES snapshots(work_id, snapshot_id)
);
CREATE TABLE snapshot_entries (
  snapshot_id BLOB NOT NULL REFERENCES snapshots(snapshot_id),
  entity_key TEXT NOT NULL,
  object_id BLOB NOT NULL REFERENCES objects(object_id),
  byte_count INTEGER NOT NULL CHECK (byte_count >= 0),
  content_type TEXT NOT NULL CHECK (content_type IN (
    'application/vnd.fuminiwa.entity+json;version=2',
    'application/octet-stream'
  )),
  PRIMARY KEY (snapshot_id, entity_key),
  CHECK (
    (content_type = 'application/vnd.fuminiwa.entity+json;version=2' AND
      byte_count <= 16777216) OR
    (content_type = 'application/octet-stream' AND byte_count <= 262144000)
  )
);
CREATE TABLE history_occurrences (
  occurrence_id TEXT PRIMARY KEY,
  work_id TEXT NOT NULL,
  snapshot_id BLOB NOT NULL,
  reason TEXT NOT NULL,
  pinned INTEGER NOT NULL CHECK (pinned IN (0, 1)),
  local_generation INTEGER NOT NULL CHECK (local_generation > 0),
  created_at TEXT NOT NULL,
  FOREIGN KEY (work_id, snapshot_id) REFERENCES snapshots(work_id, snapshot_id)
);

CREATE TABLE sync_intents (
  intent_id TEXT PRIMARY KEY,
  work_id TEXT NOT NULL,
  source_snapshot_id BLOB NOT NULL,
  source_generation INTEGER NOT NULL CHECK (source_generation > 0),
  kind TEXT NOT NULL CHECK (kind IN ('latest', 'checkpoint', 'restore', 'conflictResolution')),
  status TEXT NOT NULL CHECK (status IN ('pending', 'sealed', 'acknowledged', 'quarantined', 'parked')),
  created_at TEXT NOT NULL,
  FOREIGN KEY (work_id, source_snapshot_id) REFERENCES snapshots(work_id, snapshot_id)
);
CREATE TABLE sealed_commands (
  command_id TEXT PRIMARY KEY,
  work_id TEXT NOT NULL,
  intent_id TEXT REFERENCES sync_intents(intent_id),
  account_id TEXT NOT NULL,
  account_fence TEXT NOT NULL,
  command_kind TEXT NOT NULL CHECK (command_kind IN (
    'createWork', 'prepareObject', 'finalizeObject', 'registerSnapshot', 'publish',
    'resolveDevice', 'resolveServer', 'cloneWork', 'restore'
  )),
  canonical_request BLOB NOT NULL CHECK (length(canonical_request) <= 33554432),
  request_digest BLOB NOT NULL CHECK (length(request_digest) = 32),
  source_snapshot_id BLOB NOT NULL,
  source_generation INTEGER NOT NULL CHECK (source_generation > 0),
  status TEXT NOT NULL CHECK (status IN ('sealed', 'sending', 'completed', 'quarantined', 'conflictPending', 'parked')),
  response_status INTEGER CHECK (response_status BETWEEN 100 AND 599),
  canonical_response BLOB CHECK (length(canonical_response) <= 33554432),
  receipt_verified INTEGER NOT NULL DEFAULT 0 CHECK (receipt_verified IN (0, 1)),
  UNIQUE (account_id, command_id),
  FOREIGN KEY (work_id, account_id) REFERENCES account_bindings(work_id, account_id),
  FOREIGN KEY (work_id, source_snapshot_id) REFERENCES snapshots(work_id, snapshot_id),
  CHECK ((response_status IS NULL) = (canonical_response IS NULL))
);
CREATE TABLE remote_receipts (
  account_id TEXT NOT NULL,
  command_id TEXT NOT NULL,
  command_kind TEXT NOT NULL CHECK (command_kind IN (
    'createWork', 'prepareObject', 'finalizeObject', 'registerSnapshot', 'publish',
    'resolveDevice', 'resolveServer', 'cloneWork', 'restore'
  )),
  request_digest BLOB NOT NULL CHECK (length(request_digest) = 32),
  response_status INTEGER NOT NULL CHECK (response_status BETWEEN 100 AND 599),
  canonical_response BLOB NOT NULL CHECK (length(canonical_response) <= 33554432),
  read_back_verified INTEGER NOT NULL CHECK (read_back_verified IN (0, 1)),
  PRIMARY KEY (account_id, command_id),
  FOREIGN KEY (account_id, command_id)
    REFERENCES sealed_commands(account_id, command_id)
);

-- Inbox bytes are never authoritative until the whole closure is verified and
-- adopted. No FK from inbox_* to objects/snapshots is intentional.
CREATE TABLE inbox_batches (
  inbox_id TEXT PRIMARY KEY,
  work_id TEXT NOT NULL REFERENCES works(work_id),
  account_id TEXT NOT NULL,
  account_fence TEXT NOT NULL,
  snapshot_id BLOB NOT NULL CHECK (length(snapshot_id) = 32),
  manifest_bytes BLOB NOT NULL CHECK (length(manifest_bytes) <= 16777216),
  expected_current_snapshot_id BLOB,
  expected_local_generation INTEGER NOT NULL CHECK (expected_local_generation >= 0),
  state TEXT NOT NULL CHECK (state IN ('staged', 'verified', 'rejected', 'adopted')),
  rejection_code TEXT,
  UNIQUE (work_id, snapshot_id, inbox_id),
  FOREIGN KEY (work_id, account_id) REFERENCES account_bindings(work_id, account_id)
);
CREATE TABLE inbox_objects (
  inbox_id TEXT NOT NULL REFERENCES inbox_batches(inbox_id),
  object_id BLOB NOT NULL CHECK (length(object_id) = 32),
  byte_count INTEGER NOT NULL CHECK (byte_count BETWEEN 0 AND 262144000),
  bytes BLOB NOT NULL,
  verified INTEGER NOT NULL CHECK (verified IN (0, 1)),
  PRIMARY KEY (inbox_id, object_id),
  CHECK (length(bytes) = byte_count)
);
CREATE TABLE inbox_closure (
  inbox_id TEXT NOT NULL REFERENCES inbox_batches(inbox_id),
  entity_key TEXT NOT NULL,
  object_id BLOB NOT NULL,
  PRIMARY KEY (inbox_id, entity_key),
  FOREIGN KEY (inbox_id, object_id) REFERENCES inbox_objects(inbox_id, object_id)
);

CREATE TABLE conflicts (
  conflict_id TEXT PRIMARY KEY,
  work_id TEXT NOT NULL REFERENCES works(work_id),
  current_revision INTEGER NOT NULL CHECK (current_revision > 0),
  state TEXT NOT NULL CHECK (state IN ('active', 'resolved')),
  UNIQUE (work_id, conflict_id),
  FOREIGN KEY (conflict_id, current_revision)
    REFERENCES conflict_candidates(conflict_id, revision)
    DEFERRABLE INITIALLY DEFERRED
);
CREATE UNIQUE INDEX one_active_conflict_per_work
  ON conflicts(work_id) WHERE state = 'active';
CREATE TABLE conflict_candidates (
  conflict_id TEXT NOT NULL,
  work_id TEXT NOT NULL,
  revision INTEGER NOT NULL CHECK (revision > 0),
  base_snapshot_id BLOB,
  local_snapshot_id BLOB NOT NULL,
  remote_snapshot_id BLOB NOT NULL,
  remote_inbox_id TEXT NOT NULL,
  pinned INTEGER NOT NULL CHECK (pinned IN (0, 1)),
  PRIMARY KEY (conflict_id, revision),
  FOREIGN KEY (work_id, conflict_id) REFERENCES conflicts(work_id, conflict_id),
  FOREIGN KEY (work_id, base_snapshot_id) REFERENCES snapshots(work_id, snapshot_id),
  FOREIGN KEY (work_id, local_snapshot_id) REFERENCES snapshots(work_id, snapshot_id),
  FOREIGN KEY (work_id, remote_snapshot_id, remote_inbox_id)
    REFERENCES inbox_batches(work_id, snapshot_id, inbox_id)
);
-- conflict_candidates are append-only. The local repository may update only
-- conflicts.current_revision/state and must reject UPDATE/DELETE of an older
-- candidate in its conformance tests.
CREATE TABLE restore_records (
  restore_id TEXT PRIMARY KEY,
  work_id TEXT NOT NULL,
  account_id TEXT NOT NULL,
  selected_snapshot_id BLOB NOT NULL,
  pre_restore_snapshot_id BLOB NOT NULL,
  result_snapshot_id BLOB NOT NULL,
  command_id TEXT NOT NULL UNIQUE,
  FOREIGN KEY (work_id, selected_snapshot_id) REFERENCES snapshots(work_id, snapshot_id),
  FOREIGN KEY (work_id, pre_restore_snapshot_id) REFERENCES snapshots(work_id, snapshot_id),
  FOREIGN KEY (work_id, result_snapshot_id) REFERENCES snapshots(work_id, snapshot_id),
  FOREIGN KEY (account_id, command_id)
    REFERENCES sealed_commands(account_id, command_id)
);

CREATE TABLE migration_ledger (
  migration_id TEXT PRIMARY KEY,
  account_id TEXT,
  source_kind TEXT NOT NULL,
  source_digest BLOB NOT NULL,
  export_backup_marker TEXT,
  adoption_marker TEXT,
  evidence_bytes BLOB NOT NULL,
  state TEXT NOT NULL CHECK (state IN ('discovered', 'backupExported', 'staged', 'verified', 'committed', 'quarantined')),
  UNIQUE (source_kind, source_digest),
  CHECK (account_id IS NOT NULL OR state IN ('discovered', 'backupExported', 'staged', 'quarantined'))
);
-- Offline adoption staging intentionally has no FK to works, snapshots,
-- account_bindings, or objects. Verified adoption copies a complete closure
-- into those authority tables in one later transaction.
CREATE TABLE migration_staging_batches (
  migration_id TEXT PRIMARY KEY REFERENCES migration_ledger(migration_id),
  proposed_work_id TEXT NOT NULL,
  proposed_document_id TEXT NOT NULL,
  snapshot_id BLOB NOT NULL CHECK (length(snapshot_id) = 32),
  manifest_bytes BLOB NOT NULL CHECK (length(manifest_bytes) <= 16777216),
  verified_account_id TEXT,
  state TEXT NOT NULL CHECK (state IN ('staged', 'verified', 'quarantined')),
  CHECK (state <> 'verified' OR verified_account_id IS NOT NULL)
);
CREATE TABLE migration_staging_objects (
  migration_id TEXT NOT NULL REFERENCES migration_staging_batches(migration_id),
  object_id BLOB NOT NULL CHECK (length(object_id) = 32),
  byte_count INTEGER NOT NULL CHECK (byte_count BETWEEN 0 AND 262144000),
  bytes BLOB NOT NULL,
  PRIMARY KEY (migration_id, object_id),
  CHECK (length(bytes) = byte_count)
);
CREATE TABLE quarantine_records (
  quarantine_id TEXT PRIMARY KEY,
  work_id TEXT,
  account_id TEXT,
  reason TEXT NOT NULL,
  evidence_bytes BLOB NOT NULL,
  created_at TEXT NOT NULL,
  FOREIGN KEY (work_id) REFERENCES works(work_id)
);

CREATE INDEX sync_intents_pending ON sync_intents(work_id, status, source_generation);
CREATE INDEX sealed_commands_pending ON sealed_commands(work_id, status);
CREATE INDEX inbox_by_work ON inbox_batches(work_id, state);

-- Atomic checkpoint transition (one BEGIN IMMEDIATE transaction):
-- 1. verify works.local_generation == expected_generation;
-- 2. INSERT exact object BLOBs, Snapshot, parents, entries and occurrence;
-- 3. UPDATE works SET current_snapshot_id=?, local_generation=expected+1
--    WHERE work_id=? AND local_generation=expected;
-- 4. require changes() == 1 and UPSERT only an unsealed coalescible latest
--    SyncIntent; never use INSERT OR REPLACE on a sealed/receipted row;
-- 5. COMMIT. No network/UI await occurs inside this boundary.
-- New works begin at generation 0 with current_snapshot_id NULL; their first
-- checkpoint performs the same 0 -> 1 transition.

-- Conditional ACK (one transaction): persist remote head/receipt first, then
-- mark only Intent rows with source_generation <= acknowledged source. Clear
-- current pending state only when works.current_snapshot_id and
-- works.local_generation still equal the sealed source. A newer edit remains.

-- Safe remote adoption (one BEGIN IMMEDIATE transaction):
-- 1. require inbox state=verified and revalidate full manifest/object closure;
-- 2. require works.current_snapshot_id == expected_current_snapshot_id and
--    works.local_generation == expected_local_generation;
-- 3. copy inbox object BLOBs/Snapshot into authoritative tables, add the
--    pre-adoption pinned occurrence, and UPDATE current plus local_generation
--    to expected+1 using the same CAS; record the adopted history occurrence;
-- 4. mark inbox adopted and conflict resolved; create no SyncIntent for the
--    selected remote bytes; COMMIT. CAS failure leaves inbox verified and the
--    concurrent local edit untouched.
