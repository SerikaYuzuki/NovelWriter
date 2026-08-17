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
  sync_lane TEXT NOT NULL DEFAULT 'normal'
    CHECK (sync_lane IN ('normal', 'keepBothReserved')),
  CHECK (
    (local_generation = 0 AND current_snapshot_id IS NULL) OR
    (local_generation > 0 AND current_snapshot_id IS NOT NULL)
  ),
  CHECK (
    (acknowledged_head_snapshot_id IS NULL) =
    (acknowledged_head_generation IS NULL)
  ),
  FOREIGN KEY (work_id, current_snapshot_id)
    REFERENCES snapshots(work_id, snapshot_id)
    DEFERRABLE INITIALLY DEFERRED,
  FOREIGN KEY (work_id, remote_equivalent_local_snapshot_id)
    REFERENCES snapshots(work_id, snapshot_id)
    DEFERRABLE INITIALLY DEFERRED
);
CREATE TABLE account_bindings (
  work_id TEXT NOT NULL REFERENCES works(work_id),
  server_instance_id TEXT NOT NULL,
  protocol_epoch INTEGER NOT NULL CHECK (protocol_epoch > 0),
  account_id TEXT NOT NULL,
  account_fence TEXT NOT NULL,
  state TEXT NOT NULL CHECK (state IN ('bound', 'quarantined', 'parked')),
  PRIMARY KEY (
    work_id, server_instance_id, protocol_epoch, account_id, account_fence
  )
);
CREATE UNIQUE INDEX one_bound_binding_per_work
  ON account_bindings(work_id) WHERE state = 'bound';
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
  scope_kind TEXT NOT NULL CHECK (scope_kind IN ('unbound', 'bound')),
  server_instance_id TEXT,
  protocol_epoch INTEGER CHECK (protocol_epoch IS NULL OR protocol_epoch > 0),
  account_id TEXT,
  account_fence TEXT,
  created_at TEXT NOT NULL,
  FOREIGN KEY (work_id, source_snapshot_id) REFERENCES snapshots(work_id, snapshot_id),
  FOREIGN KEY (
    work_id, server_instance_id, protocol_epoch, account_id, account_fence
  ) REFERENCES account_bindings(
    work_id, server_instance_id, protocol_epoch, account_id, account_fence
  ),
  CHECK (
    (scope_kind = 'unbound' AND server_instance_id IS NULL AND
      protocol_epoch IS NULL AND account_id IS NULL AND account_fence IS NULL) OR
    (scope_kind = 'bound' AND server_instance_id IS NOT NULL AND
      protocol_epoch IS NOT NULL AND account_id IS NOT NULL AND account_fence IS NOT NULL)
  )
);
CREATE TABLE sealed_commands (
  command_id TEXT PRIMARY KEY,
  work_id TEXT NOT NULL,
  intent_id TEXT REFERENCES sync_intents(intent_id),
  account_id TEXT NOT NULL,
  account_fence TEXT NOT NULL,
  server_instance_id TEXT NOT NULL,
  protocol_epoch INTEGER NOT NULL CHECK (protocol_epoch > 0),
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
  UNIQUE (account_id, work_id, command_id),
  FOREIGN KEY (
    work_id, server_instance_id, protocol_epoch, account_id, account_fence
  ) REFERENCES account_bindings(
    work_id, server_instance_id, protocol_epoch, account_id, account_fence
  ),
  FOREIGN KEY (work_id, source_snapshot_id) REFERENCES snapshots(work_id, snapshot_id),
  CHECK ((response_status IS NULL) = (canonical_response IS NULL))
);
CREATE TABLE remote_receipts (
  account_id TEXT NOT NULL,
  work_id TEXT NOT NULL,
  command_id TEXT NOT NULL,
  command_kind TEXT NOT NULL CHECK (command_kind IN (
    'createWork', 'prepareObject', 'finalizeObject', 'registerSnapshot', 'publish',
    'resolveDevice', 'resolveServer', 'cloneWork', 'restore'
  )),
  request_digest BLOB NOT NULL CHECK (length(request_digest) = 32),
  response_status INTEGER NOT NULL CHECK (response_status BETWEEN 100 AND 599),
  canonical_response BLOB NOT NULL CHECK (length(canonical_response) <= 33554432),
  terminal_result TEXT NOT NULL CHECK (terminal_result IN (
    'applied', 'noChanges', 'conflictPending'
  )),
  account_matched INTEGER NOT NULL CHECK (account_matched IN (0, 1)),
  command_digest_matched INTEGER NOT NULL CHECK (command_digest_matched IN (0, 1)),
  resource_matched INTEGER NOT NULL CHECK (resource_matched IN (0, 1)),
  head_matched INTEGER NOT NULL CHECK (head_matched IN (0, 1)),
  state_matched INTEGER NOT NULL CHECK (state_matched IN (0, 1)),
  remote_head_snapshot_id BLOB,
  remote_head_generation INTEGER CHECK (
    remote_head_generation IS NULL OR remote_head_generation > 0
  ),
  clone_head_snapshot_id BLOB,
  clone_head_generation INTEGER CHECK (
    clone_head_generation IS NULL OR clone_head_generation > 0
  ),
  PRIMARY KEY (account_id, command_id),
  UNIQUE (account_id, work_id, command_id),
  FOREIGN KEY (account_id, work_id, command_id)
    REFERENCES sealed_commands(account_id, work_id, command_id),
  CHECK (
    account_matched = 1 AND command_digest_matched = 1 AND
    resource_matched = 1 AND head_matched = 1 AND state_matched = 1
  ),
  CHECK ((remote_head_snapshot_id IS NULL) = (remote_head_generation IS NULL)),
  CHECK ((clone_head_snapshot_id IS NULL) = (clone_head_generation IS NULL))
);

-- Inbox bytes are never authoritative until the whole closure is verified and
-- adopted. No FK from inbox_* to objects/snapshots is intentional.
CREATE TABLE inbox_batches (
  inbox_id TEXT PRIMARY KEY,
  work_id TEXT NOT NULL REFERENCES works(work_id),
  document_id TEXT NOT NULL,
  document_created_at TEXT NOT NULL,
  server_instance_id TEXT NOT NULL,
  protocol_epoch INTEGER NOT NULL CHECK (protocol_epoch > 0),
  account_id TEXT NOT NULL,
  account_fence TEXT NOT NULL,
  snapshot_id BLOB NOT NULL CHECK (length(snapshot_id) = 32),
  manifest_bytes BLOB NOT NULL CHECK (length(manifest_bytes) <= 16777216),
  expected_current_snapshot_id BLOB,
  expected_local_generation INTEGER NOT NULL CHECK (expected_local_generation >= 0),
  expected_remote_head_snapshot_id BLOB,
  expected_remote_head_generation INTEGER CHECK (expected_remote_head_generation IS NULL OR expected_remote_head_generation > 0),
  state TEXT NOT NULL CHECK (state IN ('staged', 'verified', 'rejected', 'adopted')),
  rejection_code TEXT,
  CHECK ((expected_remote_head_snapshot_id IS NULL) = (expected_remote_head_generation IS NULL)),
  UNIQUE (work_id, snapshot_id, inbox_id),
  FOREIGN KEY (
    work_id, server_instance_id, protocol_epoch, account_id, account_fence
  ) REFERENCES account_bindings(
    work_id, server_instance_id, protocol_epoch, account_id, account_fence
  )
);
CREATE TABLE inbox_snapshots (
  inbox_id TEXT NOT NULL REFERENCES inbox_batches(inbox_id),
  snapshot_id BLOB NOT NULL CHECK (length(snapshot_id) = 32),
  work_id TEXT NOT NULL,
  manifest_bytes BLOB NOT NULL CHECK (length(manifest_bytes) <= 16777216),
  is_head INTEGER NOT NULL CHECK (is_head IN (0, 1)),
  verified INTEGER NOT NULL CHECK (verified IN (0, 1)),
  PRIMARY KEY (inbox_id, snapshot_id),
  UNIQUE (inbox_id, work_id, snapshot_id)
);
CREATE UNIQUE INDEX one_inbox_head
  ON inbox_snapshots(inbox_id) WHERE is_head = 1;
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
  inbox_id TEXT NOT NULL,
  snapshot_id BLOB NOT NULL,
  entity_key TEXT NOT NULL,
  object_id BLOB NOT NULL,
  byte_count INTEGER NOT NULL CHECK (byte_count >= 0),
  content_type TEXT NOT NULL CHECK (content_type IN (
    'application/vnd.fuminiwa.entity+json;version=2',
    'application/octet-stream'
  )),
  PRIMARY KEY (inbox_id, snapshot_id, entity_key),
  FOREIGN KEY (inbox_id, snapshot_id)
    REFERENCES inbox_snapshots(inbox_id, snapshot_id),
  FOREIGN KEY (inbox_id, object_id) REFERENCES inbox_objects(inbox_id, object_id)
);

CREATE TABLE conflicts (
  conflict_id TEXT PRIMARY KEY,
  work_id TEXT NOT NULL REFERENCES works(work_id),
  server_instance_id TEXT NOT NULL,
  protocol_epoch INTEGER NOT NULL CHECK (protocol_epoch > 0),
  account_id TEXT NOT NULL,
  account_fence TEXT NOT NULL,
  current_revision INTEGER NOT NULL CHECK (current_revision > 0),
  source_generation INTEGER NOT NULL CHECK (source_generation > 0),
  state TEXT NOT NULL CHECK (
    state IN ('active', 'resolved', 'quarantined', 'parked')
  ),
  UNIQUE (work_id, conflict_id),
  FOREIGN KEY (
    work_id, server_instance_id, protocol_epoch, account_id, account_fence
  ) REFERENCES account_bindings(
    work_id, server_instance_id, protocol_epoch, account_id, account_fence
  ),
  FOREIGN KEY (conflict_id, current_revision, source_generation)
    REFERENCES conflict_candidates(conflict_id, revision, source_generation)
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
  source_generation INTEGER NOT NULL CHECK (source_generation > 0),
  pinned INTEGER NOT NULL CHECK (pinned IN (0, 1)),
  PRIMARY KEY (conflict_id, revision),
  UNIQUE (conflict_id, revision, source_generation),
  FOREIGN KEY (work_id, conflict_id) REFERENCES conflicts(work_id, conflict_id),
  FOREIGN KEY (work_id, base_snapshot_id) REFERENCES snapshots(work_id, snapshot_id),
  FOREIGN KEY (work_id, local_snapshot_id) REFERENCES snapshots(work_id, snapshot_id),
  FOREIGN KEY (work_id, remote_snapshot_id, remote_inbox_id)
    REFERENCES inbox_batches(work_id, snapshot_id, inbox_id)
);
CREATE UNIQUE INDEX conflict_candidate_identity_with_base
  ON conflict_candidates(
    conflict_id,base_snapshot_id,local_snapshot_id,remote_snapshot_id,
    source_generation
  ) WHERE base_snapshot_id IS NOT NULL;
CREATE UNIQUE INDEX conflict_candidate_identity_without_base
  ON conflict_candidates(
    conflict_id,local_snapshot_id,remote_snapshot_id,source_generation
  ) WHERE base_snapshot_id IS NULL;
-- conflict_candidates are append-only. The local repository may update only
-- conflicts.current_revision/state and must reject UPDATE/DELETE of an older
-- candidate in its conformance tests.
CREATE TABLE restore_records (
  restore_id TEXT PRIMARY KEY,
  work_id TEXT NOT NULL,
  account_id TEXT,
  selected_snapshot_id BLOB NOT NULL,
  pre_restore_snapshot_id BLOB NOT NULL,
  result_snapshot_id BLOB NOT NULL,
  intent_id TEXT NOT NULL UNIQUE,
  command_id TEXT UNIQUE,
  selected_remote_equivalent_snapshot_id BLOB,
  selected_remote_equivalent_generation INTEGER CHECK (
    selected_remote_equivalent_generation IS NULL OR
    selected_remote_equivalent_generation > 0
  ),
  expected_remote_head_snapshot_id BLOB,
  expected_remote_head_generation INTEGER CHECK (
    expected_remote_head_generation IS NULL OR
    expected_remote_head_generation BETWEEN 1 AND 9007199254740991
  ),
  state TEXT NOT NULL CHECK (state IN ('prepared', 'sealed', 'finalized')),
  FOREIGN KEY (work_id, selected_snapshot_id) REFERENCES snapshots(work_id, snapshot_id),
  FOREIGN KEY (work_id, pre_restore_snapshot_id) REFERENCES snapshots(work_id, snapshot_id),
  FOREIGN KEY (work_id, result_snapshot_id) REFERENCES snapshots(work_id, snapshot_id),
  FOREIGN KEY (intent_id) REFERENCES sync_intents(intent_id),
  FOREIGN KEY (account_id, work_id, command_id)
    REFERENCES sealed_commands(account_id, work_id, command_id),
  CHECK (
    (selected_remote_equivalent_snapshot_id IS NULL) =
    (selected_remote_equivalent_generation IS NULL)
  ),
  CHECK (
    (expected_remote_head_snapshot_id IS NULL) =
    (expected_remote_head_generation IS NULL)
  ),
  CHECK (
    (state = 'prepared' AND command_id IS NULL) OR
    (state IN ('sealed', 'finalized') AND command_id IS NOT NULL)
  )
);
CREATE TABLE snapshot_remote_equivalents (
  work_id TEXT NOT NULL,
  local_snapshot_id BLOB NOT NULL,
  remote_snapshot_id BLOB NOT NULL,
  remote_generation INTEGER NOT NULL CHECK (remote_generation > 0),
  PRIMARY KEY (work_id, local_snapshot_id),
  FOREIGN KEY (work_id, local_snapshot_id)
    REFERENCES snapshots(work_id, snapshot_id)
);
CREATE TABLE pending_keep_both (
  reservation_id TEXT PRIMARY KEY,
  source_work_id TEXT NOT NULL,
  conflict_id TEXT NOT NULL,
  conflict_revision INTEGER NOT NULL CHECK (conflict_revision > 0),
  source_generation INTEGER NOT NULL CHECK (source_generation > 0),
  local_candidate_snapshot_id BLOB NOT NULL,
  remote_snapshot_id BLOB NOT NULL,
  new_work_id TEXT NOT NULL UNIQUE,
  new_document_id TEXT NOT NULL,
  new_root_snapshot_id BLOB NOT NULL,
  expected_original_head_snapshot_id BLOB NOT NULL,
  expected_original_head_generation INTEGER NOT NULL
    CHECK (expected_original_head_generation > 0),
  command_id TEXT UNIQUE,
  state TEXT NOT NULL CHECK (
    state IN ('prepared', 'sealed', 'finalized', 'quarantined', 'parked')
  ),
  created_at TEXT NOT NULL,
  FOREIGN KEY (source_work_id, conflict_id)
    REFERENCES conflicts(work_id, conflict_id),
  FOREIGN KEY (source_work_id, local_candidate_snapshot_id)
    REFERENCES snapshots(work_id, snapshot_id),
  FOREIGN KEY (new_work_id, new_root_snapshot_id)
    REFERENCES snapshots(work_id, snapshot_id),
  FOREIGN KEY (command_id) REFERENCES sealed_commands(command_id),
  UNIQUE (source_work_id, conflict_id),
  CHECK (
    (state = 'prepared' AND command_id IS NULL) OR
    (state IN ('sealed', 'finalized') AND command_id IS NOT NULL) OR
    state IN ('quarantined', 'parked')
  )
);
CREATE TABLE binding_transitions (
  transition_id TEXT PRIMARY KEY,
  work_id TEXT NOT NULL REFERENCES works(work_id),
  old_server_instance_id TEXT NOT NULL,
  old_protocol_epoch INTEGER NOT NULL,
  old_account_id TEXT NOT NULL,
  old_account_fence TEXT NOT NULL,
  disposition TEXT NOT NULL CHECK (disposition IN ('quarantined', 'parked')),
  new_server_instance_id TEXT NOT NULL,
  new_protocol_epoch INTEGER NOT NULL,
  new_account_id TEXT NOT NULL,
  new_account_fence TEXT NOT NULL,
  created_at TEXT NOT NULL
);

CREATE TABLE migration_ledger (
  migration_id TEXT PRIMARY KEY,
  account_id TEXT,
  source_kind TEXT NOT NULL,
  source_digest BLOB NOT NULL,
  export_backup_marker TEXT,
  adoption_marker TEXT,
  quarantined_from_state TEXT CHECK (quarantined_from_state IN (
    'discovered', 'backupExported', 'staged', 'verified'
  )),
  evidence_bytes BLOB NOT NULL,
  state TEXT NOT NULL CHECK (state IN ('discovered', 'backupExported', 'staged', 'verified', 'committed', 'quarantined')),
  UNIQUE (source_kind, source_digest),
  CHECK (account_id IS NOT NULL OR state IN ('discovered', 'backupExported', 'staged', 'quarantined')),
  CHECK (
    (state = 'discovered' AND export_backup_marker IS NULL AND
      adoption_marker IS NULL AND quarantined_from_state IS NULL) OR
    (state IN ('backupExported', 'staged', 'verified') AND
      export_backup_marker IS NOT NULL AND
      length(export_backup_marker) BETWEEN 1 AND 512 AND
      adoption_marker IS NULL AND quarantined_from_state IS NULL) OR
    (state = 'committed' AND export_backup_marker IS NOT NULL AND
      adoption_marker IS NOT NULL AND
      length(export_backup_marker) BETWEEN 1 AND 512 AND
      length(adoption_marker) BETWEEN 1 AND 512 AND
      quarantined_from_state IS NULL) OR
    (state = 'quarantined' AND adoption_marker IS NULL AND
      quarantined_from_state IS NOT NULL AND (
        (quarantined_from_state = 'discovered' AND export_backup_marker IS NULL) OR
        (quarantined_from_state IN ('backupExported', 'staged', 'verified') AND
          export_backup_marker IS NOT NULL AND
          length(export_backup_marker) BETWEEN 1 AND 512)
      ))
  ),
  CHECK (
    state <> 'quarantined' OR quarantined_from_state <> 'verified' OR
    account_id IS NOT NULL
  )
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

-- Snapshot graph and conflict candidates are append-only. State transitions
-- occur only in works/conflicts/journals; immutable content is never rewritten.
CREATE TRIGGER objects_immutable_update
BEFORE UPDATE ON objects
BEGIN
  SELECT RAISE(ABORT, 'immutable object');
END;
CREATE TRIGGER objects_immutable_delete
BEFORE DELETE ON objects
BEGIN
  SELECT RAISE(ABORT, 'immutable object');
END;
CREATE TRIGGER snapshots_immutable_update
BEFORE UPDATE ON snapshots
BEGIN
  SELECT RAISE(ABORT, 'immutable snapshot');
END;
CREATE TRIGGER snapshots_immutable_delete
BEFORE DELETE ON snapshots
BEGIN
  SELECT RAISE(ABORT, 'immutable snapshot');
END;
CREATE TRIGGER snapshot_parents_immutable_update
BEFORE UPDATE ON snapshot_parents
BEGIN
  SELECT RAISE(ABORT, 'immutable snapshot parent');
END;
CREATE TRIGGER snapshot_parents_immutable_delete
BEFORE DELETE ON snapshot_parents
BEGIN
  SELECT RAISE(ABORT, 'immutable snapshot parent');
END;
CREATE TRIGGER snapshot_entries_immutable_update
BEFORE UPDATE ON snapshot_entries
BEGIN
  SELECT RAISE(ABORT, 'immutable snapshot entry');
END;
CREATE TRIGGER snapshot_entries_immutable_delete
BEFORE DELETE ON snapshot_entries
BEGIN
  SELECT RAISE(ABORT, 'immutable snapshot entry');
END;
CREATE TRIGGER conflict_candidates_immutable_update
BEFORE UPDATE ON conflict_candidates
BEGIN
  SELECT RAISE(ABORT, 'immutable conflict candidate');
END;
CREATE TRIGGER conflict_candidates_immutable_delete
BEFORE DELETE ON conflict_candidates
BEGIN
  SELECT RAISE(ABORT, 'immutable conflict candidate');
END;

CREATE INDEX sync_intents_pending ON sync_intents(work_id, status, source_generation);
CREATE INDEX sealed_commands_pending ON sealed_commands(work_id, status);
CREATE INDEX inbox_by_work ON inbox_batches(work_id, state);

-- Every remote receipt is constrained to the same account/work/command as its
-- sealed command. A cloneWork receipt remains on the source Work and atomically
-- finalizes the durable pending_keep_both reservation only after the server
-- confirms both heads. The reserved clone has no independent publish Intent
-- before that receipt. createWork is sealed only after the local Work and
-- account binding exist, so no local FK exception is required.

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

-- Conditional ACK (one transaction): validate every typed read-back predicate,
-- persist the monotonic remote head and exact operation receipt, then mark only
-- the Intent explicitly linked to the sealed command and only when its exact
-- SnapshotID/generation still match. prepare/finalize/register/transfer never
-- acknowledge a checkpoint Intent. No ACK rewrites works.current_snapshot_id;
-- a newer edit and its coalesced or later Intent always remain.

-- Safe remote adoption (one BEGIN IMMEDIATE transaction):
-- 1. require inbox state=verified and revalidate every canonical manifest,
--    object, parent, entry, anchor and head in the full graph closure;
-- 2. require works.current_snapshot_id == expected_current_snapshot_id and
--    works.local_generation == expected_local_generation;
-- 3. copy all graph object BLOBs/Snapshots into authoritative tables, add the
--    pre-adoption pinned occurrence, and UPDATE current plus local_generation
--    to expected+1 using the same CAS; record the adopted history occurrence;
-- 4. mark inbox adopted and conflict resolved; create no SyncIntent for the
--    selected remote bytes; COMMIT. When an already-sealed conflict choice is
--    acknowledged after a newer local generation exists, install only the
--    immutable graph/history/remote baseline and resolve that exact conflict;
--    leave current, the active editor and the newer Intent untouched.
