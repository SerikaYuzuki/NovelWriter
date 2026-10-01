# D-02 head-first open + history backfill — reviewed design (implement as D-106)

Goal: opening a work not on this device installs only the latest snapshot H (manifest + all its objects) and opens the editor; older history is backfilled in the background with a resumable cursor. Never delete/truncate history; never weaken digest/graph/anchor/scope/CAS validation; editing/autosave/IME/Undo and WorkID/session/account/generation gates unchanged; manuscript kept on failure.

## Server (snapshot_download.rs)
- Requests without `mode` stay byte-identical to D-101/D-105. Do NOT add keys to /v2/capabilities (client validates a closed key set). Negotiate like D-105: new client sends `mode=head`; if an old server returns 400/404/405/422, retry once without `mode` and fall back to the full D-101/D-102 import.
- `mode=head`: `GET /v2/works/{w}/download?snapshotId=H&mode=head[&include=totals]` returns manifest H and objects ≤256 KiB referenced by H only (no recursive ancestor query); same `(kind,id)` order and page limits; large objects via the existing object GET from H's entries. Closed response gains `"mode":"head"`. Cursor `{"kind":"head",account,fence,server,epoch,workId,snapshotId,after…}`. Totals cover H only.
- `mode=backfill`: ancestors of pinned root H ordered by `depth` DESC (depth = longest distance from a root = 1 + max parent depth; immutable per snapshot so children always precede parents even with two-parent merges — do NOT use shortest distance from H), then snapshotId ASC within a depth. Items grouped per snapshot: its new objects first, then its manifest closing the group; exclude objects referenced by H and objects already sent in earlier groups. Return `nextCursor` (after the last item) and `resumeCursor` (after the last closed group, or null). Separate cursor struct `{"kind":"backfill",…,"snapshotId":H,"afterDepth","afterSnapshotId","afterItem"}`; reject mode/cursor kind mismatches and old cursors. First page `include=totals` = remaining ancestors' count/bytes. Compute ancestors/edges/objects once, order in memory, store in the existing 30 s DownloadCache; oversized graphs recompute cold per page. (A later `snapshots.depth` column must not change cursor meaning.) Dedicated backfill semaphore with 1 permit so head/initial imports get priority; when full return 503 + Retry-After. Re-check account/deletion visibility, ownership and availability in PostgreSQL every page.

## Client storage (append-only SQLite migration)
`snapshot_parents` has immediate FKs to existing parent rows, so defer missing parents into a boundary table:

```sql
-- Shallow history (D-106).
CREATE TABLE shallow_boundaries (
  work_id TEXT NOT NULL, snapshot_id BLOB NOT NULL,
  parent_snapshot_id BLOB NOT NULL CHECK (length(parent_snapshot_id)=32),
  PRIMARY KEY (snapshot_id, parent_snapshot_id),
  CHECK (snapshot_id <> parent_snapshot_id),
  FOREIGN KEY (work_id, snapshot_id) REFERENCES snapshots(work_id, snapshot_id));
CREATE INDEX shallow_boundaries_parent ON shallow_boundaries(work_id, parent_snapshot_id);
CREATE TABLE history_backfills (
  work_id TEXT PRIMARY KEY REFERENCES works(work_id), root_snapshot_id BLOB NOT NULL,
  server_instance_id …, protocol_epoch …, account_id …, account_fence …,
  resume_cursor TEXT, state TEXT CHECK (state IN ('running','paused','failed','suspended','complete')),
  failure_code TEXT, received_snapshots INTEGER NOT NULL DEFAULT 0, total_snapshots INTEGER,
  updated_at TEXT NOT NULL,
  FOREIGN KEY (work_id, root_snapshot_id) REFERENCES snapshots(work_id, snapshot_id),
  FOREIGN KEY (work_id, server_instance_id, …) REFERENCES account_bindings(…));
-- shallow_boundaries: no UPDATE; DELETE only when the matching snapshot_parents row exists (trigger).
```

Migration: `Schema.open` currently appends one tail migration keyed by the `-- Work deletion journal.` marker; generalize to an ordered list of known markers, applying/verifying from each previous checksum. Existing tables unchanged.

Invariants:
- B0: for each parent p of snapshot s exactly one of `snapshot_parents(s,p)` / `shallow_boundaries(s,p)` exists.
- B1: boundary rows are created only for snapshots received from the server and verified (head install, backfill, Inbox). Locally created snapshots (leaves, promotions, restore, conflict resolution) always have local parents.
- B2: every path that inserts snapshot X replaces boundary rows `(c,X)` with `snapshot_parents` rows in the same transaction.

Install (inside the D-102 single BEGIN IMMEDIATE): H digest equals the pinned ID and server head; manifest workId/schema; every object digest/size; full entity validation; document anchor; binding before/after; gen0 + current NULL CAS; no conflict/unsent intents; monotonic head; boundary rows exactly equal H's manifest parents; create `history_backfills` row `running`.

Backfill page (one page = one transaction): each manifest digest/workId/schema; new objects entity-validated once per unique key/object; `work/document` ObjectID equals the work's anchor (equivalent of D-101's "all snapshots reference the same document object"); every snapshot connects to H through an existing boundary row or an edge within the page (hash-chain proof of ancestry); existing CAS bytes attested; unique-object budget; binding and deletion re-checked in the transaction; save `resume_cursor` in the same transaction. When boundary rows reach 0 the row set equals a D-101 full import.

Code changes (verified locations):
| Location | Needs ancestors? | Change |
|---|---|---|
| `attestEncodedRows` (+SQLite.swift ~438), run by every `loadEncoded` | parent rows match manifest | match on union of `snapshot_parents` ∪ boundary rows equal to manifest parents, disjoint |
| `validateParents` (~404) via `committedSnapshot` (+SnapshotLookup:54) | parent exists locally | pass if local or a boundary row for the same child exists |
| `validateGraphParents` (+GraphValidation:106) | Inbox parents local | allow local parents or parent IDs on the work's boundary; deeper unknown parents → `historyIncomplete` (retryable) |
| `conflictAncestors` / `validateConflictBase` / `graphHead` (+ConflictLineage) | common ancestor | return set + incomplete flag; when proving non-membership/disjointness while incomplete → `historyIncomplete`, never `invalidSnapshot`; NEVER treat incomplete as "base nil / disjoint" |
| `publishBaseHead` (+PublishBase) | candidate → confirmed head | unchanged (leaves/promotions descend from H locally; server CAS is authoritative) |
| `registeredSnapshotIDs` / `nextSnapshotTransferView` (+Transfer) | registration | starts from confirmed head and stops at H; by B1 never descends into the boundary; invalidate `registeredAncestorCache` on each backfill commit |
| `checkpointParents` (+Promotion) | leaf parent | unchanged |
| `fetchSnapshot` (+SnapshotGraph:72) | stops at locally committed | also stop at boundary parent IDs; deeper unknown IDs → `historyIncomplete` instead of walking to root |
| `snapshotParents` API | listing | return manifest parents (including boundary) |
| deletion purge (+Deletion:146) | tables | delete the two new tables before snapshots |

Operations: always available (incl. offline): edit, autosave, promote, publish, fast-forward, ordinary 3-choice conflict, keepBoth/account clone, history/preview/restore of local versions, export. Needing ancestors: restore of an unfetched version, Inbox merges with deep parents, conflicts whose base is older than the boundary — prioritize backfill and retry when it arrives; keep manuscript and unsent intents; never discard as failure.

During backfill: stays pinned to the first H; newer heads arrive via the normal Inbox (stops at local versions or the boundary). Resume from `resume_cursor` after restart with the same binding; same account with a changed fence → discard cursor and restart (idempotent re-verification); different account → parked. Server 404/401 for work/account deletion → `suspended`, keep local work (D-092). One backfill per WorkID and one globally; cancel on account-transition suspension; pause in Low Data Mode. Only works the user opened/took onto the device (no automatic fetching of remote-only works, U-10).

UX: first open shows the D-105 phases for H only. Shelf row secondary note 「古い履歴を取得中 320 / 1,467」 (or MB without totals), separate from sync status. History list marks per-item availability (`SyncV2HistoryItem` field): unfetched → 「古い履歴を取得中…」; paused/offline/failed → 「オンラインで取得」 (priority fetch). Restoring an unfetched version: 「この版はまだ端末にありません。取得後に復元できます。」 + [今すぐ取得]. Conflict waiting: 「サーバーの変更を確認するため古い履歴を取得しています。原稿は端末に保存済みです。」 Failure: 「古い履歴を取得できませんでした・通信が途切れました」 + [再試行]; validation failures are not auto-retried: 「サーバーの履歴を確認できませんでした」 + details.

## Steps
1. Server & contract (client unchanged): modes, two cursor kinds, depth ordering, resumeCursor, backfill semaphore; D-106 draft, download.md "Head-first and backfill", schema(s), openapi, CONFORMANCE. Tests: no-mode responses byte-identical; head returns only H's objects; merge ancestry puts children before parents; dedupe vs H; group boundaries/resumeCursor and an oversized single group; cursor binding (account/fence/work/root/mode), unknown keys and kind mixing rejected; deletion/other account 404; totals; >4,096-generation linear history; order stable under concurrent publish.
2. Client head-first + backfill: migration + Schema.open generalization; B0–B2; table above; `installShallowHead`, `applyBackfillPage`, `backfillState`, `snapshotAvailability`; Runtime +DownloadHead/+Backfill; Application backfill coordinator; `historyIncomplete` mapping; per-item history availability. Old server → D-101 full import. Docs: sqlite.sql, state-machine, SNAPSHOT_SYNC_V2 §4, ui-state, finalize D-106, scenario fixture `shallow-install-backfill.json`. Tests: migration from each prior checksum / fresh / tamper rejected; install CAS/binding/cancel rollback; edit/promote/publish during backfill (expected head H); mid-page interruption, resume after restart, fence change restart, other account parked, 404 suspended; head advance during backfill (H1 adoption); malformed pages (anchor mismatch, snapshot outside boundary, digest mismatch, extra object) add no rows; incomplete lineage → `historyIncomplete`; completed row set equals D-101; deletion purge; cache invalidation; a 256-item page holds the write lock < 100 ms.
3. Priority fetch & UX: restore/merge-Inbox/conflict-waiting priority backfill, 「オンラインで取得」, Low Data, wording, accessibility. Tests: restore of an unfetched version succeeds after fetch; deep-parent merge Inbox adopts after waiting; conflict creation succeeds after waiting; offline display.

Review hot spots: (1) `attestEncodedRows`/`validateParents` run on every load — ordinary works without boundary rows must keep full parent attestation (pin B1 with tests); (2) never confuse incomplete with disjoint/not-ancestor; (3) checksum-chain migration; (4) depth ordering with merges; (5) mode/cursor confusion; (6) per-page lock time vs autosave; (7) stale `registeredAncestorCache`.
