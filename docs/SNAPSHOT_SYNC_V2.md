# FUMINIWA Snapshot Sync v2

Status: design contract, D-080. This document replaces the v1 runtime contract
for the next implementation. It does not migrate or delete existing data.

## 1. Scope and cutover

v2 is a new, server-readable, local-first synchronization namespace. Its live
components are physically separated from v1:

- the client opens only the v2 SQLite database and v2 CAS root;
- the Rust service uses the v2 API namespace and a new PostgreSQL schema and
  object-store/Docker volume;
- v1 databases, package snapshots, server rows, and old caches are read-only
  archive inputs for an explicit migration/import tool, never a live fallback;
- the live client has no v1 dual-read, dual-write, schema fallback, or
  CloudKit path. A missing or invalid v2 database is a startup error, not an
  empty-database fallback.

The development volume names are `fuminiwa_sync_v2_pgdata` and
`fuminiwa_sync_v2_objects`. A deployment may choose different names only in a
versioned deployment manifest. The client does not connect to PostgreSQL or an
object store directly.

The v2 media type is `application/vnd.fuminiwa.sync.v2+jcs`. Every accepted
JSON body is already RFC 8785 JCS UTF-8. The server stores the exact accepted
manifest and command bytes in PostgreSQL `BYTEA`; it never parses a manifest
into JSONB and reserializes it before checking its digest.

## 2. Authorities and physical runtime modes

`RuntimeMode.v2Live` is the only mode allowed in a production app. The mode
selects a distinct composition at process start, before opening a database or
creating a network transport:

| Mode | Local root | Network namespace | Allowed mutation |
| --- | --- | --- | --- |
| `v2Live` | `Library/SnapshotSyncV2/` | `/v2/...` | v2 SQLite and v2 server only |
| `v1ArchiveReadOnly` | explicit archive URL | none | archive read only |
| `v2Test` | test temporary root | injected fake only | test root only |

`v1ArchiveReadOnly` is an offline import source, not a sync mode. It cannot
  construct a v2 worker or use a production URL. `v2Test` must fail closed if
  a production root or URL is injected. macOS and iOS use the same v2 domain,
  SQLite, command, conflict, and restore kernel; only filesystem and UI
  adapters differ.

SQLite is the sole local authority. A committed checkpoint contains the local
  current pointer, immutable Snapshot row, object references, account binding,
  and sealed command/outbox state in one transaction. The network is never
  awaited inside that transaction. `.novelpkg` remains Import/Export only.

## 3. Identity, account isolation, and fence

Every work has an immutable `workId`. A work is `unbound`, `bound`, or
`quarantined`; binding is `(serverInstanceId, protocolEpoch, accountId,
accountFence)`. `accountId` is opaque and never an Apple subject or profile
field.

- Login does not adopt an unbound work.
- A different `accountId` never rebinds a work or sends its commands. The work
  is parked and remains editable locally. Moving it requires explicit
  Export/Import or a new WorkID clone.
- A normal access/refresh rotation with the same account and fence continues.
- A changed fence quarantines presence, cursor, command, and attempt. The
  worker performs capabilities/bootstrap/missing-object checks and seals a new
  command before resuming. It never reuses the old sealed command.
- Account binding, command scope, and server authorization are checked before
  any object existence or title is disclosed.

## 4. Snapshot and checkpoint schema

The v2 manifest is a closed object with `schemaVersion: 2`, one `workId`, zero
to two parent Snapshot IDs, and sorted entries. An entry maps a stable
`entityKey` to a SHA-256 `objectId`, exact `byteCount`, and closed `contentType`.
The Snapshot ID is SHA-256 of the exact canonical manifest bytes. The v2
manifest is deliberately small; entity payload schemas remain closed and are
versioned by content type. A server may retain history, but may not mutate an
accepted manifest.

Checkpoint capture is atomic and has these required fields:

```text
checkpointId, workId, snapshotId, localGeneration,
currentBefore, reason, pinned, accountBinding, sealedCommandId?
```

Autosave produces dense local leaves from the stable checkpoint. Manual and
lifecycle checkpoints promote a leaf or occurrence atomically. Restore first
protects the current state, then creates a new two-parent Snapshot whose
content is the selected historical Snapshot; it never rewinds the head in
place. A keep-both resolution creates a new WorkID and never silently changes
the active work identity.

## 5. Sealed command state machine

Each state-changing request is a sealed command. Before its first network byte,
SQLite commits `commandId`, `commandKind`, exact canonical request bytes,
`requestDigest`, binding, source generation, source Snapshot, and retry state.
After sending, those fields are immutable. A lost response retries the exact
command; a changed request gets a new command ID.

```text
localCommitted
  -> sealed
  -> sending
  -> acknowledged
       |-- readBackVerified -> completed
       |-- lostResponse -> sealed (exact retry)
       |-- fenceMismatch -> quarantined (new bootstrap)
       |-- divergence -> conflictPending
conflictPending
  |-- useDevice -> sealed(resolveDevice)
  |-- useServer -> sealed(resolveServer)
  |-- keepBoth -> sealed(cloneWork)
  `-- no choice -> parked (no overwrite)
```

There is at most one active conflict per work. New divergence updates that
record's immutable branch references and increments a server revision; it does
not create a competing UI queue. The three choices are exactly:

1. **この端末の版を使う** — publish the durable local branch against the
   observed remote head.
2. **サーバーの版を使う** — adopt the verified remote branch at a safe
   document boundary while preserving the pre-adoption local checkpoint.
3. **両方を残す** — clone to a new WorkID, preserving both histories.

No choice, authentication failure, or remote unavailability leaves the local
  manuscript and pending commands intact.

## 6. Wire minimum

The v2 wire has these endpoints under `/v2`:

| Method | Path | Purpose |
| --- | --- | --- |
| GET | `/v2/capabilities` | server instance, protocol epoch, account fence, limits |
| POST | `/v2/objects/prepare` | sealed object upload command |
| PUT | `/v2/objects/{object_id}` | exact bytes, only after prepare |
| POST | `/v2/objects/finalize` | receipt-idempotent object finalize |
| POST | `/v2/snapshots/register` | immutable exact manifest registration |
| POST | `/v2/works/{work_id}/publish` | expected-head CAS |
| GET | `/v2/works/{work_id}/conflict` | single active conflict |
| POST | `/v2/works/{work_id}/conflict/resolve` | one of the three choices |
| POST | `/v2/works/{work_id}/restore` | new two-parent restore Snapshot |
| GET | `/v2/works` | account-scoped catalog; no cross-account existence leak |

Every mutating body contains `schemaVersion: 2`, `commandId`, `binding`, and
the operation-specific payload. The server derives the authenticated account
from the bearer session and rejects a body or header with a different scope.
All command responses are receipt-idempotent. A CAS failure is a preserved
divergence, not an overwrite instruction.

## 7. Migration and release gates

The migration tool reads v1/package/CloudKit archives as immutable input and
writes only a staged v2 database/CAS. It verifies bytes, hashes, schema, and
account scope before an explicit adoption marker. It never deletes, rewrites,
or automatically uploads the archive. The live app cannot invoke that reader.

Before v2 is enabled, Swift and Rust independent harnesses must agree on all
canonical bytes, SHA-256 IDs, schema failures, command digests, account
isolation, conflict choices, restore graph, and process-restart states. The
fixture set in `docs/sync/v2/fixtures/` is the minimum shared corpus.

See [`docs/sync/v2/README.md`](sync/v2/README.md) for the versioned wire and
fixture files. Existing `docs/sync/v1/` remains historical and is not edited by
this decision.
