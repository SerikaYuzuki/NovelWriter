-- Reference lookups for blob GC and account-scoped object reads.
CREATE INDEX account_objects_object_id ON sync_v2.account_objects(object_id);
CREATE INDEX snapshot_entries_account_object ON sync_v2.snapshot_entries(account_id, object_id);
