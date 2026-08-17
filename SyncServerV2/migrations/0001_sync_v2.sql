CREATE SCHEMA IF NOT EXISTS sync_v2;
CREATE TABLE sync_v2.server_meta(key TEXT PRIMARY KEY,value TEXT NOT NULL);
INSERT INTO sync_v2.server_meta(key,value) VALUES
  ('namespace','fuminiwa-snapshot-sync-v2'),
  ('protocol_epoch','2'),
  ('schema_version','2'),
  ('schema_checksum','631b0fed89a0031f33c9ac86b75695309c276d354d31e78b4a0db4eeb39c4657'),
  ('deployment_id','unbound');
CREATE TABLE sync_v2.account_scopes(account_id TEXT PRIMARY KEY,server_instance_id TEXT NOT NULL,protocol_epoch BIGINT NOT NULL,account_fence TEXT NOT NULL);
CREATE TABLE sync_v2.works(account_id TEXT NOT NULL REFERENCES sync_v2.account_scopes(account_id),work_id UUID NOT NULL,document_id UUID NOT NULL,state TEXT NOT NULL,head_snapshot_id BYTEA,head_generation BIGINT,PRIMARY KEY(account_id,work_id));
CREATE TABLE sync_v2.global_blobs(object_id BYTEA PRIMARY KEY,byte_count BIGINT NOT NULL,raw_bytes BYTEA NOT NULL);
CREATE TABLE sync_v2.account_objects(account_id TEXT NOT NULL REFERENCES sync_v2.account_scopes(account_id),object_id BYTEA NOT NULL REFERENCES sync_v2.global_blobs(object_id),state TEXT NOT NULL,PRIMARY KEY(account_id,object_id));
CREATE TABLE sync_v2.snapshots(account_id TEXT NOT NULL,work_id UUID NOT NULL,snapshot_id BYTEA NOT NULL,manifest_bytes BYTEA NOT NULL,manifest_digest BYTEA NOT NULL,created_at TIMESTAMPTZ NOT NULL,PRIMARY KEY(account_id,snapshot_id),FOREIGN KEY(account_id,work_id) REFERENCES sync_v2.works(account_id,work_id));
ALTER TABLE sync_v2.works ADD CONSTRAINT works_head_fk FOREIGN KEY(account_id,head_snapshot_id) REFERENCES sync_v2.snapshots(account_id,snapshot_id) DEFERRABLE INITIALLY DEFERRED;
CREATE TABLE sync_v2.snapshot_parents(account_id TEXT NOT NULL,work_id UUID NOT NULL,snapshot_id BYTEA NOT NULL,parent_snapshot_id BYTEA NOT NULL,PRIMARY KEY(account_id,snapshot_id,parent_snapshot_id));
CREATE TABLE sync_v2.snapshot_entries(account_id TEXT NOT NULL,snapshot_id BYTEA NOT NULL,entity_key TEXT NOT NULL,object_id BYTEA NOT NULL,byte_count BIGINT NOT NULL,content_type TEXT NOT NULL,PRIMARY KEY(account_id,snapshot_id,entity_key));
CREATE TABLE sync_v2.sealed_commands(account_id TEXT NOT NULL REFERENCES sync_v2.account_scopes(account_id),command_id UUID NOT NULL,work_id UUID NOT NULL,account_fence TEXT NOT NULL,command_kind TEXT NOT NULL,canonical_request BYTEA NOT NULL,request_digest BYTEA NOT NULL,source_snapshot_id BYTEA NOT NULL,source_generation BIGINT NOT NULL,state TEXT NOT NULL,PRIMARY KEY(account_id,command_id),FOREIGN KEY(account_id,work_id) REFERENCES sync_v2.works(account_id,work_id));
CREATE TABLE sync_v2.receipts(account_id TEXT NOT NULL REFERENCES sync_v2.account_scopes(account_id),command_id UUID NOT NULL,command_kind TEXT NOT NULL,request_digest BYTEA NOT NULL,canonical_request BYTEA NOT NULL,response_status INTEGER,canonical_response BYTEA,completed_at TIMESTAMPTZ,state TEXT NOT NULL,PRIMARY KEY(account_id,command_id),FOREIGN KEY(account_id,command_id) REFERENCES sync_v2.sealed_commands(account_id,command_id) DEFERRABLE INITIALLY DEFERRED);
CREATE TABLE sync_v2.upload_capabilities(account_id TEXT NOT NULL REFERENCES sync_v2.account_scopes(account_id),upload_id UUID NOT NULL,command_id UUID NOT NULL,work_id UUID NOT NULL,account_fence TEXT NOT NULL,object_id BYTEA NOT NULL,byte_count BIGINT NOT NULL,state TEXT NOT NULL,expires_at TIMESTAMPTZ NOT NULL,PRIMARY KEY(account_id,upload_id),FOREIGN KEY(account_id,command_id) REFERENCES sync_v2.sealed_commands(account_id,command_id),FOREIGN KEY(account_id,work_id) REFERENCES sync_v2.works(account_id,work_id));
CREATE TABLE sync_v2.active_conflicts(account_id TEXT NOT NULL,conflict_id UUID NOT NULL,work_id UUID NOT NULL,current_revision BIGINT NOT NULL,state TEXT NOT NULL,PRIMARY KEY(account_id,conflict_id),FOREIGN KEY(account_id,work_id) REFERENCES sync_v2.works(account_id,work_id));
CREATE UNIQUE INDEX one_active_conflict_per_account_work ON sync_v2.active_conflicts(account_id,work_id) WHERE state='active';
CREATE TABLE sync_v2.conflict_candidates(account_id TEXT NOT NULL,conflict_id UUID NOT NULL,work_id UUID NOT NULL,revision BIGINT NOT NULL,base_snapshot_id BYTEA,local_snapshot_id BYTEA NOT NULL,remote_snapshot_id BYTEA NOT NULL,pinned BOOLEAN NOT NULL DEFAULT TRUE,created_at TIMESTAMPTZ NOT NULL,PRIMARY KEY(account_id,conflict_id,revision),FOREIGN KEY(account_id,conflict_id) REFERENCES sync_v2.active_conflicts(account_id,conflict_id));
CREATE TABLE sync_v2.conflict_events(account_id TEXT NOT NULL,event_id BIGINT GENERATED ALWAYS AS IDENTITY,conflict_id UUID NOT NULL,revision BIGINT NOT NULL,event_kind TEXT NOT NULL,canonical_event BYTEA NOT NULL,created_at TIMESTAMPTZ NOT NULL,PRIMARY KEY(account_id,event_id));
CREATE TABLE sync_v2.history(account_id TEXT NOT NULL,occurrence_id UUID NOT NULL,event_id BIGINT GENERATED ALWAYS AS IDENTITY,work_id UUID NOT NULL,snapshot_id BYTEA NOT NULL,reason TEXT NOT NULL,pinned BOOLEAN NOT NULL,created_at TIMESTAMPTZ NOT NULL,PRIMARY KEY(account_id,occurrence_id),UNIQUE(account_id,event_id),FOREIGN KEY(account_id,work_id) REFERENCES sync_v2.works(account_id,work_id));
CREATE TABLE sync_v2.head_events(account_id TEXT NOT NULL,event_id BIGINT GENERATED ALWAYS AS IDENTITY,work_id UUID NOT NULL,generation BIGINT NOT NULL,snapshot_id BYTEA NOT NULL,command_id UUID NOT NULL,created_at TIMESTAMPTZ NOT NULL,PRIMARY KEY(account_id,event_id),UNIQUE(account_id,work_id,generation),FOREIGN KEY(account_id,work_id) REFERENCES sync_v2.works(account_id,work_id),FOREIGN KEY(account_id,command_id) REFERENCES sync_v2.receipts(account_id,command_id));
CREATE TABLE sync_v2.catalog_events(account_id TEXT NOT NULL,event_id BIGINT GENERATED ALWAYS AS IDENTITY,work_id UUID NOT NULL,event_kind TEXT NOT NULL,head_generation BIGINT,head_snapshot_id BYTEA,title TEXT NOT NULL,tombstoned BOOLEAN NOT NULL,created_at TIMESTAMPTZ NOT NULL,PRIMARY KEY(account_id,event_id));
CREATE INDEX work_catalog_cursor ON sync_v2.catalog_events(account_id,event_id);
CREATE INDEX snapshot_history_cursor ON sync_v2.history(account_id,work_id,event_id);

-- Contract completion constraints. This migration is only for a new v2
-- database; it intentionally has no compatibility path to the v1 schema.
ALTER TABLE sync_v2.works
  ADD CONSTRAINT works_head_pair_ck CHECK ((head_snapshot_id IS NULL) = (head_generation IS NULL));
ALTER TABLE sync_v2.snapshots
  ADD CONSTRAINT snapshots_id_len_ck CHECK (octet_length(snapshot_id)=32),
  ADD CONSTRAINT snapshots_digest_len_ck CHECK (octet_length(manifest_digest)=32),
  ADD CONSTRAINT snapshots_manifest_len_ck CHECK (octet_length(manifest_bytes)<=16777216),
  ADD CONSTRAINT snapshots_digest_equal_ck CHECK (manifest_digest=snapshot_id);
ALTER TABLE sync_v2.snapshots
  ADD CONSTRAINT snapshots_work_id_uq UNIQUE(account_id,work_id,snapshot_id),
  ADD CONSTRAINT snapshots_digest_uq UNIQUE(account_id,manifest_digest);
ALTER TABLE sync_v2.global_blobs
  ADD CONSTRAINT global_blob_id_len_ck CHECK(octet_length(object_id)=32),
  ADD CONSTRAINT global_blob_count_ck CHECK(byte_count BETWEEN 0 AND 262144000),
  ADD CONSTRAINT global_blob_bytes_ck CHECK(octet_length(raw_bytes)=byte_count);
ALTER TABLE sync_v2.account_objects
  ADD CONSTRAINT account_object_state_ck CHECK(state IN('available','quarantined','deleting'));
ALTER TABLE sync_v2.works
  ADD CONSTRAINT works_head_snapshot_scope_fk FOREIGN KEY(account_id,work_id,head_snapshot_id)
  REFERENCES sync_v2.snapshots(account_id,work_id,snapshot_id) DEFERRABLE INITIALLY DEFERRED;
ALTER TABLE sync_v2.account_scopes
  ADD CONSTRAINT account_scope_epoch_ck CHECK(protocol_epoch > 0);
ALTER TABLE sync_v2.works
  ADD CONSTRAINT works_state_ck CHECK(state IN('bound','quarantined')),
  ADD CONSTRAINT works_generation_ck CHECK(head_generation IS NULL OR head_generation > 0);
ALTER TABLE sync_v2.snapshot_parents
  ADD CONSTRAINT snapshot_parent_fk FOREIGN KEY(account_id,work_id,snapshot_id) REFERENCES sync_v2.snapshots(account_id,work_id,snapshot_id),
  ADD CONSTRAINT snapshot_parent_target_fk FOREIGN KEY(account_id,work_id,parent_snapshot_id) REFERENCES sync_v2.snapshots(account_id,work_id,snapshot_id),
  ADD CONSTRAINT snapshot_parent_not_self_ck CHECK(snapshot_id<>parent_snapshot_id);
ALTER TABLE sync_v2.snapshot_entries
  ADD CONSTRAINT snapshot_entry_snapshot_fk FOREIGN KEY(account_id,snapshot_id) REFERENCES sync_v2.snapshots(account_id,snapshot_id),
  ADD CONSTRAINT snapshot_entry_object_fk FOREIGN KEY(account_id,object_id) REFERENCES sync_v2.account_objects(account_id,object_id),
  ADD CONSTRAINT snapshot_entry_content_ck CHECK ((content_type='application/vnd.fuminiwa.entity+json;version=2' AND byte_count<=16777216) OR (content_type='application/octet-stream' AND byte_count<=262144000));
ALTER TABLE sync_v2.receipts ADD COLUMN work_id UUID NOT NULL;
ALTER TABLE sync_v2.receipts
  ADD CONSTRAINT receipts_work_fk FOREIGN KEY(account_id,work_id) REFERENCES sync_v2.works(account_id,work_id) DEFERRABLE INITIALLY DEFERRED,
  ADD CONSTRAINT receipts_work_command_uq UNIQUE(account_id,work_id,command_id),
  ADD CONSTRAINT receipts_work_kind_uq UNIQUE(account_id,work_id,command_id,command_kind),
  ADD CONSTRAINT receipts_command_kind_ck CHECK(command_kind IN ('createWork','prepareObject','finalizeObject','registerSnapshot','publish','resolveDevice','resolveServer','cloneWork','restore'));
ALTER TABLE sync_v2.sealed_commands
  ADD CONSTRAINT sealed_work_command_uq UNIQUE(account_id,work_id,command_id),
  ADD CONSTRAINT sealed_work_kind_uq UNIQUE(account_id,work_id,command_id,command_kind),
  ADD CONSTRAINT sealed_command_kind_ck CHECK(command_kind IN ('createWork','prepareObject','finalizeObject','registerSnapshot','publish','resolveDevice','resolveServer','cloneWork','restore')),
  ADD CONSTRAINT sealed_state_ck CHECK(state IN('sealed','sending','completed','quarantined','conflictPending','parked')),
  ADD CONSTRAINT sealed_request_len_ck CHECK(octet_length(canonical_request)<=33554432),
  ADD CONSTRAINT sealed_digest_len_ck CHECK(octet_length(request_digest)=32),
  ADD CONSTRAINT sealed_source_id_len_ck CHECK(octet_length(source_snapshot_id)=32),
  ADD CONSTRAINT sealed_generation_ck CHECK(source_generation>0);
ALTER TABLE sync_v2.receipts
  ADD CONSTRAINT receipts_state_ck CHECK(state IN('reserved','completed')),
  ADD CONSTRAINT receipts_kind_ck CHECK(command_kind IN ('createWork','prepareObject','finalizeObject','registerSnapshot','publish','resolveDevice','resolveServer','cloneWork','restore')),
  ADD CONSTRAINT receipts_digest_len_ck CHECK(octet_length(request_digest)=32),
  ADD CONSTRAINT receipts_request_len_ck CHECK(octet_length(canonical_request)<=33554432),
  ADD CONSTRAINT receipts_response_len_ck CHECK(canonical_response IS NULL OR octet_length(canonical_response)<=33554432),
  ADD CONSTRAINT receipts_state_shape_ck CHECK((state='reserved' AND response_status IS NULL AND canonical_response IS NULL AND completed_at IS NULL) OR (state='completed' AND response_status IS NOT NULL AND canonical_response IS NOT NULL AND completed_at IS NOT NULL));
ALTER TABLE sync_v2.upload_capabilities
  ADD CONSTRAINT upload_sealed_composite_fk FOREIGN KEY(account_id,work_id,command_id) REFERENCES sync_v2.sealed_commands(account_id,work_id,command_id),
  ADD CONSTRAINT upload_object_id_len_ck CHECK(octet_length(object_id)=32),
  ADD CONSTRAINT upload_byte_count_ck CHECK(byte_count BETWEEN 0 AND 262144000),
  ADD CONSTRAINT upload_state_ck CHECK(state IN('prepared','uploaded','finalized','expired'));
ALTER TABLE sync_v2.active_conflicts ADD COLUMN source_generation BIGINT NOT NULL;
ALTER TABLE sync_v2.active_conflicts ADD CONSTRAINT active_conflict_source_generation_ck CHECK(source_generation>0),
  ADD CONSTRAINT active_conflict_revision_ck CHECK(current_revision>0),
  ADD CONSTRAINT active_conflict_state_ck CHECK(state IN('active','resolved'));
ALTER TABLE sync_v2.conflict_candidates ADD COLUMN source_generation BIGINT NOT NULL;
ALTER TABLE sync_v2.conflict_candidates
  ADD CONSTRAINT conflict_candidate_source_generation_ck CHECK(source_generation>0),
  ADD CONSTRAINT conflict_candidate_revision_ck CHECK(revision>0),
  ADD CONSTRAINT conflict_candidate_remote_len_ck CHECK(octet_length(remote_snapshot_id)=32),
  ADD CONSTRAINT conflict_candidate_local_len_ck CHECK(octet_length(local_snapshot_id)=32),
  ADD CONSTRAINT conflict_candidate_base_len_ck CHECK(base_snapshot_id IS NULL OR octet_length(base_snapshot_id)=32);
ALTER TABLE sync_v2.conflict_candidates
  ADD CONSTRAINT conflict_candidate_work_fk FOREIGN KEY(account_id,work_id,base_snapshot_id) REFERENCES sync_v2.snapshots(account_id,work_id,snapshot_id),
  ADD CONSTRAINT conflict_candidate_local_fk FOREIGN KEY(account_id,work_id,local_snapshot_id) REFERENCES sync_v2.snapshots(account_id,work_id,snapshot_id),
  ADD CONSTRAINT conflict_candidate_remote_fk FOREIGN KEY(account_id,work_id,remote_snapshot_id) REFERENCES sync_v2.snapshots(account_id,work_id,snapshot_id),
  ADD CONSTRAINT conflict_revision_source_uq UNIQUE(account_id,conflict_id,revision,source_generation);
ALTER TABLE sync_v2.active_conflicts
  ADD CONSTRAINT active_conflict_revision_source_fk FOREIGN KEY(account_id,conflict_id,current_revision,source_generation) REFERENCES sync_v2.conflict_candidates(account_id,conflict_id,revision,source_generation) DEFERRABLE INITIALLY DEFERRED;
CREATE TABLE sync_v2.restore_receipts(account_id TEXT NOT NULL,command_id UUID NOT NULL,work_id UUID NOT NULL,selected_snapshot_id BYTEA NOT NULL,pre_restore_snapshot_id BYTEA NOT NULL,result_snapshot_id BYTEA NOT NULL,PRIMARY KEY(account_id,command_id),FOREIGN KEY(account_id,work_id) REFERENCES sync_v2.works(account_id,work_id),FOREIGN KEY(account_id,work_id,selected_snapshot_id) REFERENCES sync_v2.snapshots(account_id,work_id,snapshot_id),FOREIGN KEY(account_id,work_id,pre_restore_snapshot_id) REFERENCES sync_v2.snapshots(account_id,work_id,snapshot_id),FOREIGN KEY(account_id,work_id,result_snapshot_id) REFERENCES sync_v2.snapshots(account_id,work_id,snapshot_id),FOREIGN KEY(account_id,work_id,command_id) REFERENCES sync_v2.receipts(account_id,work_id,command_id));
ALTER TABLE sync_v2.head_events ADD COLUMN command_work_id UUID NOT NULL, ADD COLUMN command_kind TEXT NOT NULL, ADD COLUMN command_scope TEXT NOT NULL;
ALTER TABLE sync_v2.head_events ADD CONSTRAINT head_command_scope_ck CHECK((command_scope='sameWork' AND command_work_id=work_id) OR (command_scope='cloneNewWork' AND command_work_id<>work_id AND command_kind='cloneWork'));
ALTER TABLE sync_v2.head_events ADD CONSTRAINT head_receipt_fk FOREIGN KEY(account_id,command_work_id,command_id,command_kind) REFERENCES sync_v2.receipts(account_id,work_id,command_id,command_kind);
ALTER TABLE sync_v2.catalog_events ADD CONSTRAINT catalog_head_pair_ck CHECK((head_generation IS NULL)=(head_snapshot_id IS NULL));
CREATE TABLE sync_v2.quarantine_records(account_id TEXT NOT NULL,quarantine_id UUID NOT NULL,work_id UUID,reason TEXT NOT NULL,evidence_bytes BYTEA NOT NULL,created_at TIMESTAMPTZ NOT NULL,PRIMARY KEY(account_id,quarantine_id),FOREIGN KEY(account_id,work_id) REFERENCES sync_v2.works(account_id,work_id));
CREATE TABLE sync_v2.migration_ledger(migration_id UUID PRIMARY KEY,account_id TEXT,source_kind TEXT NOT NULL,source_digest BYTEA NOT NULL,export_backup_marker TEXT,adoption_marker TEXT,quarantined_from_state TEXT,evidence_bytes BYTEA NOT NULL,state TEXT NOT NULL,UNIQUE(source_kind,source_digest),CHECK(account_id IS NOT NULL OR state IN('discovered','backupExported','staged','quarantined')));
CREATE TABLE sync_v2.migration_staging_batches(migration_id UUID PRIMARY KEY REFERENCES sync_v2.migration_ledger(migration_id),proposed_work_id UUID NOT NULL,proposed_document_id UUID NOT NULL,snapshot_id BYTEA NOT NULL,manifest_bytes BYTEA NOT NULL,verified_account_id TEXT,state TEXT NOT NULL,CHECK(state<>'verified' OR verified_account_id IS NOT NULL));
CREATE TABLE sync_v2.migration_staging_objects(migration_id UUID NOT NULL REFERENCES sync_v2.migration_staging_batches(migration_id),object_id BYTEA NOT NULL,byte_count BIGINT NOT NULL,raw_bytes BYTEA NOT NULL,PRIMARY KEY(migration_id,object_id),CHECK(octet_length(raw_bytes)=byte_count));

-- The v2 migration is installed only into a fresh database.  Keep these
-- constraints in the migration itself (rather than relying on repository
-- checks) so direct SQL readers and writers observe the same authority.
ALTER TABLE sync_v2.upload_capabilities
  ADD CONSTRAINT upload_command_uq UNIQUE(account_id,command_id);
ALTER TABLE sync_v2.active_conflicts
  ADD CONSTRAINT active_conflict_identity_uq UNIQUE(account_id,work_id,conflict_id);
ALTER TABLE sync_v2.conflict_events
  ADD CONSTRAINT conflict_event_candidate_fk
  FOREIGN KEY(account_id,conflict_id,revision)
  REFERENCES sync_v2.conflict_candidates(account_id,conflict_id,revision);
ALTER TABLE sync_v2.history
  ADD CONSTRAINT history_snapshot_fk
  FOREIGN KEY(account_id,work_id,snapshot_id)
  REFERENCES sync_v2.snapshots(account_id,work_id,snapshot_id);
ALTER TABLE sync_v2.head_events
  ADD CONSTRAINT head_event_snapshot_fk
  FOREIGN KEY(account_id,work_id,snapshot_id)
  REFERENCES sync_v2.snapshots(account_id,work_id,snapshot_id);
ALTER TABLE sync_v2.catalog_events
  ADD CONSTRAINT catalog_event_kind_ck CHECK(event_kind IN('upsert','tombstone')),
  ADD CONSTRAINT catalog_head_generation_ck CHECK(head_generation IS NULL OR head_generation>0),
  ADD CONSTRAINT catalog_head_snapshot_fk
  FOREIGN KEY(account_id,work_id,head_snapshot_id)
  REFERENCES sync_v2.snapshots(account_id,work_id,snapshot_id);
ALTER TABLE sync_v2.migration_ledger
  ADD CONSTRAINT migration_source_state_ck CHECK(quarantined_from_state IS NULL OR quarantined_from_state IN('discovered','backupExported','staged','verified')),
  ADD CONSTRAINT migration_state_ck CHECK(state IN('discovered','backupExported','staged','verified','committed','quarantined')),
  ADD CONSTRAINT migration_account_state_ck CHECK(account_id IS NOT NULL OR state IN('discovered','backupExported','staged','quarantined')),
  ADD CONSTRAINT migration_marker_shape_ck CHECK(
    (state='discovered' AND export_backup_marker IS NULL AND adoption_marker IS NULL AND quarantined_from_state IS NULL) OR
    (state IN('backupExported','staged','verified') AND export_backup_marker IS NOT NULL AND length(export_backup_marker) BETWEEN 1 AND 512 AND adoption_marker IS NULL AND quarantined_from_state IS NULL) OR
    (state='committed' AND export_backup_marker IS NOT NULL AND adoption_marker IS NOT NULL AND length(export_backup_marker) BETWEEN 1 AND 512 AND length(adoption_marker) BETWEEN 1 AND 512 AND quarantined_from_state IS NULL) OR
    (state='quarantined' AND adoption_marker IS NULL AND quarantined_from_state IS NOT NULL AND ((quarantined_from_state='discovered' AND export_backup_marker IS NULL) OR (quarantined_from_state IN('backupExported','staged','verified') AND export_backup_marker IS NOT NULL AND length(export_backup_marker) BETWEEN 1 AND 512)))
  ),
  ADD CONSTRAINT migration_verified_account_ck CHECK(state<>'quarantined' OR quarantined_from_state<>'verified' OR account_id IS NOT NULL);
ALTER TABLE sync_v2.migration_staging_batches
  ADD CONSTRAINT staging_manifest_id_len_ck CHECK(octet_length(snapshot_id)=32),
  ADD CONSTRAINT staging_manifest_len_ck CHECK(octet_length(manifest_bytes)<=16777216),
  ADD CONSTRAINT staging_state_ck CHECK(state IN('staged','verified','quarantined'));
ALTER TABLE sync_v2.migration_staging_objects
  ADD CONSTRAINT staging_object_id_len_ck CHECK(octet_length(object_id)=32),
  ADD CONSTRAINT staging_object_count_ck CHECK(byte_count BETWEEN 0 AND 262144000);
