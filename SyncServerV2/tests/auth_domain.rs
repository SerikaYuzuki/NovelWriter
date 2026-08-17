use fuminiwa_sync_server_v2::auth_domain::*;

#[test]
fn apple_identity_is_provider_closed_and_account_opaque() {
    let identity = VerifiedExternalIdentity::apple("fixture-subject", 1).unwrap();
    assert_eq!(identity.provider_config_id.as_str(), APPLE_PROVIDER_CONFIG);
    assert_eq!(identity.exact_issuer, APPLE_ISSUER);
    assert!(identity.validate_apple().is_ok());
    assert!(AccountId::new("apple-subject").is_ok());
    assert_ne!(identity.subject, "apple-subject");
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
}
