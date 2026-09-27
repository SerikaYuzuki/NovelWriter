use fuminiwa_sync_server_v2::application::{binding_matches, parse_command};
use fuminiwa_sync_server_v2::auth_domain::{
    AccountId, AuthError, AuthenticatedPrincipal, OperationId, SessionGrant, SessionId, TenantId,
    CREATE_CHALLENGE_COMMAND, EXCHANGE_APPLE_COMMAND, REVOKE_SESSION_COMMAND,
    ROTATE_REFRESH_COMMAND,
};
use fuminiwa_sync_server_v2::auth_wire::{
    decode_exchange_response, encode_exchange_response, parse_auth_command, AuthCommand,
    ClientPlatform,
};
use fuminiwa_sync_server_v2::domain::{canonical_json, PROTOCOL_EPOCH};
use serde_json::json;

#[test]
fn accepted_commands_match_the_audited_canonical_digests() {
    let create = br#"{"clientPlatform":"macos","flow":"native","operationId":"10000000-0000-4000-8000-000000000002","provider":"apple"}"#;
    let parsed = parse_auth_command(CREATE_CHALLENGE_COMMAND, create).unwrap();
    assert_eq!(
        hex::encode(parsed.digest),
        "4f44d7abc543ae94b555744edecf0a67707a178460f017e59c511d0f1799ed53"
    );
    assert_eq!(parsed.canonical_bytes, create);
    match parsed.command {
        AuthCommand::CreateChallenge(command) => {
            assert_eq!(command.platform, ClientPlatform::Macos);
            assert_eq!(command.platform.audience(), "dev.serikayuzuki.fuminiwa");
        }
        _ => panic!("wrong command"),
    }

    let exchange = br#"{"authorizationCode":"fixture-apple-code-success","challengeId":"20000000-0000-4000-8000-000000000001","identityToken":"fixtureHeader.fixturePayload.fixtureSignature","operationId":"30000000-0000-4000-8000-000000000001","provider":"apple","state":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"}"#;
    assert_eq!(
        hex::encode(
            parse_auth_command(EXCHANGE_APPLE_COMMAND, exchange)
                .unwrap()
                .digest
        ),
        "75a40223cf4b218d38daf9793971e2c0d71eef47e4b2f5f96a1b7956f1d088e5"
    );
    let exchange_debug = format!(
        "{:?}",
        parse_auth_command(EXCHANGE_APPLE_COMMAND, exchange).unwrap()
    );
    assert!(!exchange_debug.contains("fixture-apple-code-success"));
    assert!(!exchange_debug.contains("fixturePayload"));

    let refresh = br#"{"rotationId":"50000000-0000-4000-8000-000000000001"}"#;
    assert_eq!(
        hex::encode(
            parse_auth_command(ROTATE_REFRESH_COMMAND, refresh)
                .unwrap()
                .digest
        ),
        "2940fdbc17870d157b88ae03f77975c4df643d5e5d14a6c5b6456085eb0aa865"
    );

    let revoke =
        br#"{"operationId":"60000000-0000-4000-8000-000000000001","scope":"currentSession"}"#;
    assert_eq!(
        hex::encode(
            parse_auth_command(REVOKE_SESSION_COMMAND, revoke)
                .unwrap()
                .digest
        ),
        "6bfd63f8f66aaaa28baccffe95c84028f5ad0b8d63206675fa74fc0a916d00e1"
    );
}

#[test]
fn parser_rejects_client_authority_duplicates_unknowns_and_noncanonical_json() {
    let with_audience = br#"{"audience":"attacker.example","clientPlatform":"macos","flow":"native","operationId":"10000000-0000-4000-8000-000000000002","provider":"apple"}"#;
    assert_eq!(
        parse_auth_command(CREATE_CHALLENGE_COMMAND, with_audience).unwrap_err(),
        AuthError::InvalidRequest
    );

    let duplicate = br#"{"clientPlatform":"macos","clientPlatform":"ios","flow":"native","operationId":"10000000-0000-4000-8000-000000000002","provider":"apple"}"#;
    assert_eq!(
        parse_auth_command(CREATE_CHALLENGE_COMMAND, duplicate).unwrap_err(),
        AuthError::InvalidRequest
    );

    let unknown = br#"{"clientPlatform":"macos","flow":"native","operationId":"10000000-0000-4000-8000-000000000002","provider":"apple","x":true}"#;
    assert_eq!(
        parse_auth_command(CREATE_CHALLENGE_COMMAND, unknown).unwrap_err(),
        AuthError::InvalidRequest
    );

    let whitespace = br#"{ "clientPlatform":"macos","flow":"native","operationId":"10000000-0000-4000-8000-000000000002","provider":"apple"}"#;
    assert_eq!(
        parse_auth_command(CREATE_CHALLENGE_COMMAND, whitespace).unwrap_err(),
        AuthError::InvalidRequest
    );

    let uppercase_uuid = br#"{"clientPlatform":"macos","flow":"native","operationId":"10000000-0000-4000-8000-00000000000A","provider":"apple"}"#;
    assert_eq!(
        parse_auth_command(CREATE_CHALLENGE_COMMAND, uppercase_uuid).unwrap_err(),
        AuthError::InvalidIdentifier
    );

    let missing_exchange_provider = br#"{"authorizationCode":"code","challengeId":"20000000-0000-4000-8000-000000000001","identityToken":"token","operationId":"30000000-0000-4000-8000-000000000001","state":"state"}"#;
    assert_eq!(
        parse_auth_command(EXCHANGE_APPLE_COMMAND, missing_exchange_provider).unwrap_err(),
        AuthError::InvalidRequest
    );

    let invalid_state = br#"{"authorizationCode":"code","challengeId":"20000000-0000-4000-8000-000000000001","identityToken":"a.b.c","operationId":"30000000-0000-4000-8000-000000000001","provider":"apple","state":"not-256-bit"}"#;
    assert_eq!(
        parse_auth_command(EXCHANGE_APPLE_COMMAND, invalid_state).unwrap_err(),
        AuthError::InvalidRequest
    );

    let invalid_jws = br#"{"authorizationCode":"code","challengeId":"20000000-0000-4000-8000-000000000001","identityToken":"not-a-compact-jws","operationId":"30000000-0000-4000-8000-000000000001","provider":"apple","state":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"}"#;
    assert_eq!(
        parse_auth_command(EXCHANGE_APPLE_COMMAND, invalid_jws).unwrap_err(),
        AuthError::InvalidRequest
    );
}

#[test]
fn session_receipt_is_closed_openapi_shaped_jcs_and_hydrates_internal_tenant() {
    let tenant = TenantId::new("tenant_fixture").unwrap();
    let grant = SessionGrant {
        principal: AuthenticatedPrincipal {
            account_id: AccountId::new("acct_AAAAAAAAAAAAAAAA").unwrap(),
            tenant_id: tenant.clone(),
            session_id: SessionId::new("40000000-0000-4000-8000-000000000001").unwrap(),
            account_auth_epoch: 1,
            account_fence: vec![0x11; 32],
        },
        access_token: format!("fma1_{}", "A".repeat(43)),
        refresh_token: format!("fmr1_{}", "B".repeat(43)),
        refresh_generation: 1,
        access_expires_at_unix: 1_776_470_100,
        refresh_expires_at_unix: 1_784_245_200,
    };
    let bytes = encode_exchange_response(
        &grant,
        "00000000-0000-4000-8000-000000000001",
        &OperationId::new("30000000-0000-4000-8000-000000000001").unwrap(),
    )
    .unwrap();
    let value: serde_json::Value = serde_json::from_slice(&bytes).unwrap();
    assert_eq!(
        value
            .as_object()
            .unwrap()
            .keys()
            .cloned()
            .collect::<Vec<_>>(),
        ["binding", "receipt", "tokens"]
    );
    assert!(value.get("principal").is_none());
    assert!(bytes
        .windows(b"tenant_fixture".len())
        .all(|window| window != b"tenant_fixture"));
    assert_eq!(decode_exchange_response(&bytes, tenant).unwrap(), grant);
}

#[test]
fn auth_binding_projects_live_sync_v2_epoch_into_authenticated_command_scope() {
    let tenant = TenantId::new("tenant_fixture").unwrap();
    let grant = SessionGrant {
        principal: AuthenticatedPrincipal {
            account_id: AccountId::new("acct_AAAAAAAAAAAAAAAA").unwrap(),
            tenant_id: tenant,
            session_id: SessionId::new("40000000-0000-4000-8000-000000000001").unwrap(),
            account_auth_epoch: 1,
            account_fence: vec![0x11; 32],
        },
        access_token: format!("fma1_{}", "A".repeat(43)),
        refresh_token: format!("fmr1_{}", "B".repeat(43)),
        refresh_generation: 1,
        access_expires_at_unix: 1_776_470_100,
        refresh_expires_at_unix: 1_784_245_200,
    };
    let response = encode_exchange_response(
        &grant,
        "00000000-0000-4000-8000-000000000001",
        &OperationId::new("30000000-0000-4000-8000-000000000001").unwrap(),
    )
    .unwrap();
    let auth: serde_json::Value = serde_json::from_slice(&response).unwrap();
    assert_eq!(auth["binding"]["syncProtocolEpoch"], PROTOCOL_EPOCH);
    let mut old_auth = auth.clone();
    old_auth["binding"]["syncProtocolEpoch"] = json!(1);
    let old_auth_bytes = canonical_json(&old_auth).unwrap();
    assert!(
        decode_exchange_response(&old_auth_bytes, TenantId::new("tenant_fixture").unwrap())
            .is_err()
    );

    let binding = &auth["binding"];
    let sync_principal = fuminiwa_sync_server_v2::AuthenticatedPrincipal {
        account_id: binding["accountId"].as_str().unwrap().into(),
        account_fence: binding["accountFence"].as_str().unwrap().into(),
        account_auth_epoch: 1,
        server_instance_id: binding["serverInstanceId"].as_str().unwrap().into(),
        protocol_epoch: binding["syncProtocolEpoch"].as_i64().unwrap(),
    };
    let command_value = json!({
        "binding": {
            "accountFence": sync_principal.account_fence.clone(),
            "accountId": sync_principal.account_id.clone(),
            "protocolEpoch": sync_principal.protocol_epoch,
            "serverInstanceId": sync_principal.server_instance_id.clone()
        },
        "commandId": "00000000-0000-4000-8000-000000000001",
        "commandKind": "createWork",
        "payload": {
            "documentId": "00000000-0000-0000-0000-000000000002",
            "workId": "00000000-0000-0000-0000-000000000003"
        },
        "schemaVersion": 2,
        "sourceGeneration": 1,
        "sourceSnapshotId": "0000000000000000000000000000000000000000000000000000000000000000"
    });
    let command_bytes = canonical_json(&command_value).unwrap();
    let command = parse_command(&command_bytes).unwrap();
    assert!(binding_matches(&command.value, &sync_principal));

    let mut wrong_epoch = command_value;
    wrong_epoch["binding"]["protocolEpoch"] = json!(1);
    let wrong_bytes = canonical_json(&wrong_epoch).unwrap();
    assert!(matches!(
        parse_command(&wrong_bytes),
        Err(fuminiwa_sync_server_v2::SyncError::ProtocolEpochMismatch)
    ));
}
