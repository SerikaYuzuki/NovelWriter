use serde_json::Value;
use sha2::{Digest, Sha256};
use std::collections::{HashMap, HashSet};
use std::fs;
use std::path::{Path, PathBuf};

fn json_files(directory: &Path, files: &mut Vec<PathBuf>) {
    let entries = fs::read_dir(directory).expect("fixture directory must be readable");
    for entry in entries {
        let path = entry
            .expect("fixture directory entry must be readable")
            .path();
        if path.is_dir() {
            json_files(&path, files);
        } else if path
            .extension()
            .is_some_and(|extension| extension == "json")
        {
            files.push(path);
        }
    }
}

fn verify(value: &Value, source: &Path, location: &str) -> usize {
    match value {
        Value::Object(object) => {
            let mut count = 0;
            for (utf8_key, value) in object {
                let Value::String(canonical) = value else {
                    continue;
                };
                if !utf8_key.starts_with("expectedCanonical") || !utf8_key.ends_with("Utf8") {
                    continue;
                }
                let bytes = canonical.as_bytes();
                let prefix = utf8_key.trim_end_matches("Utf8");
                if let Some(expected) = object.get(&format!("{prefix}ByteCount")) {
                    assert_eq!(
                        expected.as_u64(),
                        Some(bytes.len() as u64),
                        "{}:{}: byte count mismatch",
                        source.display(),
                        location
                    );
                }
                let digest = hex::encode(Sha256::digest(bytes));
                if let Some(Value::String(expected)) = object.get(&format!("{prefix}Sha256")) {
                    assert_eq!(
                        digest,
                        *expected,
                        "{}:{}: SHA-256 mismatch",
                        source.display(),
                        location
                    );
                }
                if utf8_key == "expectedCanonicalUtf8" {
                    if let Some(Value::String(expected)) = object.get("expectedCanonicalUtf8Hex") {
                        assert_eq!(
                            hex::encode(bytes),
                            *expected,
                            "{}:{}: UTF-8 hex mismatch",
                            source.display(),
                            location
                        );
                    }
                }
                count += 1;
            }
            for (key, child) in object {
                count += verify(child, source, &format!("{location}.{key}"));
            }
            count
        }
        Value::Array(array) => array
            .iter()
            .enumerate()
            .map(|(index, child)| verify(child, source, &format!("{location}[{index}]")))
            .sum(),
        _ => 0,
    }
}

fn verify_scenarios(
    value: &Value,
    source: &Path,
    location: &str,
    scenario_ids: &mut HashSet<String>,
) -> usize {
    match value {
        Value::Object(object) => {
            let mut count = 0;
            if let Some(Value::String(scenario_id)) = object.get("scenarioId") {
                assert!(
                    !scenario_id.is_empty(),
                    "{source:?}:{location}: empty scenarioId"
                );
                assert!(
                    scenario_ids.insert(scenario_id.clone()),
                    "duplicate scenarioId: {scenario_id}"
                );
                assert_eq!(object.get("fixtureVersion"), Some(&Value::from(1)));
                assert_eq!(
                    object.get("status"),
                    Some(&Value::String("reviewedDesignContract".to_owned()))
                );
                assert!(
                    matches!(object.get("description"), Some(Value::String(value)) if !value.trim().is_empty())
                );
                if let Some(forbidden) = object.get("forbiddenOutcomes") {
                    assert!(matches!(forbidden, Value::Array(values) if !values.is_empty()));
                }
                if let Some(Value::Array(choices)) = object.get("choices") {
                    let choices: Vec<&str> = choices.iter().filter_map(Value::as_str).collect();
                    assert!(choices.contains(&"useThisDevice"));
                    assert!(choices.contains(&"useOnline"));
                    assert!(choices.iter().any(|choice| choice.contains("keepBoth")));
                }
                if let Some(Value::Object(digest)) = object.get("digestContract") {
                    assert_eq!(
                        digest.get("publishWireContainsRequestDigest"),
                        Some(&Value::Bool(false))
                    );
                    assert_eq!(
                        digest.get("publishWireFields"),
                        Some(&Value::Array(
                            [
                                "candidateSnapshotId",
                                "expectedHead",
                                "operationId",
                                "workId",
                            ]
                            .into_iter()
                            .map(Value::from)
                            .collect(),
                        ))
                    );
                }
                if let Some(Value::Array(primary_key)) = object.get("remotePresencePrimaryKey") {
                    assert_eq!(
                        primary_key,
                        &[
                            Value::from("serverInstanceId"),
                            Value::from("protocolEpoch"),
                            Value::from("accountId"),
                            Value::from("accountFence"),
                            Value::from("objectId"),
                        ]
                    );
                }
                count += 1;
            }
            for (key, child) in object {
                count +=
                    verify_scenarios(child, source, &format!("{location}.{key}"), scenario_ids);
            }
            count
        }
        Value::Array(array) => array
            .iter()
            .enumerate()
            .map(|(index, child)| {
                verify_scenarios(child, source, &format!("{location}[{index}]"), scenario_ids)
            })
            .sum(),
        _ => 0,
    }
}

fn replay_lost_ack_fixture(value: &Value, source: &Path) -> usize {
    let Value::Object(object) = value else {
        return 0;
    };
    if object.get("scenarioId")
        != Some(&Value::String(
            "intent-attempt-lost-ack-exact-retry".to_owned(),
        ))
    {
        return 0;
    }
    let commands = object
        .get("commands")
        .and_then(Value::as_array)
        .expect("lost-ack commands must be an array")
        .iter()
        .map(|command| {
            command
                .get("type")
                .and_then(Value::as_str)
                .expect("lost-ack command type must be a string")
        })
        .collect::<Vec<_>>();
    assert_eq!(
        commands,
        vec![
            "observeRemote",
            "sealAttempt",
            "publish",
            "restartClientProcess",
            "retrySealedAttempt",
            "readBackAndAcknowledge",
        ],
        "{source:?}: lost-ack command sequence changed"
    );
    let steps = object
        .get("steps")
        .and_then(Value::as_array)
        .expect("lost-ack steps must be an array");
    assert_eq!(
        steps.len(),
        6,
        "{source:?}: lost-ack replay must have six steps"
    );
    let step_two_sqlite = steps[1]
        .get("expectedSqlite")
        .and_then(Value::as_object)
        .expect("lost-ack step two sqlite state is required");
    let canonical = step_two_sqlite
        .get("publishDigestInputCanonicalUtf8")
        .and_then(Value::as_str)
        .expect("lost-ack canonical command bytes are required");
    let digest = step_two_sqlite
        .get("sealedAttempt")
        .and_then(Value::as_object)
        .and_then(|attempt| attempt.get("requestDigest"))
        .and_then(Value::as_str)
        .expect("lost-ack request digest is required");
    assert_eq!(hex::encode(Sha256::digest(canonical.as_bytes())), digest);

    let committed_generation = steps[2]
        .get("expectedServer")
        .and_then(|server| server.get("head"))
        .and_then(|head| head.get("generation"))
        .and_then(Value::as_u64);
    let replay_generation = steps[4]
        .get("expectedServerHeadGeneration")
        .and_then(Value::as_u64);
    let final_generation = steps[5]
        .get("expectedServerHeadGeneration")
        .and_then(Value::as_u64);
    assert_eq!(committed_generation, Some(8));
    assert_eq!(replay_generation, Some(8));
    assert_eq!(final_generation, Some(8));
    let final_sqlite = steps[5]
        .get("expectedSqlite")
        .and_then(Value::as_object)
        .expect("lost-ack final sqlite state is required");
    assert_eq!(final_sqlite.get("syncIntent"), Some(&Value::Null));
    assert_eq!(final_sqlite.get("sealedAttempt"), Some(&Value::Null));
    1
}

fn replay_conflict_resolution_fixture(value: &Value, source: &Path) -> usize {
    let Value::Object(object) = value else {
        return 0;
    };
    if object.get("scenarioId")
        != Some(&Value::String(
            "conflict-concurrent-edit-during-resolution".to_owned(),
        ))
    {
        return 0;
    }
    assert_eq!(
        object.get("choices"),
        Some(&Value::Array(
            ["useThisDevice", "useOnline", "keepBoth"]
                .into_iter()
                .map(Value::from)
                .collect(),
        ))
    );
    assert_eq!(
        object.get("commandSequence"),
        Some(&Value::Array(
            [
                "flushAndSealPendingResolutionAtGeneration52",
                "sendAtLeastOneByte",
                "autosaveEditAsGeneration53",
                "serverCommitResolutionAndLoseResponse",
                "restartAndReplayExactCommand",
                "readBackAndConditionallyAcknowledge",
            ]
            .into_iter()
            .map(Value::from)
            .collect(),
        ))
    );
    let initial = object
        .get("sharedInitialState")
        .and_then(Value::as_object)
        .expect("conflict shared initial state is required");
    assert_eq!(initial.get("sourceLocalGeneration"), Some(&Value::from(52)));
    assert_eq!(initial.get("newerLocalGeneration"), Some(&Value::from(53)));
    let expected = object
        .get("expectedForEveryChoice")
        .and_then(Value::as_object)
        .expect("conflict expected state is required");
    assert_eq!(
        expected.get("resolvedRemoteHeadGeneration"),
        Some(&Value::from(10))
    );
    assert_eq!(
        expected.get("acknowledgedThroughLocalGeneration"),
        Some(&Value::from(52))
    );
    assert_eq!(
        expected.get("activeEditorInjectionCount"),
        Some(&Value::from(0))
    );
    assert_eq!(
        expected.get("exactCommandReplayCountAfterLostAck"),
        Some(&Value::from(1))
    );
    let local = expected
        .get("localCurrentAfterAcknowledge")
        .and_then(Value::as_object)
        .expect("conflict local state is required");
    let intent = expected
        .get("syncIntentAfterAcknowledge")
        .and_then(Value::as_object)
        .expect("conflict intent state is required");
    assert_eq!(local.get("localGeneration"), Some(&Value::from(53)));
    assert_eq!(intent.get("localGeneration"), Some(&Value::from(53)));
    let keep_both = object
        .get("keepBothAdditionalExpectation")
        .and_then(Value::as_object)
        .expect("keep-both expectation is required");
    assert_eq!(
        keep_both.get("cloneRootPublishedExactlyOnce"),
        Some(&Value::Bool(true))
    );
    assert_eq!(
        keep_both.get("partialOriginalOrCloneCommitAllowed"),
        Some(&Value::Bool(false))
    );
    let _ = source;
    1
}

fn replay_remote_advance_fixture(value: &Value, source: &Path) -> usize {
    let Value::Object(object) = value else {
        return 0;
    };
    if object.get("scenarioId")
        != Some(&Value::String(
            "saved-local-pending-remote-advance".to_owned(),
        ))
    {
        return 0;
    }
    let initial = object
        .get("initialState")
        .and_then(Value::as_object)
        .expect("remote advance initial state is required");
    let expected = object
        .get("expected")
        .and_then(Value::as_object)
        .expect("remote advance expected state is required");
    let command = object
        .get("command")
        .and_then(Value::as_object)
        .expect("remote advance command is required");
    assert_eq!(
        command.get("type"),
        Some(&Value::String(
            "stageRemoteAndEvaluateFastForward".to_owned()
        ))
    );
    assert_eq!(
        initial.get("editorHasUnsavedChanges"),
        Some(&Value::Bool(false))
    );
    assert!(initial
        .get("pendingSyncIntent")
        .is_some_and(Value::is_object));
    assert_eq!(
        expected.get("remoteStoredInInbox"),
        Some(&Value::Bool(true))
    );
    assert_eq!(
        expected.get("fastForwardApplied"),
        Some(&Value::Bool(false))
    );
    assert_eq!(
        expected.get("currentLocalSnapshotId"),
        initial.get("currentLocalSnapshotId")
    );
    assert_eq!(
        expected.get("pendingSyncIntentPreserved"),
        Some(&Value::Bool(true))
    );
    assert_eq!(
        expected.get("remoteCallbackInjectedIntoActiveEditor"),
        Some(&Value::Bool(false))
    );
    assert_eq!(
        expected.get("nextAction"),
        Some(&Value::String("reconcile".to_owned()))
    );
    let _ = source;
    1
}

fn replay_refresh_rotation_fixture(value: &Value, source: &Path) -> usize {
    let Value::Object(object) = value else {
        return 0;
    };
    if object.get("name")
        != Some(&Value::String(
            "one-time-refresh-rotation-exact-replay-and-reuse-revocation".to_owned(),
        ))
    {
        return 0;
    }
    let steps = object
        .get("steps")
        .and_then(Value::as_array)
        .expect("refresh rotation steps must be an array");
    assert!(
        steps.len() >= 6,
        "{source:?}: refresh rotation fixture is incomplete"
    );
    let first_expect = steps[0]
        .get("expect")
        .and_then(Value::as_object)
        .expect("first refresh expectation is required");
    assert_eq!(
        steps[0].get("path"),
        Some(&Value::String("/v1/auth/tokens:refresh".to_owned()))
    );
    assert_eq!(first_expect.get("status"), Some(&Value::from(200)));
    let replay_expect = steps[1]
        .get("expect")
        .and_then(Value::as_object)
        .expect("refresh replay expectation is required");
    assert_eq!(
        replay_expect.get("sameCanonicalResponseAsStep"),
        Some(&Value::String("rotate-first-use".to_owned()))
    );
    let reuse_expect = steps[2]
        .get("expect")
        .and_then(Value::as_object)
        .expect("refresh reuse expectation is required");
    let reuse_body = reuse_expect
        .get("body")
        .and_then(Value::as_object)
        .expect("refresh reuse error body is required");
    assert_eq!(reuse_expect.get("status"), Some(&Value::from(401)));
    assert_eq!(
        reuse_body.get("code"),
        Some(&Value::String("refreshTokenReused".to_owned()))
    );
    assert_eq!(
        reuse_body.get("recoveryAction"),
        Some(&Value::String("interactiveAppleSignIn".to_owned()))
    );
    let first_state = steps[0]
        .get("expectState")
        .and_then(Value::as_object)
        .expect("first refresh state is required");
    let reuse_state = steps[2]
        .get("expectState")
        .and_then(Value::as_object)
        .expect("refresh reuse state is required");
    assert_eq!(
        first_state.get("accountAuthEpoch"),
        reuse_state.get("accountAuthEpoch")
    );
    assert_eq!(first_state.get("appleProviderCalls"), Some(&Value::from(0)));
    assert_eq!(reuse_state.get("appleProviderCalls"), Some(&Value::from(0)));
    let delayed = steps[steps.len() - 1]
        .get("expect")
        .and_then(Value::as_object)
        .expect("delayed refresh expectation is required");
    assert_eq!(
        delayed.get("keychainCompareAndSwap"),
        Some(&Value::String("rejectedPredecessorMismatch".to_owned()))
    );
    1
}

fn replay_apple_exchange_fixture(value: &Value, source: &Path) -> usize {
    let Value::Object(object) = value else {
        return 0;
    };
    if object.get("name")
        != Some(&Value::String(
            "apple-native-validation-mapping-and-exact-replay".to_owned(),
        ))
    {
        return 0;
    }
    let steps = object
        .get("steps")
        .and_then(Value::as_array)
        .expect("Apple exchange steps must be an array");
    let by_id = steps
        .iter()
        .filter_map(|step| Some((step.get("id")?.as_str()?.to_owned(), step.as_object()?)))
        .collect::<HashMap<_, _>>();
    for (id, status) in [
        ("read-public-capabilities", 200),
        ("create-success-challenge", 201),
        ("exchange-success", 200),
        ("reauth-exchange-same-identity", 200),
    ] {
        let expect = by_id
            .get(id)
            .and_then(|step| step.get("expect"))
            .and_then(Value::as_object)
            .expect("Apple exchange expected response is required");
        assert_eq!(expect.get("status"), Some(&Value::from(status)));
    }
    let challenge_expect = by_id
        .get("create-success-challenge")
        .and_then(|step| step.get("expect"))
        .and_then(Value::as_object)
        .expect("Apple challenge expectation is required");
    let challenge_body = challenge_expect
        .get("body")
        .and_then(Value::as_object)
        .expect("Apple challenge body is required");
    assert_eq!(
        challenge_body.get("provider"),
        Some(&Value::String("apple".to_owned()))
    );
    assert!(challenge_body.get("receipt").is_some_and(Value::is_object));
    for (id, expected_replay) in [
        (
            "create-success-challenge-lost-ack-replay",
            "create-success-challenge",
        ),
        ("exchange-success-lost-ack-replay", "exchange-success"),
    ] {
        let expect = by_id
            .get(id)
            .and_then(|step| step.get("expect"))
            .and_then(Value::as_object)
            .expect("Apple replay expectation is required");
        assert_eq!(
            expect.get("sameCanonicalResponseAsStep"),
            Some(&Value::String(expected_replay.to_owned()))
        );
    }
    let success_binding = by_id
        .get("exchange-success")
        .and_then(|step| step.get("expect"))
        .and_then(|expect| expect.get("body"))
        .and_then(|body| body.get("binding"))
        .and_then(Value::as_object)
        .expect("Apple success binding is required");
    let reauth_binding = by_id
        .get("reauth-exchange-same-identity")
        .and_then(|step| step.get("expect"))
        .and_then(|expect| expect.get("body"))
        .and_then(|body| body.get("binding"))
        .and_then(Value::as_object)
        .expect("Apple reauth binding is required");
    assert_eq!(
        success_binding.get("accountId"),
        reauth_binding.get("accountId")
    );
    assert_eq!(
        success_binding.get("accountFence"),
        reauth_binding.get("accountFence")
    );
    let reauth_state = by_id
        .get("reauth-exchange-same-identity")
        .and_then(|step| step.get("expectState"))
        .and_then(Value::as_object)
        .expect("Apple reauth state is required");
    assert_eq!(
        reauth_state.get("externalIdentityMappings"),
        Some(&Value::from(1))
    );
    for id in [
        "exchange-wrong-state",
        "exchange-wrong-issuer",
        "exchange-wrong-audience",
        "exchange-wrong-nonce",
    ] {
        let step = by_id.get(id).expect("Apple invalid claim step is required");
        let expect = step
            .get("expect")
            .and_then(Value::as_object)
            .expect("Apple invalid claim response is required");
        let state = step
            .get("expectState")
            .and_then(Value::as_object)
            .expect("Apple invalid claim state is required");
        assert_eq!(expect.get("status"), Some(&Value::from(422)));
        assert_eq!(state.get("accountMutation"), Some(&Value::Bool(false)));
    }
    let _ = source;
    1
}

#[test]
fn reviewed_v1_fixtures_preserve_canonical_bytes_and_digests() {
    let repository = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    let roots = [
        repository.join("../docs/sync/v1"),
        repository.join("../docs/auth/v1"),
    ];
    let mut files = Vec::new();
    for root in roots {
        json_files(&root, &mut files);
    }
    files.sort();
    assert!(!files.is_empty(), "reviewed v1 JSON fixtures must exist");

    let mut vectors = 0;
    let mut scenarios = 0;
    let mut replays = 0;
    let mut scenario_ids = HashSet::new();
    for file in &files {
        let bytes = fs::read(file).expect("fixture must be readable");
        let value: Value = serde_json::from_slice(&bytes).expect("fixture must be valid JSON");
        vectors += verify(&value, file, "$");
        let is_sync_fixture = file.to_string_lossy().contains("/docs/sync/v1/fixtures/");
        let is_auth_fixture = file.to_string_lossy().contains("/docs/auth/v1/fixtures/");
        if is_sync_fixture {
            scenarios += verify_scenarios(&value, file, "&", &mut scenario_ids);
        }
        if is_sync_fixture || is_auth_fixture {
            replays += replay_lost_ack_fixture(&value, file);
            replays += replay_conflict_resolution_fixture(&value, file);
            replays += replay_remote_advance_fixture(&value, file);
            replays += replay_refresh_rotation_fixture(&value, file);
            replays += replay_apple_exchange_fixture(&value, file);
        }
    }
    assert!(
        vectors > 0,
        "reviewed fixtures must contain canonical vectors"
    );
    assert!(
        scenarios > 0,
        "reviewed fixtures must contain scenario records"
    );
    assert_eq!(
        replays, 5,
        "lost-ack, conflict, remote-advance, refresh, and Apple exchange replays are required"
    );
}
