use fuminiwa_sync_server_v2::domain::{canonical_json, sha256};
use serde::Deserialize;
use serde_json::Value;
use std::{fs, path::PathBuf};

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
