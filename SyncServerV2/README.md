# FUMINIWA Snapshot Sync v2 server

This is the isolated v2 server namespace selected by D-080. It uses Axum,
SQLx/PostgreSQL and `sync_v2` tables; object bytes are initially PostgreSQL
`BYTEA` behind the `ObjectStore` trait. Mutating `ObjectStore` operations use
the caller's SQLx transaction; object bytes, upload state, ownership and the
command receipt cannot commit independently. The v1 `SyncServer/` directory,
database, Docker project and volumes are never read or mounted.

## Local development and LAN staging

```sh
cp SyncServerV2/.env.example /secure/fuminiwa-sync-v2-role-split.env
# Fill the copy with v2-only paths and values; never commit that file.
# Fresh volume only: explicitly provision the temporary admin once.
docker compose --env-file /secure/fuminiwa-sync-v2-role-split.env \
  -f SyncServerV2/docker-compose.yml \
  -f SyncServerV2/docker-compose.provision.yml \
  -p fuminiwa-sync-v2-role-split \
  --profile provision run --rm bootstrap-admin
# Normal startup and every exact-v2 restart omit the provision profile.
docker compose --env-file /secure/fuminiwa-sync-v2-role-split.env \
  -f SyncServerV2/docker-compose.yml -p fuminiwa-sync-v2-role-split up --build -d
```

The `bootstrap-admin` one-shot, official PostgreSQL initialization role name,
and its password live only in `docker-compose.provision.yml`; they are not
part of the normal startup graph. The one-shot validates the exact OID-10
initialization authority, fixed target database, and empty user catalog in one
transaction under the deployment advisory lock before creating any role. The
fresh check covers user roles, every OID-bearing catalog, mutable OID-less
catalog state, database/public-schema ACLs, and role/database settings.
Pointing it at an exact-v2, legacy, role-only, catalog-object-only, or otherwise
non-fresh database aborts with zero catalog changes. If the provision
file/profile is omitted on a fresh
volume, PostgreSQL itself and the migrator both fail closed. On an exact-v2
restart, use only `docker-compose.yml`: the official PostgreSQL initialization
identifier and secret are absent from the rendered graph and cannot be
mounted/contacted; the migrator uses only the permanent bootstrap role for
read-only attestation.

The one-shot runs as the same fixed numeric `10001:10001` identity as the v2
server image. Its admin-password bind mount must therefore be the mode-`0400`
runtime copy produced by `prepare-runtime-secrets.sh`; making an operator
source secret world-readable is not an accepted workaround.

The only database volume is `fuminiwa-sync-v2-role-split-data`; Caddy also has two
edge-state volumes (`fuminiwa-sync-v2-role-split-caddy-data` and
`fuminiwa-sync-v2-role-split-caddy-config`). The only project, network, containers, and
volumes are `fuminiwa-sync-v2-role-split-*`. This compose file never names, mounts, or
connects to the v1 project or its volumes. The Axum listener is internal to
the compose network; only Caddy's LAN staging TLS port (default `8443`) is
published. `tls internal` is intentionally staging-only and requires trusting
the generated Caddy local CA on each test device.

The `migrator` one-shot service is the only service that can run SQLx
migrations, bootstrap `server_meta`/`deployment_binding`, or grant privileges.
It first inventories the database under the v2 advisory lock. A fresh database
is bootstrapped with `fuminiwa_sync_v2_migrator` (DDL/migration owner) and
`fuminiwa_sync_v2_runtime` (DML-only runtime role), then the exact grants are
read back before the server is allowed to start. The server itself never runs
SQLx migrations and starts only after read-only catalog, role/ACL, schema
marker, and deployment-binding verification. Runtime PostgreSQL sequence
access is `USAGE` only on the required sequences. The source does not use
`currval`, `setval`, or `last_value`; PostgreSQL has no separate sequence
`EXECUTE` privilege, so `USAGE` is the least privilege needed for inserts.
The official PostgreSQL OID-10 initialization role is isolated to the
one-shot `bootstrap-admin` service and is never mounted into the migrator or
server. That service creates the temporary `fuminiwa_sync_v2_bootstrap_admin`
role under the same advisory lock. The migrator then creates and owns the
fixed bootstrap role, migration owner, and runtime role; after DDL and grants
it hardens the temporary admin to `NOLOGIN NOSUPERUSER NOCREATEDB
NOCREATEROLE NOINHERIT NOREPLICATION NOBYPASSRLS`. It closes the admin
authority and reacquires the lock through a new fixed-bootstrap connection,
including `is_superuser=off` and ACL read-back.

On an already-initialized exact v2 database, a repeated migrator invocation is
read-only and succeeds only when the role/ACL attestation is already exact. A
legacy, single-role, partial, mixed, or unrecognized database is rejected
without `ALTER`, `DROP`, automatic role creation, or automatic grants.

The server image runs as the non-root `fuminiwa` user with a read-only root
filesystem, a small `tmpfs` at `/tmp`, all Linux capabilities dropped, and
`no-new-privileges`. Caddy uses read-only root storage with only its explicit
`/data` and `/config` volumes writable. PostgreSQL retains its dedicated v2
data volume and is never reused for v1. Secret values are supplied only as
read-only files under `/run/secrets`; no secret belongs in this repository or
in container environment values. The server binary is Production-only and
fails closed before opening PostgreSQL when any Auth v1 key or Apple
configuration is absent. Test and preview authentication are
dependency-injected in process tests; the binary has no fixture-token startup
mode.

Compose file-backed secrets retain the source file's numeric ownership on the
staging host. Because the server runs as uid/gid `10001`, prepare a separate
v2-only runtime directory rather than weakening the permissions on operator
originals:

```sh
sudo SyncServerV2/scripts/prepare-runtime-secrets.sh \
  /DATA/AppData/fuminiwa-sync-v2/secrets \
  /DATA/AppData/fuminiwa-sync-v2/runtime-secrets
```

Set every `*_FILE`/`*_HOST_PATH` entry in the private compose env file to the
corresponding file under `runtime-secrets`. The script rejects symlinked
inputs, leaves the source directory untouched, atomically replaces only the
ten named v2 copies, and sets mode `0400` with owner `10001:10001`. Re-run it
after rotating a source secret, before recreating only the v2 server.

Before using a new host or IP, inspect the rendered configuration without
starting it and verify that every resource has the v2 prefix:

```sh
docker compose --env-file /secure/fuminiwa-sync-v2-role-split.env \
  -f SyncServerV2/docker-compose.yml -p fuminiwa-sync-v2-role-split config
docker compose --env-file /secure/fuminiwa-sync-v2-role-split.env \
  -f SyncServerV2/docker-compose.yml \
  -f SyncServerV2/docker-compose.provision.yml \
  -p fuminiwa-sync-v2-role-split --profile provision config
```

On `192.168.11.5`, use a new Compose project exactly as shown above. Do not
run `down -v`, `volume rm`, `docker system prune`, or any command against the
old project while validating v2. The v2 health chain is PostgreSQL readiness,
then the Axum listener, then Caddy TLS. The public Auth capabilities probe
must return `200`; any `401` or other status is a failed health read-back.
This endpoint proves only listener/router readiness and is not an account or
data read-back.

## Verification

```sh
cargo fmt --check
cargo test --offline
cargo clippy --offline --all-targets -- -D warnings
```

The PostgreSQL integration gate is opt-in. Set
`FUMINIWA_V2_TEST_DATABASE_URL` to an externally provisioned, newly-created
empty database whose name is `fuminiwa_v2_test` or begins with
`fuminiwa_v2_test_`. The runner does not create or drop a database, schema,
container, or volume. It applies the checked-in migrations to that database,
runs repository scenarios, and leaves its synthetic rows intact. Test-only
setup directly forces upload expiry, a migration-marker mismatch, and a
catalog tombstone/race. It also runs two concurrent fresh `Repository::connect`
calls to exercise the deployment-wide identity-lock TOCTOU boundary. These
writes are not production API paths.

The operator must discard the entire disposable database after the run. Use a
second fresh database for the HTTP integration gate because each gate refuses
an initialized database:

```sh
FUMINIWA_V2_TEST_DATABASE_URL='postgres://.../fuminiwa_v2_test_repository_<uuid>' \
  cargo run --bin sync_v2_scenario_runner
FUMINIWA_V2_TEST_DATABASE_URL='postgres://.../fuminiwa_v2_test_http_<uuid>' \
  cargo test --test integration_gate postgres_and_http_scenarios_are_opt_in \
  -- --exact --nocapture
```

Without the variable, ordinary tests emit an explicit integration skip and no
network or fixed LAN endpoint is contacted. The guard rejects private-LAN
hosts, legacy/production/staging database names, names without the test marker,
and any database that already has non-system tables. Never point it at v1, a
development/staging authority, or a production volume.

The role-split gate is a separate opt-in PostgreSQL run. Provision three
separately named, disposable databases whose names begin with
`fuminiwa_v2_role_split_test_`: one empty fresh database, one database where an
operator-created unknown table is present, and one database containing only a
legacy/single-role `sync_v2.server_meta` marker. Supply their URLs and the
four password-file paths through the `FUMINIWA_V2_ROLE_SPLIT_*` environment
names in `.env.example`; never put credential values in this repository. Build
both binaries before running the gate:

```sh
cargo build --manifest-path SyncServerV2/Cargo.toml --offline \
  --bin sync_v2_migrator --bin sync_v2_role_split_runner
FUMINIWA_V2_ROLE_SPLIT_TEST_DATABASE_URL='postgres://.../fuminiwa_v2_role_split_test_fresh_<uuid>' \
FUMINIWA_V2_ROLE_SPLIT_UNKNOWN_DATABASE_URL='postgres://.../fuminiwa_v2_role_split_test_unknown_<uuid>' \
FUMINIWA_V2_ROLE_SPLIT_SINGLE_ROLE_DATABASE_URL='postgres://.../fuminiwa_v2_role_split_test_legacy_<uuid>' \
FUMINIWA_V2_ROLE_SPLIT_SERVER_INSTANCE_ID='<lowercase-uuid>' \
FUMINIWA_V2_ROLE_SPLIT_BOOTSTRAP_ADMIN_PASSWORD_FILE='/secure/v2/bootstrap-admin-password' \
FUMINIWA_V2_ROLE_SPLIT_BOOTSTRAP_PASSWORD_FILE='/secure/v2/bootstrap-password' \
FUMINIWA_V2_ROLE_SPLIT_MIGRATION_PASSWORD_FILE='/secure/v2/migration-password' \
FUMINIWA_V2_ROLE_SPLIT_RUNTIME_PASSWORD_FILE='/secure/v2/runtime-password' \
FUMINIWA_V2_MIGRATOR_BIN='SyncServerV2/target/debug/sync_v2_migrator' \
  SyncServerV2/target/debug/sync_v2_role_split_runner
```

The runner does not create or drop databases, roles, schemas, containers, or
volumes. Missing variables print `NO-GO` and exit 2. It runs two concurrent
fresh migrators, verifies convergence and repeat read-only fingerprints,
exercises allowed runtime DML, rejects runtime database/schema/public CREATE,
TEMP, migration-table/column access, sequence `last_value`/`setval`, and
confirms unknown/legacy rejection leaves catalog fingerprints unchanged. The
unknown-object and legacy-marker databases must already be operator-provisioned;
the runner performs no setup writes to those targets and returns `NO-GO` when
their required marker is absent.

Before starting the runner, provision the fixed temporary bootstrap admin on
every disposable PostgreSQL cluster used by the three targets. When all three
databases are on one cluster, one explicit `docker compose --profile
provision run --rm bootstrap-admin` invocation is sufficient because roles
are cluster-scoped. If the targets are on separate clusters, run the same
one-shot independently on each cluster. The runner first opens the unknown and
legacy targets through this temporary admin to capture their immutable
pre-rejection catalog/data fingerprints; it then provisions the fresh target,
which hardens that admin to `NOLOGIN`. Therefore unknown/legacy markers and
their temporary-admin access must be prepared before the runner starts. Never
put a password value in the command line; supply all four password-file paths
shown above.

For a disposable PostgreSQL database, create a separate v2-only Compose
project and volume; do not use the staging project or its volume. For example,
with a locally installed PostgreSQL client and a separately managed
administrator connection, provision a fresh database named
`fuminiwa_v2_test_repository_<uuid>` and a role scoped only to that database,
then set `FUMINIWA_V2_TEST_DATABASE_URL` for one run. The runner deliberately
does not create/drop databases because both operations require elevated
authority. After collecting the result, remove that disposable database and
role through the same explicitly named administrator connection. Never use a
wildcard, `TRUNCATE`, or the v2 staging database for this step. A second fresh
database is required for the HTTP gate, as shown above.

## Production Sign in with Apple authority

The adapter uses only Apple's fixed issuer, JWKS, and token endpoints. It
follows Apple's primary documentation for
[authenticating users](https://developer.apple.com/documentation/signinwithapple/authenticating-users-with-sign-in-with-apple),
[token generation and validation](https://developer.apple.com/documentation/signinwithapplerestapi/generate-and-validate-tokens),
[client-secret creation](https://developer.apple.com/documentation/accountorganizationaldatasharing/creating-a-client-secret),
and [JWKS retrieval](https://developer.apple.com/documentation/signinwithapplerestapi/fetch-apple%27s-public-key-for-verifying-token-signature).
No private key, provider token, or real identity fixture belongs in this
repository.

## Staging TLS and health read-back

The included Caddy edge uses `tls internal` only for a LAN staging deployment.
The generated local CA must be explicitly trusted on each test device; it is
not a production certificate. Production requires a separately managed,
publicly trusted TLS edge and must not expose the Axum listener directly.
Before device testing, verify the edge health response and certificate chain
from the same network path used by the app, then read back the authenticated
capabilities response and a newly created v2 work. A successful container
healthcheck alone is not a TLS or account-isolation read-back.

The device-facing URL is
`https://${FUMINIWA_SYNC_V2_EDGE_HOST}:${FUMINIWA_SYNC_V2_EDGE_PORT}` (defaults
to `https://192.168.11.5:8443`). The edge host is part of the Caddy site
address, so the internally issued leaf certificate contains the exact LAN IP
used by macOS and iOS. Trusting the Caddy staging CA is a separate test-device
setup step; do not weaken certificate validation in the app. Keep the server's
`8092` port unexposed from the host.

The non-installing export and verification procedure is documented in
[`docs/SNAPSHOT_SYNC_V2_STAGING.md`](../docs/SNAPSHOT_SYNC_V2_STAGING.md).
Run [`Scripts/export-sync-v2-staging-ca.sh`](../Scripts/export-sync-v2-staging-ca.sh)
to export only the public root, print its SHA-256 fingerprint, verify the leaf
SAN `IP Address:192.168.11.5`, and read back `/v1/auth/capabilities` using
`curl --cacert`. The script never uses `-k` and never installs trust; macOS and
iOS trust are explicit, manual opt-in steps.
