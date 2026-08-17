# v1/archive to v2 migration evidence

Migration has two separate products and success boundaries:

1. **Export backup projection** reads legacy v1/package data and produces a
   verified, read-only backup artifact plus evidence. The current
   `Tools/SnapshotSyncV2Migration` work is this phase only; its success never
   means a Work was adopted into v2.
2. **v2 adoption** consumes a verified backup artifact, stages a new v2
   Work/Snapshot/object closure, verifies the logical model/account scope, and
   writes a separate adoption marker transaction.

Both are explicit, offline, resumable operations. The live v2 runtime never
opens the archive reader. Each source is represented in `migration_ledger`
with source kind/digest, exact evidence, `export_backup_marker`, and a distinct
`adoption_marker`. The successful sequence is:

```text
discovered -> backupExported -> staged -> verified -> committed
                         `-> quarantined
```

The ledger encodes marker/state correspondence rather than relying on runner
convention. `discovered` has neither marker. `backupExported`, `staged`, and
`verified` require a non-empty `export_backup_marker` and forbid an adoption
marker. `committed` requires both non-empty markers. `quarantined` requires
`quarantined_from_state`, never has an adoption marker, and retains the export
marker exactly when its origin was `backupExported`, `staged`, or `verified`;
a quarantine originating at `discovered` has no export marker. A quarantine
from `verified` also retains its verified AccountID. Empty strings do not
satisfy any marker requirement.

`staged` copies exact manifest/object bytes to
`migration_staging_batches`/`migration_staging_objects` without changing the
source. Those tables intentionally have no FK to authoritative Work,
Snapshot, object, or account-binding rows, so a not-yet-adopted Work can be
resumed safely after a crash. They are never exposed by the live HTTP API.
`verified` requires the source hash, object byte count, schema, account scope,
portable projection, and every referenced object to read back successfully.
Any invalid UTF-8, unknown account scope, duplicate identity, symlink, digest
mismatch, or unsupported payload goes to `quarantined` with evidence and never
becomes a v2 Work. A migration run has exactly one declared target database:

The standalone package also inventories every non-hidden tree entry, including
empty directories and opaque/orphan files. Each entry records its normalized
relative path, kind, byte count, SHA-256/ObjectID (for files), and empty-directory
flag. The current v2 SQLite schema has no portable-resource CAS, so a non-empty
opaque-resource inventory is staged only long enough to record evidence and then
quarantined; it is never silently dropped into a lossy committed Work. A later
resource-CAS decision must extend the schema and fixtures before commit is
enabled.

- **client SQLite adoption** revalidates the staged closure, adds the local
  WorkID/first Snapshot and adoption marker in one SQLite transaction, then
  later publishes through `createWork` -> object prepare/upload/finalize ->
  register -> publish;
- **operator-only PostgreSQL adoption** revalidates the closure and adds the
  server Work, objects, first Snapshot/head/history/catalog rows and adoption
  marker in one PostgreSQL transaction. It does not call `createWork`, because
  the Work is already present, and it is not reachable from the live HTTP API.

The SQLite and PostgreSQL ledgers/staging tables belong to these distinct
target runs; a single run never commits both. In either case the original work
is not rebound or deleted, and staging itself is never live authority.

`account_id` remains nullable until independently verified. An unknown or
ambiguous account can only enter `quarantined`; it cannot be committed,
uploaded, or inferred from title/path/device/login timing.

The adoption marker is written only after SQLite/PostgreSQL transaction commit
and BLOB read-back. On crash, an uncommitted marker is retried from staging or
moved to quarantine; it is never treated as imported merely because files
exist. A failed migration cannot create an empty replacement database.
