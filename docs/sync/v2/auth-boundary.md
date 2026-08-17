# Auth v1 wire in the v2 deployment

Snapshot Sync v2 reuses `docs/auth/v1/` as the authentication wire and state
contract, not an old sync database or an Apple credential shortcut. The new
v2 PostgreSQL volume implements those tables in the separately namespaced
`auth_v1` schema and implements sync content in `sync_v2`. The checked-in
Compose revision still uses one PostgreSQL role for both schemas; the
schema-level authority boundary is not a database-role isolation claim.

```text
Apple native credential
  -> Apple adapter verifies issuer/audience/signature/state/nonce/code
  -> VerifiedExternalIdentity(providerConfig, issuer, subject)
  -> auth_v1 maps to opaque AccountID
  -> auth_v1 issues FUMINIWA session
  -> middleware creates AuthenticatedPrincipal(AccountID, SessionID, AuthEpoch, AccountFence)
  -> /v2 capabilities returns matching AccountFence
  -> sync_v2 queries only by principal AccountID
```

Apple authorization code, identity/access/refresh token, subject, email, and
name never enter a sync request, `sync_v2`, Snapshot, SQLite, object payload,
cursor, receipt, or log. A request body AccountID is only compared with the
principal; it never selects scope. The eventual role split must preserve this
boundary, but it is not enabled by this deployment revision. A separate
runtime role cannot be introduced by changing this Compose file alone: the
server currently opens one SQLx pool and runs all migrations and runtime
queries through it, while existing v2 objects are owned by the current role.
A fresh-only bootstrap plus a versioned, non-destructive grants/ownership
migration and read-back tests are required; until those are implemented,
there is no claim that database roles isolate auth from sync.

Development bearer support is a separately compiled/configured harness. A
production build/configuration has no dev-token verifier or fallback secret;
startup fails closed if a development-auth flag/token is present. Production
never accepts a fixed token after Apple or FUMINIWA session verification fails.

The sync deployment persists the authenticated `AccountAuthEpoch` alongside
the opaque fence. A strictly newer epoch for the same AccountID atomically
quarantines old sealed commands and parked works, then updates the scope;
equal or older epochs, or a same-epoch fence change, are rejected. A different
AccountID can never perform this rebind.
