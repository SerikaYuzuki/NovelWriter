# v1/archive to v2 migration evidence

Migration has two separate products and success boundaries:

1. **Export backup projection** reads legacy v1/package data and produces a
   verified, read-only backup artifact plus evidence. The current
   `Tools/SnapshotSyncV2Migration` work is this phase only; its success never
   means a Work was adopted into v2.
2. **v2 adoption** consumes a verified backup artifact, stages a new v2
   Work/Snapshot/object closure in the client SQLite store, verifies the
   logical model/account scope, and writes a separate adoption marker
   transaction. This client adoption path is the only implemented cutover
   path.

Both are explicit, offline, resumable operations. The live v2 runtime never
opens the archive reader. Each source is represented in `migration_ledger`
with source kind/digest, exact evidence, `export_backup_marker`, and a distinct
`adoption_marker`. The successful sequence is:

```text
discovered -> backupExported -> staged -> verified -> committed
                         `-> quarantined
```

The ledger encodes marker/state correspondence rather than relying on runner
convention. `discovered` has neither marker. `backupExported`, `staged`, and
`verified` require a non-empty `export_backup_marker` and forbid an adoption
marker. `committed` requires both non-empty markers. `quarantined` requires
`quarantined_from_state`, never has an adoption marker, and retains the export
marker exactly when its origin was `backupExported`, `staged`, or `verified`;
a quarantine originating at `discovered` has no export marker. A quarantine
from `verified` also retains its verified AccountID. Empty strings do not
satisfy any marker requirement.

`staged` copies exact manifest/object bytes to
`migration_staging_batches`/`migration_staging_objects` without changing the
source. Those tables intentionally have no FK to authoritative Work,
Snapshot, object, or account-binding rows, so a not-yet-adopted Work can be
resumed safely after a crash. They are never exposed by the live HTTP API.
`verified` requires the source hash, object byte count, schema, account scope,
portable projection, and every referenced object to read back successfully.
Any invalid UTF-8, unknown account scope, duplicate identity, symlink, digest
mismatch, or unsupported payload goes to `quarantined` with evidence and never
becomes a v2 Work. A migration run has exactly one declared target database:

## External provenance authority

The stage's `migration-ledger.json`, `migration-run.json`, `.state/`, and
`COMMITTED` marker are untrusted projections. A committing client must also be
given an operator-provided, canonical JSON authority file outside the stage and
outside the target database. The CLI requires all of:

```text
--trusted-authority-root <authority-root>
--trusted-authority <authority-root/provenance.json>
--expected-authority-digest <sha256 of canonical bytes>
--expected-authority-id <operator authority identity>
```

The authority root and file must resolve without symlinks, the file must be a
regular file contained by the root, and neither may overlap the stage or target
root. The adopter rehashes and canonical-decodes the authority before staging
and again immediately before the SQLite commit. A path swap, symlink, changed
canonical bytes, changed authority ID, or changed expected digest fails closed.

The authority records the source SQLite digest, source archive-manifest digest,
classification-ledger digest, and an exact entry for each WorkID. Each entry
must match the package tree digest, snapshot ID, projection digest, and
path-independent canonical inventory-evidence digest. The stage report's
matching fields are insufficient on their own.

The v2 provenance contract keeps the two snapshot identities disjoint:
`sourceWireSnapshotID` and `sourceWireSnapshotDigest` identify the legacy
SQLite manifest read independently by the exporter, while
`adoptionSnapshotID` and `adoptionProjectionDigest` are recomputed from the
package read-back that the adopter will commit. `snapshotID` and
`projectionDigest` remain compatibility aliases only; they cannot substitute
for either side of the contract. The source row also carries an exact
`sourceProjectionDigest` (versioned separately from adoption) and
`sourceObjectClosureSHA256`. `inventoryEvidenceSHA256` is the SHA-256 of the
canonical path-independent inventory evidence, including regular files,
directories (including empty directories), byte counts, object IDs, and
portable-resource metadata. A report, run file, sidecar, or self-generated
matching digest is never sufficient without this independent source/package
comparison.

The source and adoption projection digests are independent authorities and
must not be compared with each other. The builder carries both typed/versioned
values through the export report, state sidecar, source SQLite evidence, and
authority entry. It also carries and independently checks all eight literal
classification columns against the SQLite work/snapshot rows and acknowledged
heads; a non-empty operator evidence value is retained exactly.

`verified_candidate` is an adoption candidate only. It is never equivalent to
the authority disposition `verified`; an authority entry with
`verified_candidate`, `quarantine`, or `needs-review` is rejected by the client
adopter even when a copied package is placed under `verified/` and the stage
report is rewritten.

The standalone `snapshot-sync-v2-authority-builder` creates this authority
from an existing committed stage. It takes the stage root, the stage-external
literal classification CSV, the read-only legacy archive root and manifest,
and the read-only source SQLite. The operator must provide expected SHA-256
values for all three external evidence files, the expected Work count, and a
separate authority identity. It validates all input realpaths, regular-file /
directory types, symlink absence, non-writable state, committed stage
report/run, literal classification, and every package's tree/projection/
path-independent inventory evidence before creating a new authority root.
The builder never modifies the stage or source archive; an existing or
overlapping output root, input tamper, or output race fails closed.

Every archive-manifest path is resolved to a realpath and checked for a
portable Unicode/case-fold collision key and filesystem device/inode identity.
An alias, hardlink collision, symlink, or duplicate source-SQLite entry is
rejected. A committed stage whose content still matches the immutable source
may resume an interrupted read-only seal; a mismatch fails before resealing.

The exporter atomically writes `COMMITTED` only after all works and issue lists
pass, then seals the complete stage tree read-only (`0444` files and `0555`
directories). The builder rehashes the report, run, marker, every sidecar and
package tree, plus the classification CSV, source SQLite, and archive manifest
again immediately before creating a sibling temporary authority root. That
root is fully verified and sealed before an atomic same-filesystem rename to
the final root; a failed attempt cleans only its owned temporary root and
leaves a pre-existing final root unchanged. The adopter repeats
authority and package read-back after its final commit hook and only then opens
the SQLite commit transaction. A failed or partially writable seal is not an
authority.

The standalone package also inventories every non-hidden tree entry, including
empty directories and opaque/orphan files. Each entry records its normalized
relative path, kind, byte count, SHA-256/ObjectID (for files), and empty-directory
flag. The v2 client SQLite schema now has a local-only resource CAS and
`work_resources` path mirror. A validated resource inventory may therefore be
adopted into the client Work in the same transaction as its first Snapshot;
resource bytes remain outside Snapshot identity and are never sent by the v2
online wire. A missing digest, unsafe path, duplicate/collision, symlink, or
unsupported item still fails closed into quarantine. Server/operator adoption
does not infer ownership of local-only resources and must retain its existing
quarantine behavior until a separate remote-resource contract is adopted.

- **client SQLite adoption** revalidates the staged closure, adds the local
  WorkID/first Snapshot and adoption marker in one SQLite transaction, then
  later publishes through `createWork` -> object prepare/upload/finalize ->
  register -> publish;
- **operator-only PostgreSQL adoption** is not implemented and is not reachable
  from the live HTTP API. The server must not be populated by a direct
  migration runner; after client SQLite adoption, the normal authenticated
  `createWork` -> object prepare/upload/finalize -> register -> publish wire
  path is the only server onboarding path. Direct PostgreSQL adoption remains
  NO-GO until a separately reviewed operator contract exists.

The SQLite ledger/staging tables belong to the client adoption run and are not
server authority. The original work is not rebound or deleted, and staging is
never live authority.

`account_id` remains nullable until independently verified. An unknown or
ambiguous account can only enter `quarantined`; it cannot be committed,
uploaded, or inferred from title/path/device/login timing.

The adoption marker is written only after the SQLite transaction commit and
BLOB read-back. On crash, an uncommitted marker is retried from staging or
moved to quarantine; it is never treated as imported merely because files
exist. A failed migration cannot create an empty replacement database.
