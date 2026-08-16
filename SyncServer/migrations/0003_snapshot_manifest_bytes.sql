ALTER TABLE snapshots
  ADD COLUMN IF NOT EXISTS manifest_bytes BYTEA;
