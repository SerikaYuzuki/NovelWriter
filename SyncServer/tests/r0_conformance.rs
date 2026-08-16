use serde_json::Value;
use sha2::{Digest, Sha256};
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
    for file in &files {
        let bytes = fs::read(file).expect("fixture must be readable");
        let value: Value = serde_json::from_slice(&bytes).expect("fixture must be valid JSON");
        vectors += verify(&value, file, "$");
    }
    assert!(
        vectors > 0,
        "reviewed fixtures must contain canonical vectors"
    );
}
