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
