# v2 conformance and red-team checks

This document maps the current executable conformance checks. Current executable entry points are
`Scripts/conformance-v2.py`, `Scripts/check-sync-v2-boundary.sh`, and
`Scripts/conformance-v2.sh`, run from the repository root. Prefer those maintained
scripts for fixture integrity and runtime checks. The Swift and Rust runners
must agree on fixtures without sharing canonicalization or state-machine code.

A contract/document check, runtime test, opt-in PostgreSQL Gate, and physical
device acceptance establish different facts. Match the check to the changed
boundary and report which layer ran. Current implementation gaps are in
[CODE_HEALTH](../../CODE_HEALTH.md); this file is not a record of a new
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


Account deletion uses `tests/account_deletion_gate.rs` with an explicit fresh `FUMINIWA_ACCOUNT_DELETION_TEST_URL`. `Scripts/conformance-v2.sh` unsets `FUMINIWA_V2_TEST_DATABASE_URL`, `FUMINIWA_ACCOUNT_DELETION_TEST_URL`, and `AUTH_V2_TEST_DATABASE_URL`. Backup tests are `Scripts/operations/test_backup.py`.


## D-103 local leaf contract

`fixtures/scenarios/local-leaf-promotion.json` is executed by the independent
Python reducer in `Scripts/conformance-v2.py`: sibling parents, zero remote
commands for autosaves, idle/max timing, explicit/lifecycle/restart promotion,
retained upgrade ancestry, parked/deleted local bytes and divergent-head CAS.
Swift `LocalLeafTests`, `LocalLeafRecoveryTests` and `LeafPromotionTests` exercise
real temporary SQLite, the production planner/worker and an injected timer.
Other store/runtime restore and three-choice conflict suites remain required.
App tests cover lifecycle flushing and EditorKit's existing IME/Undo gate.
No real DB, account or server is needed, and a local pass does not establish
physical device acceptance or production deployment.

## D-106 server-only head-first/backfill contract

The client/storage/UX steps in [the reviewed design](shallow-history-design.md)
are pending. No conformance result below establishes shallow client install,
physical-device acceptance or deployment. No-mode D-101/D-105 bytes and the
closed capabilities response remain unchanged.

| Boundary | Executable checks |
| --- | --- |
| Legacy response/cursor bytes, with and without totals | Existing `download-page*.json` byte/digest unit fixtures; opt-in `tests/support/shallow_download_pages.rs::assert_legacy_bytes` independently serializes every legacy page, including its original cursor, before and after mode requests |
| H-only manifests/objects, inline cutoff, opt-in totals per mode | Rust `snapshot_download::shallow::tests`; independent Python `check_shallow_download`; PostgreSQL head/large-object checks |
| Merge longest-depth ordering, ID tie order, H/earlier-group dedupe | Rust planner tests, shared shortcut-merge fixture, Python iterative postorder reducer, PostgreSQL grouped stream |
| Oversized single group, item/byte boundaries, safe resume and empty terminal | Rust planner tests (300-object group, byte-split group, oversized manifest); shared two-page fixture; PostgreSQL restart from closed group and terminal cursor |
| Closed cursor variants, canonical encoding, account/fence/server/epoch/work/H binding, kind/legacy mixing | Rust cursor tests, Python independent rejection checks; PostgreSQL HTTP schema/fence status checks |
| Warm-cache isolation and mutable visibility/ownership/availability | DownloadCache scope/mode/capacity/expiry unit tests; PostgreSQL quarantine/deleting/available transitions, foreign-account 404 equality, mode continuation immediately after work deletion |
| No generation cutoff, pinned ordering while publishing | Rust 5,001-snapshot linear planner; Python independent 5,001-depth reducer; PostgreSQL bulk-seeded 4,100-snapshot history and real HTTP publish during a pinned multi-page read |
| Backfill concurrency isolation | Existing `saturated_download_rejects_without_auth_or_database_wait` now also holds the single backfill permit, asserts 503 + `Retry-After: 1`, and verifies head/legacy can still reach authentication |

`fixtures/scenarios/shallow-download.json` contains digest-checked manifests,
small object bytes, reproducible large-object descriptors, a binding and page
filenames. `fixtures/canonical/download-head-1.json` and
`download-backfill-{1,2}.json` (with SHA-256 sidecars) pin the exact new closed
JCS envelopes, cursor encodings, totals and group boundaries. Rust constructs
plans from these inputs and compares canonical bytes; Python independently
rebuilds ancestry, longest depths, deduplicated groups, page limits and cursors.
Python does not import production code or use a database.

Run from the repository root:

```sh
cargo fmt --manifest-path SyncServerV2/Cargo.toml --check
cargo clippy --manifest-path SyncServerV2/Cargo.toml --all-targets -- -D warnings
cargo test --manifest-path SyncServerV2/Cargo.toml
python3 Scripts/conformance-v2.py
```

The new HTTP/SQL assertions run inside the existing opt-in
`postgres_and_http_scenarios_are_opt_in` gate. Reviewers must provision a **fresh,
isolated** test database, set `FUMINIWA_V2_TEST_DATABASE_URL`, and run:

```sh
cargo test --manifest-path SyncServerV2/Cargo.toml --test integration_gate postgres_and_http_scenarios_are_opt_in -- --nocapture
```

An ordinary `cargo test` with that variable unset compiles this gate and emits
SKIP; it is not PostgreSQL evidence. The account-deletion gate has its own
separate opt-in variable as described above.

## D-106 client Step 2

`shallow-install-backfill.json` is a complete entity-valid work shared by the
Rust download planner, Python independent reducer and Swift URLProtocol-to-SQLite
installation test. `install-head-1.json` and `install-backfill-1.json` pin exact
canonical wire bytes. The original `shallow-download.json` remains unchanged:
its attachment-only manifests test transport ordering, and the client rejects
those incomplete entity closures rather than weakening validation.

Swift coverage lives in `ShallowHistoryTests`, `ShallowMigrationTests`,
`ShallowConcurrentTests`, `ShallowDownloadTests`, `BackfillInterruptionTests`
and `HistoryBackfillCoordinatorTests`. The opt-in `FUMINIWA_IMPORT_BENCHMARK=1`
reports head/full time-to-editable and enforces the 256-item page write-lock
budget. Tests use disposable SQLite roots and stub HTTP only.

The old `6b089b87...` retired-restore checksum candidate cannot be reproduced
by its pre-existing DDL builder. It remains fail-closed; tests do not claim that
unsupported historical schema migrated. Other reproducible legacy candidates,
the pre-deletion base, deletion tail, fresh schema and tampering are exercised.
See [verification record](../../shallow-step2-verification.md) for actual runs.
