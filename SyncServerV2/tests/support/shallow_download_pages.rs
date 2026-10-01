//! Opt-in PostgreSQL + Axum assertions, including warm-cache mutable checks.
use super::download_pages::seed_snapshot;
use super::*;
use fuminiwa_sync_server_v2::domain::sha256;
use std::collections::{BTreeMap, BTreeSet};

type Digest = [u8; 32];

async fn seed_object(context: &ScenarioContext, n: usize, size: usize) -> Value {
    let mut bytes = vec![0; size];
    let tag = format!("D-106-{n:08}");
    bytes[..tag.len()].copy_from_slice(tag.as_bytes());
    let id = sha256(&bytes);
    let mut tx = context.repo.pool.begin().await.unwrap();
    context
        .repo
        .object_store
        .put(&mut tx, &id, &bytes)
        .await
        .unwrap();
    sqlx::query(
        "INSERT INTO sync_v2.account_objects(account_id,object_id,state) VALUES($1,$2,'available')",
    )
    .bind(&context.account_a.account_id)
    .bind(id.as_slice())
    .execute(&mut *tx)
    .await
    .unwrap();
    tx.commit().await.unwrap();
    serde_json::json!({"entityKey":format!("attachment/{}/bytes",Uuid::new_v4()),"objectId":hex::encode(id),"byteCount":size,"contentType":"application/octet-stream"})
}

async fn ok_page(context: &ScenarioContext, path: &str) -> (Value, Vec<u8>) {
    let (status, headers, bytes) = get(context, &context.account_a.account_id, path).await;
    assert_eq!(
        status,
        StatusCode::OK,
        "{}",
        String::from_utf8_lossy(&bytes)
    );
    assert_eq!(headers["cache-control"], "no-store");
    assert_eq!(headers["pragma"], "no-cache");
    let page: Value = serde_json::from_slice(&bytes).unwrap();
    assert_eq!(canonical_json(&page).unwrap(), bytes);
    let items = page["items"].as_array().unwrap();
    assert!(items.len() <= 256);
    let mut raw_size = 0;
    for item in items {
        let raw = URL_SAFE_NO_PAD
            .decode(item["bytesBase64URL"].as_str().unwrap())
            .unwrap();
        raw_size += raw.len();
        assert_eq!(hex::encode(sha256(&raw)), item["id"]);
    }
    assert!(raw_size <= 2 * 1024 * 1024 || (items.len() == 1 && items[0]["kind"] == "manifest"));
    assert!(page["nextCursor"].is_null() || !items.is_empty());
    (page, bytes)
}

fn decode_cursor(cursor: &Value) -> Value {
    serde_json::from_slice(&URL_SAFE_NO_PAD.decode(cursor.as_str().unwrap()).unwrap()).unwrap()
}

fn encode_cursor(cursor: &Value) -> String {
    URL_SAFE_NO_PAD.encode(canonical_json(cursor).unwrap())
}

// An independent reference for the D-101/D-105 bytes. Fetch the entire fixture
// graph here (not production query/cache/paging code), sort identities, construct
// the original closed envelope and cursor, then compare every byte of each page.
async fn assert_legacy_bytes(context: &ScenarioContext, head: Digest) {
    let account = &context.account_a.account_id;
    let rows = sqlx::query(r#"WITH RECURSIVE a(id) AS (
        SELECT $3::bytea UNION SELECT p.parent_snapshot_id FROM sync_v2.snapshot_parents p JOIN a ON p.snapshot_id=a.id WHERE p.account_id=$1 AND p.work_id=$2
    ) SELECT 0::smallint AS kind,s.snapshot_id AS id,s.manifest_bytes AS bytes FROM sync_v2.snapshots s JOIN a ON s.snapshot_id=a.id WHERE s.account_id=$1 AND s.work_id=$2
    UNION ALL SELECT 1::smallint,b.object_id,b.raw_bytes FROM sync_v2.global_blobs b JOIN sync_v2.account_objects o ON o.object_id=b.object_id AND o.account_id=$1 WHERE o.state='available' AND b.object_id IN (SELECT e.object_id FROM sync_v2.snapshot_entries e JOIN a ON e.snapshot_id=a.id WHERE e.account_id=$1)"#)
        .bind(account).bind(context.primary_work).bind(head.as_slice()).fetch_all(&context.repo.pool).await.unwrap();
    let mut all: Vec<(i16, Vec<u8>, Vec<u8>)> = rows
        .iter()
        .map(|r| (r.get("kind"), r.get("id"), r.get("bytes")))
        .collect();
    all.sort_by(|a, b| (&a.0, &a.1).cmp(&(&b.0, &b.1)));
    let totals =
        serde_json::json!({"items":all.len(),"bytes":all.iter().map(|i|i.2.len()).sum::<usize>()});
    all.retain(|i| i.0 == 0 || i.2.len() <= 256 * 1024);
    let path = format!(
        "/v2/works/{}/download?snapshotId={}",
        context.primary_work,
        hex::encode(head)
    );
    let mut start = 0;
    let mut request_cursor = None;
    loop {
        let mut end = start;
        let mut size = 0;
        while end < all.len() && end - start < 256 {
            if end > start && size + all[end].2.len() > 2 * 1024 * 1024 {
                break;
            }
            size += all[end].2.len();
            end += 1;
        }
        let next = if end < all.len() {
            Some(encode_cursor(
                &serde_json::json!({"accountId":account,"accountFence":context.account_a.account_fence,
                "serverInstanceId":context.account_a.server_instance_id,"protocolEpoch":context.account_a.protocol_epoch,
                "workId":context.primary_work,"snapshotId":hex::encode(head),"afterKind":all[end-1].0,"afterId":hex::encode(&all[end-1].1)}),
            ))
        } else {
            None
        };
        let items: Vec<_>=all[start..end].iter().map(|i|serde_json::json!({"kind":if i.0==0 {"manifest"} else {"object"},"id":hex::encode(&i.1),"bytesBase64URL":URL_SAFE_NO_PAD.encode(&i.2)})).collect();
        let expected = serde_json::json!({"result":"noChanges","snapshotId":hex::encode(head),"items":items,"nextCursor":next});
        let url = request_cursor
            .as_ref()
            .map_or(path.clone(), |c| format!("{path}&cursor={c}"));
        let (_, bytes) = ok_page(context, &url).await;
        assert_eq!(bytes, canonical_json(&expected).unwrap());
        if start == 0 {
            let mut expected = expected;
            expected["totals"] = totals.clone();
            let (_, bytes) = ok_page(context, &format!("{path}&include=totals")).await;
            assert_eq!(bytes, canonical_json(&expected).unwrap());
        }
        if next.is_none() {
            break;
        }
        request_cursor = next;
        start = end;
    }
}

pub(super) async fn verify_shallow_download(context: &ScenarioContext) -> Vec<String> {
    let work = context.primary_work;
    let account = &context.account_a.account_id;
    let shared = seed_object(context, 0, 32).await;
    let ancient = seed_object(context, 1, 32).await;
    let mut huge_group = vec![shared.clone(), ancient.clone()];
    for n in 2..302 {
        huge_group.push(seed_object(context, n, 32).await);
    }
    // Also force a byte-boundary split and exercise separately fetched objects.
    for n in 302..312 {
        huge_group.push(seed_object(context, n, 256 * 1024).await);
    }
    let large = seed_object(context, 312, 256 * 1024 + 1).await;
    huge_group.push(large.clone());
    let r = seed_snapshot(context, work, &[], &[shared.clone(), ancient.clone()]).await;
    let a = seed_snapshot(context, work, &[r], std::slice::from_ref(&ancient)).await;
    let b = seed_snapshot(context, work, &[a], &huge_group).await;
    let c = seed_snapshot(context, work, &[r], std::slice::from_ref(&shared)).await;
    let m = seed_snapshot(context, work, &[b, c], std::slice::from_ref(&shared)).await;
    let h = seed_snapshot(context, work, &[m, r], std::slice::from_ref(&shared)).await;
    let path = format!("/v2/works/{work}/download?snapshotId={}", hex::encode(h));
    assert_legacy_bytes(context, h).await;

    let (head, _) = ok_page(context, &format!("{path}&mode=head&include=totals")).await;
    assert_eq!(head["mode"], "head");
    assert!(head.get("resumeCursor").is_none());
    let head_items = head["items"].as_array().unwrap();
    assert_eq!(head_items.len(), 2);
    assert_eq!(head_items[0]["id"], hex::encode(h));
    assert_eq!(head_items[1]["id"], shared["objectId"]);
    assert!(head["nextCursor"].is_null());
    assert_eq!(head["totals"]["items"], 2);
    let head_size: usize = head_items
        .iter()
        .map(|i| {
            URL_SAFE_NO_PAD
                .decode(i["bytesBase64URL"].as_str().unwrap())
                .unwrap()
                .len()
        })
        .sum();
    assert_eq!(head["totals"]["bytes"], head_size);
    let (plain_head, _) = ok_page(context, &format!("{path}&mode=head")).await;
    assert!(plain_head.get("totals").is_none());
    let (huge_head, _) = ok_page(
        context,
        &format!(
            "/v2/works/{work}/download?snapshotId={}&mode=head&include=totals",
            hex::encode(b)
        ),
    )
    .await;
    let head_cursor = huge_head["nextCursor"].clone();
    assert!(head_cursor.is_string());
    assert_eq!(decode_cursor(&head_cursor)["kind"], "head");

    let backfill_path = format!("{path}&mode=backfill");
    let (first, first_bytes) = ok_page(context, &format!("{backfill_path}&include=totals")).await;
    let (warm, warm_bytes) = ok_page(context, &format!("{backfill_path}&include=totals")).await;
    assert_eq!(first_bytes, warm_bytes);
    assert_eq!(first, warm);
    assert_eq!(first["items"][0]["id"], hex::encode(m));
    assert_eq!(
        decode_cursor(&first["resumeCursor"])["afterSnapshotId"],
        hex::encode(m)
    );
    assert_eq!(decode_cursor(&first["resumeCursor"])["afterItem"], 0);
    let (restart, _) = ok_page(
        context,
        &format!(
            "{backfill_path}&cursor={}",
            first["resumeCursor"].as_str().unwrap()
        ),
    )
    .await;
    assert_eq!(restart["items"][0], first["items"][1]);
    assert_eq!(restart["resumeCursor"], first["resumeCursor"]);

    let mut page = first.clone();
    let mut seen = BTreeSet::new();
    let mut manifests = vec![];
    let mut raw_total = 0;
    let mut last_closed = Value::Null;
    let mut count = 0;
    loop {
        for item in page["items"].as_array().unwrap() {
            assert!(seen.insert((
                item["kind"].as_str().unwrap().to_owned(),
                item["id"].as_str().unwrap().to_owned()
            )));
            assert_ne!(item["id"], shared["objectId"]);
            assert_ne!(item["id"], large["objectId"]);
            raw_total += URL_SAFE_NO_PAD
                .decode(item["bytesBase64URL"].as_str().unwrap())
                .unwrap()
                .len();
            if item["kind"] == "manifest" {
                manifests.push(item["id"].as_str().unwrap().to_owned());
                last_closed = item["id"].clone();
            }
        }
        assert_eq!(
            decode_cursor(&page["resumeCursor"])["afterSnapshotId"],
            last_closed
        );
        count += 1;
        assert!(count < 10);
        let Some(cursor) = page["nextCursor"].as_str() else {
            break;
        };
        page = ok_page(context, &format!("{backfill_path}&cursor={cursor}"))
            .await
            .0;
        assert!(page.get("totals").is_none());
    }
    assert!(count >= 2);
    let mut siblings = vec![hex::encode(a), hex::encode(c)];
    siblings.sort();
    assert_eq!(
        manifests,
        [
            vec![hex::encode(m), hex::encode(b)],
            siblings,
            vec![hex::encode(r)]
        ]
        .concat()
    );
    assert_eq!(
        first["totals"],
        serde_json::json!({"items":seen.len()+1,"bytes":raw_total+256*1024+1})
    );
    let (terminal, _) = ok_page(
        context,
        &format!(
            "{backfill_path}&cursor={}",
            page["resumeCursor"].as_str().unwrap()
        ),
    )
    .await;
    assert!(terminal["items"].as_array().unwrap().is_empty());
    assert!(terminal["nextCursor"].is_null());
    assert_eq!(terminal["resumeCursor"], page["resumeCursor"]);

    // Query grammar, closed/bound cursors, all three cursor families.
    let backfill_cursor = first["nextCursor"].as_str().unwrap();
    for suffix in [
        "mode=invalid",
        "mode=head&extra=1",
        "mode=backfill&include=no",
        "mode=head&include=no",
    ] {
        assert_eq!(
            get(context, account, &format!("{path}&{suffix}")).await.0,
            StatusCode::UNPROCESSABLE_ENTITY
        );
    }
    for url in [
        format!("{backfill_path}&cursor={backfill_cursor}&include=totals"),
        format!("{path}&mode=head&cursor={backfill_cursor}"),
        format!("{path}&cursor={backfill_cursor}"),
        format!("{backfill_path}&cursor={}", head_cursor.as_str().unwrap()),
    ] {
        assert_eq!(
            get(context, account, &url).await.0,
            StatusCode::UNPROCESSABLE_ENTITY
        );
    }
    let (legacy, _) = ok_page(context, &path).await;
    for mode in ["head", "backfill"] {
        assert_eq!(
            get(
                context,
                account,
                &format!(
                    "{path}&mode={mode}&cursor={}",
                    legacy["nextCursor"].as_str().unwrap()
                )
            )
            .await
            .0,
            StatusCode::UNPROCESSABLE_ENTITY
        );
    }
    let cursor_value = decode_cursor(&first["nextCursor"]);
    for (key, value, status) in [
        (
            "extra",
            serde_json::json!(true),
            StatusCode::UNPROCESSABLE_ENTITY,
        ),
        (
            "afterItem",
            serde_json::json!(99_999),
            StatusCode::UNPROCESSABLE_ENTITY,
        ),
        (
            "accountId",
            serde_json::json!("foreign"),
            StatusCode::FORBIDDEN,
        ),
        (
            "accountFence",
            serde_json::json!("stale"),
            StatusCode::FORBIDDEN,
        ),
        (
            "serverInstanceId",
            serde_json::json!("stale"),
            StatusCode::FORBIDDEN,
        ),
        ("protocolEpoch", serde_json::json!(3), StatusCode::FORBIDDEN),
        (
            "workId",
            serde_json::json!(Uuid::new_v4()),
            StatusCode::FORBIDDEN,
        ),
        (
            "snapshotId",
            serde_json::json!(hex::encode(r)),
            StatusCode::FORBIDDEN,
        ),
    ] {
        let mut bad = cursor_value.clone();
        bad[key] = value;
        assert_eq!(
            get(
                context,
                account,
                &format!("{backfill_path}&cursor={}", encode_cursor(&bad))
            )
            .await
            .0,
            status,
            "{key}"
        );
    }
    for mode in ["head", "backfill"] {
        let foreign = get(
            context,
            &context.account_b.account_id,
            &format!("{path}&mode={mode}"),
        )
        .await;
        let absent = get(
            context,
            &context.account_b.account_id,
            &format!(
                "/v2/works/{}/download?snapshotId={}&mode={mode}",
                Uuid::new_v4(),
                hex::encode(h)
            ),
        )
        .await;
        assert_eq!(foreign.0, StatusCode::NOT_FOUND);
        assert_eq!(foreign.2, absent.2);
    }
    // Warm head and warm backfill cannot bypass changing object availability.
    for state in ["quarantined", "deleting", "available"] {
        sqlx::query(
            "UPDATE sync_v2.account_objects SET state=$3 WHERE account_id=$1 AND object_id=$2",
        )
        .bind(account)
        .bind(hex::decode(shared["objectId"].as_str().unwrap()).unwrap())
        .bind(state)
        .execute(&context.repo.pool)
        .await
        .unwrap();
        for url in [
            format!("{path}&mode=head"),
            format!("{backfill_path}&cursor={backfill_cursor}"),
        ] {
            assert_eq!(
                get(context, account, &url).await.0,
                if state == "available" {
                    StatusCode::OK
                } else {
                    StatusCode::NOT_FOUND
                }
            );
        }
    }
    // No stale cache bypass for account-object ownership loss (the FK normally
    // prevents deleting ownership; changing its state exercises the deny path).
    let (no_ancestors, _) = ok_page(
        context,
        &format!(
            "/v2/works/{work}/download?snapshotId={}&mode=backfill&include=totals",
            hex::encode(r)
        ),
    )
    .await;
    assert_eq!(
        no_ancestors["totals"],
        serde_json::json!({"items":0,"bytes":0})
    );
    assert!(no_ancestors["resumeCursor"].is_null());
    // The same root's no-mode responses remain identical after both mode caches.
    assert_legacy_bytes(context, h).await;
    verify_deep_history(context).await;
    verify_concurrent_publish(context).await;
    vec![
        format!(
            "/v2/works/{work}/download?snapshotId={}&mode=head&cursor={}",
            hex::encode(b),
            head_cursor.as_str().unwrap()
        ),
        format!("{backfill_path}&cursor={backfill_cursor}"),
    ]
}

async fn verify_deep_history(context: &ScenarioContext) {
    let mut ids = Vec::new();
    let mut bytes = Vec::new();
    let mut parents = Vec::new();
    let mut previous: Option<Digest> = None;
    // Single bulk transaction avoids 4,100 network round trips in the gate.
    for _ in 0..4100 {
        let manifest = serde_json::json!({"schemaVersion":2,"workId":context.primary_work,"parentSnapshotIds":previous.map(hex::encode).into_iter().collect::<Vec<_>>(),"entries":[]});
        let raw = canonical_json(&manifest).unwrap();
        let id = sha256(&raw);
        if let Some(parent) = previous {
            parents.push((id.to_vec(), parent.to_vec()));
        }
        ids.push(id.to_vec());
        bytes.push(raw);
        previous = Some(id);
    }
    let mut tx = context.repo.pool.begin().await.unwrap();
    sqlx::query("INSERT INTO sync_v2.snapshots(account_id,work_id,snapshot_id,manifest_bytes,manifest_digest,created_at) SELECT $1,$2,id,raw,id,now() FROM unnest($3::bytea[],$4::bytea[]) AS t(id,raw)")
        .bind(&context.account_a.account_id).bind(context.primary_work).bind(&ids).bind(bytes).execute(&mut *tx).await.unwrap();
    let (children, parents): (Vec<_>, Vec<_>) = parents.into_iter().unzip();
    sqlx::query("INSERT INTO sync_v2.snapshot_parents(account_id,work_id,snapshot_id,parent_snapshot_id) SELECT $1,$2,child,parent FROM unnest($3::bytea[],$4::bytea[]) AS t(child,parent)")
        .bind(&context.account_a.account_id).bind(context.primary_work).bind(children).bind(parents).execute(&mut *tx).await.unwrap();
    tx.commit().await.unwrap();
    let path = format!(
        "/v2/works/{}/download?snapshotId={}&mode=backfill",
        context.primary_work,
        hex::encode(previous.unwrap())
    );
    let mut url = format!("{path}&include=totals");
    let mut received = vec![];
    let mut positions = BTreeMap::new();
    loop {
        let (page, _) = ok_page(context, &url).await;
        if received.is_empty() {
            assert_eq!(page["totals"]["items"], 4099);
        }
        for item in page["items"].as_array().unwrap() {
            assert_eq!(item["kind"], "manifest");
            positions.insert(item["id"].as_str().unwrap().to_owned(), received.len());
            received.push(item["id"].as_str().unwrap().to_owned());
        }
        let Some(cursor) = page["nextCursor"].as_str() else {
            break;
        };
        assert_eq!(page["nextCursor"], page["resumeCursor"]);
        url = format!("{path}&cursor={cursor}");
        assert!(received.len() < 4100);
    }
    assert_eq!(
        received,
        ids[..4099]
            .iter()
            .rev()
            .map(hex::encode)
            .collect::<Vec<_>>()
    );
    assert_eq!(positions.len(), 4099);
}

async fn verify_concurrent_publish(context: &ScenarioContext) {
    // This separate work uses the original valid entity fixture and the real
    // publish HTTP route, including head events, receipts and CAS validation.
    let account = &context.account_a.account_id;
    let work = Uuid::new_v4();
    sqlx::query("INSERT INTO sync_v2.works(account_id,work_id,document_id,state) SELECT account_id,$3,document_id,'bound' FROM sync_v2.works WHERE account_id=$1 AND work_id=$2")
        .bind(account).bind(context.primary_work).bind(work).execute(&context.repo.pool).await.unwrap();
    let bytes: Vec<u8> = sqlx::query_scalar(
        "SELECT manifest_bytes FROM sync_v2.snapshots WHERE account_id=$1 AND snapshot_id=$2",
    )
    .bind(account)
    .bind(context.root_snapshot.as_slice())
    .fetch_one(&context.repo.pool)
    .await
    .unwrap();
    let manifest: Value = serde_json::from_slice(&bytes).unwrap();
    let entries = manifest["entries"].as_array().unwrap();
    let root = seed_snapshot(context, work, &[], entries).await;
    let mut lineage = vec![root];
    for _ in 0..300 {
        let child = seed_snapshot(context, work, &[*lineage.last().unwrap()], entries).await;
        lineage.push(child);
    }
    let head = *lineage.last().unwrap();
    let publish_path = format!("/v2/works/{work}/publish");
    let initial = command_bytes(
        account,
        CommandKind::Publish,
        Uuid::new_v4(),
        work,
        head,
        1,
        serde_json::json!({"workId":work,"candidateSnapshotId":hex::encode(head),"expectedRemoteHead":null}),
    );
    let (status, _, bytes) = request(
        context,
        account,
        "POST",
        &publish_path,
        Some(initial),
        Some(SYNC_MEDIA_TYPE),
    )
    .await;
    assert_eq!(
        status,
        StatusCode::OK,
        "{}",
        String::from_utf8_lossy(&bytes)
    );
    let published: Value = serde_json::from_slice(&bytes).unwrap();
    let download_path = format!(
        "/v2/works/{work}/download?snapshotId={}&mode=backfill&include=totals",
        hex::encode(head)
    );
    let (before, before_bytes) = ok_page(context, &download_path).await;
    assert_eq!(before["items"][0]["id"], hex::encode(lineage[299]));
    assert_eq!(before["items"][1]["id"], hex::encode(lineage[298]));
    assert!(before["nextCursor"].is_string());
    let candidate = seed_snapshot(context, work, &[head], entries).await;
    let next = command_bytes(
        account,
        CommandKind::Publish,
        Uuid::new_v4(),
        work,
        candidate,
        2,
        serde_json::json!({"workId":work,"candidateSnapshotId":hex::encode(candidate),"expectedRemoteHead":published["head"]}),
    );
    let (publish_result, (_, during)) = tokio::join!(
        request(
            context,
            account,
            "POST",
            &publish_path,
            Some(next),
            Some(SYNC_MEDIA_TYPE)
        ),
        ok_page(context, &download_path)
    );
    assert_eq!(
        publish_result.0,
        StatusCode::OK,
        "{}",
        String::from_utf8_lossy(&publish_result.2)
    );
    let published: Value = serde_json::from_slice(&publish_result.2).unwrap();
    assert_eq!(published["head"]["snapshotId"], hex::encode(candidate));
    assert_eq!(during, before_bytes);
    assert_eq!(ok_page(context, &download_path).await.1, before_bytes);
    let mut page = before;
    let mut received = vec![];
    loop {
        received.extend(
            page["items"]
                .as_array()
                .unwrap()
                .iter()
                .map(|i| i["id"].as_str().unwrap().to_owned()),
        );
        let Some(cursor) = page["nextCursor"].as_str() else {
            break;
        };
        let path = format!(
            "/v2/works/{work}/download?snapshotId={}&mode=backfill&cursor={cursor}",
            hex::encode(head)
        );
        page = ok_page(context, &path).await.0;
    }
    assert_eq!(
        received,
        lineage[..300]
            .iter()
            .rev()
            .map(hex::encode)
            .collect::<Vec<_>>()
    );
}
