use super::*;
use fuminiwa_sync_server_v2::domain::sha256;
use std::collections::BTreeSet;

pub(super) async fn verify_download_pages(context: &ScenarioContext) {
    let account = &context.account_a.account_id;
    let work = context.primary_work;
    let bytes: Vec<u8> = sqlx::query_scalar(
        "SELECT manifest_bytes FROM sync_v2.snapshots WHERE account_id=$1 AND snapshot_id=$2",
    )
    .bind(account)
    .bind(context.root_snapshot.as_slice())
    .fetch_one(&context.repo.pool)
    .await
    .unwrap();
    let mut manifest: Value = serde_json::from_slice(&bytes).unwrap();
    let mut head = context.root_snapshot;
    // More than a page of immutable ancestors sharing the same object set.
    for _ in 0..300 {
        manifest["parentSnapshotIds"] = serde_json::json!([hex::encode(head)]);
        let bytes = canonical_json(&manifest).unwrap();
        let id = sha256(&bytes);
        sqlx::query("INSERT INTO sync_v2.snapshots(account_id,work_id,snapshot_id,manifest_bytes,manifest_digest,created_at) VALUES($1,$2,$3,$4,$3,now())")
            .bind(account).bind(work).bind(id.as_slice()).bind(bytes).execute(&context.repo.pool).await.unwrap();
        sqlx::query("INSERT INTO sync_v2.snapshot_parents(account_id,work_id,snapshot_id,parent_snapshot_id) VALUES($1,$2,$3,$4)")
            .bind(account).bind(work).bind(id.as_slice()).bind(head.as_slice()).execute(&context.repo.pool).await.unwrap();
        sqlx::query("INSERT INTO sync_v2.snapshot_entries(account_id,snapshot_id,entity_key,object_id,byte_count,content_type) SELECT account_id,$3,entity_key,object_id,byte_count,content_type FROM sync_v2.snapshot_entries WHERE account_id=$1 AND snapshot_id=$2")
            .bind(account).bind(context.root_snapshot.as_slice()).bind(id.as_slice()).execute(&context.repo.pool).await.unwrap();
        head = id;
    }
    let path = format!("/v2/works/{work}/download?snapshotId={}", hex::encode(head));
    let count_before: i64 = sqlx::query_scalar("SELECT count(*) FROM sync_v2.snapshots")
        .fetch_one(&context.repo.pool)
        .await
        .unwrap();
    let mut cursor: Option<String> = None;
    let mut seen = BTreeSet::new();
    let mut pages = 0;
    loop {
        let url = cursor
            .as_ref()
            .map_or(path.clone(), |cursor| format!("{path}&cursor={cursor}"));
        let (status, headers, bytes) = get(context, account, &url).await;
        assert_eq!(
            status,
            StatusCode::OK,
            "{}",
            String::from_utf8_lossy(&bytes)
        );
        assert_eq!(headers["cache-control"], "no-store");
        let value: Value = serde_json::from_slice(&bytes).unwrap();
        assert_eq!(canonical_json(&value).unwrap(), bytes);
        assert_eq!(value["snapshotId"], hex::encode(head));
        let items = value["items"].as_array().unwrap();
        assert!(items.len() <= 256);
        let mut decoded_size = 0;
        for item in items {
            let bytes = URL_SAFE_NO_PAD
                .decode(item["bytesBase64URL"].as_str().unwrap())
                .unwrap();
            decoded_size += bytes.len();
            assert_eq!(item["id"], hex::encode(sha256(&bytes)));
            assert!(seen.insert((
                item["kind"].as_str().unwrap().to_owned(),
                item["id"].as_str().unwrap().to_owned()
            )));
        }
        assert!(decoded_size <= 2 * 1024 * 1024 || items.len() == 1);
        pages += 1;
        cursor = value["nextCursor"].as_str().map(str::to_owned);
        if let Some(cursor) = &cursor {
            let wrong_head = format!(
                "/v2/works/{work}/download?snapshotId={}&cursor={cursor}",
                hex::encode(context.root_snapshot)
            );
            assert_eq!(
                get(context, account, &wrong_head).await.0,
                StatusCode::FORBIDDEN
            );
        } else {
            break;
        }
        assert!(pages < 5);
    }
    assert!(pages >= 2);
    assert_eq!(
        seen.iter().filter(|(kind, _)| kind == "manifest").count(),
        301
    );
    assert_eq!(
        seen.iter().filter(|(kind, _)| kind == "object").count(),
        manifest["entries"].as_array().unwrap().len()
    );
    assert_eq!(
        sqlx::query_scalar::<_, i64>("SELECT count(*) FROM sync_v2.snapshots")
            .fetch_one(&context.repo.pool)
            .await
            .unwrap(),
        count_before
    );

    let foreign = get(context, &context.account_b.account_id, &path).await;
    let absent = get(
        context,
        &context.account_b.account_id,
        &format!(
            "/v2/works/{}/download?snapshotId={}",
            Uuid::new_v4(),
            hex::encode(head)
        ),
    )
    .await;
    assert_eq!(foreign.0, StatusCode::NOT_FOUND);
    assert_eq!((foreign.0, foreign.2), (absent.0, absent.2));
}
