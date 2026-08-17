# FUMINIWA Snapshot Sync v2 server

This is the isolated v2 server namespace selected by D-080. It uses Axum,
SQLx/PostgreSQL and `sync_v2` tables; object bytes are initially PostgreSQL
`BYTEA` behind the `ObjectStore` trait. Mutating `ObjectStore` operations use
the caller's SQLx transaction; object bytes, upload state, ownership and the
command receipt cannot commit independently. The v1 `SyncServer/` directory,
database, Docker project and volumes are never read or mounted.

## Local development and LAN staging

```sh
cp SyncServerV2/.env.example /secure/fuminiwa-sync-v2.env
# Fill the copy with v2-only paths and values; never commit that file.
docker compose --env-file /secure/fuminiwa-sync-v2.env \
  -f SyncServerV2/docker-compose.yml -p fuminiwa-sync-v2 up --build -d
```

The only database volume is `fuminiwa-sync-v2-data`; Caddy also has two
edge-state volumes (`fuminiwa-sync-v2-caddy-data` and
`fuminiwa-sync-v2-caddy-config`). The only project, network, containers, and
volumes are `fuminiwa-sync-v2-*`. This compose file never names, mounts, or
connects to the v1 project or its volumes. The Axum listener is internal to
the compose network; only Caddy's LAN staging TLS port (default `8443`) is
published. `tls internal` is intentionally staging-only and requires trusting
the generated Caddy local CA on each test device.

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
six named v2 copies, and sets mode `0400` with owner `10001:10001`. Re-run it
after rotating a source secret, before recreating only the v2 server.

Before using a new host or IP, inspect the rendered configuration without
starting it and verify that every resource has the v2 prefix:

```sh
docker compose --env-file /secure/fuminiwa-sync-v2.env \
  -f SyncServerV2/docker-compose.yml -p fuminiwa-sync-v2 config
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
catalog tombstone/race; these writes are not production API paths.

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
