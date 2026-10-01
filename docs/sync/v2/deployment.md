# v2 Docker and database namespace

The development deployment is a new Compose project/service revision that
mounts one named data volume for v2 PostgreSQL. The edge service additionally
uses two named Caddy state volumes; those are not database or application
data authorities:

```text
API prefix:       /v2
PostgreSQL volume fuminiwa-sync-v2-role-split-data
auth schema:      auth_v1 (separate schema namespace)
sync schema:      sync_v2 (separate schema namespace)
object bytes:     sync_v2.global_blobs.raw_bytes BYTEA
```

The v2 Compose revision uses one official initialization role, one temporary
bootstrap-admin role, and three persistent application roles:

- The official PostgreSQL OID-10 initialization role is used only by the
  one-shot `bootstrap-admin` service. It creates
  `fuminiwa_sync_v2_bootstrap_admin` under the deployment advisory lock; the
  official role is never passed to the migrator or runtime.
- `fuminiwa_sync_v2_bootstrap` is the permanent login/connect authority and
  target-database owner. After migration and grants, the temporary admin is
  hardened to `NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT
  NOREPLICATION NOBYPASSRLS`; the migrator closes that authority and
  reattests through a fresh permanent-bootstrap connection.
- `fuminiwa_sync_v2_migrator` is the schema/object owner. The one-shot
  `migrator` service runs SQLx DDL, writes `_sqlx_migrations`, bootstraps
  `server_meta` and `deployment_binding`, and grants the audited runtime ACL.
- `fuminiwa_sync_v2_runtime` is the server login. It has `USAGE` on
  `auth_v1`/`sync_v2`, exact table DML (with read-only `server_meta` and
  `deployment_binding`), and `USAGE` only on required sequences. The source
  never uses `currval`, `setval`, or `last_value`, so sequence `SELECT` and
  `UPDATE` are prohibited.
  It has no database/schema CREATE, object ownership, migration-table access,
  role membership, or superuser/createdb/createrole/bypass-RLS capability.

The server opens its pool only as `fuminiwa_sync_v2_runtime`; it never invokes
SQLx migrations or writes deployment metadata. Startup performs catalog
identity, role/ACL, exact marker, and binding read-back. PostgreSQL has no
separate sequence `EXECUTE` privilege; `USAGE` is the exact minimum
PostgreSQL privilege required for the server's nextval-backed inserts.

Fresh bootstrap is the only path that creates roles, applies grants, or
downgrades the temporary admin. A re-run against an exact v2 volume first
connects through the already-hardened permanent bootstrap role and is
read-only: it never
re-requests role DDL or grants. Legacy, single-role, mixed, partial, or
unknown databases fail closed; the migrator never auto-ALTERs, rewrites
ownership, or grants privileges on an existing volume.

The `bootstrap-admin` Compose service, official PostgreSQL initialization role
identifier, and secret exist only in `docker-compose.provision.yml` under the
explicit `provision` profile. For a newly-created volume, merge that file and
run `docker compose --profile provision run --rm bootstrap-admin` once before
starting the normal migrator/server graph. Its SQL verifies the expected OID-10
superuser, fixed database identity, absence of every user-created role, and an
empty user catalog inside one transaction protected by the deployment advisory
lock. The catalog guard scans every OID-bearing PostgreSQL catalog at the
`FirstNormalObjectId` boundary and separately checks mutable catalogs without
OIDs, default database/public-schema ACLs, role membership, and role/database
settings. An exact-v2, legacy, role-only, or catalog-object-only unknown target
fails before role creation and rolls back without catalog change. If
provisioning is omitted, fresh
PostgreSQL initialization and the migrator fail closed. Normal startup and
exact-v2 restart use only `docker-compose.yml`; the official OID-10 identifier
and secret are absent from the rendered graph, cannot be mounted or contacted,
and the migrator uses only the permanent bootstrap read-back path.
The one-shot process uses fixed uid/gid `10001:10001`, so its password mount is
the mode-`0400` runtime copy prepared for that identity, not a world-readable
operator source file.

It does not mount a v1 PostgreSQL volume, legacy object directory, package
root, or CloudKit credential. Startup fails if the configured database lacks
the v2 schema checksum/protocol epoch or points at a known v1 volume/schema.
The live service never runs an archive or SQLx migration automatically. The
migrator accepts only a genuinely fresh database for writes; exact split v2 is
read-back-only. Legacy, partial, nonempty, and unrecognized user schemas fail
closed, and the rejection path leaves the database unchanged.

The migrator takes one deployment-wide PostgreSQL session advisory lock before
the fresh inventory and holds it through role setup, SQLx migration,
server_meta/binding bootstrap, grants, and final attestation. The runtime does
not need that lock for DDL coordination because it lacks DDL authority; it
performs a read-only inventory and metadata check after the migrator service
has completed successfully.

Before that inventory, the locked permanent-bootstrap session is attested
separately: `current_user` must be `fuminiwa_sync_v2_bootstrap`, its session
must report `is_superuser=off`, and it must own the target database with
`CONNECT`/`CREATE`. The temporary admin's catalog flags are also read back as
non-login and non-privileged. Fresh role-count preflight rejects any partial
bootstrap role set.

Migration authority names every index and constraint that could exceed
PostgreSQL's 63-byte identifier limit (including
`conflict_candidates_conflict_revision_generation_key`,
`external_identities_account_provider_issuer_key`, and
`provider_credentials_identity_audience_generation_key`). The catalog
attestation expects these exact deterministic names; PostgreSQL's implicit
identifier truncation is not accepted as the contract.

`sync_v2_role_split_runner` is the opt-in PostgreSQL gate for this boundary.
It requires three separately provisioned disposable databases and password-file
paths, runs concurrent fresh migrators, repeats the migrator while comparing
catalog fingerprints, exercises allowed runtime DML, attempts denied database/
schema/public/TEMP/column/migration-table/sequence operations, and verifies
unknown or legacy rejection without catalog changes. Missing gate variables
are an explicit `NO-GO`; the runner never creates or drops databases, roles,
schemas, containers, or volumes. The unknown-object and legacy-marker targets
must already be provisioned by the operator; missing markers are `NO-GO`, and
the runner performs no setup writes to those existing targets.

## Existing v2 volume upgrade (operator-controlled)

This role split is a fresh-only Compose/bootstrap contract. Do not point the
new Compose file at an existing v2 volume that was initialized with the old
single role and do not run `ALTER ROLE`, `ALTER ... OWNER`, `GRANT`, `REVOKE`,
or SQLx migrations against it through the application stack. Stop the old v2
stack only after a verified PostgreSQL backup, provision a separately named
disposable copy, and have an operator-reviewed upgrade tool inventory ownership
and ACLs, apply a versioned non-destructive ownership/grants migration, and
read back every role/object/privilege before any cutover. Until that tool and
rollback evidence exist, retain the old v2 stack/volume and deploy the new
Compose project only with a newly provisioned
`fuminiwa-sync-v2-role-split-data` volume. The earlier `fuminiwa-sync-v2-data` volume is outside this deployment
procedure. Its current existence and contents must be inventoried before an
operator change; this document is not evidence of live volume state.

`PostgresObjectStore` is the only initial `ObjectStore` implementation. A
future S3 adapter requires a new versioned deployment manifest, data-copy plus
read-back migration, rollback evidence, and a later Decision. It is not an
ambient environment-variable switch in this deployment.

## Exact role-split v2 upgrade: work deletion (0005)

`SyncServerV2/operations/0005_upgrade.sql` is the narrow operator upgrade for
an already-attested role-split database with exactly migrations 1–4 and their
checked-in SHA-384 checksums. It is not the fresh migrator and does not accept
legacy/single-role databases. Stop API writers, take a PostgreSQL custom-format
backup, verify restoration in an isolated database, and apply this script as
`fuminiwa_sync_v2_migrator` with `ON_ERROR_STOP`. It changes only the deletion
DDL, its runtime grant, and the SQLx migration record, in one transaction.
The script rejects repeat application; ordinary exact-v2 startup is read-only.
Retain the previous image/container and backup before replacing the API.
The old runtime cannot attest the added schema and must not be restarted
against version 5 without an explicitly reviewed rollback.

## Exact role-split v2 upgrade: known migrations (0006–0011)

The explicit `sync_v2_migrator --upgrade-server-fixes-20261001` path (the older
`--upgrade-review-20260913` flag remains an alias) accepts only an
attested role-split database with the checked-in migration checksums and a
complete history through version 5, 6, 7, 8, 9, 10 or 11. Under the existing deployment lock,
SQLx applies only the remaining migrations. Ordinary startup does not upgrade.
The current runtime requires account deletion (0008), independent AI records/recovery receipts (0009), browser auth (0010), and the reference indexes (0011), and refuses an older database. Runtime privileges remain DML-only.

0006 adds the verified Apple authentication watermark and durable provider
validation state. A verified login supersedes pending validation across all
audiences of that identity. Same-second notification/auth ordering is treated
as uncertain and validated with Apple. Indeterminate responses retain retry
state; only an authoritative invalid credential causes account invalidation.
0007 stores incomplete upload bytes on the existing capability row. Final
hash verification, explicit finalize and expiry cleanup remain server-owned.

Before cutover: retain the old image and container metadata, stop API writers,
take a custom-format PostgreSQL backup, restore it into an isolated database,
and rehearse the upgrade there. Verify recorded versions, preserved account
and work data, runtime role attestation, then start the new API and check both
trusted HTTPS health/auth responses and authenticated upload behavior.
See [operational evidence](../../ACCOUNT_RETENTION_OPERATIONS.md) for the last recorded rollout. Verify live state before the next upgrade; these instructions alone are not deployment evidence.

## Account deletion (0008)

明示削除lifecycle v1はmigration 0008を追加し、runtimeへ新tableのDMLを付与する。明示upgrade flagは上記`--upgrade-review-20260913`を使用し、既知の履歴と対象server instanceを照合する。0008追加後は旧binaryがinventory照合で拒否するため、単純なimage切戻しをしない。適用・復元・backups・検証証跡は[自動運用](../../ACCOUNT_RETENTION_OPERATIONS.md)。


## AI records and work recovery (0009)

0009 adds `assistant_records` and `recovery_operations`. Existing snapshot wire data stays unchanged. The runtime receives exact DML grants and USAGE-only access to the AI sequence; account erasure and expired-work purge include these rows. Apply with the same explicit reviewed-upgrade command, after an isolated backup restore and role attestation. A pre-0009 binary must not be restarted against the upgraded inventory. See [AI contract](assistant.md) and [rollout evidence](../../PROTECTION_AI_ACCEPTANCE.md).


## Server review fixes (0011, 2026-10-01)

Migration `0011_reference_indexes.sql` adds
`account_objects_object_id(object_id)` and
`snapshot_entries_account_object(account_id, object_id)`. The existing migrator
owns both indexes. No snapshot depth/generation column or wire change is added.
The identity inventory recognizes the exact pre-index catalog for the explicit
upgrade, rejects a partially installed pair, and the runtime requires both
valid indexes. The earlier migration files and their checksums are unchanged.
The base `postgres.sql` contract includes the additional index DDL; subsequent
feature migrations remain in their existing files. Older binaries reject the
new inventory, so rollback requires the retained backup/image pair, not merely
an image swap. No upgrade or deployment is implied by checking in this change.

Runtime resource limits (per server process):

- PostgreSQL pool: 10 connections, acquire timeout 5 seconds. Each new connection
  sets `statement_timeout = '30s'`, covering sync/auth/worker statements and lock
  waits on that shared pool. These are statement limits, not an end-to-end request
  deadline. The separate DDL migrator pool does not inherit runtime timeouts.
- Download: two concurrent handlers, including authentication, DB reads, digest
  checks and response serialization. A saturated handler returns existing 503
  `retryable` without waiting for a permit. Upload retains its separate two slots.
- Download metadata: per-repository cache of at most four account/work/root
  closures for 30 seconds, at most 100,000 identities each, containing only IDs
  and sizes, never manuscript bytes or authorization decisions. Cold pages expand
  ancestry/entries once; warm pages reuse metadata. Oversized closures remember
  only a short-lived bypass marker and use the bounded uncached query. There is
  no history truncation. Work visibility is checked before any cache read, and
  object availability is rechecked per page, in one repeatable-read, read-only
  transaction. At most two `ANY` queries fetch the selected payloads.
- Lineage: one ancestry check visits at most 100,000 distinct snapshots and stops
  immediately at the requested ancestor. This is not a maximum retained history
  or generation number. `UNION` deduplicates merges and terminates even corrupt
  cycles; a missing ancestor remains `NotAncestor`, and exhausted budget fails
  closed as `lineageViolation`. Parent existence plus the manifest hash prevents
  cycles through the registration API. The separately documented 100,000-object
  graph budget is a different limit.
- Blob deletion requires absence of both account ownership and **any** upload
  capability referencing that ObjectID, including prepared/in-flight, uploaded,
  finalized and expired rows. This change adds no orphan sweep or pruning policy.

The default tracing filter is `info` when `RUST_LOG` is unset; Compose explicitly
uses `${RUST_LOG:-info}`. HTTP completion logs contain only method, matched route
**template**, status and elapsed milliseconds (through response construction).
Database-to-503 warnings contain SQLSTATE and a fixed error category only (for
example `pool_timeout`), never PostgreSQL messages,
details, bind values, headers, cursors, tokens or bodies.

## HTTP compression and URLSession

Caddy uses `encode gzip`, negotiated via the request's `Accept-Encoding`, with
an explicit response matcher for `application/vnd.fuminiwa.sync.v2+jcs` and
`application/json` (including parameter suffixes). Binary object responses use
`application/octet-stream` and are excluded, avoiding re-compression of images
or compressed attachments. Default Caddy minimum-size behavior still applies.
See the [Caddy encode reference](https://caddyserver.com/docs/caddyfile/directives/encode).

Gzip is supported by URLSession's HTTP content decoding; the Data delivered to
the client is the decoded canonical payload, which is what digest validation
must hash. Do not compare compressed Content-Length to decoded Data length or
add a second gzip decode. Apple documents URLSession's gzip/Brotli support in
[WWDC18 session 714](https://developer.apple.com/videos/play/wwdc2018/714/).
Zstd is deliberately not enabled here because older URLSession versions may not
support it. The application media type, JCS bytes, digests, page ordering,
limits and cursor format are unchanged.

On a Mac permitting loopback listeners, run
`python3 SyncServerV2/scripts/verify-urlsession-gzip.py` from the repository root.
It serves only a synthetic checked-in fixture on an ephemeral `127.0.0.1` port,
checks URLSession's gzip negotiation, and compares returned bytes and SHA-256
with the uncompressed fixture. This is a client transport smoke test, not a
Caddy deployment or device-acceptance gate. Restricted sandboxes which deny
local socket bind cannot execute the transport portion of this test.
