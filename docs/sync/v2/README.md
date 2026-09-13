# Snapshot Sync wire v2

This directory is the current Snapshot Sync v2 contract. Auth v1 is a
separate live authentication protocol; retired Sync v1 is not a fallback.

- **Contract**: closed wire/schema/fixture/DDL selected by D-080 through D-085. A contract defect is a design issue; implementation behavior does not silently replace it.
- **Implementation**: Swift v2 domain/store/application/runtime and the Rust server exist. Production, device acceptance, and all integration Gates are not complete. See the [current handoff](../../SNAPSHOT_SYNC_V2_HANDOFF.md) for dated evidence and open work.

Use this directory when changing the synchronization contract. For a UI-only change, start from the shared UI projection and the app entry points instead of loading every fixture. A wire/schema change needs matching fixtures and independent conformance evidence.

- [AI feedback attachments](assistant-feedback.md): read-only dated Markdown using the existing attachment wire format.

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
- command responses are closed by command kind: `createWork`,
  `prepareObject` (`noChanges`/`applied`), `finalizeObject`,
  `registerSnapshot`, `publish` (`noChanges`/`applied`/`conflictPending`),
  `resolveDevice`, `resolveServer`, `cloneWork`, and `restore`. There is no
  generic `CommandResult`; `parked`/`retryable` are nonterminal errors and
  never carry a receipt.
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
- `fixtures/canonical/responses/`: exact one-line JCS response bodies,
  SHA-256 sidecars, and expected decode models for every terminal response
  variant. Receipt envelopes include the original HTTP status and exact
  `canonicalResponseBase64URL`.
- `fixtures/scenarios/*.json`: language-neutral state-machine acceptance cases.

The canonical bytes in the hash fixture are UTF-8, one-line JSON with no final
newline. Implementations must use RFC 8785 JCS, not `JSONSerialization` or a
JSONB round trip. The fixture is intentionally composed only of strings,
integers, arrays, and objects whose sorted JCS order is unambiguous.

## Verification entry points

Run commands from the repository root. Select the smallest check that covers the changed boundary:

```sh
python3 Scripts/conformance-v2.py       # independent canonical fixture bytes/hashes
./Scripts/check-sync-v2-boundary.sh     # live/test/archive composition
./Scripts/conformance-v2.sh            # independent Python/Swift/Rust suite
```

The independent suite intentionally disables PostgreSQL integration. Real DB transaction/role tests require separately provisioned disposable databases; see [CONFORMANCE.md](CONFORMANCE.md) and the [server README](../../../SyncServerV2/README.md). A suite pass is not staging or device acceptance.

- [作品の完全削除](work-deletion.md): scope付き削除intent、再試行、復活防止、追加DDL [work-deletion.sql](work-deletion.sql)。

現在の実装にない旧移行ツールは[取り込み・更新境界](migration.md)を参照する。
