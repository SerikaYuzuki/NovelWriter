# v2 conformance and red-team checks

This document maps the current executable conformance checks. Current executable entry points are
`Scripts/conformance-v2.py`, `Scripts/check-sync-v2-boundary.sh`, and
`Scripts/conformance-v2.sh`, run from the repository root. Prefer those maintained
scripts for fixture integrity and runtime checks. The Swift and Rust runners
must agree on fixtures without sharing canonicalization or state-machine code.

A contract/document check, runtime test, opt-in PostgreSQL Gate, and physical
device acceptance establish different facts. Match the check to the changed
boundary and report which layer ran. Current implementation evidence is in the
[handoff](../../SNAPSHOT_SYNC_V2_HANDOFF.md); this file is not a record of a new
successful run.

## Rust HTTP source-to-test map

The opt-in PostgreSQL gate is the only test that exercises the Axum routes
against a database. Without a fresh disposable `FUMINIWA_V2_TEST_DATABASE_URL`
it remains an explicit NO-GO/skip and does not connect anywhere.

| Contract area | Rust source | Test/evidence |
| --- | --- | --- |
| Authenticated AccountID/Fence/epoch headers before lookup | `SyncServerV2/src/http.rs` (`principal`, `command_inner`) | `tests/integration_gate.rs` foreign/absent resource equality and missing-scope checks |
| Exact JCS request/response media type and no-store headers | `SyncServerV2/src/http.rs` (`require_media_type`, `error_response`, `canonical_response`) | `src/http.rs` unit tests; integration gate response headers |
| Canonical command parsing and closed result unions | `SyncServerV2/src/application.rs`; `src/postgres.rs` response validation | `tests/domain.rs`; `tests/fixtures.rs` |
| Raw manifest BYTEA digest/round-trip | `src/postgres.rs` register/manifest; `src/http.rs` manifest | `tests/fixtures.rs`; opt-in repository + HTTP gate |
| Receipt lookup, exact replay, and read-back predicates | `src/postgres.rs` receipt lookup/complete; `src/http.rs` receipt | `tests/domain.rs`; `tests/fixtures.rs`; opt-in HTTP gate |
| Catalog/history pagination and sealed cursors | `src/http.rs` list/history/cursor helpers | opt-in HTTP gate cursor continuation checks |
| One active conflict and closed useDevice/useServer/keepBoth/restore results | `src/postgres.rs` publish/resolve/restore; `src/application.rs` payload validation | `tests/fixtures.rs`; opt-in repository scenarios and stale-resolution HTTP check |
| Foreign/absent 404 non-disclosure and body/path bounds | `src/http.rs` scope, digest/UUID parsing, body limits | opt-in HTTP gate; `tests/domain.rs` canonical/schema bounds |


Account deletion uses `tests/account_deletion_gate.rs` with an explicit fresh `FUMINIWA_ACCOUNT_DELETION_TEST_URL`. The normal gate unsets both opt-in database URLs. Backup tests are `Scripts/operations/test_backup.py`.
