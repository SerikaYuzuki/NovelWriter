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
