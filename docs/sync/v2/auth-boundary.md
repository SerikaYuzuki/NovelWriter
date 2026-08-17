# Auth v1 wire in the v2 deployment

Snapshot Sync v2 reuses `docs/auth/v1/` as the authentication wire and state
contract, not an old sync database or an Apple credential shortcut. The new
v2 PostgreSQL volume implements those tables in the separately namespaced
`auth_v1` schema and implements sync content in `sync_v2`. The checked-in
Compose revision uses a dedicated migration owner and runtime role. The runtime
role is granted only the exact `auth_v1`/`sync_v2` table DML, read-only
`server_meta`/`deployment_binding`, and PostgreSQL sequence `USAGE, SELECT,
UPDATE`; it has no migration-table, schema/database DDL, ownership,
role-membership, or superuser capability. The one-shot migrator is the only
process allowed to run SQLx migrations or bootstrap deployment metadata. The
server performs read-only role/ACL and metadata attestation before serving
requests.

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
principal; it never selects scope. The role split is fresh-only. A repeated
migrator invocation against an exact already-split v2 database is read-only; a
legacy single-role, partial, mixed, or unknown volume fails closed without
automatic `ALTER`, ownership rewrite, `GRANT`, or `REVOKE`. Existing staging
data therefore requires a separately reviewed, versioned, non-destructive
operator migration before cutover.

Development bearer support is a separately compiled/configured harness. A
production build/configuration has no dev-token verifier or fallback secret;
startup fails closed if a development-auth flag/token is present. Production
never accepts a fixed token after Apple or FUMINIWA session verification fails.

The sync deployment persists the authenticated `AccountAuthEpoch` alongside
the opaque fence. A strictly newer epoch for the same AccountID atomically
quarantines old sealed commands and parked works, then updates the scope;
equal or older epochs, or a same-epoch fence change, are rejected. A different
AccountID can never perform this rebind.
