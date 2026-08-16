# v1/archive to v2 migration evidence

Migration is an explicit, offline, resumable operation. The live v2 runtime
never opens the archive reader. Each source is represented in `migration_ledger`
with the source kind, source digest, exact evidence bytes, and a monotonic
marker. The only successful sequence is:

```text
discovered -> staged -> verified -> committed
                         `-> quarantined
```

`staged` copies bytes to a new v2 CAS staging root without changing the source.
`verified` requires the source hash, object byte count, schema, account scope,
portable projection, and every referenced object to read back successfully.
Any invalid UTF-8, unknown account scope, duplicate identity, symlink, digest
mismatch, or unsupported payload goes to `quarantined` with evidence and never
becomes a v2 Work. `committed` adds a new v2 WorkID and its first Snapshot in
one transaction; the original work is not rebound or deleted.

The marker is written only after SQLite/PostgreSQL transaction commit and CAS
read-back. On crash, an uncommitted marker is retried from staging or moved to
quarantine; it is never treated as imported merely because files exist. A
failed migration cannot create an empty replacement database.
