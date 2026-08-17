# v2 Docker and database namespace

The development deployment is a new Compose project/service revision that
mounts one named data volume for v2 PostgreSQL. The edge service additionally
uses two named Caddy state volumes; those are not database or application
data authorities:

```text
API prefix:       /v2
PostgreSQL volume fuminiwa-sync-v2-data
auth schema:      auth_v1 (separate schema namespace)
sync schema:      sync_v2 (separate schema namespace)
object bytes:     sync_v2.global_blobs.raw_bytes BYTEA
```

The checked-in Compose file currently bootstraps both schemas with one
PostgreSQL role. This is an intentional, audited limitation of the current
revision: separate database owners/roles are **NO-GO for this deployment
change**. A fresh-only bootstrap would need file-backed credentials, an
explicit migration-owner service, runtime grants, and authenticated
read-back. The server currently opens one SQLx pool for both migrations and
runtime queries, and existing v2 objects are owned by the current role;
splitting those roles without a versioned, non-destructive ownership/grants
migration would either break startup or require destructive rewriting. Do not
weaken startup or claim role isolation until that blocker is resolved in a
separate deployment revision.

It does not mount a v1 PostgreSQL volume, legacy object directory, package
root, or CloudKit credential. Startup fails if the configured database lacks
the v2 schema checksum/protocol epoch or points at a known v1 volume/schema.
The live service never runs an archive migration automatically. Before
running SQLx migrations, startup accepts only a genuinely fresh database or
an existing exact v2 `sync_v2.server_meta` marker (with SQLx's own migration
bookkeeping allowed). Legacy, partial, nonempty, and unrecognized user
schemas fail closed, and the guard is read-only so a rejection leaves the
database unchanged.

Startup takes one deployment-wide PostgreSQL session advisory lock before
reading that inventory. The lock ordering is fixed: acquire the advisory
lock, inspect the complete identity inventory, run SQLx migrations, then
verify `server_meta` and the singleton deployment binding; release the lock
only after the final verification succeeds. The checked-out session keeps the
lock across all phases, and the SQLx advisory-lock guard releases it when that
session is returned or closed on every error path. Every v2 server startup uses
the same key, so a concurrent startup cannot pass the pre-migration check and create or
accept an unknown DDL object in the guard-to-migration window.

`PostgresObjectStore` is the only initial `ObjectStore` implementation. A
future S3 adapter requires a new versioned deployment manifest, data-copy plus
read-back migration, rollback evidence, and a later Decision. It is not an
ambient environment-variable switch in this deployment.
