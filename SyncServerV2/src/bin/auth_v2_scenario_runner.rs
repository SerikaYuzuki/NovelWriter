//! Explicit Auth v1 PostgreSQL conformance gate.
//!
//! The runner refuses ambient/LAN databases. It only accepts a fresh database
//! whose name contains `auth_v2_test`, then applies migrations and executes the
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
    ) -> Result<VerifiedExternalIdentity, AuthError> {
        self.calls.fetch_add(1, Ordering::SeqCst);
        let mut identity = VerifiedExternalIdentity::apple(self.subject.clone(), unix_now())?;
        if let Some(secret) = self.credential_by_audience.get(&challenge.audience) {
            identity.provider_credential = Some(VerifiedProviderCredential {
                audience: challenge.audience.clone(),
                encrypted_refresh_token: secret.clone(),
            });
        }
        Ok(identity)
    }

    async fn revoke(
        &self,
        _credential_id: &CredentialId,
        _audience: &str,
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
        "set AUTH_V2_TEST_DATABASE_URL to a fresh isolated database whose name contains auth_v2_test"
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
    if !database.contains("auth_v2_test") {
        return Err(format!(
            "refusing database {database:?}; isolated database name must contain auth_v2_test"
        )
        .into());
    }
    let already_initialized: bool = sqlx::query(
        "SELECT EXISTS (SELECT 1 FROM information_schema.schemata WHERE schema_name IN ('auth_v1','sync_v2')) OR to_regclass('public._sqlx_migrations') IS NOT NULL AS initialized",
    )
    .fetch_one(pool)
    .await?
    .try_get("initialized")?;
    if already_initialized {
        return Err("database is not fresh; create a new temporary auth_v2_test database".into());
    }
    Ok(())
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
    let app = AuthApplication::new(repository);
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
