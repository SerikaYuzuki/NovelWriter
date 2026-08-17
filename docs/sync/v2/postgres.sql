-- FUMINIWA Snapshot Sync v2 server schema.
-- Auth v1 supplies AuthenticatedPrincipal.account_id. The sync schema stores
-- no Apple subject, email, identity token, authorization code, or credential.
-- The same new PostgreSQL deployment installs the frozen Auth v1 state in a
-- separately namespaced auth_v1 schema/migration; this sync DDL neither owns nor
-- joins those provider/session tables.
CREATE SCHEMA IF NOT EXISTS sync_v2;

CREATE TABLE sync_v2.server_meta (
  key TEXT PRIMARY KEY,
  value TEXT NOT NULL
);
INSERT INTO sync_v2.server_meta(key, value) VALUES
  ('namespace', 'fuminiwa-snapshot-sync-v2'),
  ('protocol_epoch', '2'),
  ('schema_version', '2'),
  ('ddl_contract_marker', 'snapshot-sync-v2-postgres-r3');
-- The deployment identity is intentionally not a static migration value.
-- Repository startup inserts the expected environment-provided instance once
-- into this singleton table, then rejects every mismatch fail-closed.
CREATE TABLE sync_v2.deployment_binding (
  singleton BOOLEAN PRIMARY KEY DEFAULT TRUE CHECK (singleton),
  server_instance_id TEXT NOT NULL CHECK (length(server_instance_id) BETWEEN 1 AND 128),
  bound_at TIMESTAMPTZ NOT NULL
);
CREATE TABLE sync_v2.account_scopes (
  account_id TEXT PRIMARY KEY,
  server_instance_id TEXT NOT NULL,
  protocol_epoch BIGINT NOT NULL CHECK (protocol_epoch > 0),
  account_auth_epoch BIGINT NOT NULL CHECK (account_auth_epoch > 0),
  account_fence TEXT NOT NULL
);
CREATE TABLE sync_v2.works (
  account_id TEXT NOT NULL REFERENCES sync_v2.account_scopes(account_id),
  work_id UUID NOT NULL,
  document_id UUID NOT NULL,
  state TEXT NOT NULL CHECK (state IN ('bound', 'quarantined')),
  head_snapshot_id BYTEA,
  head_generation BIGINT CHECK (head_generation IS NULL OR head_generation > 0),
  CHECK ((head_snapshot_id IS NULL) = (head_generation IS NULL)),
  PRIMARY KEY (account_id, work_id)
);

-- Raw bytes may be physically deduplicated globally, but possession and every
-- API lookup are account scoped. ObjectStore is a Rust trait; v2 initially uses
-- PostgresObjectStore over this BYTEA table. A future S3 adapter is a separate
-- deployment migration and does not change account_objects identity.
CREATE TABLE sync_v2.global_blobs (
  object_id BYTEA PRIMARY KEY CHECK (octet_length(object_id) = 32),
  byte_count BIGINT NOT NULL CHECK (byte_count BETWEEN 0 AND 262144000),
  raw_bytes BYTEA NOT NULL,
  CHECK (octet_length(raw_bytes) = byte_count)
);
CREATE TABLE sync_v2.account_objects (
  account_id TEXT NOT NULL REFERENCES sync_v2.account_scopes(account_id),
  object_id BYTEA NOT NULL REFERENCES sync_v2.global_blobs(object_id),
  state TEXT NOT NULL CHECK (state IN ('available', 'quarantined', 'deleting')),
  PRIMARY KEY (account_id, object_id)
);
CREATE TABLE sync_v2.snapshots (
  account_id TEXT NOT NULL,
  work_id UUID NOT NULL,
  snapshot_id BYTEA NOT NULL CHECK (octet_length(snapshot_id) = 32),
  manifest_bytes BYTEA NOT NULL CHECK (octet_length(manifest_bytes) <= 16777216),
  manifest_digest BYTEA NOT NULL CHECK (octet_length(manifest_digest) = 32),
  created_at TIMESTAMPTZ NOT NULL,
  PRIMARY KEY (account_id, snapshot_id),
  UNIQUE (account_id, work_id, snapshot_id),
  UNIQUE (account_id, manifest_digest),
  CHECK (manifest_digest = snapshot_id),
  FOREIGN KEY (account_id, work_id) REFERENCES sync_v2.works(account_id, work_id)
);
ALTER TABLE sync_v2.works
  ADD CONSTRAINT works_head_snapshot_fk
  FOREIGN KEY (account_id, work_id, head_snapshot_id)
  REFERENCES sync_v2.snapshots(account_id, work_id, snapshot_id)
  DEFERRABLE INITIALLY DEFERRED;
CREATE TABLE sync_v2.snapshot_parents (
  account_id TEXT NOT NULL,
  work_id UUID NOT NULL,
  snapshot_id BYTEA NOT NULL,
  parent_snapshot_id BYTEA NOT NULL,
  PRIMARY KEY (account_id, snapshot_id, parent_snapshot_id),
  CHECK (snapshot_id <> parent_snapshot_id),
  FOREIGN KEY (account_id, work_id, snapshot_id)
    REFERENCES sync_v2.snapshots(account_id, work_id, snapshot_id),
  FOREIGN KEY (account_id, work_id, parent_snapshot_id)
    REFERENCES sync_v2.snapshots(account_id, work_id, snapshot_id)
);
CREATE TABLE sync_v2.snapshot_entries (
  account_id TEXT NOT NULL,
  snapshot_id BYTEA NOT NULL,
  entity_key TEXT NOT NULL,
  object_id BYTEA NOT NULL,
  byte_count BIGINT NOT NULL CHECK (byte_count >= 0),
  content_type TEXT NOT NULL CHECK (content_type IN (
    'application/vnd.fuminiwa.entity+json;version=2',
    'application/octet-stream'
  )),
  PRIMARY KEY (account_id, snapshot_id, entity_key),
  CHECK (
    (content_type = 'application/vnd.fuminiwa.entity+json;version=2' AND
      byte_count <= 16777216) OR
    (content_type = 'application/octet-stream' AND byte_count <= 262144000)
  ),
  FOREIGN KEY (account_id, snapshot_id)
    REFERENCES sync_v2.snapshots(account_id, snapshot_id),
  FOREIGN KEY (account_id, object_id)
    REFERENCES sync_v2.account_objects(account_id, object_id)
);

CREATE TABLE sync_v2.upload_capabilities (
  account_id TEXT NOT NULL REFERENCES sync_v2.account_scopes(account_id),
  upload_id UUID NOT NULL,
  command_id UUID NOT NULL,
  work_id UUID NOT NULL,
  account_fence TEXT NOT NULL,
  object_id BYTEA NOT NULL CHECK (octet_length(object_id) = 32),
  byte_count BIGINT NOT NULL CHECK (byte_count BETWEEN 0 AND 262144000),
  state TEXT NOT NULL CHECK (state IN ('prepared', 'uploaded', 'finalized', 'expired')),
  expires_at TIMESTAMPTZ NOT NULL,
  PRIMARY KEY (account_id, upload_id),
  UNIQUE (account_id, command_id),
  FOREIGN KEY (account_id, work_id) REFERENCES sync_v2.works(account_id, work_id)
);
CREATE TABLE sync_v2.receipts (
  account_id TEXT NOT NULL REFERENCES sync_v2.account_scopes(account_id),
  command_id UUID NOT NULL,
  work_id UUID NOT NULL,
  command_kind TEXT NOT NULL CHECK (command_kind IN (
    'createWork', 'prepareObject', 'finalizeObject', 'registerSnapshot', 'publish',
    'resolveDevice', 'resolveServer', 'cloneWork', 'restore'
  )),
  request_digest BYTEA NOT NULL CHECK (octet_length(request_digest) = 32),
  canonical_request BYTEA NOT NULL CHECK (octet_length(canonical_request) <= 33554432),
  response_status INTEGER CHECK (response_status BETWEEN 100 AND 599),
  canonical_response BYTEA CHECK (octet_length(canonical_response) <= 33554432),
  completed_at TIMESTAMPTZ,
  state TEXT NOT NULL CHECK (state IN ('reserved', 'completed')),
  PRIMARY KEY (account_id, command_id),
  UNIQUE (account_id, work_id, command_id),
  UNIQUE (account_id, work_id, command_id, command_kind),
  CHECK (
    (state = 'reserved' AND response_status IS NULL AND
      canonical_response IS NULL AND completed_at IS NULL) OR
    (state = 'completed' AND response_status IS NOT NULL AND
      canonical_response IS NOT NULL AND completed_at IS NOT NULL)
  ),
  FOREIGN KEY (account_id, work_id)
    REFERENCES sync_v2.works(account_id, work_id)
    DEFERRABLE INITIALLY DEFERRED
);
CREATE TABLE sync_v2.sealed_commands (
  account_id TEXT NOT NULL REFERENCES sync_v2.account_scopes(account_id),
  command_id UUID NOT NULL,
  work_id UUID NOT NULL,
  account_fence TEXT NOT NULL,
  command_kind TEXT NOT NULL CHECK (command_kind IN (
    'createWork', 'prepareObject', 'finalizeObject', 'registerSnapshot', 'publish',
    'resolveDevice', 'resolveServer', 'cloneWork', 'restore'
  )),
  canonical_request BYTEA NOT NULL CHECK (octet_length(canonical_request) <= 33554432),
  request_digest BYTEA NOT NULL CHECK (octet_length(request_digest) = 32),
  source_snapshot_id BYTEA NOT NULL CHECK (octet_length(source_snapshot_id) = 32),
  source_generation BIGINT NOT NULL CHECK (source_generation > 0),
  state TEXT NOT NULL CHECK (state IN ('sealed', 'sending', 'completed', 'quarantined', 'conflictPending', 'parked')),
  PRIMARY KEY (account_id, command_id),
  UNIQUE (account_id, work_id, command_id),
  UNIQUE (account_id, work_id, command_id, command_kind),
  FOREIGN KEY (account_id, work_id) REFERENCES sync_v2.works(account_id, work_id)
);
ALTER TABLE sync_v2.upload_capabilities
  ADD CONSTRAINT upload_capability_sealed_command_fk
  FOREIGN KEY (account_id, work_id, command_id)
  REFERENCES sync_v2.sealed_commands(account_id, work_id, command_id);
ALTER TABLE sync_v2.receipts
  ADD CONSTRAINT receipt_sealed_command_fk
  FOREIGN KEY (account_id, work_id, command_id, command_kind)
  REFERENCES sync_v2.sealed_commands(account_id, work_id, command_id, command_kind)
  DEFERRABLE INITIALLY DEFERRED;

CREATE TABLE sync_v2.active_conflicts (
  account_id TEXT NOT NULL,
  conflict_id UUID NOT NULL,
  work_id UUID NOT NULL,
  current_revision BIGINT NOT NULL CHECK (current_revision > 0),
  source_generation BIGINT NOT NULL CHECK (source_generation > 0),
  state TEXT NOT NULL CHECK (state IN ('active', 'resolved')),
  PRIMARY KEY (account_id, conflict_id),
  UNIQUE (account_id, work_id, conflict_id),
  FOREIGN KEY (account_id, work_id) REFERENCES sync_v2.works(account_id, work_id)
);
CREATE UNIQUE INDEX one_active_conflict_per_account_work
  ON sync_v2.active_conflicts(account_id, work_id) WHERE state = 'active';
CREATE TABLE sync_v2.conflict_candidates (
  account_id TEXT NOT NULL,
  conflict_id UUID NOT NULL,
  work_id UUID NOT NULL,
  revision BIGINT NOT NULL CHECK (revision > 0),
  base_snapshot_id BYTEA,
  local_snapshot_id BYTEA NOT NULL,
  remote_snapshot_id BYTEA NOT NULL,
  source_generation BIGINT NOT NULL CHECK (source_generation > 0),
  pinned BOOLEAN NOT NULL DEFAULT TRUE,
  created_at TIMESTAMPTZ NOT NULL,
  PRIMARY KEY (account_id, conflict_id, revision),
  UNIQUE (account_id, conflict_id, revision, source_generation),
  FOREIGN KEY (account_id, work_id, conflict_id)
    REFERENCES sync_v2.active_conflicts(account_id, work_id, conflict_id),
  FOREIGN KEY (account_id, work_id, base_snapshot_id)
    REFERENCES sync_v2.snapshots(account_id, work_id, snapshot_id),
  FOREIGN KEY (account_id, work_id, local_snapshot_id)
    REFERENCES sync_v2.snapshots(account_id, work_id, snapshot_id),
  FOREIGN KEY (account_id, work_id, remote_snapshot_id)
    REFERENCES sync_v2.snapshots(account_id, work_id, snapshot_id)
);
ALTER TABLE sync_v2.active_conflicts
  ADD CONSTRAINT active_conflict_current_revision_fk
  FOREIGN KEY (account_id, conflict_id, current_revision, source_generation)
  REFERENCES sync_v2.conflict_candidates(account_id, conflict_id, revision, source_generation)
  DEFERRABLE INITIALLY DEFERRED;
CREATE TABLE sync_v2.conflict_events (
  account_id TEXT NOT NULL,
  event_id BIGINT GENERATED ALWAYS AS IDENTITY,
  conflict_id UUID NOT NULL,
  revision BIGINT NOT NULL,
  event_kind TEXT NOT NULL,
  canonical_event BYTEA NOT NULL,
  created_at TIMESTAMPTZ NOT NULL,
  PRIMARY KEY (account_id, event_id),
  FOREIGN KEY (account_id, conflict_id, revision)
    REFERENCES sync_v2.conflict_candidates(account_id, conflict_id, revision)
);
-- The application repository exposes INSERT-only operations for
-- conflict_candidates/conflict_events. Only active_conflicts.current_revision
-- and state are mutable; an implementation migration must grant/revoke its DB
-- role accordingly and test that an earlier candidate cannot be updated.
CREATE TABLE sync_v2.history (
  account_id TEXT NOT NULL,
  occurrence_id UUID NOT NULL,
  event_id BIGINT GENERATED ALWAYS AS IDENTITY,
  work_id UUID NOT NULL,
  snapshot_id BYTEA NOT NULL,
  reason TEXT NOT NULL,
  pinned BOOLEAN NOT NULL,
  created_at TIMESTAMPTZ NOT NULL,
  PRIMARY KEY (account_id, occurrence_id),
  UNIQUE (account_id, event_id),
  FOREIGN KEY (account_id, work_id) REFERENCES sync_v2.works(account_id, work_id),
  FOREIGN KEY (account_id, work_id, snapshot_id)
    REFERENCES sync_v2.snapshots(account_id, work_id, snapshot_id)
);
CREATE TABLE sync_v2.restore_receipts (
  account_id TEXT NOT NULL,
  command_id UUID NOT NULL,
  work_id UUID NOT NULL,
  selected_snapshot_id BYTEA NOT NULL,
  pre_restore_snapshot_id BYTEA NOT NULL,
  result_snapshot_id BYTEA NOT NULL,
  PRIMARY KEY (account_id, command_id),
  FOREIGN KEY (account_id, work_id) REFERENCES sync_v2.works(account_id, work_id),
  FOREIGN KEY (account_id, work_id, selected_snapshot_id)
    REFERENCES sync_v2.snapshots(account_id, work_id, snapshot_id),
  FOREIGN KEY (account_id, work_id, pre_restore_snapshot_id)
    REFERENCES sync_v2.snapshots(account_id, work_id, snapshot_id),
  FOREIGN KEY (account_id, work_id, result_snapshot_id)
    REFERENCES sync_v2.snapshots(account_id, work_id, snapshot_id),
  FOREIGN KEY (account_id, work_id, command_id)
    REFERENCES sync_v2.receipts(account_id, work_id, command_id)
);
CREATE TABLE sync_v2.head_events (
  account_id TEXT NOT NULL,
  event_id BIGINT GENERATED ALWAYS AS IDENTITY,
  work_id UUID NOT NULL,
  generation BIGINT NOT NULL CHECK (generation > 0),
  snapshot_id BYTEA NOT NULL,
  command_id UUID NOT NULL,
  command_work_id UUID NOT NULL,
  command_kind TEXT NOT NULL,
  command_scope TEXT NOT NULL CHECK (command_scope IN ('sameWork', 'cloneNewWork')),
  created_at TIMESTAMPTZ NOT NULL,
  PRIMARY KEY (account_id, event_id),
  UNIQUE (account_id, work_id, generation),
  CHECK (
    (command_scope = 'sameWork' AND command_work_id = work_id) OR
    (command_scope = 'cloneNewWork' AND command_work_id <> work_id AND
      command_kind = 'cloneWork')
  ),
  FOREIGN KEY (account_id, work_id) REFERENCES sync_v2.works(account_id, work_id),
  FOREIGN KEY (account_id, work_id, snapshot_id)
    REFERENCES sync_v2.snapshots(account_id, work_id, snapshot_id),
  FOREIGN KEY (account_id, command_work_id, command_id, command_kind)
    REFERENCES sync_v2.receipts(account_id, work_id, command_id, command_kind)
);
CREATE TABLE sync_v2.catalog_events (
  account_id TEXT NOT NULL,
  event_id BIGINT GENERATED ALWAYS AS IDENTITY,
  work_id UUID NOT NULL,
  event_kind TEXT NOT NULL CHECK (event_kind IN ('upsert', 'tombstone')),
  head_generation BIGINT CHECK (head_generation IS NULL OR head_generation > 0),
  head_snapshot_id BYTEA CHECK (head_snapshot_id IS NULL OR octet_length(head_snapshot_id) = 32),
  title TEXT NOT NULL,
  tombstoned BOOLEAN NOT NULL,
  created_at TIMESTAMPTZ NOT NULL,
  PRIMARY KEY (account_id, event_id),
  CHECK ((head_generation IS NULL) = (head_snapshot_id IS NULL)),
  FOREIGN KEY (account_id, work_id) REFERENCES sync_v2.works(account_id, work_id),
  FOREIGN KEY (account_id, work_id, head_snapshot_id)
    REFERENCES sync_v2.snapshots(account_id, work_id, snapshot_id)
);
CREATE TABLE sync_v2.quarantine_records (
  account_id TEXT NOT NULL,
  quarantine_id UUID NOT NULL,
  work_id UUID,
  reason TEXT NOT NULL,
  evidence_bytes BYTEA NOT NULL,
  created_at TIMESTAMPTZ NOT NULL,
  PRIMARY KEY (account_id, quarantine_id),
  FOREIGN KEY (account_id, work_id) REFERENCES sync_v2.works(account_id, work_id)
);

-- Offline migration evidence is source-scoped, not a remotely addressable
-- tenant resource. account_id is nullable until verified. Unknown accounts can
-- only be quarantined and cannot create Work/Snapshot rows.
CREATE TABLE sync_v2.migration_ledger (
  migration_id UUID PRIMARY KEY,
  account_id TEXT,
  source_kind TEXT NOT NULL,
  source_digest BYTEA NOT NULL,
  export_backup_marker TEXT,
  adoption_marker TEXT,
  quarantined_from_state TEXT CHECK (quarantined_from_state IN (
    'discovered', 'backupExported', 'staged', 'verified'
  )),
  evidence_bytes BYTEA NOT NULL,
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

-- Offline adoption staging is deliberately outside the authoritative Work,
-- Snapshot and account-object FK graph. This permits a verified backup for a
-- not-yet-created Work to survive a crash without making it live.
CREATE TABLE sync_v2.migration_staging_batches (
  migration_id UUID PRIMARY KEY REFERENCES sync_v2.migration_ledger(migration_id),
  proposed_work_id UUID NOT NULL,
  proposed_document_id UUID NOT NULL,
  snapshot_id BYTEA NOT NULL CHECK (octet_length(snapshot_id) = 32),
  manifest_bytes BYTEA NOT NULL CHECK (octet_length(manifest_bytes) <= 16777216),
  verified_account_id TEXT,
  state TEXT NOT NULL CHECK (state IN ('staged', 'verified', 'quarantined')),
  CHECK (state <> 'verified' OR verified_account_id IS NOT NULL)
);
CREATE TABLE sync_v2.migration_staging_objects (
  migration_id UUID NOT NULL REFERENCES sync_v2.migration_staging_batches(migration_id),
  object_id BYTEA NOT NULL CHECK (octet_length(object_id) = 32),
  byte_count BIGINT NOT NULL CHECK (byte_count BETWEEN 0 AND 262144000),
  raw_bytes BYTEA NOT NULL,
  PRIMARY KEY (migration_id, object_id),
  CHECK (octet_length(raw_bytes) = byte_count)
);

CREATE INDEX work_catalog_cursor ON sync_v2.catalog_events(account_id, event_id);
CREATE INDEX snapshot_history_cursor ON sync_v2.history(account_id, work_id, event_id);

-- Transaction/lock order for every mutating route:
-- 1. derive account_id exclusively from AuthenticatedPrincipal;
-- 2. INSERT the exact request as a reserved receipts(account_id, command_id)
--    row, or lock/read the existing row; reject any kind/bytes reuse. The
--    unique insert happens before the Work lock, and rollback removes an
--    incomplete reservation;
-- 3. lock account_scopes, then works(account_id, work_id) FOR UPDATE;
-- 4. lock head/conflict/upload rows in their PK order;
-- 5. mutate head, append conflict/history/catalog/head events, read back the
--    predicates, and finalize the exact canonical response/receipt in the same
--    transaction. GET receipt exposes only state=completed.
-- Every route joins by account_id. Foreign and absent resources return the
-- same notFoundInAccount response before any existence detail is revealed.
-- createWork is the sole missing-Work exception: after receipt reservation and
-- account-scope lock it takes a transaction advisory lock over the exact
-- (account_id, work_id) key, rechecks absence, inserts the null-head Work and
-- then seals/completes the command in that same transaction. It emits no
-- catalog event because title bytes are not registered yet; the first
-- successful publish appends the initial catalog event from its verified
-- Snapshot closure.
-- It never adopts an existing Work from another account. All later object,
-- snapshot and publish routes require the account-scoped Work row.
-- document_id is intentionally not unique: importing the same portable
-- package twice creates two independent WorkIDs without remote deduplication.
-- receipts always retain work_id and are constrained to the same scoped
-- sealed command. createWork alone reserves that receipt before the Work row;
-- both FKs are deferred and the same transaction must insert the Work and
-- sealed command before completion. cloneWork remains scoped to its source
-- Work; a new-Work head event uses command_scope=cloneNewWork plus the source
-- command_work_id and a receipt constrained to command_kind=cloneWork.
