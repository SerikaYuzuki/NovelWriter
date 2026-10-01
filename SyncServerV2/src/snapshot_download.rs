//! Bounded, read-only pages of an immutable snapshot's complete ancestry.
//! Objects are deduplicated across the entire graph, not repeated per version.
use crate::{
    application::strict_json,
    domain::{
        canonical_json, decode_digest, sha256, AuthenticatedPrincipal, SyncError, SyncResult,
    },
    http::{canonical_response, error_response, principal, AppState},
};
use axum::{
    extract::{Path, Query, State},
    http::{HeaderMap, StatusCode},
    response::Response,
};
use base64::{engine::general_purpose::URL_SAFE_NO_PAD, Engine};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use sqlx::Row;
use std::{
    collections::HashMap,
    sync::{Arc, Mutex},
    time::{Duration, Instant},
};
use uuid::Uuid;

mod shallow;

const PAGE_ITEMS: usize = 256;
const PAGE_BYTES: usize = 2 * 1024 * 1024;
const INLINE_OBJECT_BYTES: i64 = 256 * 1024;

#[derive(Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Cursor {
    account_id: String,
    account_fence: String,
    server_instance_id: String,
    protocol_epoch: i64,
    work_id: Uuid,
    snapshot_id: String,
    after_kind: i16,
    after_id: String,
}

impl Cursor {
    fn decode(
        raw: &str,
        p: &AuthenticatedPrincipal,
        work: Uuid,
        head: &[u8; 32],
    ) -> SyncResult<Self> {
        if raw.len() > 2048 {
            return Err(SyncError::SizeLimitExceeded);
        }
        let bytes = URL_SAFE_NO_PAD
            .decode(raw)
            .map_err(|_| SyncError::InvalidCanonicalBytes)?;
        let value = strict_json(&bytes)?;
        if canonical_json(&value).map_err(|_| SyncError::InvalidCanonicalBytes)? != bytes {
            return Err(SyncError::InvalidCanonicalBytes);
        }
        let cursor: Self = serde_json::from_value(value)
            .map_err(|_| SyncError::SchemaViolation("download cursor".into()))?;
        if cursor.account_id != p.account_id
            || cursor.account_fence != p.account_fence
            || cursor.server_instance_id != p.server_instance_id
            || cursor.protocol_epoch != p.protocol_epoch
            || cursor.work_id != work
            || cursor.snapshot_id != hex::encode(head)
        {
            return Err(SyncError::AccountFenceMismatch);
        }
        if !(0..=1).contains(&cursor.after_kind) {
            return Err(SyncError::SchemaViolation("download cursor kind".into()));
        }
        decode_digest(&cursor.after_id).map_err(SyncError::SchemaViolation)?;
        Ok(cursor)
    }

    fn encode(&self) -> SyncResult<String> {
        let value = serde_json::to_value(self).map_err(|_| SyncError::Retryable)?;
        Ok(URL_SAFE_NO_PAD.encode(canonical_json(&value).map_err(|_| SyncError::Retryable)?))
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct DownloadTotals {
    items: u64,
    bytes: u64,
}

impl DownloadTotals {
    fn value(&self) -> SyncResult<Value> {
        const MAX_SAFE_INTEGER: u64 = 9_007_199_254_740_991;
        if self.items > MAX_SAFE_INTEGER || self.bytes > MAX_SAFE_INTEGER {
            return Err(SyncError::SizeLimitExceeded);
        }
        Ok(json!({"items":self.items,"bytes":self.bytes}))
    }
}

#[derive(Clone)]
struct Item {
    kind: i16,
    id: [u8; 32],
    byte_count: usize,
}

// Per-repository cache: immutable graph metadata only. Scope/visibility and
// mutable object availability are always read from PostgreSQL on every page.
type CacheKey = (String, Uuid, [u8; 32], &'static str);
#[derive(Clone)]
enum CachedGraph {
    Metadata(Arc<Vec<Item>>),
    Shallow(Arc<shallow::Plan>),
    Oversized { items: u64, bytes: u64 },
}
#[derive(Default)]
pub struct DownloadCache(Mutex<HashMap<CacheKey, (Instant, CachedGraph)>>);
const CACHE_ITEMS: usize = 100_000;
const CACHE_ROOTS: usize = 4;
const CACHE_TTL: Duration = Duration::from_secs(30);
static DOWNLOAD_PERMITS: tokio::sync::Semaphore = tokio::sync::Semaphore::const_new(2);

impl DownloadCache {
    fn get(&self, key: &CacheKey) -> Option<CachedGraph> {
        let mut cache = self.0.lock().ok()?;
        cache.retain(|_, (created, _)| created.elapsed() < CACHE_TTL);
        cache.get(key).map(|(_, items)| items.clone())
    }

    fn insert(&self, key: CacheKey, items: CachedGraph) {
        if let Ok(mut cache) = self.0.lock() {
            if cache.len() >= CACHE_ROOTS {
                if let Some(oldest) = cache
                    .iter()
                    .min_by_key(|(_, (created, _))| *created)
                    .map(|(key, _)| key.clone())
                {
                    cache.remove(&oldest);
                }
            }
            cache.insert(key, (Instant::now(), items));
        }
    }
}

fn decode_items(rows: &[sqlx::postgres::PgRow]) -> SyncResult<Vec<Item>> {
    rows.iter()
        .map(|row| {
            let id: Vec<u8> = row.try_get("id")?;
            let size: i64 = row.try_get("byte_count")?;
            Ok(Item {
                kind: row.try_get("kind")?,
                id: id.try_into().map_err(|_| SyncError::Retryable)?,
                byte_count: usize::try_from(size).map_err(|_| SyncError::Retryable)?,
            })
        })
        .collect()
}

pub(crate) async fn download(
    Path(work): Path<String>,
    headers: HeaderMap,
    State(state): State<AppState>,
    Query(params): Query<HashMap<String, String>>,
) -> Response {
    let semaphore = if params.get("mode").is_some_and(|mode| mode == "backfill") {
        &shallow::BACKFILL_PERMITS
    } else {
        &DOWNLOAD_PERMITS
    };
    let _permit = match semaphore.try_acquire() {
        Ok(permit) => permit,
        Err(_) => {
            let mut response = error_response(SyncError::Retryable);
            if params.get("mode").is_some_and(|mode| mode == "backfill") {
                response
                    .headers_mut()
                    .insert("retry-after", "1".parse().unwrap());
            }
            return response;
        }
    };
    let p = match principal(&headers, &state).await {
        Ok(p) => p,
        Err(response) => return response,
    };
    match page(&state, &p, &work, &params).await {
        Ok(value) => canonical_response(StatusCode::OK, value),
        Err(error) => error_response(error),
    }
}

async fn page(
    state: &AppState,
    p: &AuthenticatedPrincipal,
    work: &str,
    params: &HashMap<String, String>,
) -> SyncResult<Value> {
    if params.contains_key("mode") {
        return shallow::page(state, p, work, params).await;
    }
    legacy_page(state, p, work, params).await
}

async fn legacy_page(
    state: &AppState,
    p: &AuthenticatedPrincipal,
    work: &str,
    params: &HashMap<String, String>,
) -> SyncResult<Value> {
    let work_id = Uuid::parse_str(work).map_err(|_| SyncError::NotFound)?;
    if work_id.to_string() != work
        || params
            .keys()
            .any(|key| key != "snapshotId" && key != "cursor" && key != "include")
    {
        return Err(SyncError::SchemaViolation("download query".into()));
    }
    if params.get("include").is_some_and(|value| value != "totals")
        || (params.contains_key("include") && params.contains_key("cursor"))
    {
        return Err(SyncError::SchemaViolation("download include".into()));
    }
    let head = decode_digest(
        params
            .get("snapshotId")
            .ok_or_else(|| SyncError::SchemaViolation("snapshotId".into()))?,
    )
    .map_err(SyncError::SchemaViolation)?;
    let mut tx = state.repo.pool.begin().await?;
    sqlx::query("SET TRANSACTION ISOLATION LEVEL REPEATABLE READ, READ ONLY")
        .execute(&mut *tx)
        .await?;
    let visible: bool = sqlx::query_scalar("SELECT EXISTS(SELECT 1 FROM sync_v2.works w JOIN sync_v2.snapshots s ON s.account_id=w.account_id AND s.work_id=w.work_id WHERE w.account_id=$1 AND w.work_id=$2 AND s.snapshot_id=$3 AND w.state='bound' AND NOT EXISTS(SELECT 1 FROM sync_v2.deleted_works d WHERE d.account_id=w.account_id AND d.work_id=w.work_id))")
        .bind(&p.account_id).bind(work_id).bind(head.as_slice()).fetch_one(&mut *tx).await?;
    if !visible {
        return Err(SyncError::NotFound);
    }
    let cursor = params
        .get("cursor")
        .map(|raw| Cursor::decode(raw, p, work_id, &head))
        .transpose()?;
    let after_kind = cursor.as_ref().map_or(-1, |cursor| cursor.after_kind);
    let after_id = cursor
        .as_ref()
        .map(|cursor| decode_digest(&cursor.after_id).map_err(SyncError::SchemaViolation))
        .transpose()?
        .unwrap_or([0; 32]);
    // Cache at most four small closures. Oversized graphs keep the bounded
    // original query path; the cache capacity is not a history cutoff.
    let key = (p.account_id.clone(), work_id, head, "full");
    let mut metadata = state.repo.download_cache.get(&key);
    let mut cold_candidates = None;
    if metadata.is_none() {
        let rows = sqlx::query(r#"
        WITH RECURSIVE ancestors(snapshot_id) AS (
          SELECT snapshot_id FROM sync_v2.snapshots WHERE account_id=$1 AND work_id=$2 AND snapshot_id=$3
          UNION
          SELECT p.parent_snapshot_id FROM sync_v2.snapshot_parents p JOIN ancestors a ON a.snapshot_id=p.snapshot_id
          WHERE p.account_id=$1 AND p.work_id=$2
        ), items AS MATERIALIZED (
          SELECT 0::smallint AS kind,s.snapshot_id AS id,octet_length(s.manifest_bytes)::bigint AS byte_count,true AS available
          FROM sync_v2.snapshots s JOIN ancestors a ON a.snapshot_id=s.snapshot_id WHERE s.account_id=$1 AND s.work_id=$2
          UNION ALL
          SELECT (CASE WHEN b.byte_count <= $4 THEN 1 ELSE 2 END)::smallint,b.object_id,b.byte_count,o.state='available' FROM sync_v2.global_blobs b
          JOIN sync_v2.account_objects o ON o.object_id=b.object_id AND o.account_id=$1
          WHERE b.object_id IN (
            SELECT e.object_id FROM sync_v2.snapshot_entries e JOIN ancestors a ON a.snapshot_id=e.snapshot_id WHERE e.account_id=$1
          )
        )
        (SELECT kind,id,byte_count,true AS cache_entry, count(*) OVER() AS total_items, (sum(byte_count) OVER())::bigint AS total_bytes FROM items ORDER BY kind,id LIMIT $5)
        UNION ALL
        (SELECT kind,id,byte_count,false AS cache_entry, 0::bigint AS total_items, 0::bigint AS total_bytes FROM items
         WHERE kind < 2 AND available AND (kind,id)>($6,$7) ORDER BY kind,id LIMIT $8)
    "#)
            .bind(&p.account_id).bind(work_id).bind(head.as_slice())
            .bind(INLINE_OBJECT_BYTES).bind((CACHE_ITEMS + 1) as i64)
            .bind(after_kind).bind(after_id.as_slice()).bind((PAGE_ITEMS + 1) as i64)
            .fetch_all(&mut *tx).await?;
        let mut cache_rows = Vec::new();
        let mut page_rows = Vec::new();
        for row in rows {
            if row.try_get::<bool, _>("cache_entry")? {
                cache_rows.push(row);
            } else {
                page_rows.push(row);
            }
        }
        let mut candidates = decode_items(&page_rows)?;
        candidates.sort_by_key(|item| (item.kind, item.id));
        cold_candidates = Some(candidates);
        if cache_rows.len() <= CACHE_ITEMS {
            let mut items = decode_items(&cache_rows)?;
            items.sort_by_key(|item| (item.kind, item.id));
            metadata = Some(CachedGraph::Metadata(Arc::new(items)));
        } else {
            let first = cache_rows.first().ok_or(SyncError::Retryable)?;
            metadata = Some(CachedGraph::Oversized {
                items: first.try_get::<i64, _>("total_items")? as u64,
                bytes: first.try_get::<i64, _>("total_bytes")? as u64,
            });
        }
        state
            .repo
            .download_cache
            .insert(key, metadata.clone().ok_or(SyncError::Retryable)?);
    }
    // Sum cached metadata once on the negotiated first page, never per page.
    // Oversized closures cache aggregate totals without retaining unbounded metadata.
    let totals = if params.contains_key("include") {
        match &metadata {
            Some(CachedGraph::Metadata(items)) => Some(DownloadTotals {
                items: items.len() as u64,
                bytes: items.iter().try_fold(0_u64, |sum, i| {
                    sum.checked_add(i.byte_count as u64)
                        .ok_or(SyncError::SizeLimitExceeded)
                })?,
            }),
            Some(CachedGraph::Oversized { items, bytes }) => Some(DownloadTotals {
                items: *items,
                bytes: *bytes,
            }),
            None | Some(CachedGraph::Shallow(_)) => None,
        }
    } else {
        None
    };
    let candidates = if let Some(candidates) = cold_candidates {
        candidates
    } else if let Some(CachedGraph::Metadata(metadata)) = metadata {
        let mut selected: Vec<_> = metadata
            .iter()
            .filter(|item| item.kind == 0 && (item.kind, item.id) > (after_kind, after_id))
            .take(PAGE_ITEMS + 1)
            .cloned()
            .collect();
        if selected.len() < PAGE_ITEMS + 1 {
            let ids: Vec<Vec<u8>> = metadata
                .iter()
                .filter(|item| item.kind == 1 && (item.kind, item.id) > (after_kind, after_id))
                .map(|item| item.id.to_vec())
                .collect();
            // Never cache mutable availability (including quarantine).
            let rows = sqlx::query("SELECT 1::smallint AS kind,b.object_id AS id,b.byte_count FROM sync_v2.global_blobs b JOIN sync_v2.account_objects o ON o.object_id=b.object_id WHERE o.account_id=$1 AND o.state='available' AND b.object_id=ANY($2::bytea[]) AND b.byte_count <= $3 ORDER BY b.object_id LIMIT $4")
                .bind(&p.account_id).bind(ids).bind(INLINE_OBJECT_BYTES)
                .bind((PAGE_ITEMS + 1 - selected.len()) as i64).fetch_all(&mut *tx).await?;
            selected.extend(decode_items(&rows)?);
        }
        selected
    } else {
        let rows = sqlx::query(r#"
        WITH RECURSIVE ancestors(snapshot_id) AS (
          SELECT snapshot_id FROM sync_v2.snapshots WHERE account_id=$1 AND work_id=$2 AND snapshot_id=$3
          UNION
          SELECT p.parent_snapshot_id FROM sync_v2.snapshot_parents p JOIN ancestors a ON a.snapshot_id=p.snapshot_id
          WHERE p.account_id=$1 AND p.work_id=$2
        ), items AS (
          SELECT 0::smallint AS kind,s.snapshot_id AS id,octet_length(s.manifest_bytes)::bigint AS byte_count
          FROM sync_v2.snapshots s JOIN ancestors a ON a.snapshot_id=s.snapshot_id WHERE s.account_id=$1 AND s.work_id=$2
          UNION ALL
          SELECT 1::smallint,b.object_id,b.byte_count FROM sync_v2.global_blobs b
          JOIN sync_v2.account_objects o ON o.object_id=b.object_id AND o.account_id=$1 AND o.state='available'
          WHERE b.byte_count <= $6 AND b.object_id IN (
            SELECT e.object_id FROM sync_v2.snapshot_entries e JOIN ancestors a ON a.snapshot_id=e.snapshot_id WHERE e.account_id=$1
          )
        )
        SELECT kind,id,byte_count FROM items WHERE (kind,id)>($4,$5) ORDER BY kind,id LIMIT $7
    "#).bind(&p.account_id).bind(work_id).bind(head.as_slice())
            .bind(after_kind).bind(after_id.as_slice()).bind(INLINE_OBJECT_BYTES).bind((PAGE_ITEMS + 1) as i64)
            .fetch_all(&mut *tx).await?;
        decode_items(&rows)?
    };
    let count = page_prefix(&candidates);
    let manifests: Vec<Vec<u8>> = candidates[..count]
        .iter()
        .filter(|i| i.kind == 0)
        .map(|i| i.id.to_vec())
        .collect();
    let objects: Vec<Vec<u8>> = candidates[..count]
        .iter()
        .filter(|i| i.kind == 1)
        .map(|i| i.id.to_vec())
        .collect();
    let mut payloads = HashMap::new();
    if !manifests.is_empty() {
        let rows: Vec<(Vec<u8>, Vec<u8>)> = sqlx::query_as("SELECT snapshot_id,manifest_bytes FROM sync_v2.snapshots WHERE account_id=$1 AND work_id=$2 AND snapshot_id=ANY($3::bytea[])")
            .bind(&p.account_id).bind(work_id).bind(manifests).fetch_all(&mut *tx).await?;
        payloads.extend(rows.into_iter().map(|(id, bytes)| ((0, id), bytes)));
    }
    if !objects.is_empty() {
        let rows: Vec<(Vec<u8>, Vec<u8>)> = sqlx::query_as("SELECT b.object_id,b.raw_bytes FROM sync_v2.global_blobs b JOIN sync_v2.account_objects a ON a.object_id=b.object_id WHERE a.account_id=$1 AND a.state='available' AND b.object_id=ANY($2::bytea[])")
            .bind(&p.account_id).bind(objects).fetch_all(&mut *tx).await?;
        payloads.extend(rows.into_iter().map(|(id, bytes)| ((1, id), bytes)));
    }
    tx.commit().await?;
    let mut items = Vec::with_capacity(count);
    for item in &candidates[..count] {
        let bytes = payloads
            .remove(&(item.kind, item.id.to_vec()))
            .ok_or(SyncError::NotFound)?;
        if bytes.len() != item.byte_count || sha256(&bytes) != item.id {
            return Err(SyncError::Retryable);
        }
        items.push(
            json!({"kind": if item.kind == 0 { "manifest" } else { "object" },
            "id": hex::encode(item.id), "bytesBase64URL": URL_SAFE_NO_PAD.encode(bytes)}),
        );
    }
    let next = if count < candidates.len() {
        let last = &candidates[count - 1];
        Some(
            Cursor {
                account_id: p.account_id.clone(),
                account_fence: p.account_fence.clone(),
                server_instance_id: p.server_instance_id.clone(),
                protocol_epoch: p.protocol_epoch,
                work_id,
                snapshot_id: hex::encode(head),
                after_kind: last.kind,
                after_id: hex::encode(last.id),
            }
            .encode()?,
        )
    } else {
        None
    };
    let mut response = json!({"result":"noChanges", "snapshotId":hex::encode(head), "items":items, "nextCursor":next});
    if let Some(totals) = totals {
        response["totals"] = totals.value()?;
    }
    Ok(response)
}

fn page_prefix(items: &[Item]) -> usize {
    let mut bytes = 0_usize;
    let mut count = 0;
    for item in items.iter().take(PAGE_ITEMS) {
        // One legal manifest can exceed the normal page budget (16 MiB cap).
        if count > 0 && bytes.saturating_add(item.byte_count) > PAGE_BYTES {
            break;
        }
        bytes = bytes.saturating_add(item.byte_count);
        count += 1;
    }
    count
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn saturated_download_rejects_without_auth_or_database_wait() {
        use crate::{
            auth::{FixtureAccessAuthenticator, RuntimeMode},
            object_store::PostgresObjectStore,
            Repository,
        };
        let pool = sqlx::postgres::PgPoolOptions::new()
            .connect_lazy("postgresql://fixture@127.0.0.1:1/unused_test")
            .unwrap();
        let state = AppState {
            repo: Arc::new(Repository {
                pool: pool.clone(),
                object_store: Arc::new(PostgresObjectStore { pool }),
                download_cache: Arc::default(),
                server_instance_id: "test-instance".into(),
                protocol_epoch: 2,
            }),
            access_authenticator: Arc::new(
                FixtureAccessAuthenticator::new(RuntimeMode::Test, "fixture-fence".into()).unwrap(),
            ),
        };
        let permits = DOWNLOAD_PERMITS.try_acquire_many(2).unwrap();
        let response = download(
            Path("unused".into()),
            HeaderMap::new(),
            State(state.clone()),
            Query(HashMap::new()),
        )
        .await;
        assert_eq!(response.status(), StatusCode::SERVICE_UNAVAILABLE);
        drop(permits);
        let response = download(
            Path("unused".into()),
            HeaderMap::new(),
            State(state.clone()),
            Query(HashMap::new()),
        )
        .await;
        assert_eq!(response.status(), StatusCode::UNAUTHORIZED);
        let backfill = shallow::BACKFILL_PERMITS.try_acquire().unwrap();
        let response = download(
            Path("unused".into()),
            HeaderMap::new(),
            State(state.clone()),
            Query(HashMap::from([("mode".into(), "backfill".into())])),
        )
        .await;
        assert_eq!(response.status(), StatusCode::SERVICE_UNAVAILABLE);
        assert_eq!(response.headers()["retry-after"], "1");
        for mode in [None, Some("head")] {
            let params = mode
                .map(|mode| HashMap::from([("mode".into(), mode.into())]))
                .unwrap_or_default();
            let response = download(
                Path("unused".into()),
                HeaderMap::new(),
                State(state.clone()),
                Query(params),
            )
            .await;
            assert_eq!(response.status(), StatusCode::UNAUTHORIZED);
        }
        drop(backfill);
    }

    #[test]
    fn metadata_cache_is_scoped_bounded_and_expires() {
        let cache = DownloadCache::default();
        let work = Uuid::new_v4();
        let first = ("account-a".to_owned(), work, [0; 32], "full");
        cache.insert(first.clone(), CachedGraph::Metadata(Arc::new(vec![])));
        assert!(cache.get(&first).is_some());
        for mode in ["head", "backfill"] {
            assert!(cache
                .get(&("account-a".into(), work, [0; 32], mode))
                .is_none());
        }
        assert!(cache
            .get(&("account-b".into(), work, [0; 32], "full"))
            .is_none());
        assert!(cache
            .get(&("account-a".into(), Uuid::new_v4(), [0; 32], "full"))
            .is_none());
        for id in 1..=CACHE_ROOTS {
            cache.insert(
                ("account-a".into(), work, [id as u8; 32], "full"),
                CachedGraph::Oversized { items: 0, bytes: 0 },
            );
        }
        assert!(cache.get(&first).is_none());
        assert_eq!(cache.0.lock().unwrap().len(), CACHE_ROOTS);
        let last = (
            "account-a".to_owned(),
            work,
            [CACHE_ROOTS as u8; 32],
            "full",
        );
        cache.0.lock().unwrap().get_mut(&last).unwrap().0 = Instant::now() - CACHE_TTL;
        assert!(cache.get(&last).is_none());
    }

    #[test]
    fn shared_download_fixtures_validate_both_closed_envelopes_and_totals() {
        let fixtures: &[(&[u8], &str, bool)] = &[
            (
                include_bytes!("../../docs/sync/v2/fixtures/canonical/download-page.json"),
                include_str!("../../docs/sync/v2/fixtures/canonical/download-page.sha256"),
                false,
            ),
            (
                include_bytes!("../../docs/sync/v2/fixtures/canonical/download-page-totals.json"),
                include_str!("../../docs/sync/v2/fixtures/canonical/download-page-totals.sha256"),
                true,
            ),
        ];
        for (bytes, digest, negotiated) in fixtures {
            let page = strict_json(bytes).unwrap();
            assert_eq!(canonical_json(&page).unwrap(), *bytes);
            assert_eq!(hex::encode(sha256(bytes)), digest.trim());
            let expected = if *negotiated {
                vec!["items", "nextCursor", "result", "snapshotId", "totals"]
            } else {
                vec!["items", "nextCursor", "result", "snapshotId"]
            };
            assert_eq!(
                page.as_object()
                    .unwrap()
                    .keys()
                    .map(String::as_str)
                    .collect::<Vec<_>>(),
                expected
            );
            let mut previous: Option<(String, String)> = None;
            let mut raw_bytes = 0;
            for item in page["items"].as_array().unwrap() {
                let id = item["id"].as_str().unwrap();
                let raw = URL_SAFE_NO_PAD
                    .decode(item["bytesBase64URL"].as_str().unwrap())
                    .unwrap();
                raw_bytes += raw.len() as u64;
                assert_eq!(hex::encode(sha256(&raw)), id);
                let key = (item["kind"].as_str().unwrap().to_owned(), id.to_owned());
                assert!(previous.as_ref().is_none_or(|previous| previous < &key));
                previous = Some(key);
            }
            if *negotiated {
                let totals: DownloadTotals =
                    serde_json::from_value(page["totals"].clone()).unwrap();
                assert_eq!(totals.value().unwrap(), page["totals"]);
                assert_eq!(totals.items, page["items"].as_array().unwrap().len() as u64);
                assert_eq!(totals.bytes, raw_bytes);
            }
        }
        for invalid in [
            json!({"items":-1,"bytes":0}),
            json!({"items":1,"bytes":0.5}),
            json!({"items":1,"bytes":0,"extra":1}),
            json!({"items":true,"bytes":0}),
        ] {
            assert!(serde_json::from_value::<DownloadTotals>(invalid).is_err());
        }
        assert!(DownloadTotals {
            items: 1,
            bytes: u64::MAX
        }
        .value()
        .is_err());
    }

    #[test]
    fn page_is_bounded_without_truncating_a_large_manifest() {
        let items = (0..300)
            .map(|_| Item {
                kind: 0,
                id: [1; 32],
                byte_count: 1024,
            })
            .collect::<Vec<_>>();
        assert_eq!(page_prefix(&items), 256);
        let items = (0..20)
            .map(|_| Item {
                kind: 1,
                id: [1; 32],
                byte_count: 256 * 1024,
            })
            .collect::<Vec<_>>();
        assert_eq!(page_prefix(&items), 8);
        let items = vec![
            Item {
                kind: 0,
                id: [1; 32],
                byte_count: 16 * 1024 * 1024,
            },
            Item {
                kind: 0,
                id: [2; 32],
                byte_count: 1,
            },
        ];
        assert_eq!(page_prefix(&items), 1);
        assert_eq!(page_prefix(&[]), 0);
    }

    #[test]
    fn cursor_is_bound_to_account_fence_work_and_immutable_head() {
        let p = AuthenticatedPrincipal::fixture("test-account");
        let work = Uuid::new_v4();
        let cursor = Cursor {
            account_id: p.account_id.clone(),
            account_fence: p.account_fence.clone(),
            server_instance_id: p.server_instance_id.clone(),
            protocol_epoch: 2,
            work_id: work,
            snapshot_id: hex::encode([1; 32]),
            after_kind: 0,
            after_id: hex::encode([2; 32]),
        };
        let encoded = cursor.encode().unwrap();
        assert!(Cursor::decode(&encoded, &p, work, &[1; 32]).is_ok());
        assert!(Cursor::decode(&encoded, &p, work, &[3; 32]).is_err());
        assert!(Cursor::decode(&encoded, &p, Uuid::new_v4(), &[1; 32]).is_err());
        for foreign in [
            AuthenticatedPrincipal {
                account_id: "other".into(),
                ..p.clone()
            },
            AuthenticatedPrincipal {
                account_fence: "other".into(),
                ..p.clone()
            },
        ] {
            assert!(Cursor::decode(&encoded, &foreign, work, &[1; 32]).is_err());
        }
    }
}
