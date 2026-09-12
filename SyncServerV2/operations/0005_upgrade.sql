\set ON_ERROR_STOP on
BEGIN;
SELECT pg_advisory_xact_lock(739205, 5);
DO $$ BEGIN
 IF current_user <> 'fuminiwa_sync_v2_migrator' OR current_database() <> 'fuminiwa_sync_v2' THEN
  RAISE EXCEPTION 'unexpected upgrade authority';
 END IF;
 IF (SELECT count(*) FROM public._sqlx_migrations) <> 4 OR EXISTS (
 SELECT 1 FROM (VALUES
(1,'ba65478a022042de66c2ddc1b296210ac089f3ff4f7f80cd99ffa0ca8cd75487912b91b6736baa919e5aa51dea13a69a'),
(2,'30c44267557450fb35946656cfbdf5dee1dd6ee830104eedaf715189ce6e35f9b9952e5aacccd7a9aeaf1ed2a132c4b3'),
(3,'8cec5ae349c57ef650a7634277ae6d3adedd24e8ca4dae1850d83be76354494cdca8a7cd0312eb9a05f9e6c0d4afb8b9'),
(4,'0a1f7e1b86fd7c80d55951ee992da7f70bb0c2e46df4793e99189710e5887a99531f3e38308af259ef559d087b33d9a6')
 ) expected(version,checksum)
 LEFT JOIN public._sqlx_migrations m USING(version)
 WHERE m.version IS NULL OR NOT m.success OR encode(m.checksum,'hex')<>expected.checksum
 ) THEN RAISE EXCEPTION 'upgrade requires exact migrations 1 through 4'; END IF;
END $$;
-- Permanent, account-scoped identity markers prevent late create/publish retries
-- from resurrecting erased manuscripts. No manuscript/title bytes are retained.
CREATE TABLE sync_v2.deleted_works (
  account_id TEXT NOT NULL REFERENCES sync_v2.account_scopes(account_id),
  work_id UUID NOT NULL,
  deleted_at TIMESTAMPTZ NOT NULL,
  PRIMARY KEY (account_id, work_id)
);

-- A surviving clone keeps its own head/history when its source is deleted.
-- Detach the source receipt FK without retaining the source's command bytes.
ALTER TABLE sync_v2.head_events ALTER COLUMN command_work_id DROP NOT NULL;
ALTER TABLE sync_v2.head_events DROP CONSTRAINT head_events_command_scope_check;
ALTER TABLE sync_v2.head_events DROP CONSTRAINT head_events_check;
ALTER TABLE sync_v2.head_events ADD CHECK (
  command_scope IN ('sameWork', 'cloneNewWork', 'deletedOrigin')
);
ALTER TABLE sync_v2.head_events ADD CHECK (
  (command_scope='sameWork' AND command_work_id=work_id) OR
  (command_scope='cloneNewWork' AND command_work_id<>work_id AND command_kind='cloneWork') OR
  (command_scope='deletedOrigin' AND command_work_id IS NULL AND command_kind='cloneWork')
);

GRANT SELECT,INSERT,UPDATE,DELETE ON sync_v2.deleted_works TO fuminiwa_sync_v2_runtime;
INSERT INTO public._sqlx_migrations(version,description,success,checksum,execution_time)
VALUES(5,'work deletion',true,decode('359600eaad28a7fe020548748651b822c3483f414a059d09ce4cef98ed6d0152e8486726317c63d7cd09a09defa21830','hex'),0);
COMMIT;
