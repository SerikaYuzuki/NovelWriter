#!/usr/bin/env python3
"""Small, dependency-free integrity gate for the reviewed v1 fixtures.

This is deliberately independent of the application and server serializers.
It checks the byte-level assertions embedded in the shared fixtures so that a
bad fixture cannot silently become the de-facto protocol.  Swift and Rust
repeat the same checks in their own test targets.
"""

from __future__ import annotations

import hashlib
import json
import sys
from pathlib import Path
from typing import Any


class DuplicateKeyError(ValueError):
    pass


def reject_duplicate_keys(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise DuplicateKeyError(f"duplicate JSON key: {key}")
        result[key] = value
    return result


def reject_constant(value: str) -> None:
    raise ValueError(f"non-finite JSON number: {value}")


def canonical_assertions(node: Any, source: Path, location: str) -> int:
    checked = 0
    if isinstance(node, dict):
        if "expectedCanonicalUtf8" in node:
            canonical = node["expectedCanonicalUtf8"]
            if not isinstance(canonical, str):
                raise AssertionError(f"{source}:{location}: expectedCanonicalUtf8 is not a string")
            data = canonical.encode("utf-8")
            expected_count = node.get("expectedByteCount")
            if expected_count is not None and expected_count != len(data):
                raise AssertionError(
                    f"{source}:{location}: byte count {len(data)} != {expected_count}"
                )
            expected_sha = node.get("expectedSha256")
            actual_sha = hashlib.sha256(data).hexdigest()
            if expected_sha is not None and expected_sha != actual_sha:
                raise AssertionError(
                    f"{source}:{location}: sha256 {actual_sha} != {expected_sha}"
                )
            expected_hex = node.get("expectedCanonicalUtf8Hex")
            if expected_hex is not None and expected_hex != data.hex():
                raise AssertionError(
                    f"{source}:{location}: UTF-8 hex does not match expectedCanonicalUtf8Hex"
                )
            checked += 1
        for key, value in node.items():
            checked += canonical_assertions(value, source, f"{location}.{key}")
    elif isinstance(node, list):
        for index, value in enumerate(node):
            checked += canonical_assertions(value, source, f"{location}[{index}]")
    return checked


def assert_fixture_ids(node: Any, source: Path, location: str = "$.") -> None:
    if isinstance(node, dict):
        for key, value in node.items():
            if key in {"cases", "steps"} and isinstance(value, list):
                ids = [
                    item.get("id")
                    for item in value
                    if isinstance(item, dict) and isinstance(item.get("id"), str)
                ]
                if len(ids) != len(set(ids)):
                    raise AssertionError(f"{source}:{location}.{key}: duplicate fixture id")
            assert_fixture_ids(value, source, f"{location}{key}.")
    elif isinstance(node, list):
        for index, value in enumerate(node):
            assert_fixture_ids(value, source, f"{location}[{index}].")


def scenario_assertions(node: Any, source: Path, location: str = "$") -> int:
    checked = 0
    if isinstance(node, dict):
        if "scenarioId" in node:
            scenario_id = node.get("scenarioId")
            if not isinstance(scenario_id, str) or not scenario_id:
                raise AssertionError(f"{source}:{location}: scenarioId must be non-empty")
            if node.get("fixtureVersion") != 1:
                raise AssertionError(f"{source}:{location}: scenario fixtureVersion must be 1")
            if node.get("status") != "reviewedDesignContract":
                raise AssertionError(f"{source}:{location}: scenario is not reviewedDesignContract")
            if not isinstance(node.get("description"), str) or not node["description"].strip():
                raise AssertionError(f"{source}:{location}: scenario description is missing")
            forbidden = node.get("forbiddenOutcomes")
            if forbidden is not None and (not isinstance(forbidden, list) or not forbidden):
                raise AssertionError(f"{source}:{location}: forbiddenOutcomes must not be empty")

            choices = node.get("choices")
            if isinstance(choices, list):
                required = {"useThisDevice", "useOnline"}
                if not required.issubset(choices):
                    raise AssertionError(f"{source}:{location}: conflict choices omit a primary choice")
                if not any("keepBoth" in str(choice) for choice in choices):
                    raise AssertionError(f"{source}:{location}: conflict choices omit keep-both")

            digest_contract = node.get("digestContract")
            if isinstance(digest_contract, dict):
                if digest_contract.get("publishWireContainsRequestDigest") is not False:
                    raise AssertionError(f"{source}:{location}: publish wire must not carry requestDigest")
                if digest_contract.get("publishWireFields") != [
                    "candidateSnapshotId",
                    "expectedHead",
                    "operationId",
                    "workId",
                ]:
                    raise AssertionError(f"{source}:{location}: publish wire field set changed")

            presence_key = node.get("remotePresencePrimaryKey")
            if presence_key is not None and presence_key != [
                "serverInstanceId",
                "protocolEpoch",
                "accountId",
                "accountFence",
                "objectId",
            ]:
                raise AssertionError(f"{source}:{location}: remote presence fence key changed")
            checked += 1
        for key, value in node.items():
            checked += scenario_assertions(value, source, f"{location}.{key}")
    elif isinstance(node, list):
        for index, value in enumerate(node):
            checked += scenario_assertions(value, source, f"{location}[{index}]")
    return checked


def check_file(path: Path) -> tuple[int, int, int]:
    try:
        text = path.read_bytes().decode("utf-8")
        value = json.loads(
            text,
            object_pairs_hook=reject_duplicate_keys,
            parse_constant=reject_constant,
        )
    except Exception as error:  # noqa: BLE001 - convert to a useful fixture error
        raise AssertionError(f"{path}: invalid UTF-8/JSON: {error}") from error
    assert_fixture_ids(value, path)
    return 1, canonical_assertions(value, path, "$") , scenario_assertions(value, path)


def main() -> int:
    root = Path(__file__).resolve().parents[1]
    roots = [root / "docs" / "sync" / "v1", root / "docs" / "auth" / "v1"]
    files = sorted(path for directory in roots for path in directory.rglob("*.json"))
    if not files:
        raise AssertionError("no v1 JSON fixtures found")

    json_count = 0
    vector_count = 0
    scenario_count = 0
    for path in files:
        parsed, checked, scenarios = check_file(path)
        json_count += parsed
        vector_count += checked
        scenario_count += scenarios
    print(
        f"R0 fixture integrity: {json_count} JSON files, {vector_count} canonical vectors, "
        f"{scenario_count} scenario records"
    )
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except AssertionError as error:
        print(f"R0 fixture integrity: FAIL: {error}", file=sys.stderr)
        raise SystemExit(1) from error
