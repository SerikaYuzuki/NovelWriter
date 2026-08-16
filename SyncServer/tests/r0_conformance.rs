use serde_json::Value;
use sha2::{Digest, Sha256};
use std::collections::HashSet;
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
            if let Some(Value::String(canonical)) = object.get("expectedCanonicalUtf8") {
                let bytes = canonical.as_bytes();
                if let Some(expected) = object.get("expectedByteCount") {
                    assert_eq!(
                        expected.as_u64(),
                        Some(bytes.len() as u64),
                        "{}:{}: byte count mismatch",
                        source.display(),
                        location
                    );
                }
                let digest = hex::encode(Sha256::digest(bytes));
                if let Some(Value::String(expected)) = object.get("expectedSha256") {
                    assert_eq!(
                        digest,
                        *expected,
                        "{}:{}: SHA-256 mismatch",
                        source.display(),
                        location
                    );
                }
                if let Some(Value::String(expected)) = object.get("expectedCanonicalUtf8Hex") {
                    assert_eq!(
                        hex::encode(bytes),
                        *expected,
                        "{}:{}: UTF-8 hex mismatch",
                        source.display(),
                        location
                    );
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
        if file.to_string_lossy().contains("/docs/sync/v1/fixtures/") {
            scenarios += verify_scenarios(&value, file, "&", &mut scenario_ids);
            replays += replay_lost_ack_fixture(&value, file);
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
        replays, 1,
        "one executable lost-ack replay fixture is required"
    );
}
