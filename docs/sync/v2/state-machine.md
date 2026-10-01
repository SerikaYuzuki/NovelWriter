# v2 state machine

## Work and command states

```text
localOnly -> createWorkSealed -> remoteNullHead -> remotePublished
unbound -> bound -> quarantined -> bound
                     `-> parked (different account)

localLeaf -> promoted/localCommitted -> sealed -> sending -> completed
                                  |-> sealed (lost response, exact retry)
                                  |-> quarantined (fence/epoch change)
                                  `-> conflictPending
conflictPending -> sealed(resolveDevice|resolveServer|cloneWork)
                 `-> parked (no user choice)
```

Required invariants:

1. local commit succeeds without a network call and retains the manuscript on
   every failure path;
2. at most one `conflictPending` exists per WorkID;
3. a sealed command is immutable after its first network byte;
4. a different AccountID cannot use, rebind, or disclose a work's command,
   object, title, or conflict;
5. a changed AccountFence never resumes an old command; it quarantines it and
   requires capabilities/bootstrap/replan;
6. `useServer` preserves a pre-adoption checkpoint, and `cloneWork` creates a
   new WorkID; no path rewinds a head in place;
7. active editor text is changed only at the existing safe document/IME/session
   boundary.
8. a new local Work remains editable at generation 1 or later while offline;
   its first remote plan is exactly createWork, object closure, register, then
   publish with expected head null. Register missing parent Snapshots before
   their descendants only in the closure of a promoted/protected snapshot.
   Unpromoted sibling leaves are not registration dependencies. Existing legacy
   ancestors remain required; do not rewrite or trim their graph. When the current server head is null, publish the latest
   registered checkpoint directly; do not publish each historical ancestor.
   Once a head exists, keep the existing expected-head lineage rules.
   No later step may bootstrap a missing Work.

## Recovery of response-less command quarantines

The D-107 additive SQLite upgrade records the command IDs already quarantined
with `command:unexpected` and no response/receipt/transfer/evidence. Fresh
databases have no candidates; quarantines created after upgrade are never added.
Automatic launch/foreground/network wakes and retries may replay one of these
candidates at most once, only when the original
account/server/epoch/fence binding is still active and there is no stored
response, verified receipt, upload transfer or quarantine response evidence.
The release and durable candidate consumption commit in the same transaction.
Explicit release also consumes the candidate. Re-quarantine stays blocked across
wakes and restarts until explicit sync; planners scan once per binding per launch,
not on every UI poll or command. All nine sealed command kinds are covered.
Keep the command ID, request digest,
canonical request bytes and intent unchanged; the server may already have
committed the original receipt. Deleted or reserved works remain excluded.
Other quarantine reasons (including missing reasons) and response-bearing
commands remain blocked on automatic paths. Explicit sync keeps its existing
manual retry of uploads, initial createWork and the sealed intent's publish
with the same command ID and canonical request bytes. Explicit sync also keeps
the generalized response-less retry without the legacy candidate restriction.

HTTP 408/429/5xx, including proxy-generated HTML without sync headers, are
transport failures and remain retryable before envelope validation. Invalid
2xx/409/422 headers or payloads remain fail-closed as receipt/remote-data
failures, so new invalid responses cannot enter this legacy recovery path.

After exact receipt verification, check the capability expiry even when no
transfer row existed before replay. An expired receipt remains immutable and
completed; seal a new prepare command to obtain a fresh upload ID/capability
before sending object bytes. Do not rewrite the old receipt or reuse its expired
capability. The same check applies after a process restart between receipt
acknowledgement and transfer creation.

## Conflict choices

The resolver is closed to the three values `useDevice`, `useServer`, and
`keepBoth`. The UI must present the selected branch and a stable conflict ID,
and must not offer an implicit winner or “always choose” setting in v2.

## Local leaves and promotion (D-103)

- Stable is the current snapshot unless its only local occurrences are unpinned
  `autosaveLeaf` rows; in that case the leaf's parent is stable (or none for a
  new work). Old `autosave` rows are deliberately stable at upgrade time.
- A changed autosave is a sibling of preceding leaves, atomically durable in
  SQLite with no sync intent. Unchanged autosaves do not extend history.
- Promotion adds a pinned occurrence for the same bytes plus a checkpoint
  intent atomically. Subsequent leaves parent that promoted snapshot. Explicit,
  navigation, close and migration saves, lifecycle/work switch, explicit sync,
  60-second idle and 300-second maximum-writing intervals are promotion points.
  Clocks are injectable, and both intervals are defined in one shared place.
- Launch recovery is once per attested binding/runtime, including unopened
  works. Open also recovers retained leaves. Periodic worker wakeups must not
  promote every poll. No crash-recovery path captures editor text.
- A changed remote head reconciles by protecting/queuing the current leaf;
  account fence/rebind paths likewise protect any leaf they queue. Publish uses
  the existing acknowledged ancestor/CAS rules. Ordinary adoption must reject
  an unpromoted current leaf even though there is no pending intent. Concurrent
  newer leaves are still protected by current-snapshot/generation checks.
- Parked account data never gains an unbound intent; deletion blocks promotion
  and retains bound-work local bytes for rescue. A different account cannot
  recover, queue or disclose these leaves.
- Restore, conflictResolution and keepBoth retain their current semantics,
  including protected local parents required by their graph. All local leaves,
  old chains, intents and receipts are retained. No schema/wire/server change.

## Head-first and background history (D-106 Step 2)

`remoteOnly -> verifiedHead -> shallowLocal + backfill(running) -> complete`.
Only explicit open/prefetch creates a backfill record. Launch resumes existing
`running` / `paused` records; it never enrolls remote-only catalog items.

- One global application lane serializes works. Constrained/offline connectivity
  cancels the lane and pauses it; restored connectivity resumes it.
- Account-transition suspension cancels the lane. Same-account fence changes
  reset only the cursor, replaying the pinned H idempotently. Foreign account
  bindings stay parked and cannot read or update the journal.
- A split group's objects stay in memory until its manifest closes. A page's
  closed groups and `resume_cursor` commit together. Cancellation rolls back the
  page; restart replays the unfinished group from the last closed cursor.
- 401/404 suspend the journal and preserve the local manuscript; validation
  failures become `failed` and are not automatically retried. Transport failures
  become `paused`, eligible for a later connectivity/launch wake.
- No page rewrites current/head/generation/intents. H1 adoption and new local
  leaves coexist with backfill still pinned to H. Every commit invalidates the
  registered-ancestor cache. Incomplete lineage returns `historyIncomplete`
  without deleting staged Inbox data or unsent intents.

Step 3 adds priority requests for restore, deep Inbox parents and conflict
ancestry through the same lane; it does not introduce another download worker.
