//! D-106 opt-in transport. The legacy page implementation stays isolated.
use super::*;
use std::collections::{BTreeSet, HashSet, VecDeque};

pub(super) static BACKFILL_PERMITS: tokio::sync::Semaphore = tokio::sync::Semaphore::const_new(1);

type Digest = [u8; 32];

// Internally tagged variants deliberately reject legacy cursors and each other's
// fields. No flatten: deny_unknown_fields applies to the entire wire envelope.
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "camelCase", deny_unknown_fields)]
enum ModeCursor {
    #[serde(rename_all = "camelCase")]
    Head {
        account_id: String,
        account_fence: String,
        server_instance_id: String,
        protocol_epoch: i64,
        work_id: Uuid,
        snapshot_id: String,
        after_kind: i16,
        after_id: String,
    },
    #[serde(rename_all = "camelCase")]
    Backfill {
        account_id: String,
        account_fence: String,
        server_instance_id: String,
        protocol_epoch: i64,
        work_id: Uuid,
        snapshot_id: String,
        after_depth: u64,
        after_snapshot_id: String,
        after_item: u64,
    },
}

impl ModeCursor {
    fn encode(&self) -> SyncResult<String> {
        let value = serde_json::to_value(self).map_err(|_| SyncError::Retryable)?;
        Ok(URL_SAFE_NO_PAD.encode(canonical_json(&value).map_err(|_| SyncError::Retryable)?))
    }

    fn decode(
        raw: &str,
        p: &AuthenticatedPrincipal,
        work: Uuid,
        head: &Digest,
        mode: &str,
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
        let cursor: Self = serde_json::from_value(value).map_err(|_| invalid_cursor())?;
        let (account, fence, server, epoch, w, h) = match &cursor {
            Self::Head {
                account_id,
                account_fence,
                server_instance_id,
                protocol_epoch,
                work_id,
                snapshot_id,
                after_kind,
                after_id,
            } => {
                if mode != "head" || !(0..=1).contains(after_kind) {
                    return Err(invalid_cursor());
                }
                decode_digest(after_id).map_err(SyncError::SchemaViolation)?;
                (
                    account_id,
                    account_fence,
                    server_instance_id,
                    protocol_epoch,
                    work_id,
                    snapshot_id,
                )
            }
            Self::Backfill {
                account_id,
                account_fence,
                server_instance_id,
                protocol_epoch,
                work_id,
                snapshot_id,
                after_snapshot_id,
                after_depth,
                after_item,
            } => {
                if mode != "backfill"
                    || *after_depth > 9_007_199_254_740_991
                    || *after_item > 9_007_199_254_740_991
                {
                    return Err(invalid_cursor());
                }
                decode_digest(after_snapshot_id).map_err(SyncError::SchemaViolation)?;
                (
                    account_id,
                    account_fence,
                    server_instance_id,
                    protocol_epoch,
                    work_id,
                    snapshot_id,
                )
            }
        };
        if account != &p.account_id
            || fence != &p.account_fence
            || server != &p.server_instance_id
            || *epoch != p.protocol_epoch
            || *w != work
            || h != &hex::encode(head)
        {
            return Err(SyncError::AccountFenceMismatch);
        }
        Ok(cursor)
    }
}

fn invalid_cursor() -> SyncError {
    SyncError::SchemaViolation("download mode cursor".into())
}

struct Snapshot {
    id: Digest,
    byte_count: usize,
    parents: Vec<Digest>,
    objects: Vec<Item>,
}

#[derive(Clone)]
struct PositionedItem {
    item: Item,
    depth: u64,
    snapshot: Digest,
    index: u64,
}

pub(super) struct Plan {
    items: Vec<PositionedItem>,
    totals: DownloadTotals,
}

impl Plan {
    fn cursor(
        &self,
        index: usize,
        p: &AuthenticatedPrincipal,
        work: Uuid,
        head: &Digest,
        mode: &str,
    ) -> ModeCursor {
        let pos = &self.items[index];
        if mode == "head" {
            ModeCursor::Head {
                account_id: p.account_id.clone(),
                account_fence: p.account_fence.clone(),
                server_instance_id: p.server_instance_id.clone(),
                protocol_epoch: p.protocol_epoch,
                work_id: work,
                snapshot_id: hex::encode(head),
                after_kind: pos.item.kind,
                after_id: hex::encode(pos.item.id),
            }
        } else {
            ModeCursor::Backfill {
                account_id: p.account_id.clone(),
                account_fence: p.account_fence.clone(),
                server_instance_id: p.server_instance_id.clone(),
                protocol_epoch: p.protocol_epoch,
                work_id: work,
                snapshot_id: hex::encode(head),
                after_depth: pos.depth,
                after_snapshot_id: hex::encode(pos.snapshot),
                after_item: pos.index,
            }
        }
    }

    fn start(&self, cursor: Option<&ModeCursor>) -> SyncResult<usize> {
        let Some(cursor) = cursor else {
            return Ok(0);
        };
        self.items
            .iter()
            .position(|pos| match cursor {
                ModeCursor::Head {
                    after_kind,
                    after_id,
                    ..
                } => pos.item.kind == *after_kind && hex::encode(pos.item.id) == *after_id,
                ModeCursor::Backfill {
                    after_depth,
                    after_snapshot_id,
                    after_item,
                    ..
                } => {
                    pos.depth == *after_depth
                        && hex::encode(pos.snapshot) == *after_snapshot_id
                        && pos.index == *after_item
                }
            })
            .map(|i| i + 1)
            .ok_or_else(invalid_cursor)
    }

    fn bounds(&self, start: usize) -> (usize, Option<usize>) {
        let candidates: Vec<_> = self.items[start..]
            .iter()
            .take(PAGE_ITEMS + 1)
            .map(|p| p.item.clone())
            .collect();
        let end = start + page_prefix(&candidates);
        // Includes the previous page's closed group. A partial oversized group
        // must restart at that boundary, never at its partially received objects.
        let resume = self.items[..end].iter().rposition(|p| p.item.kind == 0);
        (end, resume)
    }
}

// Kahn's algorithm computes longest distance from a root without recursion or
// any generation cutoff. A merge reached via a shortcut must not lower depth.
fn depths(snapshots: &[Snapshot]) -> SyncResult<HashMap<Digest, u64>> {
    let mut pending = HashMap::new();
    let mut children: HashMap<Digest, Vec<Digest>> = HashMap::new();
    let mut ready = VecDeque::new();
    let mut depth = HashMap::new();
    for s in snapshots {
        if pending.insert(s.id, s.parents.len()).is_some() {
            return Err(SyncError::Retryable);
        }
        depth.insert(s.id, 0_u64);
        if s.parents.is_empty() {
            ready.push_back(s.id);
        }
        for parent in &s.parents {
            children.entry(*parent).or_default().push(s.id);
        }
    }
    let mut visited = 0;
    while let Some(id) = ready.pop_front() {
        visited += 1;
        for child in children.get(&id).into_iter().flatten() {
            let next = depth[&id]
                .checked_add(1)
                .ok_or(SyncError::SizeLimitExceeded)?;
            let value = depth.get_mut(child).ok_or(SyncError::Retryable)?;
            *value = (*value).max(next);
            let count = pending.get_mut(child).ok_or(SyncError::Retryable)?;
            *count -= 1;
            if *count == 0 {
                ready.push_back(*child);
            }
        }
    }
    if visited != snapshots.len() {
        return Err(SyncError::Retryable);
    }
    Ok(depth)
}

fn build_plan(mut snapshots: Vec<Snapshot>, head: Digest, mode: &str) -> SyncResult<Plan> {
    let root = snapshots
        .iter()
        .find(|s| s.id == head)
        .ok_or(SyncError::NotFound)?;
    let mut seen: HashSet<_> = if mode == "backfill" {
        root.objects.iter().map(|o| o.id).collect()
    } else {
        HashSet::new()
    };
    let depth = if mode == "backfill" {
        depths(&snapshots)?
    } else {
        HashMap::from([(head, 0)])
    };
    if mode == "backfill" {
        snapshots.retain(|s| s.id != head);
        snapshots.sort_by_key(|s| (std::cmp::Reverse(depth[&s.id]), s.id));
    }
    let mut plan = Plan {
        items: vec![],
        totals: DownloadTotals { items: 0, bytes: 0 },
    };
    for s in snapshots {
        let mut group = Vec::new();
        let mut objects = s.objects;
        objects.sort_by_key(|o| o.id);
        for object in objects {
            if seen.insert(object.id) {
                group.push(object);
            }
        }
        let manifest = Item {
            kind: 0,
            id: s.id,
            byte_count: s.byte_count,
        };
        if mode == "head" {
            group.insert(0, manifest);
        } else {
            group.push(manifest);
        }
        let mut index = 0;
        for item in group {
            plan.totals.items = plan
                .totals
                .items
                .checked_add(1)
                .ok_or(SyncError::SizeLimitExceeded)?;
            plan.totals.bytes = plan
                .totals
                .bytes
                .checked_add(item.byte_count as u64)
                .ok_or(SyncError::SizeLimitExceeded)?;
            if item.kind == 2 {
                continue;
            }
            plan.items.push(PositionedItem {
                item,
                depth: depth[&s.id],
                snapshot: s.id,
                index,
            });
            index += 1;
        }
    }
    Ok(plan)
}

fn digest(bytes: Vec<u8>) -> SyncResult<Digest> {
    bytes.try_into().map_err(|_| SyncError::Retryable)
}
fn size(value: i64) -> SyncResult<usize> {
    usize::try_from(value).map_err(|_| SyncError::Retryable)
}

async fn load_plan(
    tx: &mut sqlx::Transaction<'_, sqlx::Postgres>,
    p: &AuthenticatedPrincipal,
    work: Uuid,
    head: Digest,
    mode: &str,
) -> SyncResult<(Plan, bool)> {
    // head intentionally has no recursive ancestor query, even on a cold cache.
    let rows = if mode == "head" {
        sqlx::query("SELECT snapshot_id,octet_length(manifest_bytes)::bigint AS byte_count FROM sync_v2.snapshots WHERE account_id=$1 AND work_id=$2 AND snapshot_id=$3")
            .bind(&p.account_id).bind(work).bind(head.as_slice()).fetch_all(&mut **tx).await?
    } else {
        sqlx::query(r#"WITH RECURSIVE ancestors(snapshot_id) AS (
            SELECT snapshot_id FROM sync_v2.snapshots WHERE account_id=$1 AND work_id=$2 AND snapshot_id=$3
            UNION SELECT p.parent_snapshot_id FROM sync_v2.snapshot_parents p JOIN ancestors a ON a.snapshot_id=p.snapshot_id WHERE p.account_id=$1 AND p.work_id=$2
        ) SELECT s.snapshot_id,octet_length(s.manifest_bytes)::bigint AS byte_count FROM sync_v2.snapshots s JOIN ancestors a USING(snapshot_id) WHERE s.account_id=$1 AND s.work_id=$2"#)
            .bind(&p.account_id).bind(work).bind(head.as_slice()).fetch_all(&mut **tx).await?
    };
    let mut snapshots = HashMap::new();
    for row in rows {
        let id = digest(row.try_get("snapshot_id")?)?;
        snapshots.insert(
            id,
            Snapshot {
                id,
                byte_count: size(row.try_get("byte_count")?)?,
                parents: vec![],
                objects: vec![],
            },
        );
    }
    let ids: Vec<_> = snapshots.keys().map(|id| id.to_vec()).collect();
    let mut weight = snapshots.len();
    if mode == "backfill" {
        let edges: Vec<(Vec<u8>, Vec<u8>)> = sqlx::query_as("SELECT snapshot_id,parent_snapshot_id FROM sync_v2.snapshot_parents WHERE account_id=$1 AND work_id=$2 AND snapshot_id=ANY($3::bytea[])")
            .bind(&p.account_id).bind(work).bind(&ids).fetch_all(&mut **tx).await?;
        weight = weight.saturating_add(edges.len());
        for (child, parent) in edges {
            snapshots
                .get_mut(&digest(child)?)
                .ok_or(SyncError::Retryable)?
                .parents
                .push(digest(parent)?);
        }
    }
    // Immutable metadata only; never retain ownership or availability in cache.
    let objects = sqlx::query("SELECT DISTINCT e.snapshot_id,e.object_id,e.byte_count FROM sync_v2.snapshot_entries e WHERE e.account_id=$1 AND e.snapshot_id=ANY($2::bytea[])")
        .bind(&p.account_id).bind(&ids).fetch_all(&mut **tx).await?;
    weight = weight.saturating_add(objects.len());
    for row in objects {
        let bytes: i64 = row.try_get("byte_count")?;
        snapshots
            .get_mut(&digest(row.try_get("snapshot_id")?)?)
            .ok_or(SyncError::Retryable)?
            .objects
            .push(Item {
                kind: if bytes <= INLINE_OBJECT_BYTES { 1 } else { 2 },
                id: digest(row.try_get("object_id")?)?,
                byte_count: size(bytes)?,
            });
    }
    Ok((
        build_plan(snapshots.into_values().collect(), head, mode)?,
        weight <= CACHE_ITEMS,
    ))
}

pub(super) async fn page(
    state: &AppState,
    p: &AuthenticatedPrincipal,
    work: &str,
    params: &HashMap<String, String>,
) -> SyncResult<Value> {
    let mode = match params.get("mode").map(String::as_str) {
        Some("head") => "head",
        Some("backfill") => "backfill",
        _ => return Err(SyncError::SchemaViolation("download mode".into())),
    };
    let work_id = Uuid::parse_str(work).map_err(|_| SyncError::NotFound)?;
    if work_id.to_string() != work
        || params
            .keys()
            .any(|k| !["mode", "snapshotId", "cursor", "include"].contains(&k.as_str()))
        || params.get("include").is_some_and(|v| v != "totals")
        || (params.contains_key("include") && params.contains_key("cursor"))
    {
        return Err(SyncError::SchemaViolation("download query".into()));
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
        .map(|c| ModeCursor::decode(c, p, work_id, &head, mode))
        .transpose()?;
    let key = (p.account_id.clone(), work_id, head, mode);
    let plan = if let Some(CachedGraph::Shallow(plan)) = state.repo.download_cache.get(&key) {
        plan
    } else {
        let (plan, cacheable) = load_plan(&mut tx, p, work_id, head, mode).await?;
        let plan = Arc::new(plan);
        if cacheable {
            state
                .repo
                .download_cache
                .insert(key, CachedGraph::Shallow(plan.clone()));
        }
        plan
    };
    let start = plan.start(cursor.as_ref())?;
    let (end, resume) = plan.bounds(start);
    // Recheck all referenced objects of every touched snapshot (including large
    // and previously deduplicated objects). Missing ownership fails closed; it
    // cannot silently close a group with skipped objects on a warm cache.
    let mut groups = BTreeSet::from([head.to_vec()]);
    groups.extend(plan.items[start..end].iter().map(|i| i.snapshot.to_vec()));
    let groups: Vec<_> = groups.into_iter().collect();
    let owned: i64 = sqlx::query_scalar("SELECT count(*) FROM sync_v2.snapshots WHERE account_id=$1 AND work_id=$2 AND snapshot_id=ANY($3::bytea[])")
        .bind(&p.account_id).bind(work_id).bind(&groups).fetch_one(&mut *tx).await?;
    let unavailable: bool = sqlx::query_scalar("SELECT EXISTS(SELECT 1 FROM sync_v2.snapshot_entries e LEFT JOIN sync_v2.account_objects a ON a.account_id=e.account_id AND a.object_id=e.object_id LEFT JOIN sync_v2.global_blobs b ON b.object_id=e.object_id WHERE e.account_id=$1 AND e.snapshot_id=ANY($2::bytea[]) AND (a.state IS DISTINCT FROM 'available' OR b.object_id IS NULL OR b.byte_count<>e.byte_count))")
        .bind(&p.account_id).bind(&groups).fetch_one(&mut *tx).await?;
    if owned != groups.len() as i64 || unavailable {
        return Err(SyncError::NotFound);
    }
    let selected = &plan.items[start..end];
    let manifests: Vec<_> = selected
        .iter()
        .filter(|i| i.item.kind == 0)
        .map(|i| i.item.id.to_vec())
        .collect();
    let objects: Vec<_> = selected
        .iter()
        .filter(|i| i.item.kind == 1)
        .map(|i| i.item.id.to_vec())
        .collect();
    let mut payloads = HashMap::new();
    let rows: Vec<(Vec<u8>, Vec<u8>)> = sqlx::query_as("SELECT snapshot_id,manifest_bytes FROM sync_v2.snapshots WHERE account_id=$1 AND work_id=$2 AND snapshot_id=ANY($3::bytea[])")
        .bind(&p.account_id).bind(work_id).bind(manifests).fetch_all(&mut *tx).await?;
    payloads.extend(rows.into_iter().map(|(id, b)| ((0, id), b)));
    let rows: Vec<(Vec<u8>, Vec<u8>)> = sqlx::query_as("SELECT b.object_id,b.raw_bytes FROM sync_v2.global_blobs b JOIN sync_v2.account_objects a ON a.object_id=b.object_id WHERE a.account_id=$1 AND a.state='available' AND b.object_id=ANY($2::bytea[])")
        .bind(&p.account_id).bind(objects).fetch_all(&mut *tx).await?;
    payloads.extend(rows.into_iter().map(|(id, b)| ((1, id), b)));
    tx.commit().await?;
    let mut items = Vec::new();
    for pos in selected {
        let item = &pos.item;
        let bytes = payloads
            .remove(&(item.kind, item.id.to_vec()))
            .ok_or(SyncError::NotFound)?;
        if bytes.len() != item.byte_count || sha256(&bytes) != item.id {
            return Err(SyncError::Retryable);
        }
        items.push(json!({"kind":if item.kind == 0 {"manifest"} else {"object"},"id":hex::encode(item.id),"bytesBase64URL":URL_SAFE_NO_PAD.encode(bytes)}));
    }
    let next = if end < plan.items.len() {
        Some(plan.cursor(end - 1, p, work_id, &head, mode).encode()?)
    } else {
        None
    };
    let mut response = json!({"result":"noChanges","snapshotId":hex::encode(head),"mode":mode,"items":items,"nextCursor":next});
    if mode == "backfill" {
        response["resumeCursor"] = json!(resume
            .map(|i| plan.cursor(i, p, work_id, &head, mode).encode())
            .transpose()?);
    }
    if params.contains_key("include") {
        response["totals"] = plan.totals.value()?;
    }
    Ok(response)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn id(n: u64) -> Digest {
        let mut id = [0; 32];
        id[24..].copy_from_slice(&n.to_be_bytes());
        id
    }
    fn object(n: u64, size: usize) -> Item {
        Item {
            kind: if size > INLINE_OBJECT_BYTES as usize {
                2
            } else {
                1
            },
            id: id(n),
            byte_count: size,
        }
    }
    fn snapshot(n: u64, parents: &[u64], objects: Vec<Item>) -> Snapshot {
        Snapshot {
            id: id(n),
            byte_count: 100,
            parents: parents.iter().map(|n| id(*n)).collect(),
            objects,
        }
    }
    fn graph() -> Vec<Snapshot> {
        // Head has a shortcut directly to root 1. Shortest distance from H
        // would put that root before its own descendants 2 and 3.
        vec![
            snapshot(1, &[], vec![object(10, 10), object(11, 20)]),
            snapshot(2, &[1], vec![object(11, 20), object(12, 30)]),
            snapshot(3, &[2], vec![object(12, 30), object(13, 40)]),
            snapshot(4, &[1, 3], vec![object(10, 10)]),
        ]
    }

    #[test]
    fn head_is_local_and_backfill_uses_longest_depth_deduping_head_and_prior_groups() {
        let h = build_plan(
            vec![snapshot(
                4,
                &[1, 3],
                vec![object(10, 10), object(90, 300_000)],
            )],
            id(4),
            "head",
        )
        .unwrap();
        assert_eq!(
            h.items.iter().map(|p| p.item.id).collect::<Vec<_>>(),
            vec![id(4), id(10)]
        );
        assert_eq!((h.totals.items, h.totals.bytes), (3, 300_110));
        let p = build_plan(graph(), id(4), "backfill").unwrap();
        assert_eq!(
            p.items.iter().map(|p| p.item.id).collect::<Vec<_>>(),
            vec![id(12), id(13), id(3), id(11), id(2), id(1)]
        );
        assert_eq!(
            p.items
                .iter()
                .filter(|p| p.item.kind == 0)
                .map(|p| p.depth)
                .collect::<Vec<_>>(),
            vec![2, 1, 0]
        );
        assert_eq!((p.totals.items, p.totals.bytes), (6, 390));
        let mut shuffled = graph();
        shuffled.reverse();
        let other = build_plan(shuffled, id(4), "backfill").unwrap();
        assert_eq!(
            p.items.iter().map(|p| p.item.id).collect::<Vec<_>>(),
            other.items.iter().map(|p| p.item.id).collect::<Vec<_>>()
        );
    }

    #[test]
    fn equal_depth_is_snapshot_id_order_and_large_objects_count_once() {
        let p = build_plan(
            vec![
                snapshot(1, &[], vec![]),
                snapshot(3, &[1], vec![object(9, 300_000)]),
                snapshot(2, &[1], vec![object(9, 300_000)]),
                snapshot(4, &[2, 3], vec![]),
            ],
            id(4),
            "backfill",
        )
        .unwrap();
        assert_eq!(
            p.items.iter().map(|p| p.item.id).collect::<Vec<_>>(),
            vec![id(2), id(3), id(1)]
        );
        assert_eq!((p.totals.items, p.totals.bytes), (4, 300_300));
        assert_eq!(
            build_plan(vec![snapshot(1, &[], vec![])], id(1), "backfill")
                .unwrap()
                .items
                .len(),
            0
        );
    }

    #[test]
    fn deep_history_is_iterative_and_invalid_graphs_fail_closed() {
        let snapshots = (0..5001)
            .rev()
            .map(|n| snapshot(n, &if n == 0 { vec![] } else { vec![n - 1] }, vec![]))
            .collect();
        let p = build_plan(snapshots, id(5000), "backfill").unwrap();
        assert_eq!(p.items.len(), 5000);
        for (i, item) in p.items.iter().enumerate() {
            assert_eq!(item.depth, 4999 - i as u64);
        }
        assert!(depths(&[snapshot(1, &[2], vec![]), snapshot(2, &[1], vec![])]).is_err());
        assert!(depths(&[snapshot(1, &[2], vec![])]).is_err());
    }

    #[test]
    fn oversized_group_resumes_at_last_closed_manifest_or_null() {
        let p = AuthenticatedPrincipal::fixture("test");
        let work = Uuid::new_v4();
        // First group takes a full page plus 45 items. No safe resume yet.
        let plan = build_plan(
            vec![
                snapshot(1, &[], vec![]),
                snapshot(2, &[1], (100..400).map(|n| object(n, 1)).collect()),
                snapshot(3, &[2], vec![]),
            ],
            id(3),
            "backfill",
        )
        .unwrap();
        assert_eq!(plan.bounds(0), (256, None));
        let next = plan.cursor(255, &p, work, &id(3), "backfill");
        assert_eq!(plan.start(Some(&next)).unwrap(), 256);
        assert_eq!(plan.bounds(256), (302, Some(301)));
        let resume = plan.cursor(301, &p, work, &id(3), "backfill");
        assert_eq!(
            plan.bounds(plan.start(Some(&resume)).unwrap()),
            (302, Some(301))
        );
        // A closed newer group precedes a group exceeding the byte budget.
        let plan = build_plan(
            vec![
                snapshot(1, &[], (100..120).map(|n| object(n, 256 * 1024)).collect()),
                snapshot(2, &[1], vec![]),
                snapshot(3, &[2], vec![]),
            ],
            id(3),
            "backfill",
        )
        .unwrap();
        assert_eq!(plan.bounds(0), (8, Some(0)));
        assert_eq!(plan.bounds(8), (16, Some(0)));
        let boundary = plan.cursor(0, &p, work, &id(3), "backfill");
        assert_eq!(plan.start(Some(&boundary)).unwrap(), 1);
        let plan = build_plan(
            vec![
                Snapshot {
                    byte_count: 16 * 1024 * 1024,
                    ..snapshot(1, &[], vec![])
                },
                snapshot(2, &[1], vec![]),
            ],
            id(2),
            "backfill",
        )
        .unwrap();
        assert_eq!(plan.bounds(0), (1, Some(0)));
    }

    #[test]
    fn shared_mode_fixtures_match_plan_payloads_cursors_and_totals() {
        let graph: Value = strict_json(include_bytes!(
            "../../../docs/sync/v2/fixtures/scenarios/shallow-download.json"
        ))
        .unwrap();
        let binding = &graph["binding"];
        let p = AuthenticatedPrincipal::fixture(binding["accountId"].as_str().unwrap());
        let work = Uuid::parse_str(binding["workId"].as_str().unwrap()).unwrap();
        let head = decode_digest(binding["snapshotId"].as_str().unwrap()).unwrap();
        type PageFixture = (&'static [u8], &'static str);
        let fixtures: [(&str, &[PageFixture]); 2] = [
            (
                "head",
                &[(
                    include_bytes!("../../../docs/sync/v2/fixtures/canonical/download-head-1.json"),
                    include_str!("../../../docs/sync/v2/fixtures/canonical/download-head-1.sha256"),
                )],
            ),
            (
                "backfill",
                &[
                    (
                        include_bytes!(
                            "../../../docs/sync/v2/fixtures/canonical/download-backfill-1.json"
                        ),
                        include_str!(
                            "../../../docs/sync/v2/fixtures/canonical/download-backfill-1.sha256"
                        ),
                    ),
                    (
                        include_bytes!(
                            "../../../docs/sync/v2/fixtures/canonical/download-backfill-2.json"
                        ),
                        include_str!(
                            "../../../docs/sync/v2/fixtures/canonical/download-backfill-2.sha256"
                        ),
                    ),
                ],
            ),
        ];
        for (mode, pages) in fixtures {
            let mut snapshots = vec![];
            let mut payloads = HashMap::new();
            for row in graph["snapshots"].as_array().unwrap() {
                let raw = URL_SAFE_NO_PAD
                    .decode(row["bytesBase64URL"].as_str().unwrap())
                    .unwrap();
                let id = sha256(&raw);
                assert_eq!(hex::encode(id), row["id"]);
                let manifest = strict_json(&raw).unwrap();
                assert_eq!(canonical_json(&manifest).unwrap(), raw);
                payloads.insert((0, id), raw.clone());
                if mode == "head" && id != head {
                    continue;
                }
                snapshots.push(Snapshot {
                    id,
                    byte_count: raw.len(),
                    parents: manifest["parentSnapshotIds"]
                        .as_array()
                        .unwrap()
                        .iter()
                        .map(|id| decode_digest(id.as_str().unwrap()).unwrap())
                        .collect(),
                    objects: manifest["entries"]
                        .as_array()
                        .unwrap()
                        .iter()
                        .map(|entry| {
                            let byte_count = entry["byteCount"].as_u64().unwrap() as usize;
                            Item {
                                id: decode_digest(entry["objectId"].as_str().unwrap()).unwrap(),
                                byte_count,
                                kind: if byte_count <= INLINE_OBJECT_BYTES as usize {
                                    1
                                } else {
                                    2
                                },
                            }
                        })
                        .collect(),
                });
            }
            for row in graph["objects"].as_array().unwrap() {
                let raw = URL_SAFE_NO_PAD
                    .decode(row["bytesBase64URL"].as_str().unwrap())
                    .unwrap();
                assert_eq!(hex::encode(sha256(&raw)), row["id"]);
                payloads.insert((1, sha256(&raw)), raw);
            }
            let plan = build_plan(snapshots, head, mode).unwrap();
            let mut start = 0;
            for (page_number, (bytes, hash)) in pages.iter().enumerate() {
                assert_eq!(hex::encode(sha256(bytes)), hash.trim());
                let page = strict_json(bytes).unwrap();
                assert_eq!(canonical_json(&page).unwrap(), *bytes);
                let (end, resume) = plan.bounds(start);
                let items: Vec<_> = plan.items[start..end].iter().map(|pos| {
                    let item = &pos.item;
                    let raw = &payloads[&(item.kind, item.id)];
                    assert_eq!(raw.len(), item.byte_count);
                    json!({"kind":if item.kind == 0 {"manifest"} else {"object"},"id":hex::encode(item.id),"bytesBase64URL":URL_SAFE_NO_PAD.encode(raw)})
                }).collect();
                let next = if end < plan.items.len() {
                    Some(
                        plan.cursor(end - 1, &p, work, &head, mode)
                            .encode()
                            .unwrap(),
                    )
                } else {
                    None
                };
                let mut expected = json!({"result":"noChanges","snapshotId":hex::encode(head),"mode":mode,"items":items,"nextCursor":next});
                if mode == "backfill" {
                    expected["resumeCursor"] = json!(
                        resume.map(|i| plan.cursor(i, &p, work, &head, mode).encode().unwrap())
                    );
                }
                if page_number == 0 {
                    expected["totals"] = plan.totals.value().unwrap();
                }
                assert_eq!(canonical_json(&expected).unwrap(), *bytes);
                if let Some(next) = page["nextCursor"].as_str() {
                    let cursor = ModeCursor::decode(next, &p, work, &head, mode).unwrap();
                    assert_eq!(plan.start(Some(&cursor)).unwrap(), end);
                }
                start = end;
            }
            assert_eq!(start, plan.items.len());
        }
    }

    #[test]
    fn cursors_are_closed_bound_canonical_and_kind_specific() {
        let p = AuthenticatedPrincipal::fixture("test");
        let work = Uuid::new_v4();
        let plans = [
            (
                "head",
                build_plan(vec![snapshot(4, &[], vec![])], id(4), "head").unwrap(),
            ),
            ("backfill", build_plan(graph(), id(4), "backfill").unwrap()),
        ];
        for (mode, plan) in plans {
            let cursor = plan.cursor(0, &p, work, &id(4), mode);
            let raw = cursor.encode().unwrap();
            assert!(ModeCursor::decode(&raw, &p, work, &id(4), mode).is_ok());
            assert!(ModeCursor::decode(&raw, &p, work, &id(5), mode).is_err());
            assert!(ModeCursor::decode(&raw, &p, Uuid::new_v4(), &id(4), mode).is_err());
            assert!(ModeCursor::decode(
                &raw,
                &p,
                work,
                &id(4),
                if mode == "head" { "backfill" } else { "head" }
            )
            .is_err());
            assert!(Cursor::decode(&raw, &p, work, &id(4)).is_err());
            for foreign in [
                AuthenticatedPrincipal {
                    account_id: "other".into(),
                    ..p.clone()
                },
                AuthenticatedPrincipal {
                    account_fence: "other".into(),
                    ..p.clone()
                },
                AuthenticatedPrincipal {
                    server_instance_id: "other".into(),
                    ..p.clone()
                },
                AuthenticatedPrincipal {
                    protocol_epoch: 3,
                    ..p.clone()
                },
            ] {
                assert!(ModeCursor::decode(&raw, &foreign, work, &id(4), mode).is_err());
            }
            let value = serde_json::to_value(&cursor).unwrap();
            for (key, val) in [("extra", json!(0)), ("kind", json!("unknown"))] {
                let mut bad = value.clone();
                bad[key] = val;
                let encoded = URL_SAFE_NO_PAD.encode(canonical_json(&bad).unwrap());
                assert!(ModeCursor::decode(&encoded, &p, work, &id(4), mode).is_err());
            }
            let mut bytes = canonical_json(&value).unwrap();
            bytes.push(b' ');
            assert!(
                ModeCursor::decode(&URL_SAFE_NO_PAD.encode(bytes), &p, work, &id(4), mode).is_err()
            );
            let mut unknown = value.clone();
            if mode == "head" {
                unknown["afterId"] = json!(hex::encode(id(999)));
            } else {
                unknown["afterItem"] = json!(999);
            }
            let forged = serde_json::from_value(unknown).unwrap();
            assert!(plan.start(Some(&forged)).is_err());
        }
        let legacy = Cursor {
            account_id: p.account_id.clone(),
            account_fence: p.account_fence.clone(),
            server_instance_id: p.server_instance_id.clone(),
            protocol_epoch: p.protocol_epoch,
            work_id: work,
            snapshot_id: hex::encode(id(4)),
            after_kind: 0,
            after_id: hex::encode(id(4)),
        }
        .encode()
        .unwrap();
        for mode in ["head", "backfill"] {
            assert!(ModeCursor::decode(&legacy, &p, work, &id(4), mode).is_err());
        }
    }
}

#[cfg(test)]
#[path = "shallow/client_fixture_tests.rs"]
mod client_fixture_tests;
