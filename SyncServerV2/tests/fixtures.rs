use base64::{engine::general_purpose::URL_SAFE_NO_PAD, Engine};
use fuminiwa_sync_server_v2::domain::{canonical_json, sha256};
use serde::Deserialize;
use serde_json::Value;
use std::{collections::HashMap, fs, path::PathBuf};

#[derive(Deserialize)]
struct CommandHashes {
    commands: Vec<CommandHash>,
}
#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct CommandHash {
    file: String,
    byte_count: usize,
    request_digest: String,
}

#[derive(Deserialize)]
struct ResponseHashes {
    responses: Vec<ResponseHash>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct ResponseHash {
    file: String,
    command_kind: String,
    result: String,
    status: u16,
    byte_count: usize,
    sha256: String,
}

fn fixture(path: &str) -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("..")
        .join("docs")
        .join("sync")
        .join("v2")
        .join("fixtures")
        .join("canonical")
        .join(path)
}

#[test]
fn canonical_snapshot_and_all_sealed_command_hashes_match_contract() {
    let snapshot: Value =
        serde_json::from_slice(&fs::read(fixture("snapshot.json")).unwrap()).unwrap();
    let snapshot_bytes = canonical_json(&snapshot).unwrap();
    let expected = fs::read_to_string(fixture("snapshot.sha256"))
        .unwrap()
        .trim()
        .to_owned();
    assert_eq!(hex::encode(sha256(&snapshot_bytes)), expected);
    let hashes: CommandHashes =
        serde_json::from_slice(&fs::read(fixture("command-hashes.json")).unwrap()).unwrap();
    for command in hashes.commands {
        let value: Value =
            serde_json::from_slice(&fs::read(fixture(&command.file)).unwrap()).unwrap();
        let bytes = canonical_json(&value).unwrap();
        assert_eq!(
            bytes.len(),
            command.byte_count,
            "{} byte count",
            command.file
        );
        assert_eq!(
            hex::encode(sha256(&bytes)),
            command.request_digest,
            "{} digest",
            command.file
        );
    }
}

#[test]
fn canonical_responses_match_closed_shapes_statuses_and_hashes() {
    let hashes: ResponseHashes =
        serde_json::from_slice(&fs::read(fixture("responses/response-hashes.json")).unwrap())
            .unwrap();
    assert_eq!(hashes.responses.len(), 12);
    let models: HashMap<String, Value> = serde_json::from_slice(
        &fs::read(fixture("responses/expected-response-models.json")).unwrap(),
    )
    .unwrap();
    for row in hashes.responses {
        let bytes = fs::read(fixture(&format!("responses/{}", row.file))).unwrap();
        assert!(
            !bytes.ends_with(b"\n"),
            "{} has a trailing newline",
            row.file
        );
        assert_eq!(bytes.len(), row.byte_count, "{} byte count", row.file);
        assert_eq!(
            hex::encode(sha256(&bytes)),
            row.sha256,
            "{} digest",
            row.file
        );
        let value: Value = serde_json::from_slice(&bytes).unwrap();
        assert_eq!(
            canonical_json(&value).unwrap(),
            bytes,
            "{} canonical",
            row.file
        );
        assert_eq!(value["commandKind"], row.command_kind, "{} kind", row.file);
        assert_eq!(value["result"], row.result, "{} result", row.file);
        let model = value
            .as_object()
            .unwrap()
            .iter()
            .filter(|(key, _)| *key != "receipt")
            .map(|(key, value)| (key.clone(), value.clone()))
            .collect::<serde_json::Map<_, _>>();
        assert_eq!(models.get(&row.file), Some(&Value::Object(model)));
        let receipt = value["receipt"].as_object().unwrap();
        assert_eq!(receipt.len(), 5);
        assert!(receipt["readBack"]
            .as_object()
            .unwrap()
            .values()
            .all(|v| v == true));
        let expected_status = match (row.command_kind.as_str(), row.result.as_str()) {
            ("createWork", "applied") | ("prepareObject", "applied") => 201,
            ("prepareObject", "noChanges") => 200,
            ("publish", "conflictPending") => 409,
            _ => 200,
        };
        assert_eq!(row.status, expected_status, "{} status", row.file);
        if matches!(
            row.command_kind.as_str(),
            "createWork" | "finalizeObject" | "registerSnapshot"
        ) {
            assert!(value["head"].is_null(), "{} sentinel head", row.file);
        }
    }
}

#[test]
fn publish_receipt_replays_exact_original_response_bytes() {
    let receipt_bytes = fs::read(fixture("receipts/publish-applied.json")).unwrap();
    let receipt: Value = serde_json::from_slice(&receipt_bytes).unwrap();
    assert_eq!(canonical_json(&receipt).unwrap(), receipt_bytes);
    assert_eq!(receipt["originalResponseStatus"], 200);
    assert_eq!(receipt["originalResult"], "applied");
    assert!(receipt["readBack"]
        .as_object()
        .unwrap()
        .values()
        .all(|v| v == true));
    let encoded = receipt["canonicalResponseBase64URL"].as_str().unwrap();
    let replay = URL_SAFE_NO_PAD.decode(encoded).unwrap();
    let original = fs::read(fixture("responses/publish-applied.json")).unwrap();
    assert_eq!(replay, original);
    assert_eq!(
        hex::encode(sha256(&replay)),
        "a953f5e4d7f72a371312b44639f689910aca814be4cf66c428a432b815da9648"
    );
}
