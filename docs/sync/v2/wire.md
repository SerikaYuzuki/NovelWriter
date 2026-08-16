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
