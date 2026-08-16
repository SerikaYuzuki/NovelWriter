-- Every sync row is owned by exactly one FUMINIWA account.  Existing rows
-- predate account ownership.  They may be adopted only when the database has
-- one (and only one) real account; otherwise the migration aborts before any
-- legacy row is assigned.
ALTER TABLE works ADD COLUMN IF NOT EXISTS account_id TEXT;
ALTER TABLE snapshots ADD COLUMN IF NOT EXISTS account_id TEXT;
ALTER TABLE conflicts ADD COLUMN IF NOT EXISTS account_id TEXT;
ALTER TABLE operations ADD COLUMN IF NOT EXISTS account_id TEXT;

CREATE TABLE IF NOT EXISTS auth_operations (
  operation_id UUID PRIMARY KEY,
  kind TEXT NOT NULL,
  request_sha256 TEXT NOT NULL,
  result JSONB NOT NULL,
  created_at TIMESTAMPTZ NOT NULL
);

-- Auth exchange receipts are created before an account is known.  Move them
-- to their own namespace before making sync operation ownership mandatory.
INSERT INTO auth_operations(operation_id, kind, request_sha256, result, created_at)
  SELECT operation_id, kind, request_sha256, result, created_at
    FROM operations
   WHERE account_id IS NULL AND kind = 'appleExchange'
  ON CONFLICT (operation_id) DO NOTHING;
DELETE FROM operations WHERE account_id IS NULL AND kind = 'appleExchange';

DO $$
DECLARE
  account_count BIGINT;
  legacy_count BIGINT;
  sole_account TEXT;
BEGIN
  SELECT COUNT(*) INTO account_count FROM accounts;
  SELECT COUNT(*) INTO legacy_count FROM works WHERE account_id IS NULL;
  SELECT legacy_count + (SELECT COUNT(*) FROM snapshots WHERE account_id IS NULL)
       + (SELECT COUNT(*) FROM conflicts WHERE account_id IS NULL)
       + (SELECT COUNT(*) FROM operations WHERE account_id IS NULL AND kind <> 'appleExchange')
    INTO legacy_count;
  IF legacy_count > 0 AND account_count <> 1 THEN
    RAISE EXCEPTION 'cannot assign legacy sync rows: expected exactly one account, found %', account_count;
  END IF;
  IF legacy_count > 0 THEN
    SELECT account_id INTO sole_account FROM accounts LIMIT 1;
    UPDATE works SET account_id = sole_account WHERE account_id IS NULL;
    UPDATE snapshots SET account_id = sole_account WHERE account_id IS NULL;
    UPDATE conflicts SET account_id = sole_account WHERE account_id IS NULL;
    UPDATE operations SET account_id = sole_account WHERE account_id IS NULL;
  END IF;
END $$;

ALTER TABLE works ALTER COLUMN account_id SET NOT NULL;
ALTER TABLE snapshots ALTER COLUMN account_id SET NOT NULL;
ALTER TABLE conflicts ALTER COLUMN account_id SET NOT NULL;
ALTER TABLE operations ALTER COLUMN account_id SET NOT NULL;

-- Establish the composite ownership keys before any child table references
-- them.  PostgreSQL requires the referenced column set to be unique at the
-- moment the foreign key is added.
ALTER TABLE works DROP CONSTRAINT IF EXISTS works_pkey;
ALTER TABLE works ADD PRIMARY KEY (account_id, work_id);
ALTER TABLE snapshots DROP CONSTRAINT IF EXISTS snapshots_pkey;
ALTER TABLE snapshots ADD PRIMARY KEY (account_id, snapshot_id);
ALTER TABLE conflicts DROP CONSTRAINT IF EXISTS conflicts_pkey;
ALTER TABLE conflicts ADD PRIMARY KEY (account_id, conflict_id);
ALTER TABLE operations DROP CONSTRAINT IF EXISTS operations_pkey;
ALTER TABLE operations ADD PRIMARY KEY (account_id, operation_id);

ALTER TABLE works ADD CONSTRAINT works_account_fk
  FOREIGN KEY (account_id) REFERENCES accounts(account_id) ON DELETE CASCADE;
ALTER TABLE snapshots ADD CONSTRAINT snapshots_account_fk
  FOREIGN KEY (account_id) REFERENCES accounts(account_id) ON DELETE CASCADE;
ALTER TABLE conflicts ADD CONSTRAINT conflicts_account_fk
  FOREIGN KEY (account_id) REFERENCES accounts(account_id) ON DELETE CASCADE;
ALTER TABLE operations ADD CONSTRAINT operations_account_fk
  FOREIGN KEY (account_id) REFERENCES accounts(account_id) ON DELETE CASCADE;
ALTER TABLE snapshots ADD CONSTRAINT snapshots_work_fk
  FOREIGN KEY (account_id, work_id) REFERENCES works(account_id, work_id) ON DELETE CASCADE;
ALTER TABLE conflicts ADD CONSTRAINT conflicts_work_fk
  FOREIGN KEY (account_id, work_id) REFERENCES works(account_id, work_id) ON DELETE CASCADE;
CREATE UNIQUE INDEX IF NOT EXISTS operations_auth_operation_id
  ON auth_operations(operation_id);

CREATE TABLE IF NOT EXISTS object_access (
  account_id TEXT NOT NULL REFERENCES accounts(account_id) ON DELETE CASCADE,
  object_id TEXT NOT NULL REFERENCES objects(object_id) ON DELETE CASCADE,
  PRIMARY KEY (account_id, object_id)
);

-- Legacy object bytes are made visible only to the sole account.  The object
-- table remains content-addressed and physically deduplicated, while this
-- relation is the authorization/presence boundary used by every route.
DO $$
DECLARE sole_account TEXT;
BEGIN
  IF (SELECT COUNT(*) FROM objects) > 0 THEN
    IF (SELECT COUNT(*) FROM accounts) <> 1 THEN
      RAISE EXCEPTION 'cannot assign legacy objects without exactly one account';
    END IF;
    SELECT account_id INTO sole_account FROM accounts LIMIT 1;
    INSERT INTO object_access(account_id, object_id)
      SELECT sole_account, object_id FROM objects
      ON CONFLICT DO NOTHING;
  END IF;
END $$;
