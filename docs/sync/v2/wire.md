# v2 wire rules

## Headers and media

All JSON requests and responses use
`application/vnd.fuminiwa.sync.v2+jcs`. Auth uses the short-lived FUMINIWA
Bearer token from Auth v1; Apple credentials never cross this boundary. Except
for `GET /v2/capabilities`, requests include `X-Fuminiwa-Server-Instance`,
`X-Fuminiwa-Protocol-Epoch`, and `X-Fuminiwa-Account-Fence`. The server checks
these before resource lookup.

## Receipt and digest

The server computes SHA-256 over the exact accepted canonical command bytes and
stores `(account_id, work_id, command_id, command_kind, digest, response)` in
the v2 receipt table. Receipt identity remains `(AccountID, commandId)`, while
the stored WorkID must equal the sealed payload/route scope. Exact retries
return the same response. Reusing a command ID
with another kind or bytes returns `commandIdReused`; a different request gets
a new ID. Transport errors, 401/403, and fence/version errors do not create a
success receipt.

## Errors

The closed HTTP error set is `invalidCanonicalBytes`, `schemaViolation`,
`unauthorized`, `accountFenceMismatch`, `protocolEpochMismatch`,
`commandIdReused`, `uploadExpired`, `uploadCapabilityMismatch`,
`objectDigestMismatch`, `snapshotDigestMismatch`, `lineageViolation`,
`staleHead`, `staleConflictRevision`, `notFoundInAccount`,
`sizeLimitExceeded`, `rateLimited`, and `retryable`. The shared local UI kernel
additionally returns `staleConflictAction` before sealing a command.
`notFoundInAccount` is deliberately indistinguishable for a foreign account
and an absent resource.

A publish divergence returns a receipted `conflictPending` result, preserves
the candidate, appends an immutable conflict revision, and advances the
work's single active-conflict projection. It never mutates a prior revision
and never means “overwrite the server”. Every candidate persists its sealed
`sourceGeneration > 0`; the active Conflict record persists the generation of
its current revision. The OpenAPI response and shared Mac/iOS projection carry
that exact value, so a revision cannot be shown or resolved with another
generation.

## Resource and cursor contract

`GET /v2/works?cursor=` returns `{items,nextCursor}` sorted by lowercase
WorkID. Its opaque cursor seals protocol epoch, AccountID, AccountFence,
the first page's catalog-event high-water mark, last emitted lowercase WorkID,
page size (default 100, maximum 500), and query digest. `highWater` is the
greatest event ID visible at the first page's repeatable-read, read-only
transaction snapshot; the page query uses that same snapshot. Catalog writers
are serialized per AccountID before allocating identity values, so an event
that commits later cannot have an ID at or below an already issued high-water
mark. Every continuation projects the latest non-tombstoned `catalog_events`
row per WorkID with `event_id <= highWater` and `work_id > last`, never the
mutable current row. `last` is a position in this WorkID-sorted projection,
not an event ID. A continuation request omits `pageSize` or repeats the sealed
value. A cursor from another account,
fence, endpoint, or query returns `accountFenceMismatch`/`schemaViolation`
before lookup. `GET /v2/works/{workId}/history?cursor=` seals the same scope
plus WorkID, first-page history-event high-water mark, and last event ID.
Pages are stable and never infer a winner from timestamps. `GET
/v2/snapshots/{snapshotId}/manifest`
returns the exact manifest bytes and its digest; `GET
/v2/objects/{objectId}` returns raw bytes and `X-Fuminiwa-Object-Digest`.
Every JCS response includes a `result` status: `noChanges`, `applied`,
`conflictPending`, `parked`, or `retryable`. Raw object download/upload uses
the equivalent `X-Fuminiwa-Result` response header. A no-op is a successful
`noChanges`, not an error.

`404 notFoundInAccount` is returned for both an absent resource and a resource
owned by another account. The server performs account and fence checks before
object, snapshot, work, history, or conflict lookup. Object prepare/finalize
also binds `uploadId`, object digest, account fence, and command ID; an upload
cannot be resumed under another account or fence.

`prepareObject` returns `noChanges` only when the principal's own
`account_objects` row is available. A digest present only in `global_blobs` for
another account follows the same `applied` upload-capability flow as an absent
blob. Global deduplication may occur only after the caller's exact bytes pass
digest/length verification; response shape and authorization never disclose
foreign possession.

`POST /v2/snapshots/register` carries exact manifest bytes as unpadded
base64url in the closed command. The server decodes them, rejects any non-JCS
or digest mismatch, and stores the decoded bytes in `BYTEA`; it never hashes
the base64 text or a parsed/JSONB reserialization. `GET /v2/receipts/{id}`
returns the exact canonical response bytes plus predicates proving account,
command digest, resource, and resulting head read-back. A command is complete
locally only when every required predicate, including `headMatched`, is true.
For a command that must not advance a head, `headMatched` proves the observed
head remained at the command's expected value; it is never omitted.

A mutating response carries a finite `CommandReceipt` summary, not a base64
copy of the response containing itself. The server stores those exact response
bytes beside the summary. `GET /v2/receipts/{id}` alone wraps the previously
stored bytes as `canonicalResponseBase64URL`, so receipt replay has no
self-referential encoding.

Every mutating route derives scope from AuthenticatedPrincipal, requires the
body binding to equal that scope, and rejects a route WorkID different from the
closed payload WorkID. Receipt identity is `(AccountID, commandId)`; reusing a
command ID with a different kind, WorkID, or bytes is always
`commandIdReused`.

A Work's first remote publication starts with the sealed `createWork` command
at `POST /v2/works`. It atomically creates only an account-scoped, null-head
Work after proving `WorkID` absent for that principal. An exact
retry replays its receipt; an occupied WorkID (including the same WorkID with a
different DocumentID) is a closed conflict and never an adopt/rebind.
DocumentID is portable content identity and is not a server uniqueness or
deduplication key, so multiple WorkIDs may carry the same DocumentID. Only
after this receipt may the
client prepare/upload/finalize objects, register the first Snapshot, and
publish from expected remote head `null`. No object or snapshot route creates
a missing Work implicitly.

`POST /v2/works/{workId}/conflict/resolve` is atomic with the following exact
semantics:

- `useDevice` stores a decision Snapshot with both the current remote parent
  and the local parent, then publishes it by expected head CAS;
- `useServer` requires the conflict revision and remote Snapshot ID, pins a
  pre-adoption local Snapshot, performs server resolution, then stages and
  installs the verified remote Snapshot with expected current Snapshot and
  local-generation CAS. It creates no new local Intent for the selected remote
  bytes;
- `keepBoth` creates the new WorkID root, both heads, resolved conflict, and
receipt in one PostgreSQL transaction. The original Work remains unchanged.

The `cloneWork` sealed command and receipt remain scoped to `sourceWorkId`.
The new Work's head event stores `commandWorkId = sourceWorkId` and the closed
`cloneNewWork` scope; this is the only head-event WorkID mismatch and is valid
only when the referenced receipt kind is `cloneWork`. `createWork` reserves a
receipt before its Work row exists using deferred Work/command constraints,
then inserts the null-head Work before completion; it emits no head event.

For `keepBoth`, `localCandidateSnapshotId` is an already registered Snapshot
of `sourceWorkId`. The server deterministically constructs the clone root by
copying its ordered entries, setting manifest `workId = newWorkId`, setting
parents to `[]`, and replacing only `work/document` with canonical bytes that
retain `documentCreatedAt` and set `documentId = newDocumentId`. It computes
the replacement ObjectID and exact JCS manifest, and requires its digest to
equal `newRootSnapshotId` before writing anything. The transaction then keeps
the source Work/head unchanged, inserts the new document object, Work, root
Snapshot/head and both history occurrences, resolves the exact conflict
revision, and completes the receipt. Any mismatch or insert failure rolls back
all of it.
