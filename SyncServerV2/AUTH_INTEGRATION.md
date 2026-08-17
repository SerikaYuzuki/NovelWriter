# Auth v1 isolated PostgreSQL gate

The normal `cargo test` suite is network-free and does not open PostgreSQL.
The transaction/race gate is explicit and fails closed unless it receives a
fresh, disposable database named `auth_v2_test` or
`auth_v2_test_<unique>`:

```sh
AUTH_V2_TEST_DATABASE_URL='postgres://.../auth_v2_test_<uuid>' \
  cargo run --manifest-path SyncServerV2/Cargo.toml --bin auth_v2_scenario_runner
```

The runner refuses any non-system schema, relation, view, sequence, type,
routine, or non-standard extension before migration; an existing SQLx or sync
schema is therefore not accepted. It never drops schemas, tables, databases,
containers, or volumes. It applies the checked-in migrations, seeds only the
Apple allowlist, and verifies concurrent first login, concurrent challenge
idempotency, invalid-exchange non-reservation, exchange/refresh/revoke exact
replay, a 301-second `providerResultKnown` process-restart recovery without a
second provider call, refresh races and reuse revocation, response-digest
read-back, active-state checks, cross-kind operation IDs, multi-audience
credentials, and plaintext-secret absence. A missing URL or a
non-fresh/non-test database prints `NO-GO` and exits with status 2.
