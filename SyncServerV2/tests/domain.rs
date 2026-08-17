use axum::http::{HeaderMap, HeaderValue};
use fuminiwa_sync_server_v2::{
    application::{binding_matches, parse_command, strict_json, validate_entity_payload},
    auth::{authenticate, RuntimeMode},
    domain::{canonical_json, replay_receipt, sha256},
    AuthenticatedPrincipal,
};
use serde_json::json;

#[test]
fn jcs_sorts_object_keys_and_is_byte_stable() {
    let value = json!({"z": 1, "a": [true, "日本語"]});
    let bytes = canonical_json(&value).unwrap();
    assert_eq!(bytes, r#"{"a":[true,"日本語"],"z":1}"#.as_bytes());
    assert_eq!(sha256(&bytes).len(), 32);
}

#[test]
fn jcs_object_key_order_uses_utf16_code_units() {
    let value = json!({"\u{e000}": 1, "\u{1f600}": 2});
    assert_eq!(
        canonical_json(&value).unwrap(),
        r#"{"😀":2,"":1}"#.as_bytes()
    );
}

#[test]
fn command_accepts_only_exact_canonical_bytes() {
    let value = json!({"binding":{"accountFence":"fixture-fence","accountId":"a","protocolEpoch":2,"serverInstanceId":"fixture-server"},"commandId":"00000000-0000-0000-0000-000000000001","commandKind":"createWork","payload":{"documentId":"00000000-0000-0000-0000-000000000002","workId":"00000000-0000-0000-0000-000000000003"},"schemaVersion":2,"sourceGeneration":1,"sourceSnapshotId":"0000000000000000000000000000000000000000000000000000000000000000"});
    let bytes = canonical_json(&value).unwrap();
    assert!(parse_command(&bytes).is_ok());
    let mut with_space = bytes.clone();
    with_space.push(b' ');
    assert!(parse_command(&with_space).is_err());
}

#[test]
fn fixture_auth_is_fail_closed_in_production() {
    let mut headers = HeaderMap::new();
    headers.insert(
        "authorization",
        HeaderValue::from_static("Bearer dev:account:fixture-fence"),
    );
    assert!(authenticate(
        &headers,
        RuntimeMode::Production,
        "fixture-server",
        "fixture-fence"
    )
    .is_err());
    let principal = authenticate(
        &headers,
        RuntimeMode::Test,
        "fixture-server",
        "fixture-fence",
    )
    .unwrap();
    assert_eq!(principal.account_id, "account");
}

#[test]
fn strict_json_rejects_non_contract_inputs() {
    let invalid_utf8 = [b'{', 0xff, b'}'];
    let cases: &[&[u8]] = &[
        b"\xef\xbb\xbf{}",
        b"{\"a\":1,\"a\":2}",
        br#"{"a":"\uD800"}"#,
        br#"{"a":"\uDC00"}"#,
        br#"{"a":-0}"#,
        br#"{"a":1.0}"#,
        br#"{"a":1e0}"#,
        br#"{"a":9007199254740992}"#,
        br#"{"a": 1}"#,
    ];
    assert!(strict_json(&invalid_utf8).is_err());
    for case in cases {
        assert!(
            strict_json(case).is_err(),
            "accepted {:?}",
            String::from_utf8_lossy(case)
        );
    }
}

#[test]
fn canonical_command_rejects_noncanonical_key_order_and_escapes() {
    let value = json!({
        "binding": {"accountFence":"fixture-fence","accountId":"a","protocolEpoch":2,"serverInstanceId":"fixture-server"},
        "commandId":"00000000-0000-0000-0000-000000000001", "commandKind":"createWork",
        "payload":{"documentId":"00000000-0000-0000-0000-000000000002","workId":"00000000-0000-0000-0000-000000000003"},
        "schemaVersion":2,"sourceGeneration":1,"sourceSnapshotId":"0000000000000000000000000000000000000000000000000000000000000000"
    });
    let canonical = canonical_json(&value).unwrap();
    assert!(parse_command(&canonical).is_ok());
    assert!(parse_command(br#"{"z":1,"a":2}"#).is_err());
    assert!(parse_command(br#"{"a":"\u0061"}"#).is_err());
}

#[test]
fn account_binding_is_non_disclosing_and_command_bytes_are_retained_exactly() {
    let principal = AuthenticatedPrincipal::fixture("account-a");
    let body = json!({
        "binding": {"accountFence":"fixture-fence","accountId":"account-a","protocolEpoch":2,"serverInstanceId":"fixture-server"},
        "commandId":"00000000-0000-0000-0000-000000000001", "commandKind":"createWork",
        "payload":{"documentId":"00000000-0000-0000-0000-000000000002","workId":"00000000-0000-0000-0000-000000000003"},
        "schemaVersion":2,"sourceGeneration":1,"sourceSnapshotId":"0000000000000000000000000000000000000000000000000000000000000000"
    });
    let bytes = canonical_json(&body).unwrap();
    let command = parse_command(&bytes).unwrap();
    assert_eq!(command.canonical_bytes, bytes);
    assert_eq!(command.request_digest, sha256(&command.canonical_bytes));
    assert!(binding_matches(&command.value, &principal));
    let foreign = AuthenticatedPrincipal::fixture("account-b");
    assert!(!binding_matches(&command.value, &foreign));
}

#[test]
fn receipt_replay_returns_the_exact_stored_response_or_rejects_reuse() {
    let response = br#"{"result":"applied","x":1}"#;
    let replay = replay_receipt(
        "createWork",
        &[7; 32],
        "createWork",
        &[7; 32],
        true,
        Some(201),
        Some(response),
    )
    .unwrap();
    assert_eq!(replay, Some((201, response.to_vec())));
    assert!(matches!(
        replay_receipt(
            "createWork",
            &[7; 32],
            "publish",
            &[7; 32],
            true,
            Some(201),
            Some(response)
        ),
        Err(fuminiwa_sync_server_v2::SyncError::CommandIdReused)
    ));
    assert!(matches!(
        replay_receipt(
            "createWork",
            &[7; 32],
            "createWork",
            &[8; 32],
            true,
            Some(201),
            Some(response)
        ),
        Err(fuminiwa_sync_server_v2::SyncError::CommandIdReused)
    ));
}

#[test]
fn entity_validator_enforces_schema_and_portable_references() {
    let character = json!({
        "age": null,
        "appearance": null,
        "background": null,
        "colorHex": "#C0392B",
        "firstPerson": "俺",
        "gender": null,
        "id": "00000000-0000-4000-8000-000000000103",
        "kana": "りゅうび",
        "memo": "主人公",
        "name": "劉備",
        "personality": null,
        "role": "主役",
        "secondPerson": null,
        "speechStyle": null
    });
    assert!(
        validate_entity_payload("character/00000000-0000-4000-8000-000000000103", &character)
            .is_ok()
    );
    let mut invalid = character.clone();
    invalid["colorHex"] = json!("red");
    assert!(
        validate_entity_payload("character/00000000-0000-4000-8000-000000000103", &invalid)
            .is_err()
    );
    let invalid_timestamp = json!({
        "documentCreatedAt": "2026-08-16T00:00:00+09:00",
        "documentId": "00000000-0000-4000-8000-000000000003"
    });
    assert!(validate_entity_payload("work/document", &invalid_timestamp).is_err());
}

#[test]
fn sync_migration_contains_fail_closed_server_identity() {
    let migration = include_str!("../migrations/0001_sync_v2.sql");
    for marker in [
        "fuminiwa-snapshot-sync-v2",
        "('protocol_epoch','2')",
        "('schema_version','2')",
        "631b0fed89a0031f33c9ac86b75695309c276d354d31e78b4a0db4eeb39c4657",
        "('deployment_id','unbound')",
    ] {
        assert!(migration.contains(marker), "missing server marker {marker}");
    }
}
