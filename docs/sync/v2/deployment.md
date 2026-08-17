# v2 Docker and database namespace

The development deployment is a new Compose project/service revision that
mounts exactly one named data volume for v2 PostgreSQL:

```text
API prefix:       /v2
PostgreSQL volume fuminiwa_sync_v2_pgdata
auth schema:      auth_v1 (separate owner/role)
sync schema:      sync_v2 (separate owner/role)
object bytes:     sync_v2.global_blobs.raw_bytes BYTEA
```

It does not mount a v1 PostgreSQL volume, legacy object directory, package
root, or CloudKit credential. Startup fails if the configured database lacks
the v2 schema checksum/protocol epoch or points at a known v1 volume/schema.
The live service never runs an archive migration automatically.

`PostgresObjectStore` is the only initial `ObjectStore` implementation. A
future S3 adapter requires a new versioned deployment manifest, data-copy plus
read-back migration, rollback evidence, and a later Decision. It is not an
ambient environment-variable switch in this deployment.
