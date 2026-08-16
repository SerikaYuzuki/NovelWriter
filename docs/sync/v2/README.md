# Snapshot Sync wire v2

This directory is the versioned implementation contract selected by D-080.
It is intentionally independent from `docs/sync/v1/`: v1 is an archive
format, not a live compatibility mode.

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
- `fixtures/canonical/snapshot.json`: smallest valid canonical manifest.
- `fixtures/canonical/snapshot.sha256`: SHA-256 of the exact canonical bytes.
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
