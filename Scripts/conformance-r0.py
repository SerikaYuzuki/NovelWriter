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
        for utf8_key, canonical in node.items():
            if not (utf8_key.startswith("expectedCanonical") and utf8_key.endswith("Utf8")):
                continue
            if not isinstance(canonical, str):
                raise AssertionError(f"{source}:{location}: {utf8_key} is not a string")
            data = canonical.encode("utf-8")
            prefix = utf8_key[: -len("Utf8")]
            expected_count = node.get(f"{prefix}ByteCount")
            if expected_count is not None and expected_count != len(data):
                raise AssertionError(
                    f"{source}:{location}: {utf8_key} byte count {len(data)} != {expected_count}"
                )
            expected_sha = node.get(f"{prefix}Sha256")
            actual_sha = hashlib.sha256(data).hexdigest()
            if expected_sha is not None and expected_sha != actual_sha:
                raise AssertionError(
                    f"{source}:{location}: {utf8_key} sha256 {actual_sha} != {expected_sha}"
                )
            expected_hex = node.get("expectedCanonicalUtf8Hex") if utf8_key == "expectedCanonicalUtf8" else None
            if expected_hex is not None and expected_hex != data.hex():
                raise AssertionError(
                    f"{source}:{location}: {utf8_key} UTF-8 hex does not match expectedCanonicalUtf8Hex"
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


def replay_lost_ack_fixture(node: Any, source: Path) -> int:
    if not isinstance(node, dict) or node.get("scenarioId") != "intent-attempt-lost-ack-exact-retry":
        return 0
    commands = [command.get("type") for command in node.get("commands", [])]
    expected_commands = [
        "observeRemote",
        "sealAttempt",
        "publish",
        "restartClientProcess",
        "retrySealedAttempt",
        "readBackAndAcknowledge",
    ]
    if commands != expected_commands:
        raise AssertionError(f"{source}: lost-ack command sequence changed")
    steps = node.get("steps")
    if not isinstance(steps, list) or len(steps) != 6:
        raise AssertionError(f"{source}: lost-ack replay must have six steps")
    step_two = steps[1]
    canonical = step_two.get("expectedSqlite", {}).get("publishDigestInputCanonicalUtf8")
    digest = step_two.get("expectedSqlite", {}).get("sealedAttempt", {}).get("requestDigest")
    if not isinstance(canonical, str) or not isinstance(digest, str):
        raise AssertionError(f"{source}: lost-ack digest vector is incomplete")
    if hashlib.sha256(canonical.encode("utf-8")).hexdigest() != digest:
        raise AssertionError(f"{source}: lost-ack request digest does not match canonical bytes")
    expected_head = steps[2].get("expectedServer", {}).get("head", {}).get("generation")
    replay_head = steps[4].get("expectedServerHeadGeneration")
    final_head = steps[5].get("expectedServerHeadGeneration")
    if not (expected_head == replay_head == final_head == 8):
        raise AssertionError(f"{source}: lost-ack replay must not increment the committed head")
    final_sqlite = steps[5].get("expectedSqlite", {})
    if final_sqlite.get("syncIntent") is not None or final_sqlite.get("sealedAttempt") is not None:
        raise AssertionError(f"{source}: lost-ack final state must clear only after read-back")
    return 1


def replay_conflict_resolution_fixture(node: Any, source: Path) -> int:
    if not isinstance(node, dict) or node.get("scenarioId") != "conflict-concurrent-edit-during-resolution":
        return 0
    if node.get("choices") != ["useThisDevice", "useOnline", "keepBoth"]:
        raise AssertionError(f"{source}: conflict resolution must expose all three choices")
    sequence = node.get("commandSequence")
    expected_sequence = [
        "flushAndSealPendingResolutionAtGeneration52",
        "sendAtLeastOneByte",
        "autosaveEditAsGeneration53",
        "serverCommitResolutionAndLoseResponse",
        "restartAndReplayExactCommand",
        "readBackAndConditionallyAcknowledge",
    ]
    if sequence != expected_sequence:
        raise AssertionError(f"{source}: conflict resolution sequence changed")
    initial = node.get("sharedInitialState", {})
    expected = node.get("expectedForEveryChoice", {})
    if (initial.get("sourceLocalGeneration"), initial.get("newerLocalGeneration")) != (52, 53):
        raise AssertionError(f"{source}: conflict source/newer generation fence changed")
    if expected.get("resolvedRemoteHeadGeneration") != 10:
        raise AssertionError(f"{source}: conflict resolution must advance remote head once")
    local = expected.get("localCurrentAfterAcknowledge", {})
    intent = expected.get("syncIntentAfterAcknowledge", {})
    if local.get("localGeneration") != 53 or intent.get("localGeneration") != 53:
        raise AssertionError(f"{source}: newer local generation was not preserved")
    if expected.get("acknowledgedThroughLocalGeneration") != 52:
        raise AssertionError(f"{source}: acknowledgement crossed the newer local generation")
    if expected.get("activeEditorInjectionCount") != 0 or expected.get("exactCommandReplayCountAfterLostAck") != 1:
        raise AssertionError(f"{source}: resolution replay/editor safety invariant changed")
    clone = node.get("keepBothAdditionalExpectation", {})
    if clone.get("cloneRootPublishedExactlyOnce") is not True or clone.get("partialOriginalOrCloneCommitAllowed") is not False:
        raise AssertionError(f"{source}: keep-both atomicity invariant changed")
    return 1


def replay_remote_advance_fixture(node: Any, source: Path) -> int:
    if not isinstance(node, dict) or node.get("scenarioId") != "saved-local-pending-remote-advance":
        return 0
    initial = node.get("initialState", {})
    expected = node.get("expected", {})
    command = node.get("command", {})
    if command.get("type") != "stageRemoteAndEvaluateFastForward":
        raise AssertionError(f"{source}: remote-advance command changed")
    if initial.get("editorHasUnsavedChanges") is not False or initial.get("pendingSyncIntent") is None:
        raise AssertionError(f"{source}: fixture must model a clean editor with a durable Intent")
    if expected.get("remoteStoredInInbox") is not True or expected.get("fastForwardApplied") is not False:
        raise AssertionError(f"{source}: pending local work must block fast-forward")
    if expected.get("currentLocalSnapshotId") != initial.get("currentLocalSnapshotId"):
        raise AssertionError(f"{source}: remote staging replaced the current local snapshot")
    if expected.get("pendingSyncIntentPreserved") is not True or expected.get("remoteCallbackInjectedIntoActiveEditor") is not False:
        raise AssertionError(f"{source}: remote advance bypassed local reconciliation")
    if expected.get("nextAction") != "reconcile":
        raise AssertionError(f"{source}: pending local work must schedule reconciliation")
    return 1


def replay_refresh_rotation_fixture(node: Any, source: Path) -> int:
    if not isinstance(node, dict) or node.get("name") != "one-time-refresh-rotation-exact-replay-and-reuse-revocation":
        return 0
    steps = node.get("steps")
    if not isinstance(steps, list) or len(steps) < 6:
        raise AssertionError(f"{source}: refresh rotation fixture is incomplete")
    first = steps[0]
    replay = steps[1]
    reuse = steps[2]
    if first.get("path") != "/v1/auth/tokens:refresh" or first.get("expect", {}).get("status") != 200:
        raise AssertionError(f"{source}: first refresh rotation must succeed")
    if replay.get("expect", {}).get("sameCanonicalResponseAsStep") != "rotate-first-use":
        raise AssertionError(f"{source}: refresh exact replay is not tied to the first receipt")
    reuse_expect = reuse.get("expect", {})
    if reuse_expect.get("status") != 401 or reuse_expect.get("body", {}).get("code") != "refreshTokenReused":
        raise AssertionError(f"{source}: consumed refresh token reuse must be typed 401")
    if reuse_expect.get("body", {}).get("recoveryAction") != "interactiveAppleSignIn":
        raise AssertionError(f"{source}: refresh reuse recovery action changed")
    first_state = first.get("expectState", {})
    reuse_state = reuse.get("expectState", {})
    if first_state.get("accountAuthEpoch") != reuse_state.get("accountAuthEpoch"):
        raise AssertionError(f"{source}: ordinary refresh/reuse changed account auth epoch")
    if first_state.get("appleProviderCalls") != 0 or reuse_state.get("appleProviderCalls") != 0:
        raise AssertionError(f"{source}: refresh rotation unexpectedly called Apple")
    delayed = steps[-1]
    delayed_expect = delayed.get("expect", {})
    if delayed_expect.get("keychainCompareAndSwap") != "rejectedPredecessorMismatch":
        raise AssertionError(f"{source}: late refresh response can roll Keychain backwards")
    return 1


def replay_apple_exchange_fixture(node: Any, source: Path) -> int:
    if not isinstance(node, dict) or node.get("name") != "apple-native-validation-mapping-and-exact-replay":
        return 0
    steps = node.get("steps")
    if not isinstance(steps, list):
        raise AssertionError(f"{source}: Apple exchange steps are missing")
    by_id = {step.get("id"): step for step in steps if isinstance(step, dict) and step.get("id")}
    for step_id, status in {
        "read-public-capabilities": 200,
        "create-success-challenge": 201,
        "exchange-success": 200,
        "reauth-exchange-same-identity": 200,
    }.items():
        if by_id.get(step_id, {}).get("expect", {}).get("status") != status:
            raise AssertionError(f"{source}: Apple exchange step {step_id} changed")
    if by_id["create-success-challenge"]["expect"].get("body", {}).get("provider") != "apple":
        raise AssertionError(f"{source}: challenge provider is not Apple")
    if by_id["create-success-challenge"]["expect"].get("body", {}).get("receipt") is None:
        raise AssertionError(f"{source}: challenge must be receipt-idempotent")
    if by_id["create-success-challenge-lost-ack-replay"]["expect"].get("sameCanonicalResponseAsStep") != "create-success-challenge":
        raise AssertionError(f"{source}: challenge replay is not exact")
    if by_id["exchange-success-lost-ack-replay"]["expect"].get("sameCanonicalResponseAsStep") != "exchange-success":
        raise AssertionError(f"{source}: Apple exchange replay is not exact")
    success_binding = by_id["exchange-success"]["expect"]["body"]["binding"]
    reauth_binding = by_id["reauth-exchange-same-identity"]["expect"]["body"]["binding"]
    if success_binding.get("accountId") != reauth_binding.get("accountId") or success_binding.get("accountFence") != reauth_binding.get("accountFence"):
        raise AssertionError(f"{source}: same Apple identity created a new account or fence")
    if by_id["reauth-exchange-same-identity"]["expectState"].get("externalIdentityMappings") != 1:
        raise AssertionError(f"{source}: same Apple identity duplicated its mapping")
    for step_id in ("exchange-wrong-state", "exchange-wrong-issuer", "exchange-wrong-audience", "exchange-wrong-nonce"):
        step = by_id.get(step_id, {})
        if step.get("expect", {}).get("status") != 422 or step.get("expectState", {}).get("accountMutation") is not False:
            raise AssertionError(f"{source}: invalid Apple claim {step_id} mutated account state")
    return 1


def check_file(path: Path) -> tuple[int, int, int, int]:
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
    return (
        1,
        canonical_assertions(value, path, "$") ,
        scenario_assertions(value, path),
        replay_lost_ack_fixture(value, path)
        + replay_conflict_resolution_fixture(value, path)
        + replay_remote_advance_fixture(value, path)
        + replay_refresh_rotation_fixture(value, path)
        + replay_apple_exchange_fixture(value, path),
    )


def main() -> int:
    root = Path(__file__).resolve().parents[1]
    roots = [root / "docs" / "sync" / "v1", root / "docs" / "auth" / "v1"]
    files = sorted(path for directory in roots for path in directory.rglob("*.json"))
    if not files:
        raise AssertionError("no v1 JSON fixtures found")

    json_count = 0
    vector_count = 0
    scenario_count = 0
    replay_count = 0
    for path in files:
        parsed, checked, scenarios, replays = check_file(path)
        json_count += parsed
        vector_count += checked
        scenario_count += scenarios
        replay_count += replays
    print(
        f"R0 fixture integrity: {json_count} JSON files, {vector_count} canonical vectors, "
        f"{scenario_count} scenario records, {replay_count} executable replays"
    )
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except AssertionError as error:
        print(f"R0 fixture integrity: FAIL: {error}", file=sys.stderr)
        raise SystemExit(1) from error
