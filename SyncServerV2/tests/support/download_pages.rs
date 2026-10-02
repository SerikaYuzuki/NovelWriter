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
    let (cold_status, _, cold_bytes) =
        get(context, account, &format!("{path}&include=totals")).await;
    assert_eq!(cold_status, StatusCode::OK);
    let cold: Value = serde_json::from_slice(&cold_bytes).unwrap();
    assert_eq!(canonical_json(&cold).unwrap(), cold_bytes);
    assert!(cold.get("totals").is_some());
    let mut cursor: Option<String> = None;
    let mut seen = BTreeSet::new();
    let mut total_bytes = 0_u64;
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
        assert!(value.get("totals").is_none());
        let items = value["items"].as_array().unwrap();
        assert!(items.len() <= 256);
        let mut decoded_size = 0;
        for item in items {
            let bytes = URL_SAFE_NO_PAD
                .decode(item["bytesBase64URL"].as_str().unwrap())
                .unwrap();
            decoded_size += bytes.len();
            total_bytes += bytes.len() as u64;
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
    let (status, _, bytes) = get(context, account, &format!("{path}&include=totals")).await;
    assert_eq!(status, StatusCode::OK);
    let enriched: Value = serde_json::from_slice(&bytes).unwrap();
    assert_eq!(cold["totals"], enriched["totals"]);
    assert_eq!(
        get(context, account, &format!("{path}&include=unknown"))
            .await
            .0,
        StatusCode::UNPROCESSABLE_ENTITY
    );
    assert_eq!(
        enriched["totals"],
        serde_json::json!({"items":seen.len(),"bytes":total_bytes})
    );
    let cursor = enriched["nextCursor"].as_str().unwrap();
    let (status, _, bytes) = get(context, account, &format!("{path}&cursor={cursor}")).await;
    assert_eq!(status, StatusCode::OK);
    let later: Value = serde_json::from_slice(&bytes).unwrap();
    assert!(later.get("totals").is_none());
    assert_ne!(
        get(
            context,
            account,
            &format!("{path}&cursor={cursor}&include=totals")
        )
        .await
        .0,
        StatusCode::OK
    );
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

pub(super) async fn seed_snapshot(
    context: &ScenarioContext,
    work: Uuid,
    parents: &[[u8; 32]],
    entries: &[Value],
) -> [u8; 32] {
    let mut parents: Vec<_> = parents.iter().map(hex::encode).collect();
    parents.sort();
    let mut entries = entries.to_vec();
    entries.sort_by_key(|e| e["entityKey"].as_str().unwrap().to_owned());
    let bytes = canonical_json(&serde_json::json!({"schemaVersion":2,"workId":work,"parentSnapshotIds":parents,"entries":entries})).unwrap();
    let id = sha256(&bytes);
    let account = &context.account_a.account_id;
    let mut tx = context.repo.pool.begin().await.unwrap();
    sqlx::query("INSERT INTO sync_v2.snapshots(account_id,work_id,snapshot_id,manifest_bytes,manifest_digest,created_at) VALUES($1,$2,$3,$4,$3,now())")
        .bind(account).bind(work).bind(id.as_slice()).bind(bytes).execute(&mut *tx).await.unwrap();
    for parent in parents {
        sqlx::query("INSERT INTO sync_v2.snapshot_parents(account_id,work_id,snapshot_id,parent_snapshot_id) VALUES($1,$2,$3,$4)")
            .bind(account).bind(work).bind(id.as_slice()).bind(hex::decode(parent).unwrap()).execute(&mut *tx).await.unwrap();
    }
    for entry in entries {
        sqlx::query("INSERT INTO sync_v2.snapshot_entries(account_id,snapshot_id,entity_key,object_id,byte_count,content_type) VALUES($1,$2,$3,$4,$5,$6)")
            .bind(account).bind(id.as_slice()).bind(entry["entityKey"].as_str().unwrap())
            .bind(hex::decode(entry["objectId"].as_str().unwrap()).unwrap()).bind(entry["byteCount"].as_i64().unwrap())
            .bind(entry["contentType"].as_str().unwrap()).execute(&mut *tx).await.unwrap();
    }
    tx.commit().await.unwrap();
    id
}

/// Synthetic persisted graph fixtures isolate download transport boundaries from
/// registerSnapshot's separate entity-materialization validation scenarios.
pub(super) async fn verify_merge_and_page_boundaries(context: &ScenarioContext) {
    let account = &context.account_a.account_id;
    let work = context.primary_work;
    let mut entries = Vec::new();
    let mut eligible = BTreeSet::new();
    let mut unavailable = Vec::new();
    for index in 0..12u8 {
        let size = if index == 9 {
            256 * 1024 + 1
        } else {
            256 * 1024
        };
        let bytes = vec![index; size];
        let id = sha256(&bytes);
        let state = match index {
            10 => "quarantined",
            11 => "deleting",
            _ => "available",
        };
        let mut tx = context.repo.pool.begin().await.unwrap();
        context
            .repo
            .object_store
            .put(&mut tx, &id, &bytes)
            .await
            .unwrap();
        sqlx::query(
            "INSERT INTO sync_v2.account_objects(account_id,object_id,state) VALUES($1,$2,$3)",
        )
        .bind(account)
        .bind(id.as_slice())
        .bind(state)
        .execute(&mut *tx)
        .await
        .unwrap();
        tx.commit().await.unwrap();
        entries.push(serde_json::json!({"entityKey":format!("attachment/{}/bytes",Uuid::new_v4()),"objectId":hex::encode(id),"byteCount":size,"contentType":"application/octet-stream"}));
        if index < 9 {
            eligible.insert(hex::encode(id));
        } else {
            unavailable.push(hex::encode(id));
        }
    }
    // Diamond: the common root and shared objects must appear exactly once.
    let root = seed_snapshot(context, work, &[], &entries[..9]).await;
    let left = seed_snapshot(context, work, &[root], &entries[..10]).await;
    let right = seed_snapshot(context, work, &[root], &entries[..11]).await;
    let head = seed_snapshot(context, work, &[left, right], &entries).await;
    let path = format!("/v2/works/{work}/download?snapshotId={}", hex::encode(head));
    let mut next = Some(path.clone());
    let mut seen = BTreeSet::new();
    let mut previous = None;
    let mut pages = 0;
    while let Some(url) = next {
        let (status, _, bytes) = get(context, account, &url).await;
        assert_eq!(
            status,
            StatusCode::OK,
            "{}",
            String::from_utf8_lossy(&bytes)
        );
        let value: Value = serde_json::from_slice(&bytes).unwrap();
        assert_eq!(canonical_json(&value).unwrap(), bytes);
        let items = value["items"].as_array().unwrap();
        let mut size = 0;
        for item in items {
            let key = (
                item["kind"].as_str().unwrap().to_owned(),
                item["id"].as_str().unwrap().to_owned(),
            );
            assert!(previous.as_ref().map_or(true, |old| old < &key));
            previous = Some(key.clone());
            assert!(seen.insert(key));
            let raw = URL_SAFE_NO_PAD
                .decode(item["bytesBase64URL"].as_str().unwrap())
                .unwrap();
            size += raw.len();
            assert_eq!(item["id"], hex::encode(sha256(&raw)));
        }
        assert!(size <= 2 * 1024 * 1024);
        pages += 1;
        assert!(pages < 5);
        next = value["nextCursor"]
            .as_str()
            .map(|cursor| format!("{path}&cursor={cursor}"));
    }
    assert_eq!(
        seen.iter().filter(|(kind, _)| kind == "manifest").count(),
        4
    );
    for id in &eligible {
        assert!(seen.contains(&("object".into(), id.clone())));
    }
    for id in &unavailable {
        assert!(!seen.contains(&("object".into(), id.clone())));
    }
    assert_eq!(seen.len(), 13);

    let (_, _, bytes) = get(context, account, &format!("{path}&include=totals")).await;
    let value: Value = serde_json::from_slice(&bytes).unwrap();
    let ids: Vec<Vec<u8>> = [root, left, right, head]
        .iter()
        .map(|id| id.to_vec())
        .collect();
    let manifest_bytes: i64 = sqlx::query_scalar("SELECT sum(octet_length(manifest_bytes))::bigint FROM sync_v2.snapshots WHERE account_id=$1 AND snapshot_id=ANY($2::bytea[])")
        .bind(account).bind(ids).fetch_one(&context.repo.pool).await.unwrap();
    let object_bytes: u64 = entries
        .iter()
        .map(|entry| entry["byteCount"].as_u64().unwrap())
        .sum();
    assert_eq!(
        value["totals"],
        serde_json::json!({"items":4+entries.len(),"bytes":manifest_bytes as u64+object_bytes})
    );

    // Valid existing cursor format: start immediately after the last manifest.
    // Nine exactly-256 KiB objects must produce eight (2 MiB) then one.
    let after = [root, left, right, head].into_iter().max().unwrap();
    let cursor = URL_SAFE_NO_PAD.encode(
        canonical_json(&serde_json::json!({
            "accountId":account,"accountFence":context.account_a.account_fence,
            "serverInstanceId":context.account_a.server_instance_id,"protocolEpoch":2,
            "workId":work,"snapshotId":hex::encode(head),"afterKind":0,"afterId":hex::encode(after)
        }))
        .unwrap(),
    );
    let (status, _, bytes) = get(context, account, &format!("{path}&cursor={cursor}")).await;
    assert_eq!(status, StatusCode::OK);
    let value: Value = serde_json::from_slice(&bytes).unwrap();
    assert_eq!(value["items"].as_array().unwrap().len(), 8);
    let cursor2 = value["nextCursor"].as_str().unwrap();
    let (status, _, bytes) = get(context, account, &format!("{path}&cursor={cursor2}")).await;
    assert_eq!(status, StatusCode::OK);
    let value: Value = serde_json::from_slice(&bytes).unwrap();
    assert_eq!(value["items"].as_array().unwrap().len(), 1);
    assert!(value["nextCursor"].is_null());

    // A warm metadata cache cannot freeze availability or bypass quarantine.
    let quarantined = eligible.first().unwrap();
    sqlx::query("UPDATE sync_v2.account_objects SET state='quarantined' WHERE account_id=$1 AND object_id=$2")
        .bind(account).bind(hex::decode(quarantined).unwrap()).execute(&context.repo.pool).await.unwrap();
    let (status, _, bytes) = get(context, account, &format!("{path}&cursor={cursor}")).await;
    assert_eq!(status, StatusCode::OK);
    let value: Value = serde_json::from_slice(&bytes).unwrap();
    assert_eq!(value["items"].as_array().unwrap().len(), 8);
    assert!(value["nextCursor"].is_null());
    assert!(value["items"]
        .as_array()
        .unwrap()
        .iter()
        .all(|item| item["id"] != *quarantined));
    // Batched missing lookup retains caller order and treats quarantine as missing.
    let mut requested: Vec<String> = (0..512)
        .map(|i| hex::encode(sha256(format!("missing-{i}").as_bytes())))
        .collect();
    requested.insert(17, hex::encode(context.object_id));
    requested.insert(23, quarantined.clone());
    let expected: Vec<_> = requested
        .iter()
        .filter(|id| **id != hex::encode(context.object_id))
        .cloned()
        .collect();
    let body =
        canonical_json(&serde_json::json!({"schemaVersion":2,"workId":work,"objectIds":requested}))
            .unwrap();
    let (status, _, bytes) = request(
        context,
        account,
        "POST",
        "/v2/objects/missing",
        Some(body),
        Some(SYNC_MEDIA_TYPE),
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    let value: Value = serde_json::from_slice(&bytes).unwrap();
    assert_eq!(value["missingObjectIds"], serde_json::json!(expected));
    let duplicate = canonical_json(
        &serde_json::json!({"schemaVersion":2,"workId":work,"objectIds":[quarantined,quarantined]}),
    )
    .unwrap();
    assert_eq!(
        request(
            context,
            account,
            "POST",
            "/v2/objects/missing",
            Some(duplicate),
            Some(SYNC_MEDIA_TYPE)
        )
        .await
        .0,
        StatusCode::UNPROCESSABLE_ENTITY
    );
}
