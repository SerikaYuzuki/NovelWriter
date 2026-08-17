//! Explicit Auth v1 PostgreSQL conformance gate.
//!
//! The runner refuses ambient/LAN databases. It only accepts a fresh database
//! named `auth_v2_test` or `auth_v2_test_<unique>`, then applies migrations and executes the
//! concurrent transaction scenarios against that isolated authority.

use async_trait::async_trait;
use fuminiwa_sync_server_v2::auth_application::{
    AuthApplication, AuthRepository, HmacSecretHasher,
};
use fuminiwa_sync_server_v2::auth_domain::*;
use fuminiwa_sync_server_v2::auth_postgres::AuthPostgresRepository;
use fuminiwa_sync_server_v2::auth_wire::{parse_auth_command, ParsedAuthCommand};
use sqlx::{postgres::PgPoolOptions, PgPool, Row};
use std::collections::HashMap;
use std::error::Error;
use std::sync::{
    atomic::{AtomicU64, AtomicUsize, Ordering},
    Arc, Mutex,
};

type VaultEntry = (String, String, Vec<u8>);

#[derive(Clone, Default)]
struct ScenarioVault {
    entries: Arc<Mutex<HashMap<Vec<u8>, VaultEntry>>>,
    next: Arc<AtomicU64>,
}

#[async_trait]
impl CredentialVault for ScenarioVault {
    fn active_key_version(&self) -> i32 {
        7
    }

    async fn seal(
        &self,
        purpose: &str,
        row_id: &str,
        plaintext: &[u8],
    ) -> Result<SealedSecret, AuthError> {
        let handle = format!(
            "auth-v2-test-envelope-{}",
            self.next.fetch_add(1, Ordering::SeqCst)
        )
        .into_bytes();
        self.entries.lock().map_err(|_| AuthError::Vault)?.insert(
            handle.clone(),
            (purpose.into(), row_id.into(), plaintext.to_vec()),
        );
        Ok(SealedSecret {
            key_version: 1,
            ciphertext: handle,
        })
    }

    async fn open(
        &self,
        purpose: &str,
        row_id: &str,
        secret: &SealedSecret,
    ) -> Result<Vec<u8>, AuthError> {
        let entries = self.entries.lock().map_err(|_| AuthError::Vault)?;
        let (stored_purpose, stored_row, plaintext) =
            entries.get(&secret.ciphertext).ok_or(AuthError::Vault)?;
        if stored_purpose != purpose || stored_row != row_id {
            return Err(AuthError::Vault);
        }
        Ok(plaintext.clone())
    }
}

#[derive(Clone)]
struct ScenarioAppleProvider {
    subject: String,
    credential_by_audience: Arc<HashMap<String, SealedSecret>>,
    calls: Arc<AtomicUsize>,
}

#[async_trait]
impl AppleProvider for ScenarioAppleProvider {
    async fn exchange(
        &self,
        challenge: &ChallengeClaim,
        _authorization_code: &[u8],
        _identity_token: &[u8],
    ) -> Result<AppleIdentityEvidence, AuthError> {
        self.calls.fetch_add(1, Ordering::SeqCst);
        let provider_credential =
            self.credential_by_audience
                .get(&challenge.audience)
                .map(|secret| VerifiedProviderCredential {
                    audience: challenge.audience.clone(),
                    vault_context: format!("fixture-{}", challenge.audience),
                    encrypted_refresh_token: secret.clone(),
                });
        AppleIdentityEvidence::from_verified_claims(
            ProviderConfigId::new(APPLE_PROVIDER_CONFIG)?,
            APPLE_ISSUER,
            self.subject.clone(),
            challenge.audience.clone(),
            challenge.nonce_hash.clone(),
            unix_now(),
            provider_credential,
        )
    }

    async fn revoke(
        &self,
        _credential: &VerifiedProviderCredential,
        _operation_id: &OperationId,
    ) -> Result<(), AuthError> {
        Ok(())
    }
}

#[tokio::main]
async fn main() {
    match run().await {
        Ok(()) => println!("GO: Auth v1 isolated PostgreSQL scenarios passed"),
        Err(error) => {
            eprintln!("NO-GO: {error}");
            std::process::exit(2);
        }
    }
}

async fn run() -> Result<(), Box<dyn Error>> {
    let database_url = std::env::var("AUTH_V2_TEST_DATABASE_URL").map_err(|_| {
        "set AUTH_V2_TEST_DATABASE_URL to a fresh isolated auth_v2_test or auth_v2_test_<unique> database"
    })?;
    let pool = PgPoolOptions::new()
        .max_connections(12)
        .connect(&database_url)
        .await?;
    require_fresh_test_database(&pool).await?;
    sqlx::migrate!("./migrations").run(&pool).await?;
    seed_apple_config(&pool).await?;
    run_scenarios(&pool).await?;
    Ok(())
}

async fn require_fresh_test_database(pool: &PgPool) -> Result<(), Box<dyn Error>> {
    let database: String = sqlx::query("SELECT current_database() AS name")
        .fetch_one(pool)
        .await?
        .try_get("name")?;
    if !is_isolated_database_name(&database) {
        return Err(format!(
            "refusing database {database:?}; use auth_v2_test or auth_v2_test_<unique>"
        )
        .into());
    }
    let row = sqlx::query(
        r#"
        SELECT
          (SELECT count(*) FROM pg_namespace n
             WHERE n.nspname NOT IN ('pg_catalog','information_schema','public')
               AND n.nspname !~ '^pg_toast'
               AND n.nspname !~ '^pg_temp') AS user_schemas,
          (SELECT count(*) FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
             WHERE (n.nspname='public' OR (
               n.nspname NOT IN ('pg_catalog','information_schema')
               AND n.nspname !~ '^pg_toast'
               AND n.nspname !~ '^pg_temp'))
               AND c.relkind IN ('r','p','v','m','S','f')) AS user_relations,
          (SELECT count(*) FROM pg_type t JOIN pg_namespace n ON n.oid=t.typnamespace
             WHERE (n.nspname='public' OR (
               n.nspname NOT IN ('pg_catalog','information_schema')
               AND n.nspname !~ '^pg_toast'
               AND n.nspname !~ '^pg_temp'))
               AND t.typtype IN ('c','d','e','r','m')) AS user_types,
          (SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
             WHERE n.nspname='public' OR (
               n.nspname NOT IN ('pg_catalog','information_schema')
               AND n.nspname !~ '^pg_toast'
               AND n.nspname !~ '^pg_temp')) AS user_routines,
          (SELECT count(*) FROM pg_extension WHERE extname NOT IN ('plpgsql'))
            AS disallowed_extensions
        "#,
    )
    .fetch_one(pool)
    .await?;
    FreshDatabaseInventory {
        user_schemas: row.try_get("user_schemas")?,
        user_relations: row.try_get("user_relations")?,
        user_types: row.try_get("user_types")?,
        user_routines: row.try_get("user_routines")?,
        disallowed_extensions: row.try_get("disallowed_extensions")?,
    }
    .require_empty()
    .map_err(Into::into)
}

#[derive(Clone, Debug, Default, Eq, PartialEq)]
struct FreshDatabaseInventory {
    user_schemas: i64,
    user_relations: i64,
    user_types: i64,
    user_routines: i64,
    disallowed_extensions: i64,
}

impl FreshDatabaseInventory {
    fn require_empty(&self) -> Result<(), String> {
        if self == &Self::default() {
            Ok(())
        } else {
            Err(format!(
                "database is not completely fresh: schemas={}, relations={}, types={}, routines={}, disallowed_extensions={}",
                self.user_schemas,
                self.user_relations,
                self.user_types,
                self.user_routines,
                self.disallowed_extensions
            ))
        }
    }
}

fn is_isolated_database_name(name: &str) -> bool {
    name == "auth_v2_test"
        || name
            .strip_prefix("auth_v2_test_")
            .is_some_and(|suffix| !suffix.is_empty())
}

async fn seed_apple_config(pool: &PgPool) -> Result<(), sqlx::Error> {
    sqlx::query("INSERT INTO auth_v1.provider_configs(provider_config_id,provider_kind,exact_issuer,allowed_audiences,enabled,config_version) VALUES($1,'apple',$2,$3,true,1)")
        .bind(APPLE_PROVIDER_CONFIG)
        .bind(APPLE_ISSUER)
        .bind(vec![
            "dev.serikayuzuki.fuminiwa".to_owned(),
            "dev.serikayuzuki.fuminiwa.ios".to_owned(),
        ])
        .execute(pool)
        .await?;
    Ok(())
}

async fn run_scenarios(pool: &PgPool) -> Result<(), Box<dyn Error>> {
    let hasher = HmacSecretHasher::new([0x11; 32], [0x22; 32]);
    let vault = ScenarioVault::default();
    let mac_credential = vault
        .seal(
            "apple_provider_refresh_v1",
            "mac-fixture",
            b"mac-provider-secret-never-persisted-plain",
        )
        .await?;
    let ios_credential = vault
        .seal(
            "apple_provider_refresh_v1",
            "ios-fixture",
            b"ios-provider-secret-never-persisted-plain",
        )
        .await?;
    let provider = ScenarioAppleProvider {
        subject: "same-concurrent-apple-subject".into(),
        credential_by_audience: Arc::new(HashMap::from([
            ("dev.serikayuzuki.fuminiwa".into(), mac_credential.clone()),
            (
                "dev.serikayuzuki.fuminiwa.ios".into(),
                ios_credential.clone(),
            ),
        ])),
        calls: Arc::new(AtomicUsize::new(0)),
    };
    let repository = AuthPostgresRepository::new(
        pool.clone(),
        Arc::new(vault.clone()),
        hasher.token_key(),
        "00000000-0000-4000-8000-000000000001".into(),
    )?;
    let app = AuthApplication::new(repository.clone());
    let now = unix_now();

    let concurrent_create = parse_auth_command(
        CREATE_CHALLENGE_COMMAND,
        br#"{"clientPlatform":"macos","flow":"native","operationId":"10000000-0000-4000-8000-000000000010","provider":"apple"}"#,
    )?;
    let (create_left, create_right) = tokio::join!(
        app.create_challenge_from_wire(&concurrent_create, now),
        app.create_challenge_from_wire(&concurrent_create, now)
    );
    ensure(
        create_left? == create_right?,
        "concurrent createChallenge did not converge to one exact receipt",
    )?;
    let challenge_count: i64 = sqlx::query("SELECT count(*) AS count FROM auth_v1.auth_challenges WHERE operation_id='10000000-0000-4000-8000-000000000010'")
        .fetch_one(pool)
        .await?
        .try_get("count")?;
    ensure(
        challenge_count == 1,
        "concurrent createChallenge created duplicate challenges",
    )?;

    let invalid_challenge =
        create_challenge(&app, "10000000-0000-4000-8000-000000000009", "macos", now).await?;
    let invalid_exchange = exchange_command(
        "30000000-0000-4000-8000-000000000009",
        &invalid_challenge.challenge_id,
        "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
    )?;
    let reserved_before: i64 =
        sqlx::query("SELECT count(*) AS count FROM auth_v1.auth_operations WHERE state='reserved'")
            .fetch_one(pool)
            .await?
            .try_get("count")?;
    ensure(
        matches!(
            app.exchange_apple_from_wire(&invalid_exchange, &provider, &hasher, &vault, now)
                .await,
            Err(AuthError::InvalidRequest)
        ),
        "invalid challenge state was not rejected",
    )?;
    let invalid_operation_count: i64 = sqlx::query(
        "SELECT count(*) AS count FROM auth_v1.auth_operations WHERE operation_id='30000000-0000-4000-8000-000000000009'",
    )
    .fetch_one(pool)
    .await?
    .try_get("count")?;
    let reserved_after: i64 =
        sqlx::query("SELECT count(*) AS count FROM auth_v1.auth_operations WHERE state='reserved'")
            .fetch_one(pool)
            .await?
            .try_get("count")?;
    ensure(
        invalid_operation_count == 0 && reserved_after == reserved_before,
        "invalid exchange reserved a durable operation",
    )?;

    let mac_challenge =
        create_challenge(&app, "10000000-0000-4000-8000-000000000001", "macos", now).await?;
    let ios_challenge =
        create_challenge(&app, "10000000-0000-4000-8000-000000000002", "ios", now).await?;
    let mac_exchange = exchange_command(
        "30000000-0000-4000-8000-000000000001",
        &mac_challenge.challenge_id,
        &mac_challenge.state,
    )?;
    let ios_exchange = exchange_command(
        "30000000-0000-4000-8000-000000000002",
        &ios_challenge.challenge_id,
        &ios_challenge.state,
    )?;
    let (mac_result, ios_result) = tokio::join!(
        app.exchange_apple_from_wire(&mac_exchange, &provider, &hasher, &vault, now),
        app.exchange_apple_from_wire(&ios_exchange, &provider, &hasher, &vault, now)
    );
    let mac_grant = mac_result?;
    let ios_grant = ios_result?;
    ensure(
        mac_grant.principal.account_id == ios_grant.principal.account_id,
        "concurrent first login created more than one AccountID",
    )?;
    ensure(
        mac_grant.principal.account_fence == ios_grant.principal.account_fence,
        "same account received different fence",
    )?;
    ensure_count(pool, "auth_v1.accounts", 1).await?;
    ensure_count(pool, "auth_v1.external_identities", 1).await?;
    ensure_count(pool, "auth_v1.provider_credentials", 2).await?;
    let distinct_audiences: i64 = sqlx::query(
        "SELECT count(DISTINCT original_audience) AS count FROM auth_v1.provider_credentials",
    )
    .fetch_one(pool)
    .await?
    .try_get("count")?;
    ensure(distinct_audiences == 2, "multi-audience grants collapsed")?;

    let resume_provider = ScenarioAppleProvider {
        subject: "same-concurrent-apple-subject".into(),
        credential_by_audience: Arc::new(HashMap::new()),
        calls: Arc::new(AtomicUsize::new(0)),
    };
    let resume_challenge =
        create_challenge(&app, "10000000-0000-4000-8000-000000000008", "macos", now).await?;
    let resume_exchange = exchange_command(
        "30000000-0000-4000-8000-000000000008",
        &resume_challenge.challenge_id,
        &resume_challenge.state,
    )?;
    let resume_operation = OperationId::new("30000000-0000-4000-8000-000000000008")?;
    let resume_claim = match repository
        .claim_challenge_for_exchange(
            &resume_challenge.challenge_id,
            &resume_operation,
            resume_exchange.digest,
            &digest_request(resume_challenge.state.as_bytes()),
            now,
        )
        .await?
    {
        ChallengeClaimResult::ProviderCallRequired(value) => value,
        _ => return Err("resume fixture did not acquire the provider call".into()),
    };
    let resume_evidence = resume_provider
        .exchange(&resume_claim, b"fixture-code", b"fixture.token.signature")
        .await?;
    let resume_identity =
        VerifiedExternalIdentity::bind_apple(resume_evidence, &resume_claim, now)?;
    let durable = DurableVerifiedIdentity::from(&resume_identity);
    let durable_value = serde_json::to_value(&durable)?;
    let durable_bytes = fuminiwa_sync_server_v2::domain::canonical_json(&durable_value)?;
    let durable_secret = vault
        .seal(
            "verified_external_identity_v1",
            resume_challenge.challenge_id.as_str(),
            &durable_bytes,
        )
        .await?;
    repository
        .mark_provider_result_known(
            &resume_challenge.challenge_id,
            &resume_operation,
            &resume_identity,
            durable_secret,
        )
        .await?;
    let restarted_app = AuthApplication::new(repository.clone());
    restarted_app
        .exchange_apple_from_wire(
            &resume_exchange,
            &resume_provider,
            &hasher,
            &vault,
            now + 301,
        )
        .await?;
    ensure(
        resume_provider.calls.load(Ordering::SeqCst) == 1,
        "providerResultKnown restart called Apple a second time",
    )?;
    let resume_state = sqlx::query("SELECT c.phase,o.state AS operation_state FROM auth_v1.auth_challenges c JOIN auth_v1.auth_operations o ON o.operation_id=c.exchange_operation_id WHERE c.challenge_id=$1")
        .bind(uuid::Uuid::parse_str(resume_challenge.challenge_id.as_str())?)
        .fetch_one(pool)
        .await?;
    ensure(
        resume_state.try_get::<String, _>("phase")? == "terminal"
            && resume_state.try_get::<String, _>("operation_state")? == "completed",
        "providerResultKnown restart did not converge terminally",
    )?;

    let exchange_operation = OperationId::new("30000000-0000-4000-8000-000000000001")?;
    let exchange_receipt_before = app
        .repository
        .find_operation_receipt(
            &exchange_operation,
            EXCHANGE_APPLE_COMMAND,
            &mac_exchange.digest,
        )
        .await?
        .ok_or("missing exchange receipt")?;
    let provider_calls_before_replay = provider.calls.load(Ordering::SeqCst);
    let mac_replay = app
        .exchange_apple_from_wire(&mac_exchange, &provider, &hasher, &vault, now)
        .await?;
    let exchange_receipt_after = app
        .repository
        .find_operation_receipt(
            &exchange_operation,
            EXCHANGE_APPLE_COMMAND,
            &mac_exchange.digest,
        )
        .await?
        .ok_or("missing replayed exchange receipt")?;
    ensure(
        mac_replay == mac_grant
            && exchange_receipt_before.response_bytes == exchange_receipt_after.response_bytes
            && provider.calls.load(Ordering::SeqCst) == provider_calls_before_replay,
        "exchange lost ACK replay changed bytes or called Apple again",
    )?;

    let authenticated = app.authenticate_access(&mac_grant.access_token).await?;
    ensure(
        authenticated.account_id == mac_grant.principal.account_id,
        "access token principal changed account",
    )?;
    ensure(
        authenticated.session_id == mac_grant.principal.session_id,
        "access token principal changed session ID",
    )?;

    let refresh = parse_auth_command(
        ROTATE_REFRESH_COMMAND,
        br#"{"rotationId":"50000000-0000-4000-8000-000000000001"}"#,
    )?;
    let first = app
        .refresh_from_wire(&refresh, mac_grant.refresh_token.clone())
        .await?;
    let replay = app
        .refresh_from_wire(&refresh, mac_grant.refresh_token.clone())
        .await?;
    ensure(
        first == replay,
        "lost ACK did not replay exact refresh result",
    )?;
    ensure(
        first.receipt.as_ref().map(|value| &value.response_bytes)
            == replay.receipt.as_ref().map(|value| &value.response_bytes),
        "lost ACK replay bytes changed",
    )?;
    let expected_response_digest = digest_request(
        &first
            .receipt
            .as_ref()
            .ok_or("missing refresh receipt")?
            .response_bytes,
    );
    let stored_response_digests = sqlx::query("SELECT o.response_digest AS operation_digest,r.response_digest AS refresh_digest FROM auth_v1.auth_operations o JOIN auth_v1.session_refresh_receipts r USING(operation_id) WHERE o.operation_id='50000000-0000-4000-8000-000000000001'")
        .fetch_one(pool)
        .await?;
    ensure(
        stored_response_digests.try_get::<Vec<u8>, _>("operation_digest")?
            == expected_response_digest
            && stored_response_digests.try_get::<Vec<u8>, _>("refresh_digest")?
                == expected_response_digest,
        "encrypted refresh receipt digest was not stored consistently",
    )?;
    let rotated = first.grant.as_ref().ok_or("missing rotated grant")?;
    ensure(
        rotated.principal.account_id == mac_grant.principal.account_id
            && rotated.principal.account_fence == mac_grant.principal.account_fence
            && rotated.principal.account_auth_epoch == mac_grant.principal.account_auth_epoch,
        "normal refresh changed AccountID, epoch, or fence",
    )?;

    let reuse = parse_auth_command(
        ROTATE_REFRESH_COMMAND,
        br#"{"rotationId":"50000000-0000-4000-8000-000000000002"}"#,
    )?;
    let reuse_first = app
        .refresh_from_wire(&reuse, mac_grant.refresh_token.clone())
        .await?;
    let reuse_replay = app
        .refresh_from_wire(&reuse, mac_grant.refresh_token.clone())
        .await?;
    ensure(
        reuse_first.reused && reuse_first.receipt.as_ref().map(|value| value.status) == Some(401),
        "old token reuse was not receipted",
    )?;
    ensure(
        reuse_first == reuse_replay,
        "reuse lost ACK did not replay exact response",
    )?;
    ensure(
        app.authenticate_access(&rotated.access_token)
            .await
            .is_err(),
        "reuse did not revoke successor access",
    )?;

    sqlx::query("UPDATE auth_v1.accounts SET state='locked' WHERE account_id=$1")
        .bind(ios_grant.principal.account_id.as_str())
        .execute(pool)
        .await?;
    ensure(
        app.authenticate_access(&ios_grant.access_token)
            .await
            .is_err(),
        "locked account authenticated",
    )?;
    let locked_refresh = parse_auth_command(
        ROTATE_REFRESH_COMMAND,
        br#"{"rotationId":"50000000-0000-4000-8000-000000000003"}"#,
    )?;
    ensure(
        matches!(
            app.refresh_from_wire(&locked_refresh, ios_grant.refresh_token.clone())
                .await,
            Err(AuthError::SessionRevoked)
        ),
        "locked account refreshed",
    )?;
    sqlx::query("UPDATE auth_v1.accounts SET state='active' WHERE account_id=$1")
        .bind(ios_grant.principal.account_id.as_str())
        .execute(pool)
        .await?;
    sqlx::query("UPDATE auth_v1.external_identities SET state='revoked' WHERE account_id=$1")
        .bind(ios_grant.principal.account_id.as_str())
        .execute(pool)
        .await?;
    ensure(
        app.authenticate_access(&ios_grant.access_token)
            .await
            .is_err(),
        "revoked identity authenticated",
    )?;
    let revoked_identity_refresh = parse_auth_command(
        ROTATE_REFRESH_COMMAND,
        br#"{"rotationId":"50000000-0000-4000-8000-000000000004"}"#,
    )?;
    ensure(
        matches!(
            app.refresh_from_wire(&revoked_identity_refresh, ios_grant.refresh_token.clone())
                .await,
            Err(AuthError::SessionRevoked)
        ),
        "revoked identity refreshed",
    )?;
    sqlx::query("UPDATE auth_v1.external_identities SET state='active' WHERE account_id=$1")
        .bind(ios_grant.principal.account_id.as_str())
        .execute(pool)
        .await?;

    let revoke = parse_auth_command(
        REVOKE_SESSION_COMMAND,
        br#"{"operationId":"60000000-0000-4000-8000-000000000001","scope":"currentSession"}"#,
    )?;
    let revoke_first = app
        .revoke_current_session_from_wire(&revoke, ios_grant.principal.session_id.clone())
        .await?;
    let revoke_replay = app
        .revoke_current_session_from_wire(&revoke, ios_grant.principal.session_id.clone())
        .await?;
    ensure(
        revoke_first.response_bytes == revoke_replay.response_bytes,
        "revoke was not exact-idempotent",
    )?;
    let revoked_state = sqlx::query("SELECT s.state AS session_state,f.state AS family_state,(SELECT count(*) FROM auth_v1.refresh_tokens t WHERE t.family_id=f.family_id AND t.state='active') AS active_refresh_tokens,(SELECT count(*) FROM auth_v1.access_tokens a WHERE a.session_id=s.session_id AND a.revoked_at IS NULL) AS active_access_tokens FROM auth_v1.auth_sessions s JOIN auth_v1.refresh_families f ON f.family_id=s.family_id WHERE s.session_id=$1")
        .bind(uuid::Uuid::parse_str(ios_grant.principal.session_id.as_str())?)
        .fetch_one(pool)
        .await?;
    ensure(
        revoked_state.try_get::<String, _>("session_state")? == "revoked"
            && revoked_state.try_get::<String, _>("family_state")? == "revoked"
            && revoked_state.try_get::<i64, _>("active_refresh_tokens")? == 0
            && revoked_state.try_get::<i64, _>("active_access_tokens")? == 0,
        "sign-out did not revoke the complete session family",
    )?;
    let cross_kind = parse_auth_command(
        ROTATE_REFRESH_COMMAND,
        br#"{"rotationId":"60000000-0000-4000-8000-000000000001"}"#,
    )?;
    ensure(
        matches!(
            app.refresh_from_wire(&cross_kind, ios_grant.refresh_token.clone())
                .await,
            Err(AuthError::OperationIdReused)
        ),
        "operation ID was reused across command kinds",
    )?;

    let race_challenge =
        create_challenge(&app, "10000000-0000-4000-8000-000000000004", "macos", now).await?;
    let race_exchange = exchange_command(
        "30000000-0000-4000-8000-000000000004",
        &race_challenge.challenge_id,
        &race_challenge.state,
    )?;
    let race_grant = app
        .exchange_apple_from_wire(&race_exchange, &provider, &hasher, &vault, now)
        .await?;
    let race_left = parse_auth_command(
        ROTATE_REFRESH_COMMAND,
        br#"{"rotationId":"50000000-0000-4000-8000-000000000005"}"#,
    )?;
    let race_right = parse_auth_command(
        ROTATE_REFRESH_COMMAND,
        br#"{"rotationId":"50000000-0000-4000-8000-000000000006"}"#,
    )?;
    let (race_left_result, race_right_result) = tokio::join!(
        app.refresh_from_wire(&race_left, race_grant.refresh_token.clone()),
        app.refresh_from_wire(&race_right, race_grant.refresh_token.clone())
    );
    let race_outcomes = [race_left_result?, race_right_result?];
    ensure(
        race_outcomes
            .iter()
            .filter(|outcome| outcome.reused)
            .count()
            == 1
            && race_outcomes
                .iter()
                .filter(|outcome| outcome.grant.is_some())
                .count()
                == 1,
        "refresh race did not produce one successor and one reuse receipt",
    )?;
    let race_successor = race_outcomes
        .iter()
        .find_map(|outcome| outcome.grant.as_ref())
        .ok_or("refresh race missing successor")?;
    ensure(
        app.authenticate_access(&race_successor.access_token)
            .await
            .is_err(),
        "refresh race reuse did not revoke the successor session",
    )?;

    let other_provider = ScenarioAppleProvider {
        subject: "different-apple-subject".into(),
        credential_by_audience: Arc::new(HashMap::new()),
        calls: Arc::new(AtomicUsize::new(0)),
    };
    let other_challenge =
        create_challenge(&app, "10000000-0000-4000-8000-000000000003", "macos", now).await?;
    let other_exchange = exchange_command(
        "30000000-0000-4000-8000-000000000003",
        &other_challenge.challenge_id,
        &other_challenge.state,
    )?;
    let other_grant = app
        .exchange_apple_from_wire(&other_exchange, &other_provider, &hasher, &vault, now)
        .await?;
    ensure(
        other_grant.principal.account_id != mac_grant.principal.account_id,
        "different subject reused another AccountID",
    )?;
    ensure_count(pool, "auth_v1.accounts", 2).await?;
    ensure(
        app.authenticate_access("fma1_invalid-but-opaque")
            .await
            .err()
            == Some(AuthError::AccountNotFound),
        "unknown token disclosed a distinguishable account result",
    )?;

    let plaintext_matches: i64 = sqlx::query("SELECT (SELECT count(*) FROM auth_v1.external_identity_secrets WHERE position(convert_to('same-concurrent-apple-subject','UTF8') in ciphertext)>0) + (SELECT count(*) FROM auth_v1.provider_credentials WHERE position(convert_to('provider-secret-never-persisted-plain','UTF8') in ciphertext)>0) AS count")
        .fetch_one(pool)
        .await?
        .try_get("count")?;
    ensure(
        plaintext_matches == 0,
        "plaintext secret material reached PostgreSQL",
    )?;
    Ok(())
}

async fn create_challenge(
    app: &AuthApplication<AuthPostgresRepository>,
    operation_id: &str,
    platform: &str,
    now: i64,
) -> Result<fuminiwa_sync_server_v2::auth_application::ChallengeResult, Box<dyn Error>> {
    let raw = format!(
        "{{\"clientPlatform\":\"{platform}\",\"flow\":\"native\",\"operationId\":\"{operation_id}\",\"provider\":\"apple\"}}"
    );
    let parsed = parse_auth_command(CREATE_CHALLENGE_COMMAND, raw.as_bytes())?;
    Ok(app.create_challenge_from_wire(&parsed, now).await?)
}

fn exchange_command(
    operation_id: &str,
    challenge_id: &ChallengeId,
    state: &str,
) -> Result<ParsedAuthCommand, AuthError> {
    let raw = format!(
        "{{\"authorizationCode\":\"fixture-code\",\"challengeId\":\"{}\",\"identityToken\":\"fixture.token.signature\",\"operationId\":\"{operation_id}\",\"provider\":\"apple\",\"state\":\"{state}\"}}",
        challenge_id.as_str()
    );
    parse_auth_command(EXCHANGE_APPLE_COMMAND, raw.as_bytes())
}

async fn ensure_count(pool: &PgPool, table: &str, expected: i64) -> Result<(), Box<dyn Error>> {
    let query = format!("SELECT count(*) AS count FROM {table}");
    let count: i64 = sqlx::query(&query)
        .fetch_one(pool)
        .await?
        .try_get("count")?;
    ensure(
        count == expected,
        &format!("{table} count {count} != {expected}"),
    )
}

fn ensure(condition: bool, message: &str) -> Result<(), Box<dyn Error>> {
    if condition {
        Ok(())
    } else {
        Err(message.to_owned().into())
    }
}

fn unix_now() -> i64 {
    chrono::Utc::now().timestamp()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn fresh_database_guard_accepts_only_empty_inventory() {
        assert!(FreshDatabaseInventory::default().require_empty().is_ok());
        for inventory in [
            FreshDatabaseInventory {
                user_schemas: 1,
                ..Default::default()
            },
            FreshDatabaseInventory {
                user_relations: 1,
                ..Default::default()
            },
            FreshDatabaseInventory {
                user_types: 1,
                ..Default::default()
            },
            FreshDatabaseInventory {
                user_routines: 1,
                ..Default::default()
            },
            FreshDatabaseInventory {
                disallowed_extensions: 1,
                ..Default::default()
            },
        ] {
            assert!(inventory.require_empty().is_err());
        }
    }

    #[test]
    fn fresh_database_guard_rejects_lookalike_names() {
        assert!(is_isolated_database_name("auth_v2_test"));
        assert!(is_isolated_database_name("auth_v2_test_550e8400"));
        assert!(!is_isolated_database_name("fuminiwa_auth_v2_test"));
        assert!(!is_isolated_database_name(
            "auth_v2_test".trim_end_matches('t')
        ));
        assert!(!is_isolated_database_name("production_auth_v2_test_copy"));
    }
}
