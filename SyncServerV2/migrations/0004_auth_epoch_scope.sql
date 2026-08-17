-- Auth fence rotation is a same-account scope transition. Keep the latest
-- authenticated epoch so a stale or replayed principal cannot rebind the
-- sync namespace backwards after a newer fence has quarantined it.
ALTER TABLE sync_v2.account_scopes
  ADD COLUMN IF NOT EXISTS account_auth_epoch BIGINT;

UPDATE sync_v2.account_scopes
SET account_auth_epoch = 1
WHERE account_auth_epoch IS NULL;

ALTER TABLE sync_v2.account_scopes
  ALTER COLUMN account_auth_epoch SET NOT NULL,
  ADD CONSTRAINT account_scopes_auth_epoch_positive
    CHECK (account_auth_epoch > 0);

UPDATE sync_v2.server_meta
SET value = 'snapshot-sync-v2-postgres-r3'
WHERE key = 'ddl_contract_marker';
