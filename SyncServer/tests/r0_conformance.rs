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
    let mut scenario_ids = HashSet::new();
    for file in &files {
        let bytes = fs::read(file).expect("fixture must be readable");
        let value: Value = serde_json::from_slice(&bytes).expect("fixture must be valid JSON");
        vectors += verify(&value, file, "$");
        if file.to_string_lossy().contains("/docs/sync/v1/fixtures/") {
            scenarios += verify_scenarios(&value, file, "&", &mut scenario_ids);
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
}
