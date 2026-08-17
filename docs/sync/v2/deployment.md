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

The v2 Compose revision uses three isolated database roles:

- `fuminiwa_sync_v2_bootstrap` exists only as the PostgreSQL image bootstrap
  administrator. It creates the two application roles and revokes PUBLIC
  database/schema defaults; it does not run application migrations.
- `fuminiwa_sync_v2_migrator` is the schema/object owner. The one-shot
  `migrator` service runs SQLx DDL, writes `_sqlx_migrations`, bootstraps
  `server_meta` and `deployment_binding`, and grants the audited runtime ACL.
- `fuminiwa_sync_v2_runtime` is the server login. It has `USAGE` on
  `auth_v1`/`sync_v2`, exact table DML (with read-only `server_meta` and
  `deployment_binding`), and `USAGE, SELECT, UPDATE` on required sequences.
  It has no database/schema CREATE, object ownership, migration-table access,
  role membership, or superuser/createdb/createrole/bypass-RLS capability.

The server opens its pool only as `fuminiwa_sync_v2_runtime`; it never invokes
SQLx migrations or writes deployment metadata. Startup performs catalog
identity, role/ACL, exact marker, and binding read-back. PostgreSQL has no
separate sequence `EXECUTE` privilege, so the sequence grant is the exact
PostgreSQL equivalent required for inserts.

Fresh bootstrap is the only path that creates roles or applies grants. A
re-run against an exact v2 volume is read-only and succeeds only when the
existing role/grant attestation is exact. Legacy, single-role, mixed, partial,
or unknown databases fail closed; the migrator never auto-ALTERs, rewrites
ownership, or grants privileges on an existing volume.

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
`fuminiwa-sync-v2-role-split-data` volume. The existing
`fuminiwa-sync-v2-data` staging volume remains untouched.

`PostgresObjectStore` is the only initial `ObjectStore` implementation. A
future S3 adapter requires a new versioned deployment manifest, data-copy plus
read-back migration, rollback evidence, and a later Decision. It is not an
ambient environment-variable switch in this deployment.
