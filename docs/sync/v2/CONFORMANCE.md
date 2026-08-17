# v2 conformance and red-team checks

The following checks are the minimum document-only gate. The independent Swift
and Rust runners must additionally exercise every scenario fixture without
sharing canonicalization or state-machine code.

## Rust HTTP source-to-test map

The opt-in PostgreSQL gate is the only test that exercises the Axum routes
against a database. Without a fresh disposable `FUMINIWA_V2_TEST_DATABASE_URL`
it remains an explicit NO-GO/skip and does not connect anywhere.

| Contract area | Rust source | Test/evidence |
| --- | --- | --- |
| Authenticated AccountID/Fence/epoch headers before lookup | `SyncServerV2/src/http.rs` (`principal`, `command_inner`) | `tests/integration_gate.rs` foreign/absent resource equality and missing-scope checks |
| Exact JCS request/response media type and no-store headers | `SyncServerV2/src/http.rs` (`require_media_type`, `error_response`, `canonical_response`) | `src/http.rs` unit tests; integration gate response headers |
| Canonical command parsing and closed result unions | `SyncServerV2/src/application.rs`; `src/postgres.rs` response validation | `tests/domain.rs`; `tests/fixtures.rs` |
| Raw manifest BYTEA digest/round-trip | `src/postgres.rs` register/manifest; `src/http.rs` manifest | `tests/fixtures.rs`; opt-in repository + HTTP gate |
| Receipt lookup, exact replay, and read-back predicates | `src/postgres.rs` receipt lookup/complete; `src/http.rs` receipt | `tests/domain.rs`; `tests/fixtures.rs`; opt-in HTTP gate |
| Catalog/history pagination and sealed cursors | `src/http.rs` list/history/cursor helpers | opt-in HTTP gate cursor continuation checks |
| One active conflict and closed useDevice/useServer/keepBoth/restore results | `src/postgres.rs` publish/resolve/restore; `src/application.rs` payload validation | `tests/fixtures.rs`; opt-in repository scenarios and stale-resolution HTTP check |
| Foreign/absent 404 non-disclosure and body/path bounds | `src/http.rs` scope, digest/UUID parsing, body limits | opt-in HTTP gate; `tests/domain.rs` canonical/schema bounds |

```sh
find docs/sync/v2 -name '*.json' -print0 | xargs -0 -n1 jq -e . >/dev/null
ruby -e 'require "yaml"; YAML.safe_load(File.read("docs/sync/v2/openapi.yaml"), aliases: true)'
python3 - <<'PY'
import base64
import hashlib
import json
import sqlite3
from pathlib import Path

import yaml
from jsonschema import Draft202012Validator

root = Path("docs/sync/v2")
canonical_root = root / "fixtures/canonical"


class UniqueKeyLoader(yaml.SafeLoader):
    pass


def construct_unique_mapping(loader, node, deep=False):
    mapping = {}
    for key_node, value_node in node.value:
        key = loader.construct_object(key_node, deep=deep)
        if key in mapping:
            raise AssertionError(f"duplicate YAML key: {key}")
        mapping[key] = loader.construct_object(value_node, deep=deep)
    return mapping


UniqueKeyLoader.add_constructor(
    yaml.resolver.BaseResolver.DEFAULT_MAPPING_TAG, construct_unique_mapping
)


def read_json(path):
    return json.loads(path.read_bytes())


def simple_fixture_jcs(value):
    return json.dumps(
        value, ensure_ascii=False, separators=(",", ":"), sort_keys=True
    ).encode()


for path in root.rglob("*.schema.json"):
    Draft202012Validator.check_schema(read_json(path))

snapshot_schema = Draft202012Validator(read_json(root / "snapshot.schema.json"))
command_schema = Draft202012Validator(read_json(root / "command.schema.json"))
expected_model_schema = Draft202012Validator(
    read_json(root / "expected-model.schema.json")
)
snapshot_bytes = (canonical_root / "snapshot.json").read_bytes()
snapshot = read_json(canonical_root / "snapshot.json")
snapshot_schema.validate(snapshot)
expected_model = read_json(canonical_root / "expected-model.json")
expected_model_schema.validate(expected_model)

entity_map = read_json(canonical_root / "entity-fixture-map.json")
for row in entity_map["fixtures"]:
    schema = Draft202012Validator(
        read_json(root / "entity-schemas" / row["schema"])
    )
    model = read_json(canonical_root / "objects" / row["file"])
    schema.validate(model)

scenario_schema = Draft202012Validator(read_json(root / "scenario.schema.json"))
for path in (root / "fixtures/scenarios").glob("*.json"):
    scenario_schema.validate(read_json(path))

for fixture, digest_file in [
    ("snapshot.json", "snapshot.sha256"),
    ("publish-command.json", "publish-command.sha256"),
]:
    exact = (canonical_root / fixture).read_bytes()
    assert not exact.endswith(b"\n"), fixture
    assert exact == simple_fixture_jcs(json.loads(exact)), fixture
    expected = (canonical_root / digest_file).read_text().strip()
    assert hashlib.sha256(exact).hexdigest() == expected, fixture

response_index = read_json(canonical_root / "responses/response-hashes.json")
response_models = read_json(canonical_root / "responses/expected-response-models.json")
assert response_index["schemaVersion"] == 2
assert len(response_index["responses"]) == 12
assert {row["commandKind"] for row in response_index["responses"]} == {
    "cloneWork", "createWork", "finalizeObject", "prepareObject", "publish",
    "registerSnapshot", "resolveDevice", "resolveServer", "restore",
}
for row in response_index["responses"]:
    exact_path = canonical_root / "responses" / row["file"]
    exact = exact_path.read_bytes()
    assert not exact.endswith(b"\n"), row["file"]
    decoded = json.loads(exact)
    assert exact == simple_fixture_jcs(decoded), row["file"]
    assert len(exact) == row["byteCount"], row["file"]
    assert hashlib.sha256(exact).hexdigest() == row["sha256"], row["file"]
    assert hashlib.sha256(exact).hexdigest() == (
        exact_path.with_suffix(exact_path.suffix + ".sha256").read_text().strip()
    )
    assert decoded["commandKind"] == row["commandKind"]
    assert decoded["result"] == row["result"]
    assert response_models[row["file"]] == {
        key: value for key, value in decoded.items() if key != "receipt"
    }
    assert decoded["receipt"]["commandId"] == decoded["commandId"]
    assert decoded["receipt"]["commandKind"] == decoded["commandKind"]
    assert decoded["receipt"]["readBack"] == {
        "accountMatched": True,
        "commandDigestMatched": True,
        "headMatched": True,
        "resourceMatched": True,
        "stateMatched": True,
    }
    assert row["status"] in {200, 201, 409}
    if row["result"] in {"noChanges", "conflictPending"}:
        assert row["status"] in {200, 409}
    if row["commandKind"] == "createWork":
        assert decoded["head"] is None and row["status"] == 201
    if row["commandKind"] in {"finalizeObject", "registerSnapshot"}:
        assert decoded["head"] is None and row["status"] == 200

receipt_bytes = (canonical_root / "receipts/publish-applied.json").read_bytes()
receipt = json.loads(receipt_bytes)
assert not receipt_bytes.endswith(b"\n")
assert receipt_bytes == simple_fixture_jcs(receipt)
assert receipt["originalResponseStatus"] == 200
assert receipt["originalResult"] == "applied"
replayed = base64.urlsafe_b64decode(
    receipt["canonicalResponseBase64URL"] + "=" * (-len(receipt["canonicalResponseBase64URL"]) % 4)
)
assert replayed == (canonical_root / "responses/publish-applied.json").read_bytes()
assert hashlib.sha256(replayed).hexdigest() == "a953f5e4d7f72a371312b44639f689910aca814be4cf66c428a432b815da9648"
assert hashlib.sha256(receipt_bytes).hexdigest() == (
    (canonical_root / "receipts/publish-applied.json.sha256").read_text().strip()
)

command_rows = read_json(canonical_root / "command-hashes.json")["commands"]
assert {row["commandKind"] for row in command_rows} == {
    "cloneWork",
    "createWork",
    "finalizeObject",
    "prepareObject",
    "publish",
    "registerSnapshot",
    "resolveDevice",
    "resolveServer",
    "restore",
}
for row in command_rows:
    exact = (canonical_root / row["file"]).read_bytes()
    command = json.loads(exact)
    assert not exact.endswith(b"\n"), row["file"]
    assert exact == simple_fixture_jcs(command), row["file"]
    assert len(exact) == row["byteCount"], row["file"]
    assert hashlib.sha256(exact).hexdigest() == row["requestDigest"], row["file"]
    assert command["commandKind"] == row["commandKind"]
    command_schema.validate(command)

register = read_json(canonical_root / "commands/register-snapshot.json")
encoded = register["payload"]["manifestBase64URL"]
decoded = base64.urlsafe_b64decode(encoded + "=" * (-len(encoded) % 4))
assert decoded == snapshot_bytes
assert hashlib.sha256(decoded).hexdigest() == register["payload"]["snapshotId"]
assert register["payload"]["manifestBytesDigest"] == register["payload"]["snapshotId"]

clone_hashes = read_json(canonical_root / "clone-derived-hashes.json")
clone_document_bytes = (canonical_root / clone_hashes["document"]["file"]).read_bytes()
clone_snapshot_bytes = (canonical_root / clone_hashes["snapshot"]["file"]).read_bytes()
assert not clone_document_bytes.endswith(b"\n")
assert not clone_snapshot_bytes.endswith(b"\n")
assert len(clone_document_bytes) == clone_hashes["document"]["byteCount"]
assert hashlib.sha256(clone_document_bytes).hexdigest() == clone_hashes["document"]["objectId"]
assert len(clone_snapshot_bytes) == clone_hashes["snapshot"]["byteCount"]
assert hashlib.sha256(clone_snapshot_bytes).hexdigest() == clone_hashes["snapshot"]["snapshotId"]
assert clone_document_bytes == simple_fixture_jcs(json.loads(clone_document_bytes))
assert clone_snapshot_bytes == simple_fixture_jcs(json.loads(clone_snapshot_bytes))
clone_snapshot = json.loads(clone_snapshot_bytes)
snapshot_schema.validate(clone_snapshot)
clone_command = read_json(canonical_root / "commands/clone-work.json")
derived_clone = json.loads(snapshot_bytes)
derived_clone["workId"] = clone_command["payload"]["newWorkId"]
derived_clone["parentSnapshotIds"] = []
clone_document = json.loads(clone_document_bytes)
assert clone_document["documentId"] == clone_command["payload"]["newDocumentId"]
clone_document_entry = next(
    entry for entry in derived_clone["entries"] if entry["entityKey"] == "work/document"
)
clone_document_entry["objectId"] = clone_hashes["document"]["objectId"]
clone_document_entry["byteCount"] = clone_hashes["document"]["byteCount"]
assert simple_fixture_jcs(derived_clone) == clone_snapshot_bytes
assert clone_command["payload"]["newRootSnapshotId"] == clone_hashes["snapshot"]["snapshotId"]

object_rows = read_json(canonical_root / "object-hashes.json")["objects"]
objects_by_digest = {row["objectId"]: row for row in object_rows}
objects_by_file = {row["file"]: row for row in object_rows}
assert len(objects_by_digest) == len(object_rows) == len(objects_by_file)
for row in object_rows:
    exact = (canonical_root / "objects" / row["file"]).read_bytes()
    assert not exact.endswith(b"\n"), row["file"]
    assert len(exact) == row["byteCount"], row["file"]
    assert hashlib.sha256(exact).hexdigest() == row["objectId"], row["file"]
    if row["file"].endswith(".json"):
        assert exact == simple_fixture_jcs(json.loads(exact)), row["file"]

keys = [entry["entityKey"] for entry in snapshot["entries"]]
assert keys == sorted(keys) and len(keys) == len(set(keys))
mandatory = {
    "work/document",
    "work/title",
    "work/synopsis",
    "work/chapter-order",
    "work/character-order",
    "work/plot-card-order",
    "work/flag-order",
    "work/world-note-order",
    "work/attachment-order",
}
assert mandatory <= set(keys)
entries = {entry["entityKey"]: entry for entry in snapshot["entries"]}
for entry in snapshot["entries"]:
    object_row = objects_by_digest[entry["objectId"]]
    assert entry["byteCount"] == object_row["byteCount"], entry["entityKey"]


def entity(entity_key):
    row = objects_by_digest[entries[entity_key]["objectId"]]
    return read_json(canonical_root / "objects" / row["file"])


document = expected_model["document"]
assert snapshot["workId"] == expected_model["workId"]
assert entity("work/document") == {
    "documentCreatedAt": document["documentCreatedAt"],
    "documentId": document["id"],
}
assert entity("work/title")["value"] == document["title"]
assert entity("work/synopsis")["value"] == document["synopsis"]
assert entity("work/chapter-order")["ids"] == [x["id"] for x in document["chapters"]]
assert entity("work/character-order")["ids"] == [x["id"] for x in document["characters"]]
assert entity("work/plot-card-order")["ids"] == [x["id"] for x in document["plotCards"]]
assert entity("work/flag-order")["ids"] == [x["id"] for x in document["flags"]]
assert entity("work/world-note-order")["ids"] == [x["id"] for x in document["worldNotes"]]
assert entity("work/attachment-order")["ids"] == [x["attachmentId"] for x in expected_model["attachments"]]

accounted = set(mandatory)
for chapter in document["chapters"]:
    chapter_prefix = f"chapter/{chapter['id']}"
    assert entity(f"{chapter_prefix}/title")["value"] == chapter["title"]
    assert entity(f"{chapter_prefix}/episode-order")["ids"] == [
        episode["id"] for episode in chapter["episodes"]
    ]
    accounted |= {f"{chapter_prefix}/title", f"{chapter_prefix}/episode-order"}
    for episode in chapter["episodes"]:
        episode_prefix = f"episode/{episode['id']}"
        for key, field in [("title", "title"), ("body", "content"), ("memo", "memo")]:
            assert entity(f"{episode_prefix}/{key}")["value"] == episode[field]
            accounted.add(f"{episode_prefix}/{key}")
for collection, prefix in [
    ("characters", "character"),
    ("plotCards", "plot-card"),
    ("flags", "flag"),
    ("worldNotes", "world-note"),
]:
    for value in document[collection]:
        key = f"{prefix}/{value['id']}"
        assert entity(key) == value
        accounted.add(key)
for attachment in expected_model["attachments"]:
    prefix = f"attachment/{attachment['attachmentId']}"
    metadata = entity(f"{prefix}/metadata")
    assert metadata == {
        "attachmentId": attachment["attachmentId"],
        "byteCount": attachment["byteCount"],
        "fileName": attachment["fileName"],
    }
    raw_entry = entries[f"{prefix}/bytes"]
    assert raw_entry["objectId"] == attachment["objectId"]
    assert raw_entry["byteCount"] == attachment["byteCount"]
    accounted |= {f"{prefix}/metadata", f"{prefix}/bytes"}
assert accounted == set(entries)

openapi = yaml.load((root / "openapi.yaml").read_text(), Loader=UniqueKeyLoader)
refs = []


def collect_refs(value):
    if isinstance(value, dict):
        for key, child in value.items():
            if key == "$ref":
                refs.append(child)
            collect_refs(child)
    elif isinstance(value, list):
        for child in value:
            collect_refs(child)


collect_refs(openapi)
for ref in refs:
    if ref.startswith("#/"):
        target = openapi
        pointer = ref[2:]
    elif ref.startswith("./"):
        file_name, fragment = (ref.split("#", 1) + [""])[:2]
        target = read_json(root / file_name[2:])
        pointer = fragment[1:] if fragment.startswith("/") else fragment
    else:
        continue
    for raw in pointer.split("/") if pointer else []:
        key = raw.replace("~1", "/").replace("~0", "~")
        target = target[int(key)] if isinstance(target, list) else target[key]
operation_ids = []
for path_item in openapi["paths"].values():
    for method, operation in path_item.items():
        if method in {"get", "post", "put", "patch", "delete"}:
            operation_ids.append(operation["operationId"])
            assert "default" in operation["responses"]
assert len(operation_ids) == len(set(operation_ids))
assert "/v2/uploads/{uploadId}" in openapi["paths"]
assert "PublishResponse" in openapi["components"]["responses"]
schemas = openapi["components"]["schemas"]
assert "CommandResult" not in schemas
assert schemas["Receipt"]["properties"]["originalResponseStatus"]["enum"] == [200, 201, 409]
assert "originalResponseStatus" in schemas["Receipt"]["required"]
assert schemas["Receipt"]["properties"]["originalResult"]["enum"] == ["noChanges", "applied", "conflictPending"]
for schema_name in [
    "CreateWorkResponse", "PrepareObjectNoChanges", "PrepareObjectApplied",
    "FinalizeObjectResponse", "RegisterSnapshotResponse", "PublishNoChangesResponse", "PublishAppliedResponse",
    "PublishConflictPendingResponse", "ResolveDeviceResponse", "ResolveServerResponse",
    "CloneWorkResponse", "RestoreResponse",
]:
    assert schemas[schema_name]["additionalProperties"] is False
assert "headMatched" in schemas["ReadBackPredicate"]["required"]
assert "sourceGeneration" in schemas["Conflict"]["required"]
assert schemas["Conflict"]["properties"]["sourceGeneration"]["minimum"] == 1
assert "workId" in schemas["CommandReceipt"]["required"]
assert "workId" in schemas["Receipt"]["required"]
for path, method, status, response_name in [
    ("/v2/works", "post", "201", "CreateWorkResponse"),
    ("/v2/objects/finalize", "post", "200", "FinalizeObjectResponse"),
    ("/v2/snapshots/register", "post", "200", "RegisterSnapshotResponse"),
    ("/v2/works/{workId}/publish", "post", "200", "PublishResponse"),
    ("/v2/works/{workId}/publish", "post", "409", "PublishConflictPendingResponse"),
    ("/v2/works/{workId}/conflict/resolve", "post", "200", "ConflictResolutionResponse"),
    ("/v2/works/{workId}/restore", "post", "200", "RestoreResponse"),
]:
    assert openapi["paths"][path][method]["responses"][status]["$ref"].endswith(response_name)

conflict_scenario = read_json(root / "fixtures/scenarios/conflict-three-choice.json")
assert conflict_scenario["initial"]["sourceGeneration"] > 0
assert all(event["sourceGeneration"] > 0 for event in conflict_scenario["events"])
assert conflict_scenario["expect"]["sourceGeneration"] == conflict_scenario["events"][-1]["sourceGeneration"]

postgres = (root / "postgres.sql").read_text()
tenant_tables = {
    "works",
    "account_objects",
    "snapshots",
    "snapshot_parents",
    "snapshot_entries",
    "upload_capabilities",
    "receipts",
    "sealed_commands",
    "active_conflicts",
    "conflict_candidates",
    "conflict_events",
    "history",
    "restore_receipts",
    "head_events",
    "catalog_events",
    "quarantine_records",
}
for table in tenant_tables:
    start = postgres.index(f"CREATE TABLE sync_v2.{table} (")
    end = postgres.index("\n);", start)
    block = postgres[start:end]
    assert "account_id TEXT NOT NULL" in block, table
    assert "PRIMARY KEY (account_id," in block, table
for required in [
    "FOREIGN KEY (account_id, work_id, parent_snapshot_id)",
    "REFERENCES sync_v2.account_objects(account_id, object_id)",
    "UNIQUE (account_id, work_id, conflict_id)",
    "PRIMARY KEY (account_id, command_id)",
    "export_backup_marker TEXT",
    "adoption_marker TEXT",
    "migration_staging_batches",
    "migration_staging_objects",
    "'createWork', 'prepareObject'",
    "CHECK ((head_snapshot_id IS NULL) = (head_generation IS NULL))",
    "UNIQUE (account_id, work_id, command_id, command_kind)",
    "FOREIGN KEY (account_id, work_id, command_id)",
    "source_generation BIGINT NOT NULL CHECK (source_generation > 0)",
    "quarantined_from_state TEXT",
    "export_backup_marker IS NOT NULL",
    "adoption_marker IS NOT NULL",
    "command_scope = 'cloneNewWork'",
]:
    assert required in postgres, required

sqlite = (root / "sqlite.sql").read_text()
for required in [
    "(acknowledged_head_snapshot_id IS NULL) =",
    "(acknowledged_head_generation IS NULL)",
    "UNIQUE (account_id, work_id, command_id)",
    "REFERENCES sealed_commands(account_id, work_id, command_id)",
    "source_generation INTEGER NOT NULL CHECK (source_generation > 0)",
    "quarantined_from_state TEXT",
    "export_backup_marker IS NOT NULL",
    "adoption_marker IS NOT NULL",
]:
    assert required in sqlite, required

db = sqlite3.connect(":memory:")
db.executescript(sqlite)


def ledger(values):
    db.execute(
        """INSERT INTO migration_ledger(
        migration_id, account_id, source_kind, source_digest,
        export_backup_marker, adoption_marker, quarantined_from_state,
        evidence_bytes, state
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)""",
        values,
    )


valid_ledger_rows = [
    ("m1", None, "v1", b"1", None, None, None, b"e", "discovered"),
    ("m2", None, "v1", b"2", "backup", None, None, b"e", "backupExported"),
    ("m3", "account-a", "v1", b"3", "backup", None, None, b"e", "verified"),
    ("m4", "account-a", "v1", b"4", "backup", "adopt", None, b"e", "committed"),
    ("m5", None, "v1", b"5", None, None, "discovered", b"e", "quarantined"),
    ("m6", None, "v1", b"6", "backup", None, "staged", b"e", "quarantined"),
]
for row in valid_ledger_rows:
    ledger(row)
db.commit()


def rejected(statement, parameters):
    try:
        db.execute(statement, parameters)
        db.commit()
    except sqlite3.IntegrityError:
        db.rollback()
        return
    raise AssertionError(parameters)


insert_ledger = """INSERT INTO migration_ledger(
migration_id, account_id, source_kind, source_digest,
export_backup_marker, adoption_marker, quarantined_from_state,
evidence_bytes, state
) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)"""
for row in [
    ("x1", None, "v1", b"x1", None, None, None, b"e", "backupExported"),
    ("x2", "account-a", "v1", b"x2", "backup", None, None, b"e", "committed"),
    ("x3", None, "v1", b"x3", "backup", "adopt", None, b"e", "staged"),
    ("x4", None, "v1", b"x4", None, None, "staged", b"e", "quarantined"),
    ("x5", None, "v1", b"x5", "backup", None, "verified", b"e", "quarantined"),
]:
    rejected(insert_ledger, row)

db.execute(
    "INSERT INTO works(work_id, document_id, document_created_at) VALUES (?, ?, ?)",
    ("work-ok", "doc-ok", "2026-08-17T00:00:00Z"),
)
db.commit()
rejected(
    """INSERT INTO works(
    work_id, document_id, document_created_at, acknowledged_head_snapshot_id
    ) VALUES (?, ?, ?, ?)""",
    ("work-bad", "doc-bad", "2026-08-17T00:00:00Z", bytes(32)),
)

print("v2 JSON/schema/hash/OpenAPI/DDL static checks passed")
PY
sqlite3 :memory: < docs/sync/v2/sqlite.sql
git diff --check -- docs/DECISIONS.md docs/SNAPSHOT_SYNC_V2.md docs/sync/v2
```

The production conformance runner must add byte-for-byte RFC 8785 JCS,
duplicate-member rejection, I-JSON safe-number checks, UTF-8/surrogate
rejection, self-parent/cycle/other-work lineage rejection, PostgreSQL migration
execution against an empty supported server, exact response receipt replay,
account/fence non-disclosure, upload capability binding, CAS current+generation
rejection, one-active-conflict revision append, and process-kill migration
markers. These are represented by the scenario fixtures and are not optional
semantic extensions of JSON Schema. The static PostgreSQL assertions above do
not replace executing `postgres.sql` in the Rust integration Gate.
