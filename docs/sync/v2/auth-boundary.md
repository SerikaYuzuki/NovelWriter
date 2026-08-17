# Auth v1 wire in the v2 deployment

Snapshot Sync v2 reuses `docs/auth/v1/` as the authentication wire and state
contract, not an old sync database or an Apple credential shortcut. The new
v2 PostgreSQL volume implements those tables in a separately owned `auth_v1`
schema/role and implements sync content in `sync_v2`.

```text
Apple native credential
  -> Apple adapter verifies issuer/audience/signature/state/nonce/code
  -> VerifiedExternalIdentity(providerConfig, issuer, subject)
  -> auth_v1 maps to opaque AccountID
  -> auth_v1 issues FUMINIWA session
  -> middleware creates AuthenticatedPrincipal(AccountID, SessionID, AuthEpoch)
  -> /v2 capabilities returns matching AccountFence
  -> sync_v2 queries only by principal AccountID
```

Apple authorization code, identity/access/refresh token, subject, email, and
name never enter a sync request, `sync_v2`, Snapshot, SQLite, object payload,
cursor, receipt, or log. A request body AccountID is only compared with the
principal; it never selects scope. The auth role cannot read manuscript BLOBs,
and the sync role cannot decrypt provider credentials.

Development bearer support is a separately compiled/configured harness. A
production build/configuration has no dev-token verifier or fallback secret;
startup fails closed if a development-auth flag/token is present. Production
never accepts a fixed token after Apple or FUMINIWA session verification fails.
