# Snapshot Sync wire v2

This directory is the versioned **design contract** selected by D-080. It is
intentionally independent from `docs/sync/v1/`: v1 is an archive format, not a
live compatibility mode.

- **Contract status**: implementation-ready design after schema/fixture/DDL
  conformance checks. A contract defect is a design P0.
- **Implementation status**: not yet satisfied. Swift/Rust runtime, migrations,
  deployment, and device acceptance are later implementation Gates; their
  absence while this is a document-only phase is not itself a contract P0.

An implementation may claim a Gate only after its independent runner passes
the exact artifacts here. Code behavior never silently overrides this contract.

## Contract files

- `snapshot.schema.json`: closed v2 manifest envelope.
- `command.schema.json`: common sealed-command envelope.
- `wire.md`: endpoint, header, receipt, and error rules.
- `state-machine.md`: local/server transitions and invariants.
- `runtime-mode.md`: physical production/test/preview composition boundary.
- `migration.md`: verified-only archive import and crash marker contract.
- `ui-state.md`: identical macOS/iOS result projection and Japanese labels.
- `sqlite.sql` / `postgres.sql`: concrete v2 local/server DDL and lock order.
- `openapi.yaml`: v2 resource, cursor, receipt, and typed-result surface.
- `entity-schemas/`: materializable work/document, value, and order payloads.
- `entity-contract.md` / `expected-model.schema.json`: dynamic EntityKey,
  referential invariants, full NovelDocument fixture, and package round trip.
- `auth-boundary.md`: Auth v1 wire in the new v2 PostgreSQL deployment and the
  Apple credential to opaque AccountID/session boundary.
- `deployment.md`: `/v2`, `auth_v1`/`sync_v2`, and the isolated PostgreSQL
  Docker volume contract.
- `fixtures/canonical/snapshot.json`: materializable full-domain canonical
  manifest with one chapter/episode and every current metadata domain.
- `fixtures/canonical/snapshot.sha256`: SHA-256 of the exact canonical bytes.
- `fixtures/canonical/clone-derived-hashes.json`: deterministic keep-both
  replacement document/root bytes and their ObjectID/SnapshotID.
- `fixtures/canonical/command-hashes.json`: one exact canonical request and
  digest for every sealed mutating command kind.
- `fixtures/scenarios/*.json`: language-neutral state-machine acceptance cases.

The canonical bytes in the hash fixture are UTF-8, one-line JSON with no final
newline. Implementations must use RFC 8785 JCS, not `JSONSerialization` or a
JSONB round trip. The fixture is intentionally composed only of strings,
integers, arrays, and objects whose sorted JCS order is unambiguous.

## Conformance commands

```sh
jq -e . docs/sync/v2/snapshot.schema.json >/dev/null
jq -e . docs/sync/v2/command.schema.json >/dev/null
find docs/sync/v2/fixtures -name '*.json' -print0 | xargs -0 -n1 jq -e . >/dev/null
printf '%s' "$(jq -cS . docs/sync/v2/fixtures/canonical/snapshot.json)" \
  | shasum -a 256
git diff --check
```

The last command is a smoke check for this simple fixture only. The real
runner must implement RFC 8785 and compare the expected digest exactly.
