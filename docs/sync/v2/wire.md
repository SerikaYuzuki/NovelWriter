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
stores `(account_id, command_id, command_kind, digest, response)` in the v2
receipt table. Exact retries return the same response. Reusing a command ID
with another kind or bytes returns `commandIdReused`; a different request gets
a new ID. Transport errors, 401/403, and fence/version errors do not create a
success receipt.

## Errors

The minimum typed errors are `invalidCanonicalBytes`, `schemaViolation`,
`accountFenceMismatch`, `protocolEpochMismatch`, `commandIdReused`,
`objectDigestMismatch`, `snapshotDigestMismatch`, `lineageViolation`,
`headConflict`, `activeConflict`, `notFoundInAccount`, `rateLimited`, and
`retryable`. `notFoundInAccount` is deliberately indistinguishable for a
foreign account and an absent resource.

`headConflict` preserves the candidate and creates or updates the work's one
active conflict. It never means “overwrite the server”.

## Resource and cursor contract

`GET /v2/works?cursor=` returns `{items,nextCursor}` sorted by lowercase
WorkID. `GET /v2/works/{workId}/history?cursor=` returns immutable occurrences
with the same opaque account scope. `GET /v2/snapshots/{snapshotId}/manifest`
returns the exact manifest bytes and its digest; `GET
/v2/objects/{objectId}` returns raw bytes and `X-Fuminiwa-Object-Digest`.
Every response includes a `result` status: `noChanges`, `applied`,
`conflictPending`, `parked`, or `retryable`. A no-op is a successful
`noChanges`, not an error.

`404 notFoundInAccount` is returned for both an absent resource and a resource
owned by another account. The server performs account and fence checks before
object, snapshot, work, history, or conflict lookup. Object prepare/finalize
also binds `uploadId`, object digest, account fence, and command ID; an upload
cannot be resumed under another account or fence.

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
