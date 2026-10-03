# FUMINIWA Snapshot Sync v2 server

This is the isolated v2 server namespace selected by D-080. It uses Axum,
SQLx/PostgreSQL and `sync_v2` tables; object bytes are initially PostgreSQL
`BYTEA` behind the `ObjectStore` trait. Mutating `ObjectStore` operations use
the caller's SQLx transaction; object bytes, upload state, ownership and the
command receipt cannot commit independently. Only the configured v2 database
and volume are opened.

## Status and task entry points

The server, Auth v1 adapter, account deletion worker, role-split deployment,
and local conformance tools are implemented; release acceptance remains open.
See [current status](../docs/CODE_HEALTH.md) and [backup/deletion operations](../docs/ACCOUNT_RETENTION_OPERATIONS.md).

- Protocol changes: [v2 contract](../docs/sync/v2/README.md) and fixtures.
- Ownership/bootstrap changes: [deployment contract](../docs/sync/v2/deployment.md).
- Auth transactions: [AUTH_INTEGRATION.md](AUTH_INTEGRATION.md) and [Auth contract](../docs/AUTH.md).
- Device TLS: [staging guide](../docs/SNAPSHOT_SYNC_V2_STAGING.md).
- ZimaOS custom app and ops web UI: [preparation, migration, rollback and updates](../docs/ZIMAOS_APP.md).

Run the commands below from the repository root. Deployment examples mutate
an explicitly selected v2 environment; reading or editing this README does not
require starting the stack. Confirm the target project/volume before executing
fresh provisioning. Exact-v2 restart uses the base Compose file only.

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

Fresh provisioning and normal restart have different authorities. The official
PostgreSQL initialization role is available only to `bootstrap-admin` in the
provision profile. The migrator owns DDL; the runtime is DML-only and opens an
already-attested database. Exact-current restart is read-only. Unknown,
partial, or single-role databases fail closed. Role names, exact ACLs, volume
identity, bootstrap guards, and explicit upgrades are defined once in the
[deployment contract](../docs/sync/v2/deployment.md).

The database volume is `fuminiwa-sync-v2-role-split-data`. Caddy's `/data` and
`/config` volumes are edge state, not manuscript storage. Only Caddy's 8443
port is exposed; Axum 8092 remains inside Compose. The public Tunnel reaches
this same edge, so a LAN URL does not imply a disposable environment.

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
  /DATA/AppData/fuminiwa-sync-v2-role-split/secrets \
  /DATA/AppData/fuminiwa-sync-v2-role-split/runtime-secrets
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

For a fresh environment, use a separately identified Compose project and volume. The configured home-server project is already used by the public endpoint; do not treat it as a new test target. Do not
run `down -v`, `volume rm`, `docker system prune`, or any command against the
old project while validating v2. The v2 health chain is PostgreSQL readiness,
then the Axum listener, then Caddy TLS. The public Auth capabilities probe
must return `200`; any `401` or other status is a failed health read-back.
This endpoint proves only listener/router readiness and is not an account or
data read-back.

## Restart policy and ops

`docker-compose.yml` sets `restart: unless-stopped` on PostgreSQL, server and
edge. The one-shot migrator and provisioning services have no restart policy.
This preserves the policy when Compose recreates a service. Existing containers
that were updated with `docker update --restart unless-stopped` retain their
policy without recreation; applying this YAML is a separate deployment step.
An explicitly stopped container stays stopped across a Docker/host restart
([Docker restart policy](https://docs.docker.com/engine/containers/start-containers-automatically/)).

Compose's `depends_on` health/completion chain applies to Compose startup, not
Docker's automatic restart after a reboot. PostgreSQL may therefore be late.
The server's `Repository::connect_from_environment` has a five-second pool
acquire timeout and propagates connection/readiness errors. `main` returns the
startup error before binding HTTP, exiting nonzero; Docker's restart policy
retries with backoff and recovers once PostgreSQL and its existing migrated
schema/roles are ready. This is a configuration-backed retry, not an added
in-process startup loop. Runtime startup is read-only and does not rerun the
migrator. Missing migrations, identity/key/role errors still require operator
repair; retry does not bypass those checks. Caddy can serve temporary upstream
errors until the server listener is ready. Read back postgres/server/edge health
and the public path separately after a reboot; a dependency order is not a
guarantee of immediate availability.

The independent `docker-compose.ops.yml` project `fuminiwa-sync-v2-ops` runs
daily encrypted backups at **03:17 Asia/Tokyo** (2026-10-03 owner decision).
It does not create/recreate the role-split services and has no network or web
port. The combined [ZimaOS app](../docs/ZIMAOS_APP.md) supplies the UI secret
and a separate bridge/port; do not start both under the same container names.
Its Alpine image includes the repository backup.py and binary
packages for Python, cryptography, Docker CLI, Supercronic and timezone data.
Only entrypoint initialization starts as root; the cron daemon and jobs run as
999:1000 with the Docker socket's supplementary gid. It does not run a backup
immediately on startup. The cron daemon and the 36-hour last-success window are
checked by `ops-healthcheck`; `unhealthy` itself is not a Docker restart trigger.

See [operations and server-side deployment commands](../docs/ACCOUNT_RETENTION_OPERATIONS.md#再起動後も続く定期実行)
for mounts, schedule configuration, manual `docker exec ... run-backup`, logs,
and reboot acceptance. Build from the repository root:

```sh
docker build -f SyncServerV2/ops/Dockerfile -t fuminiwa-sync-v2-ops:local .
docker compose --env-file /DATA/AppData/fuminiwa-sync-v2-role-split/ops/ops.env \
  -f SyncServerV2/docker-compose.ops.yml -p fuminiwa-sync-v2-ops up -d --no-build
```

## Verification

Backup/ops unit tests require Python with `cryptography` and timezone data,
without contacting Docker or a real database:

```sh
python3 -m unittest discover -s Scripts/operations -p 'test_*.py' -v
```

Container build, size and startup/cron/reboot checks require a local Docker
daemon or the separate authorized server deployment. Unit tests alone do not
prove the image build or successful production backups.

```sh
cargo fmt --manifest-path SyncServerV2/Cargo.toml --check
cargo test --manifest-path SyncServerV2/Cargo.toml --offline
cargo clippy --manifest-path SyncServerV2/Cargo.toml --offline --all-targets -- -D warnings
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
  cargo run --manifest-path SyncServerV2/Cargo.toml --bin sync_v2_scenario_runner
FUMINIWA_V2_TEST_DATABASE_URL='postgres://.../fuminiwa_v2_test_http_<uuid>' \
  cargo test --manifest-path SyncServerV2/Cargo.toml --test integration_gate postgres_and_http_scenarios_are_opt_in \
  -- --exact --nocapture
```

The repository gate also covers an 8,194-generation publish, immediate-parent
publication on that history, rejection of a non-ancestor, and cross-account
blob protection while another upload is prepared/uploaded/finalized. The HTTP
gate covers a merge DAG, object deduplication, quarantine/deleting states,
objects just above 256 KiB, and an exact 2 MiB page followed by its remainder.
The dedicated `FUMINIWA_ACCOUNT_DELETION_TEST_URL` gate in
`tests/account_deletion_gate.rs` additionally verifies the same upload protection
through account erasure; use another fresh guarded test database for that gate.

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

The included Caddy edge uses `tls internal`. Direct LAN clients must trust
its public CA. The configured public path uses Cloudflare Tunnel with public
TLS at `sync.serika.work` and validated TLS from cloudflared to Caddy; public
clients do not install the internal CA. See the [Tunnel configuration](../docs/SNAPSHOT_SYNC_V2_TUNNEL.md). Never expose Axum directly.
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

The public-root export and verification boundary is documented in
[`docs/SNAPSHOT_SYNC_V2_STAGING.md`](../docs/SNAPSHOT_SYNC_V2_STAGING.md).
The current export script still targets `fuminiwa-sync-v2-edge`, not this
Compose revision's `fuminiwa-sync-v2-role-split-edge`, and checks namespace
strings without checking Sync epoch 2. Resolve that mismatch before using it
for this deployment. Its successful output alone is not a v2 epoch, account,
or Work read-back. Device trust remains a separate explicit setup step.
