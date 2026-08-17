use fuminiwa_sync_server_v2::auth_domain::*;

fn apple_challenge() -> ChallengeClaim {
    ChallengeClaim {
        id: ChallengeId::new("20000000-0000-4000-8000-000000000001").unwrap(),
        operation_id: OperationId::new("10000000-0000-4000-8000-000000000001").unwrap(),
        provider_config_id: ProviderConfigId::new(APPLE_PROVIDER_CONFIG).unwrap(),
        audience: "dev.serikayuzuki.fuminiwa".into(),
        platform: "macos".into(),
        state_hash: vec![0x11; 32],
        nonce_hash: vec![0x22; 32],
        phase: ChallengePhase::ProviderCallStarted,
        lease_until_unix: 301,
        expires_at_unix: 301,
    }
}

#[test]
fn apple_identity_is_provider_closed_and_account_opaque() {
    let challenge = apple_challenge();
    let evidence = AppleIdentityEvidence::from_verified_claims(
        ProviderConfigId::new(APPLE_PROVIDER_CONFIG).unwrap(),
        APPLE_ISSUER,
        "fixture-subject",
        challenge.audience.clone(),
        challenge.nonce_hash.clone(),
        1,
        None,
    )
    .unwrap();
    let identity = VerifiedExternalIdentity::bind_apple(evidence, &challenge, 1).unwrap();
    assert_eq!(
        identity.provider_config_id().as_str(),
        APPLE_PROVIDER_CONFIG
    );
    assert_eq!(identity.exact_issuer(), APPLE_ISSUER);
    assert!(identity.validate_durable_for_challenge(&challenge).is_ok());
    assert!(AccountId::new("apple-subject").is_ok());
    assert_ne!(identity.subject(), "apple-subject");
    assert!(!format!("{identity:?}").contains("fixture-subject"));
}

#[test]
fn apple_identity_binding_rejects_wrong_config_audience_and_nonce() {
    let challenge = apple_challenge();
    for (config, audience, nonce, expected) in [
        (
            "apple-other-config",
            challenge.audience.as_str(),
            challenge.nonce_hash.clone(),
            AuthError::ProviderNotAllowed,
        ),
        (
            APPLE_PROVIDER_CONFIG,
            "dev.serikayuzuki.fuminiwa.ios",
            challenge.nonce_hash.clone(),
            AuthError::ProviderNotAllowed,
        ),
        (
            APPLE_PROVIDER_CONFIG,
            challenge.audience.as_str(),
            vec![0x33; 32],
            AuthError::InvalidRequest,
        ),
    ] {
        let evidence = AppleIdentityEvidence::from_verified_claims(
            ProviderConfigId::new(config).unwrap(),
            APPLE_ISSUER,
            "fixture-subject",
            audience,
            nonce,
            1,
            None,
        )
        .unwrap();
        assert_eq!(
            VerifiedExternalIdentity::bind_apple(evidence, &challenge, 1).unwrap_err(),
            expected
        );
    }
}

#[test]
fn auth_debug_views_redact_tokens_and_receipt_bytes() {
    let grant = SessionGrant {
        principal: AuthenticatedPrincipal {
            account_id: AccountId::new("acct_AAAAAAAAAAAAAAAA").unwrap(),
            tenant_id: TenantId::new("tenant_AAAAAAAAAAAAAA").unwrap(),
            session_id: SessionId::new("40000000-0000-4000-8000-000000000001").unwrap(),
            account_auth_epoch: 1,
            account_fence: vec![0x11; 32],
        },
        access_token: "fma1_access-secret".into(),
        refresh_token: "fmr1_refresh-secret".into(),
        refresh_generation: 1,
        access_expires_at_unix: 2,
        refresh_expires_at_unix: 3,
    };
    let receipt = AuthReceipt {
        operation_id: OperationId::new("30000000-0000-4000-8000-000000000001").unwrap(),
        command_kind: EXCHANGE_APPLE_COMMAND.into(),
        request_digest: [0x22; 32],
        response_bytes: b"response-containing-token".to_vec(),
        status: 200,
        session_grant: Some(grant),
    };
    let debug = format!("{receipt:?}");
    assert!(!debug.contains("access-secret"));
    assert!(!debug.contains("refresh-secret"));
    assert!(!debug.contains("response-containing-token"));
}

#[test]
fn challenge_and_refresh_transitions_are_fail_closed() {
    assert!(ChallengePhase::Claimed.can_start_provider());
    assert!(!ChallengePhase::ProviderCallStarted.can_start_provider());
    assert!(ChallengePhase::ProviderCallStarted.can_store_result());
    assert!(ChallengePhase::ProviderResultKnown.can_terminal());
    assert!(!ChallengePhase::Terminal.can_terminal());
    assert!(RefreshFamilyState::Active.can_rotate());
    assert!(!RefreshFamilyState::ReuseDetected.can_rotate());
    assert!(RefreshFamilyState::Rotated.can_revoke_for_reuse());
}

#[test]
fn fence_requires_opaque_256_bit_value_and_positive_epoch() {
    assert!(AccountFence::new(1, vec![0; 32]).is_ok());
    assert!(AccountFence::new(0, vec![0; 32]).is_err());
    assert!(AccountFence::new(1, vec![0; 31]).is_err());
}

#[test]
fn apple_credentials_are_partitioned_by_original_audience() {
    let mac = VerifiedProviderCredential {
        audience: "dev.serikayuzuki.fuminiwa".into(),
        encrypted_refresh_token: SealedSecret {
            key_version: 3,
            ciphertext: b"mac-ciphertext".to_vec(),
        },
    };
    let ios = VerifiedProviderCredential {
        audience: "dev.serikayuzuki.fuminiwa.ios".into(),
        encrypted_refresh_token: SealedSecret {
            key_version: 3,
            ciphertext: b"ios-ciphertext".to_vec(),
        },
    };
    assert_ne!(mac.audience, ios.audience);
    assert_ne!(
        mac.encrypted_refresh_token.ciphertext,
        ios.encrypted_refresh_token.ciphertext
    );
}

#[test]
fn auth_schema_has_no_plaintext_provider_secret_columns() {
    let sql = std::fs::read_to_string(concat!(
        env!("CARGO_MANIFEST_DIR"),
        "/migrations/0002_auth_v1.sql"
    ))
    .unwrap();
    assert!(!sql.contains("subject TEXT"));
    assert!(!sql.contains("authorization_code TEXT"));
    assert!(!sql.contains("refresh_token TEXT"));
    assert!(sql.contains("subject_lookup_hmac BYTEA"));
    assert!(sql.contains("response_ciphertext BYTEA"));
    assert!(sql.contains("response_digest BYTEA"));
    assert!(sql.contains("octet_length(response_digest)=32"));
    assert!(sql.contains("event_key_hmac BYTEA"));
    assert!(sql.contains("request_digest BYTEA"));
    assert!(!sql.contains("raw_jws"));
    assert!(!sql.contains("subject_jti"));
}
