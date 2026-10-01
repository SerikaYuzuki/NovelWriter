use super::*;

#[test]
fn client_install_fixture_matches_rust_download_plan() {
    let base = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../docs/sync/v2/fixtures");
    let graph =
        strict_json(&std::fs::read(base.join("scenarios/shallow-install-backfill.json")).unwrap())
            .unwrap();
    let binding = &graph["binding"];
    let head = decode_digest(binding["snapshotId"].as_str().unwrap()).unwrap();
    let work = Uuid::parse_str(binding["workId"].as_str().unwrap()).unwrap();
    let mut principal = AuthenticatedPrincipal::fixture(binding["accountId"].as_str().unwrap());
    principal.account_fence = binding["accountFence"].as_str().unwrap().into();
    principal.server_instance_id = binding["serverInstanceId"].as_str().unwrap().into();
    for mode in ["head", "backfill"] {
        let snapshots = graph["snapshots"]
            .as_array()
            .unwrap()
            .iter()
            .filter_map(|row| {
                let bytes = URL_SAFE_NO_PAD
                    .decode(row["bytesBase64URL"].as_str().unwrap())
                    .unwrap();
                let id = sha256(&bytes);
                if mode == "head" && id != head {
                    return None;
                }
                let manifest = strict_json(&bytes).unwrap();
                Some(Snapshot {
                    id,
                    byte_count: bytes.len(),
                    parents: manifest["parentSnapshotIds"]
                        .as_array()
                        .unwrap()
                        .iter()
                        .map(|v| decode_digest(v.as_str().unwrap()).unwrap())
                        .collect(),
                    objects: manifest["entries"]
                        .as_array()
                        .unwrap()
                        .iter()
                        .map(|entry| Item {
                            id: decode_digest(entry["objectId"].as_str().unwrap()).unwrap(),
                            kind: 1,
                            byte_count: entry["byteCount"].as_u64().unwrap() as usize,
                        })
                        .collect(),
                })
            })
            .collect();
        let plan = build_plan(snapshots, head, mode).unwrap();
        let mut start = 0;
        for file in graph["pages"][mode].as_array().unwrap() {
            let bytes = std::fs::read(base.join("canonical").join(file.as_str().unwrap())).unwrap();
            let page = strict_json(&bytes).unwrap();
            let (end, resume) = plan.bounds(start);
            let items = page["items"].as_array().unwrap();
            assert_eq!(items.len(), end - start);
            for (item, position) in items.iter().zip(&plan.items[start..end]) {
                let raw = URL_SAFE_NO_PAD
                    .decode(item["bytesBase64URL"].as_str().unwrap())
                    .unwrap();
                assert_eq!(sha256(&raw), position.item.id);
                assert_eq!(raw.len(), position.item.byte_count);
                assert_eq!(
                    item["kind"],
                    if position.item.kind == 0 {
                        "manifest"
                    } else {
                        "object"
                    }
                );
            }
            if start == 0 {
                assert_eq!(page["totals"], plan.totals.value().unwrap());
            }
            if mode == "backfill" {
                assert_eq!(
                    page["resumeCursor"],
                    json!(resume.map(|i| plan
                        .cursor(i, &principal, work, &head, mode)
                        .encode()
                        .unwrap()))
                );
            }
            start = end;
        }
        assert_eq!(start, plan.items.len());
    }
}
