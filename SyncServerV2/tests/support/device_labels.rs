use super::*;

async fn labelled_post(
    context: &ScenarioContext,
    path: &str,
    body: Vec<u8>,
    label: Option<&str>,
    media: &str,
) -> (StatusCode, Vec<u8>) {
    let app = router(AppState {
        repo: Arc::new(context.repo.clone()),
        access_authenticator: fixture_authenticator(),
    });
    let mut request = Request::builder()
        .method("POST")
        .uri(path)
        .body(Body::from(body))
        .unwrap();
    *request.headers_mut() = headers(&context.account_a.account_id);
    request
        .headers_mut()
        .insert("content-type", HeaderValue::from_str(media).unwrap());
    if let Some(label) = label {
        request.headers_mut().insert(
            "fuminiwa-device-label",
            HeaderValue::from_str(label).unwrap(),
        );
    }
    let response = app.oneshot(request).await.unwrap();
    (
        response.status(),
        to_bytes(response.into_body(), 64 * 1024 * 1024)
            .await
            .unwrap()
            .to_vec(),
    )
}

pub async fn verify(context: &ScenarioContext) {
    let account = &context.account_a.account_id;
    // Every INSERT path, including both rows of keep-both, actually carried metadata.
    for reason in [
        "publish",
        "preAdoptionLocal",
        "conflictResolution",
        "keepBothCloneRoot",
        "restoreBefore",
    ] {
        let count: i64 = sqlx::query_scalar("SELECT count(*) FROM sync_v2.history WHERE account_id=$1 AND reason=$2 AND device_label='保存元テスト'")
            .bind(account).bind(reason).fetch_one(&context.repo.pool).await.unwrap();
        assert!(count > 0, "unlabelled path {reason}");
    }
    // Plain reads are exactly the old shape/bytes, even with labelled database rows.
    let path = format!("/v2/works/{}/history?pageSize=1", context.primary_work);
    let (_, _, plain) = get(context, account, &path).await;
    let (_, _, opt) = get(context, account, &(path.clone() + "&include=deviceLabel")).await;
    let mut value: Value = serde_json::from_slice(&opt).unwrap();
    assert_eq!(value["items"][0]["deviceLabel"], "保存元テスト");
    for item in value["items"].as_array_mut().unwrap() {
        item.as_object_mut().unwrap().remove("deviceLabel");
    }
    assert_eq!(canonical_json(&value).unwrap(), plain);
    // Opt-in neither changes the server cursor nor needs labels in it.
    assert_eq!(
        value["nextCursor"],
        serde_json::from_slice::<Value>(&plain).unwrap()["nextCursor"]
    );

    // Transaction start timestamps need not follow commit/lock ordering.
    sqlx::query("UPDATE sync_v2.conflict_candidates SET created_at='2000-01-01T00:00:00Z' WHERE account_id=$1 AND work_id=$2")
        .bind(account).bind(context.active_conflict_work).execute(&context.repo.pool).await.unwrap();
    let path = format!("/v2/works/{}/conflict", context.active_conflict_work);
    let (_, _, plain) = get(context, account, &path).await;
    let (_, _, opt) = get(context, account, &(path + "?include=deviceLabel")).await;
    let mut value: Value = serde_json::from_slice(&opt).unwrap();
    assert_eq!(value["conflict"]["remoteDeviceLabel"], "保存元テスト");
    value["conflict"]
        .as_object_mut()
        .unwrap()
        .remove("remoteDeviceLabel");
    assert_eq!(canonical_json(&value).unwrap(), plain);

    // A different retry header never changes already committed rows/receipt bytes.
    let bytes: Vec<u8> = sqlx::query_scalar("SELECT canonical_request FROM sync_v2.sealed_commands WHERE account_id=$1 AND command_kind='publish' AND work_id=$2 LIMIT 1")
        .bind(account).bind(context.primary_work).fetch_one(&context.repo.pool).await.unwrap();
    let cmd = parse_command(&bytes).unwrap();
    let before: Vec<(Uuid, Option<String>)> = sqlx::query_as("SELECT occurrence_id,device_label FROM sync_v2.history WHERE account_id=$1 ORDER BY event_id")
        .bind(account).fetch_all(&context.repo.pool).await.unwrap();
    let expected = context
        .repo
        .command(&context.account_a, &cmd)
        .await
        .unwrap();
    let replay = labelled_post(
        context,
        &format!("/v2/works/{}/publish", context.primary_work),
        bytes,
        Some("Different"),
        SYNC_MEDIA_TYPE,
    )
    .await;
    assert_eq!(replay.0.as_u16() as i32, expected.0);
    assert_eq!(replay.1, expected.1);
    let after: Vec<(Uuid, Option<String>)> = sqlx::query_as("SELECT occurrence_id,device_label FROM sync_v2.history WHERE account_id=$1 ORDER BY event_id")
        .bind(account).fetch_all(&context.repo.pool).await.unwrap();
    assert_eq!(before, after);

    // Recovery invokes ordinary publish; absent/malformed metadata never fails it.
    for (label, expected) in [
        (Some("%E4%BB%95%E4%BA%8BMac"), Some("仕事Mac")),
        (None, None),
        (Some(""), None),
        (Some("%GG"), None),
        (Some("%0A"), None),
        (Some("%00"), None),
        (Some("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"), None),
    ] {
        let new_work = Uuid::new_v4();
        let body = serde_json::to_vec(&serde_json::json!({"operationId":Uuid::new_v4(),"snapshotId":hex::encode(context.root_snapshot),"newWorkId":new_work,"newDocumentId":Uuid::new_v4()})).unwrap();
        let path = format!("/v2/protection/{}/recover", context.primary_work);
        let (status, response) =
            labelled_post(context, &path, body.clone(), label, "application/json").await;
        assert_eq!(status, StatusCode::OK);
        let saved: Option<String> = sqlx::query_scalar(
            "SELECT device_label FROM sync_v2.history WHERE account_id=$1 AND work_id=$2",
        )
        .bind(account)
        .bind(new_work)
        .fetch_one(&context.repo.pool)
        .await
        .unwrap();
        assert_eq!(saved.as_deref(), expected);
        assert_eq!(
            labelled_post(context, &path, body, Some("Changed"), "application/json")
                .await
                .1,
            response
        );
        let saved_again: Option<String> = sqlx::query_scalar(
            "SELECT device_label FROM sync_v2.history WHERE account_id=$1 AND work_id=$2",
        )
        .bind(account)
        .bind(new_work)
        .fetch_one(&context.repo.pool)
        .await
        .unwrap();
        assert_eq!(saved_again, saved);
        if expected.is_none() {
            let (_, _, old_read) =
                get(context, account, &format!("/v2/works/{new_work}/history")).await;
            assert!(!String::from_utf8(old_read).unwrap().contains("deviceLabel"));
            let (_, _, new_read) = get(
                context,
                account,
                &format!("/v2/works/{new_work}/history?include=deviceLabel"),
            )
            .await;
            assert!(
                serde_json::from_slice::<Value>(&new_read).unwrap()["items"][0]["deviceLabel"]
                    .is_null()
            );
        }
        context
            .repo
            .delete_work(&context.account_a, new_work)
            .await
            .unwrap();
        sqlx::query("UPDATE sync_v2.deleted_works SET deleted_at=now()-interval '2 years' WHERE account_id=$1 AND work_id=$2")
            .bind(account).bind(new_work).execute(&context.repo.pool).await.unwrap();
        context.repo.purge_expired_works().await.unwrap();
        let remaining: i64 = sqlx::query_scalar(
            "SELECT count(*) FROM sync_v2.history WHERE account_id=$1 AND work_id=$2",
        )
        .bind(account)
        .bind(new_work)
        .fetch_one(&context.repo.pool)
        .await
        .unwrap();
        assert_eq!(remaining, 0);
    }
}
