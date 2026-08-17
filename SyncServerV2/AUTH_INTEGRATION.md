# Auth v1 isolated PostgreSQL gate

The normal `cargo test` suite is network-free and does not open PostgreSQL.
The transaction/race gate is explicit and fails closed unless it receives a
fresh, disposable database whose name contains `auth_v2_test`:

```sh
AUTH_V2_TEST_DATABASE_URL='postgres://.../auth_v2_test_<uuid>' \
  cargo run --manifest-path SyncServerV2/Cargo.toml --bin auth_v2_scenario_runner
```

The runner refuses an already initialized database and never drops schemas,
tables, databases, containers, or volumes. It applies the checked-in
migrations, seeds only the Apple allowlist, and verifies concurrent first
login, concurrent challenge idempotency, exchange/refresh/revoke exact replay,
refresh races and reuse revocation, response-digest read-back, active-state
checks, cross-kind operation IDs, multi-audience credentials, and
plaintext-secret absence. A missing URL or a non-fresh/non-test database
prints `NO-GO` and exits with status 2.
