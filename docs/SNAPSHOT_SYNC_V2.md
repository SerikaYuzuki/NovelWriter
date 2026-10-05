# FUMINIWA Snapshot Sync v2

Normative Snapshot Sync v2 contract. Swift/Rust implementations exist;
release acceptance remains open. Use [CODE_HEALTH](CODE_HEALTH.md) for current
implementation gaps and [versioned contracts](sync/v2/README.md) for the
specific wire, schema, fixture, and database boundary being changed.

## 1. Scope

v2 is the current server-readable, local-first synchronization namespace:

- the client opens only the v2 SQLite database; v2 object bytes are SQLite
  BLOBs in the initial implementation;
- the Rust service uses the v2 API namespace and a new PostgreSQL schema and
  new PostgreSQL Docker volume;
- old databases and archives are not opened by the live runtime;
  current portable import uses validated `.novelpkg` files;
- the live client has no v1 dual-read, dual-write, schema fallback, or
  CloudKit path. A missing or invalid v2 database is a startup error, not an
  empty-database fallback.

The checked-in role-split deployment uses
`fuminiwa-sync-v2-role-split-data`; `fuminiwa-sync-v2-data` names the earlier
deployment and is not the current Compose target. See
[`deployment.md`](sync/v2/deployment.md) for D-081 through D-085. Initial server object
bytes are PostgreSQL `BYTEA`. The Rust domain depends on an `ObjectStore`
trait; `PostgresObjectStore` is the only v2 implementation and a future S3
adapter requires a new deployment migration/gate. No external CAS root or
object Docker volume is part of this contract. The client never connects to
PostgreSQL or an object store directly.

Before SQLx migrations run, the one-shot migrator performs a fail-closed database
identity check. It permits a genuinely fresh database (PostgreSQL system
objects and SQLx's own `_sqlx_migrations` bookkeeping do not count as user
data) or an existing database whose `sync_v2.server_meta` contains the exact
v2 namespace, protocol, schema, and DDL contract markers. A legacy, partial,
nonempty, or otherwise unrecognized user schema is rejected before migration
can create, alter, or seed anything. The runtime performs read-only identity
and role/ACL attestation when opening an already-migrated v2 database; it has no migration authority.

The v2 media type is `application/vnd.fuminiwa.sync.v2+jcs`. Every accepted
JSON body is already RFC 8785 JCS UTF-8. The server stores the exact accepted
manifest and command bytes in PostgreSQL `BYTEA`; it never parses a manifest
into JSONB and reserializes it before checking its digest.

## 2. Authorities and physical runtime modes

`RuntimeMode.production` is the only mode allowed in a production app. The mode
selects a distinct composition at process start, before opening a database or
creating a network transport:

| Mode | Local root | Network namespace | Allowed mutation |
| --- | --- | --- | --- |
| `production` | platform Application Support + `FUMINIWA/SnapshotSyncV2/` | `/v2/...` | v2 SQLite and v2 server only |
| `test(TestDependencies)` | typed temporary test root | typed fake only | test SQLite only |
| `preview` | none | none | none |

There is no current standalone archive reader or archive `RuntimeMode`. `test` must fail closed if a production root, URL, or
Keychain is injected. macOS and iOS use the same v2 domain, SQLite, command,
conflict, and restore kernel; only filesystem and UI adapters differ.

SQLite is the sole local authority. A committed checkpoint contains the local
current pointer, immutable Snapshot row, object references, account binding,
and sealed command/outbox state in one transaction. The network is never
awaited inside that transaction. `.novelpkg` remains Import/Export only.

Foreground head polling uses an injected monotonic clock: while the last
accepted body edit is less than 60 seconds old, checks are 120 seconds apart;
otherwise they are 10 seconds apart. A failed check waits 60 seconds. Waiting
re-evaluates input activity, including its idle deadline. Foreground return and
completed chapter/episode/work transitions start an immediate check outside the
save/document gate; navigation never waits for that network request. Existing
promotion/upload scheduling remains intact. During continuous typing, noticing
another device's changes may be delayed by about two minutes. Expected-head CAS
at publish and the existing explicit conflict/retained-local-leaf handling are
unchanged: slowing head reads does not discard unsaved/local manuscript bytes.
These are client timing defaults, injected by the apps from device settings;
there is no wire, schema, canonical-byte or server change.

Checkpoint scope validation may reuse a current snapshot fully validated by
this Store actor or committed by its last autosave, with identical WorkID,
account scope, snapshot ID, generation and document anchor. Every open still
fully validates manifest/object/closure/decode/resource bytes; a stable,
successful open or cache-miss validation seeds the next autosave. An external
write during a successful open, or a bookkeeping failure, discards only the
cache stamp and does not turn that open into failure.

SQLite `data_version` and `total_changes()` detect SQL writes; the external-write
version is checked again under the commit lock. Audited content-neutral Store
outbox/upload writes and leaf promotion may advance only the cached change
counter after attesting the unchanged current pointer, generation, scope,
anchor and external-write version. They never insert/change current entries or
resources. Resolution/restore/clone acknowledgements, unclassified writes,
account/work changes, install/adoption/import/restore, generation mismatch,
rollback and close/reopen invalidate reuse. Other connections always invalidate
reuse on an actual DB change. New checkpoint content still passes full decode
and validation before commit. Cache bookkeeping failure cannot fail a durable
save. This changes validation timing, not schema, canonical identity or
durability. See [the audited paths](CODE_HEALTH.md#同期onでのcheckpoint-cache).

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

D-106 installs only the pinned head H for an explicitly opened or downloaded
work. `shallow_boundaries` records missing parents without weakening ordinary
parent attestation: the disjoint union of real edges and boundaries must exactly
match each manifest. Local snapshots require local parents. Every insertion
replaces incoming boundaries atomically; complete history is never truncated.
`history_backfills` persists the root, exact binding, state and safe group cursor.
Each verified page commits with its cursor in one transaction, never changing
current snapshot or local generation. Validation runs outside the SQLite write
transaction; edits, promotion and publish continue against H. Newer heads enter
through the existing Inbox/document gate. Missing ancestry is retryable
`historyIncomplete`, never evidence of disjointness or a null conflict base.
Initial mode rejection falls back to the complete D-101/D-102 import. See
[design](sync/v2/shallow-history-design.md) and [verification](sync/v2/shallow-history-verification.md).

Checkpoint capture is atomic and has these required fields:

```text
checkpointId, workId, snapshotId, localGeneration,
currentBefore, reason, pinned, accountBinding, sealedCommandId?
```

Autosave produces dense local leaves from the stable checkpoint (D-103).
The stable checkpoint is the last promoted snapshot, initially the current
snapshot of an upgraded work or the acknowledged head installed by import.
Every changed autosave commits its immutable snapshot, objects, current pointer,
generation and local history atomically, with the stable checkpoint as parent
(not the preceding leaf). It creates no sync intent, upload, register or publish.
A new work without any stable checkpoint has parentless local leaves until its
first promotion. Unchanged autosaves do not add another occurrence.

Manual and lifecycle checkpoints promote the latest leaf or occurrence
atomically: protecting reasons `explicit`, `navigation`, `close`, `migration`,
work switch/background/termination, explicit sync, 60 seconds after the last
changed autosave, and at most 300 seconds from the first outstanding leaf while
writing continues. Both intervals live in `SyncV2PromotionClock`; its clock and
sleep are injectable. Promotion protects the existing snapshot and creates its
normal account-scoped intent in the same SQLite transaction. A protecting save
with new content commits that content directly against the prior stable point.
Network work starts only after commit and never gates local saving.

Open promotes a crash-retained leaf. Launch/first recovery for an attested
binding also promotes unopened works; later periodic worker wakes do not.
A changed remote-head check reconciles a local leaf by first promoting it, so
normal expected-head CAS yields the same explicit conflict instead of silently
adopting over local changes. Same-account fence/rebind replanning protects any
leaf it queues. A parked or deleting work cannot publish through these paths.
Promotion reads durable bytes only and never captures, commits or installs
marked editor text; platform lifecycle saves retain their IME/session gates.

No SQLite schema migration is needed: new leaves use history reason
`autosaveLeaf`, `pinned=0`; an additional pinned occurrence (`promotion` or the
protecting reason) marks promotion of those same bytes. The UI labels leaves
「自動保存」. Any legacy occurrence, including old `autosave` rows, is stable;
its graph, occurrences and pending intents remain intact. Leaves that are not
promoted remain in local history and are never pruned by this change. Only
promoted/protected snapshots and their required ancestors are registered.

Restore first
protects the current state, then creates a new two-parent Snapshot whose
content is the selected historical Snapshot; it never rewinds the head in
place. A keep-both resolution creates a new WorkID and never silently changes
the active work identity.

## 5. Sealed command state machine

Each state-changing request is a sealed command. Before its first network byte,
SQLite commits `commandId`, `commandKind`, exact canonical request bytes,
`requestDigest`, WorkID, binding, source generation, source Snapshot, and retry
state. The server receipt persists the same AccountID/WorkID/command identity;
read-back requires every predicate, including the expected head, to match.
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
       |-- candidate already in remote lineage -> noChanges (200)
       |-- divergence -> conflictPending
conflictPending
  |-- useDevice -> sealed(resolveDevice)
  |-- useServer -> sealed(resolveServer)
  |-- keepBoth -> sealed(cloneWork)
  `-- no choice -> parked (no overwrite)
```

There is at most one active conflict per work. Each new divergence appends an
immutable candidate revision and atomically advances only the active-conflict
projection; earlier branch references are never updated. It does not create a
competing UI queue. The macOS/iOS UI offers two choices:

1. **この端末の版を使う** — publish the durable local branch against the
   observed remote head.
2. **サーバーの版を使う** — adopt the verified remote branch at a safe
   document boundary while preserving the pre-adoption local checkpoint.
The unselected version remains in history and can be restored. UI selection is
consumed once, with duplicate preparation rejected inside the Store transaction.
The keepBoth/cloneWork kernel and wire operations remain available for existing
data compatibility; new UI selections do not invoke them.

D-109 conservatively holds an extra unsealed decision left after a finalized
keepBoth, only when the resolved conflict, exact two-parent decision occurrence,
account binding, received remote head and verified remote Inbox agree. The
pending decision is parked once, with both branches pinned in history. A saved
editor can explicitly apply the verified server version through the existing
safe document gate. An explicit history restore retires the unused recovery
Inbox and queues only its new restore generation. Recovery never chooses a version automatically, recreates a
server conflict, modifies the clone, or deletes immutable snapshots/objects.
Repeated failed sync status alerts once per work/reason; failed automatic
adoption waits for an explicit retry of that work/Inbox.

No choice, authentication failure, or remote unavailability leaves the local
manuscript and pending commands intact.

## 6. Wire minimum

The v2 wire has these endpoints under `/v2`:

| Method | Path | Purpose |
| --- | --- | --- |
| GET | `/v2/capabilities` | server instance, protocol epoch, account fence, limits |
| POST | `/v2/works` | sealed account-scoped null-head Work bootstrap |
| POST | `/v2/objects/prepare` | sealed object upload command |
| PUT | `/v2/uploads/{upload_id}` | exact bytes with the prepared capability |
| POST | `/v2/objects/finalize` | receipt-idempotent object finalize |
| POST | `/v2/snapshots/register` | immutable exact manifest registration |
| POST | `/v2/works/{work_id}/publish` | expected-head CAS |
| GET | `/v2/works/{work_id}/conflict` | single active conflict |
| POST | `/v2/works/{work_id}/conflict/resolve` | one of the three choices |
| POST | `/v2/works/{work_id}/restore` | new two-parent restore Snapshot |
| GET | `/v2/works` | account-scoped catalog; no cross-account existence leak |
| GET | `/v2/works/{work_id}/download` | [bounded, read-only pages](sync/v2/download.md) of pinned ancestry and deduplicated small objects |

Every sealed-command body contains `schemaVersion: 2`, `commandId`, `binding`, and
the operation-specific payload. The server derives the authenticated account
from the bearer session and rejects a body or header with a different scope.
All command responses are receipt-idempotent. A CAS failure is a preserved
divergence, not an overwrite instruction. Work deletion is a separate
[scope-bound deletion API](sync/v2/work-deletion.md), not a sealed-command body.

## 7. Migration and release gates

Current import/update boundaries are in [migration](sync/v2/migration.md).
The retired standalone v1 tools are not shipped. Existing SQL migration
files and storage markers remain part of the deployed schema.

A completed v2 cutover requires Swift and Rust independent harnesses to agree on all
canonical bytes, SHA-256 IDs, schema failures, command digests, account
isolation, conflict choices, restore graph, and process-restart states. The
fixture set in `docs/sync/v2/fixtures/` is the minimum shared corpus.

See [`docs/sync/v2/README.md`](sync/v2/README.md) for the versioned wire and
fixture files. Retired v1 sources and documents are available in Git history.

## 8. Closed canonical validation

The v2 schemas are closed at every object boundary. In particular, command
`payload` is a discriminated closed schema; the allowed fields for
`createWork`, `prepareObject`, `finalizeObject`, `registerSnapshot`, `publish`,
`resolveDevice`, `resolveServer`, `cloneWork`, and `restore` are fixed in
[`docs/sync/v2/command.schema.json`](sync/v2/command.schema.json). An unknown
field, missing field, duplicate JSON member, or command-kind/payload mismatch
is rejected before a receipt is created.

Before schema validation, the parser must reject invalid UTF-8, BOMs, duplicate
members, unpaired surrogates, NaN/Infinity, negative zero, numbers outside
I-JSON's safe integer range (`±9007199254740991`), and non-JCS whitespace,
escape, key ordering, or number spelling. Strings are not Unicode-normalized.
Manifest entries are sorted by UTF-8 `entityKey` bytes, have unique keys, and
must contain the nine mandatory work singleton/order keys. Parents are unique,
sorted digests, at most two, belong to the same WorkID, cannot self-reference,
and are checked for cycles. The server also validates the `work/document`
anchor, entity payload schema, object digest and byte count, parent lineage,
and lossless `.novelpkg` projection.

The v2 hard caps are: 16 MiB manifest, 16 MiB structured entity, 250 MiB
attachment/object, 100,000 entries, and 100,000 objects in one bounded graph
traversal. Exceeding a cap preserves local bytes but returns a typed
`sizeLimitExceeded`; it never creates a partial Snapshot.

## 9. Conflict and restore transactions

`useDevice` does not overwrite the remote branch. It seals a decision Snapshot
whose two parents are the observed remote head and the local candidate parent,
then publishes it with expected-head CAS. The decision Snapshot and its
receipt are retained even when CAS reports another divergence.

`useServer` first pins the current local Snapshot as a pre-adoption history
occurrence. The server resolves the exact active conflict revision. The client
stages and verifies the remote manifest/object closure, then installs it only
if both `currentSnapshotId` and `localGeneration` still match the sealed
command. A concurrent new edit therefore remains current and is never replaced;
the selected remote bytes do not create a new local Intent. A later ordinary
edit creates the next Intent against the installed state.

`keepBoth` is one PostgreSQL transaction: preserve the original Work and head,
create a new WorkID with a root Snapshot and head, record both history roots,
mark the active conflict resolved, and insert the receipt. The transaction
must either complete all of those writes or none of them. The new root is the
deterministic clone defined in `wire.md`: same local candidate content, new
WorkID/new DocumentID, no cross-work parent, and exact digest equality with the
sealed `newRootSnapshotId`.

`active_conflicts.work_id` is unique. Repeated divergence appends an immutable
candidate row with its positive source generation and increments `revision`;
the current Conflict projection stores the same generation as the selected
candidate. It never mutates an earlier candidate or creates a second active UI
item. The UI includes revision and source generation in its sealed choice
command.

## 10. Runtime, migration, and auth boundaries

The closed RuntimeMode contract is in
[`docs/sync/v2/runtime-mode.md`](sync/v2/runtime-mode.md). Test dependencies
use distinct root/transport/keychain types, so a production URL, root, or
Keychain cannot be constructed by the test composition. Preview has no I/O.
Legacy archive tooling is not shipped; the live import path is the portable bridge.

The concrete local and server schemas are
[`sqlite.sql`](sync/v2/sqlite.sql) and
[`postgres.sql`](sync/v2/postgres.sql). `migration_ledger` and its evidence
marker follow [`migration.md`](sync/v2/migration.md); only verified staged
bytes can be committed, and crash recovery never treats an uncommitted marker
as success.

v2 reuses the frozen Auth v1 wire/state contract, not a v1 sync database. The
new v2 PostgreSQL deployment implements it in the separate `auth_v1`
schema. The current deployment separates migration ownership from the runtime
role; that runtime serves both auth and sync. Schema separation alone is not
proof of separate auth/sync process credentials. The bearer session and capabilities response provide the opaque
`AccountID`, server instance, protocol epoch, and AccountFence. `sync_v2`
never stores or joins Apple subject, email, refresh token, or provider
credential. It stores only opaque account scope and checks it on every
resource query and command. The same AccountID and unchanged Fence can
continue after token refresh. A different account or Fence is rejected before
object existence is disclosed.

## 11. Shared UI result contract

macOS and iOS use the projection and Japanese labels in
[`ui-state.md`](sync/v2/ui-state.md). In particular, an explicit sync with no
pending work returns successful `noChanges`/`同期済み`; it is never rendered as
同期失敗. Local durability and remote progress remain separate indicators.

保存した端末名は公開ごとの任意metadata（HTTPヘッダ送信・history/conflict読取のopt-in）として扱い、snapshot／sealed commandのcanonical bytesへ含めない。[wire契約](sync/v2/wire.md#保存した端末名2026-10-04)参照。

## Episode history (D-114)

While editing, history selects the episode body entries in one scoped SQLite query (including verified inbox entries), collapses consecutive equal object IDs, and lists unfetched versions in one trailing fetch control. Visible rows lazily read only the selected episode via the existing preview API; counts are cached by Work/object ID and cleared on account changes. Episode restore uses the shared document/edit boundary, an explicit pre-edit checkpoint (displayed as 手動保存), and the common persistent Undo journal. It never invokes whole-work restore and changes no wire/schema/fixture.

## 作品一覧の更新とゴミ箱（D-116）

作品一覧の「更新」はサーバーの全作品を確認し、他端末で変更した作品名と削除を一覧へ反映します。macOSはFileメニューの「作品一覧を更新」（⌘R）を執筆中にも使えます。未送信の変更がある作品は端末の名前を保ち、本文は一覧更新では変更しません。新しい版の本文は作品を開く際に従来の安全な境界で取り込みます。

削除した作品は「ゴミ箱」で削除日と残り保管日数を確認できます。サーバーの受領済み版は「元に戻す（別作品として復元）」から日時を選びます。端末のコピーは新しい作品として残すか、確認後に端末での削除を完了できます。接続失敗や404だけで原稿をゴミ箱へ移すことはありません。同期作品の救出用データは既存の安全策に従いSQLiteに保持します。
