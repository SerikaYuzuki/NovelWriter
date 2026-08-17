#!/usr/bin/env python3
"""Independent byte-level checks for the Snapshot Sync v2 contract.

This runner intentionally does not import the Swift package or Rust crate.  It
only reads the reviewed canonical fixture and verifies the bytes, digests, and
closed fixture indexes.  The language-specific runners are invoked separately
by ``conformance-v2.sh``.
"""

from __future__ import annotations

import hashlib
import json
import re
import sys
from pathlib import Path
from typing import Any


HEX256 = re.compile(r"^[0-9a-f]{64}$")
SAFE_INTEGER = (-(2**53) + 1, (2**53) - 1)


class DuplicateKeyError(ValueError):
    pass


def reject_duplicate_keys(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise DuplicateKeyError(f"duplicate JSON member: {key}")
        result[key] = value
    return result


def reject_non_finite(value: str) -> None:
    raise ValueError(f"non-finite JSON number: {value}")


def read_json(path: Path) -> Any:
    # Decode explicitly so malformed UTF-8 cannot be accepted by a platform
    # JSON reader with replacement semantics.
    raw = path.read_bytes()
    return json.loads(
        raw.decode("utf-8"),
        object_pairs_hook=reject_duplicate_keys,
        parse_constant=reject_non_finite,
    )


def validate_numbers(value: Any, path: str) -> None:
    if isinstance(value, bool) or value is None or isinstance(value, str):
        return
    if isinstance(value, int):
        if not SAFE_INTEGER[0] <= value <= SAFE_INTEGER[1]:
            raise AssertionError(f"{path}: integer is outside I-JSON safe range")
        return
    if isinstance(value, float):
        raise AssertionError(f"{path}: floating point values are not allowed")
    if isinstance(value, dict):
        for key, child in value.items():
            validate_numbers(child, f"{path}.{key}")
    elif isinstance(value, list):
        for index, child in enumerate(value):
            validate_numbers(child, f"{path}[{index}]")


def simple_jcs(value: Any) -> bytes:
    """Render the fixture's JCS-safe subset without application code.

    v2's canonical fixture deliberately contains only strings, safe integers,
    arrays, and objects with ASCII keys.  Python's compact UTF-8 rendering is
    therefore sufficient for this independent fixture check; Swift and Rust
    still provide the production RFC 8785 implementations.
    """

    return json.dumps(
        value,
        ensure_ascii=False,
        separators=(",", ":"),
        sort_keys=True,
    ).encode("utf-8")


def assert_canonical(path: Path) -> bytes:
    raw = path.read_bytes()
    if raw.endswith(b"\n"):
        raise AssertionError(f"{path}: canonical bytes must not have a trailing newline")
    value = read_json(path)
    validate_numbers(value, str(path))
    if raw != simple_jcs(value):
        raise AssertionError(f"{path}: bytes are not canonical for the fixture subset")
    return raw


def assert_hash(path: Path, expected: str, label: str) -> None:
    actual = hashlib.sha256(path.read_bytes()).hexdigest()
    if actual != expected:
        raise AssertionError(f"{label}: {actual} != {expected}")


def require_digest(value: Any, path: str) -> str:
    if not isinstance(value, str) or not HEX256.fullmatch(value):
        raise AssertionError(f"{path}: expected lowercase SHA-256 digest")
    return value


def check_canonical(root: Path) -> int:
    checked = 0
    snapshot_path = root / "snapshot.json"
    snapshot = assert_canonical(snapshot_path)
    snapshot_digest = (root / "snapshot.sha256").read_text().strip()
    require_digest(snapshot_digest, "snapshot.sha256")
    assert_hash(snapshot_path, snapshot_digest, "snapshot SHA-256")

    snapshot_value = read_json(snapshot_path)
    if snapshot_digest != hashlib.sha256(snapshot).hexdigest():
        raise AssertionError("SnapshotID does not match canonical manifest bytes")
    entries = snapshot_value.get("entries")
    if not isinstance(entries, list):
        raise AssertionError("snapshot.entries must be an array")
    keys = [entry.get("entityKey") for entry in entries]
    if keys != sorted(keys) or len(keys) != len(set(keys)):
        raise AssertionError("snapshot entity keys must be unique UTF-8 sorted values")
    checked += 1

    object_index = read_json(root / "object-hashes.json")
    object_rows = object_index.get("objects")
    if not isinstance(object_rows, list) or not object_rows:
        raise AssertionError("object-hashes.json has no objects")
    object_ids: set[str] = set()
    for row in object_rows:
        file_name = row.get("file")
        object_id = require_digest(row.get("objectId"), f"object {file_name}")
        byte_count = row.get("byteCount")
        if not isinstance(file_name, str) or not isinstance(byte_count, int):
            raise AssertionError("object hash row is incomplete")
        if object_id in object_ids:
            raise AssertionError(f"duplicate ObjectID: {object_id}")
        object_ids.add(object_id)
        object_path = root / "objects" / file_name
        data = assert_canonical(object_path) if file_name.endswith(".json") else object_path.read_bytes()
        if len(data) != byte_count:
            raise AssertionError(f"{file_name}: byte count mismatch")
        if hashlib.sha256(data).hexdigest() != object_id:
            raise AssertionError(f"{file_name}: ObjectID mismatch")
        checked += 1

    command_index = read_json(root / "command-hashes.json")
    command_rows = command_index.get("commands")
    if not isinstance(command_rows, list) or not command_rows:
        raise AssertionError("command-hashes.json has no commands")
    command_ids: set[str] = set()
    for row in command_rows:
        file_name = row.get("file")
        digest = require_digest(row.get("requestDigest"), f"command {file_name}")
        if not isinstance(file_name, str) or not isinstance(row.get("byteCount"), int):
            raise AssertionError("command hash row is incomplete")
        if digest in command_ids:
            raise AssertionError(f"duplicate command digest: {digest}")
        command_ids.add(digest)
        command_path = root / file_name
        data = assert_canonical(command_path)
        if len(data) != row["byteCount"] or hashlib.sha256(data).hexdigest() != digest:
            raise AssertionError(f"{file_name}: command digest/byte count mismatch")
        checked += 1

    response_index = read_json(root / "responses" / "response-hashes.json")
    response_rows = response_index.get("responses")
    if response_index.get("schemaVersion") != 2 or not isinstance(response_rows, list):
        raise AssertionError("response hash index is not schemaVersion 2")
    response_models = read_json(root / "responses" / "expected-response-models.json")
    response_files: set[str] = set()
    for row in response_rows:
        file_name = row.get("file")
        if not isinstance(file_name, str) or file_name in response_files:
            raise AssertionError("response hash index has an invalid or duplicate file")
        response_files.add(file_name)
        response_path = root / "responses" / file_name
        data = assert_canonical(response_path)
        response = read_json(response_path)
        expected_sha = require_digest(row.get("sha256"), f"response {file_name}")
        if len(data) != row.get("byteCount") or hashlib.sha256(data).hexdigest() != expected_sha:
            raise AssertionError(f"{file_name}: response digest/byte count mismatch")
        if file_name not in response_models:
            raise AssertionError(f"{file_name}: expected response model is missing")
        if not isinstance(response, dict) or not isinstance(response.get("receipt"), dict):
            raise AssertionError(f"{file_name}: typed receipt is missing")
        projected = dict(response)
        projected.pop("receipt")
        if projected != response_models[file_name]:
            raise AssertionError(f"{file_name}: expected response model mismatch")
        if response.get("commandKind") != row.get("commandKind") or response.get("result") != row.get("result"):
            raise AssertionError(f"{file_name}: response index semantic mismatch")
        if not isinstance(row.get("status"), int) or row["status"] < 200 or row["status"] > 599:
            raise AssertionError(f"{file_name}: invalid HTTP status contract")
        expected_pointer = f"expected-response-models.json#/{file_name}"
        if row.get("expectedModel") != expected_pointer:
            raise AssertionError(f"{file_name}: expected model pointer mismatch")
        sidecar = response_path.with_suffix(response_path.suffix + ".sha256")
        if sidecar.read_text().strip() != expected_sha:
            raise AssertionError(f"{file_name}: response sidecar digest mismatch")
        checked += 1

    for scenario in sorted((root.parent / "scenarios").glob("*.json")):
        value = read_json(scenario)
        if not isinstance(value, dict) or not value.get("name"):
            raise AssertionError(f"{scenario}: name is missing")
        if value.get("schemaVersion") != 2:
            raise AssertionError(f"{scenario}: unexpected scenario contract marker")
        checked += 1

    return checked


def main() -> int:
    repo = Path(__file__).resolve().parent.parent
    count = check_canonical(repo / "docs/sync/v2/fixtures/canonical")
    print(f"v2 independent canonical fixture checks passed ({count} vectors)")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (AssertionError, OSError, ValueError, KeyError) as error:
        print(f"NO-GO: v2 canonical fixture check failed: {error}", file=sys.stderr)
        raise SystemExit(1)
