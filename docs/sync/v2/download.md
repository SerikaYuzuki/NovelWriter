# Bounded initial graph download (D-101)

`GET /v2/works/{workId}/download?snapshotId={digest}[&cursor={opaque}]`
is a read-only, additive v2 endpoint. It does not seal commands, create receipts,
advance a head, or change the SQLite/PostgreSQL schema. Existing clients keep
using individual manifest/object reads. A new client may fall back to those
reads only when its first page request returns an untyped router 404 or 405;
a typed account-scoped 404 remains a missing root/work failure. The fallback
checks the remote deletion status before reading individual manifests; a failed later page
or invalid data must not turn into a successful partial import.

The client first obtains the head and pins that immutable Snapshot ID for every
page. The server requires the usual bearer, server instance, protocol epoch and
account fence headers. The WorkID and root snapshot must belong to that account
and the same active, non-deleted work. Foreign, deleted and missing roots have
the same account-scoped 404 response. Cursors bind account, fence, server,
protocol, WorkID and root Snapshot ID; they cannot be moved to another query.

The [closed response schema](download-page.schema.json) uses the v2 JCS media
type, `Cache-Control: no-store`, and `Pragma: no-cache`. `items` are globally
ordered by `(kind, id)`, manifests before objects, with each identity occurring
once across all pages. Manifest bytes cover the root's complete ancestry;
object bytes are deduplicated across that ancestry. The cursor resumes strictly
after the last returned identity. A concurrently published head does not alter
this pinned graph.

A page has at most 256 items and normally at most 2 MiB of decoded payload.
One legal manifest larger than that budget is returned alone (the existing
16 MiB manifest cap still applies). The server selects sizes before fetching
BYTEA payloads. Objects up to and including 256 KiB are included; larger objects
use the existing authenticated, digest-checked object GET. The complete JSON
response is bounded by 24 MiB on the client, including Base64 expansion. Empty
terminal pages are legal; nonterminal empty pages and repeated cursors are not.

Clients validate canonical response bytes, closed keys, root identity, ordering,
digest of every item, manifest WorkID/schema, complete parent closure, the
existing unique-object budget and object byte counts. Missing small objects,
extra unreferenced objects and unreachable or cyclic manifests are rejected.
Ordinary sync and conflicts use the Inbox stage/verify/adopt flow. Remote-only
first import (absent work, or generation zero/current NULL, no editor session,
no conflict or pending intent) validates the complete graph and installs it in
one BEGIN IMMEDIATE transaction. Failure or cancellation before COMMIT rolls
back all new rows; existing history and inbox evidence are retained. Both paths preserve
digest, graph, document anchor, work/session/account and generation/CAS checks.
After COMMIT, cancellation/account change rejects presentation while preserving
the complete installed work under its original binding. Downloading does not select a work
or loosen the editor boundary. Failed imports preserve the current manuscript.

Each temporary transport/5xx failure retries only that page with the same root
and cursor, at most five times. Exponential backoff with jitter waits about
31 seconds in total without server guidance; Retry-After (seconds or HTTP date)
is honored up to 30 seconds per wait. Sleeps are cancellable. Requests use a
30-second idle timeout and a one-hour resource timeout. Remote-only download
fails after 60 seconds without received page/object/byte progress, not after a
fixed overall duration. URLSession download byte callbacks extend this deadline;
local-store validation/install are outside the network stall timer. Expiry returns a
retryable failure. Refreshed credentials are retained for subsequent reads
within the same import and must preserve the original account binding. Authorization, scope, throttling and validation
failures are not silently retried. No history-count cutoff, pruning, lossy
conversion or portable-package shortcut is introduced.

Stage performs full entity validation once per unique (entity key, ObjectID),
hashes unique object bytes, and validates each snapshot's entity references.
The document anchor is decoded once; historical models are not materialized.
The existing schema_meta table stores
an inbox-validator/<inbox UUID> marker (version 1, checksum = head digest),
without schema changes. A missing, differing, or head-mismatched marker requires
full validation. Verification/adoption rehash every unique persisted object and
manifest, attest closure rows and byte counts, and check parent closure,
reachability, cycles, scope and CAS. The head digest binds the immutable ancestry;
all snapshots must reference the same work/document ObjectID, decoded once.
No mutable object bytes are trusted on reload. New rows inserted by validated
statements need no immediate read-back; existing snapshot rows retain attestation.
Imports compare reused existing CAS bytes once per unique object; ordinary
checkpoints rely on immutable content addressing, attested immutability triggers
and byte_count, with digest validation when reading objects.

Full graph validation for stage and first install runs outside the store actor,
with cancellation propagation. Mutable work/scope/CAS checks run again inside
the transaction after validation. SQLite statements are cached only per store
connection and finalized on close; transaction object caches never outlive COMMIT
or ROLLBACK.

A generation-zero local work with no current snapshot is not yet installed,
even if a staged, verified, or rejected inbox remains. Explicit open downloads
and atomically installs the graph; existing inbox evidence and adopted history remain.
The shelf continues to show this work as remote-only. Application opens and
remote-only renames join one import per WorkID, retained until cancellation
actually finishes. The platform document gate checks the durable generation
before presenting an import result, so a joined rename cannot be overwritten
by the older returned document. Account transition suspension rejects new remote opens and
cancels existing ones. Download-time binding is checked before validation, immediately before atomic
install, and after install; ordinary sync
retains its stage/verify/adopt checks; cancellation is checked at these boundaries and during graph work.
iOS open and rename hold a background task lease whose expiry cancels import.

## Negotiated progress totals (D-105)

New clients request `include=totals` only on the first page. No opt-in means
exactly the original closed envelope: old clients must never receive extra keys.
A negotiated first page includes `totals: {items, bytes}`: deduplicated manifests
and objects in the complete pinned ancestry, including large separately fetched
objects and thumbnail attachments; bytes are raw sizes, not JSON/Base64 wire
sizes. Both values are nonnegative JCS-safe integers. Totals use S-03 metadata
and its cold-query aggregates, including oversized closures; later pages incur
no totals query or summation. Mutable availability is still checked independently.
Totals do not authenticate content or relax closure/digest validation.

Older servers reject unknown query keys. On 400/404/405 (also the original server's typed schemaViolation/422) from the initial opt-in
request the client retries the same pinned root without `include`, once. Only
then may the existing untyped 404/405 endpoint fallback apply. A typed 404
fails closed immediately, including on the opt-in request. Missing totals are supported, including servers ignoring opt-in.
`include` on a cursor request or any value other than `totals` is rejected.

Manual 「この端末に取り込む」 shares the WorkID import with explicit open and
rename; it never begins an editor session. No automatic prefetch is performed.
Progress counts raw payloads (large-object byte callbacks use per-object high-water
marks so retries do not inflate the fraction), with unknown totals shown as received MB.
The stream coalesces byte updates to 10 Hz and emits phase boundaries immediately.
Before COMMIT cancellation rolls back; after COMMIT the complete local work is
retained and cancelled presentation is rejected (D-102). Retry starts a fresh
import after the cancelled single-flight has actually finished. Failure kind is
retained per WorkID until retry or account transition.

## Head-first and backfill (D-106)

[Reviewed design](shallow-history-design.md) and [D-106](../../DECISIONS.md)
cover the whole feature. Client Step 2 adds shallow SQLite installation, a
background backfill lane and per-item availability. Priority restore/merge UX
is Step 3. No `/v2/capabilities` keys, v2 name or server database schema change.

### Negotiation and head

`GET /v2/works/{workId}/download?snapshotId=H&mode=head[&include=totals]`
returns H's manifest and only H's referenced inline objects, deduplicated and
ordered by `(kind, id)` as in D-101. H's ancestors are not traversed, even for
first-page totals. Larger objects remain available through the existing object
GET using H's entries. The closed envelope adds `"mode":"head"`; it does not
have `resumeCursor`. The usual 256-item / 2 MiB raw-byte page budgets, single
oversized manifest exception, media type, digest checks and cache headers apply.

Requests **without `mode` retain exactly the D-101/D-105 response bytes**, including
old cursors, optional totals, error bodies and absence of new envelope keys.
An unknown mode, query key or include value is a schema violation. `include=totals`
is valid only without a cursor. The client negotiates with `mode=head`;
on initial 400/404/405/422 it retries once without `mode` and uses the D-101/D-102
full import. This does not make a typed account-scoped 404 a successful import:
the legacy retry still checks visibility and fails closed for a deleted/foreign
work. Later-page failure never switches modes or installs a partial graph.

### Backfill order and group boundaries

`GET /v2/works/{workId}/download?snapshotId=H&mode=backfill[&include=totals]`
returns H's strict ancestors. H stays pinned even if a newer head is published.
Depth is zero for a root, otherwise `1 + max(parent depths)`; order is depth
**descending**, then Snapshot ID ascending. It is not shortest distance from H.
This immutable topological order puts children before all parents, including
merges with shortcut edges. No generation-count cutoff is imposed.

Each ancestor is one group: new inline objects in Object ID ascending order,
then that snapshot's manifest. The manifest closes the group. Deduplication
excludes all objects referenced by H (including large objects), then objects
referenced by earlier groups. Large objects contribute to totals but are not
inline items; retrieve them through the existing object GET. Entity references
in manifests are unchanged. No history or object is truncated/deleted.

Page budgets still apply **within a group**: a group larger than a page is split,
not rejected or returned as an unbounded page. Every backfill response has
`"mode":"backfill"` and `resumeCursor` in addition to the usual keys:

- `nextCursor`: after the last returned item if more items remain; otherwise null.
- `resumeCursor`: after the last manifest closing a group anywhere in the stream
  through this page (possibly on a previous page); null if no group has closed.
  It can be non-null on a terminal page. Following a terminal resume cursor
  returns an empty terminal page with that same resume cursor.

Use `nextCursor` while receiving a stream. Persist only a verified closed-group
boundary for restart; replay from `resumeCursor` may resend a partial group's
objects and is intentionally idempotent. An oversized first group can leave
`resumeCursor` null for several pages. Empty nonterminal pages are forbidden.
These transport boundaries do not replace the pending client's digest, anchor,
ancestry, scope, generation and atomic-install validation.

### Cursors, totals and mutable checks

[Decoded cursor schemas](download-cursor.schema.json) are closed tagged unions;
clients treat the canonical-JCS/Base64URL encoding as opaque. Both bind
`accountId`, `accountFence`, `serverInstanceId`, `protocolEpoch`, `workId` and
`snapshotId` (H). Head cursors have `kind=head`, `afterKind` (0 manifest / 1
object), `afterId`. Backfill cursors have `kind=backfill`, `afterDepth`,
`afterSnapshotId` and `afterItem`, a zero-based index among the group's **inline
items and closing manifest**. Large objects do not occupy indices. The position
must exist in the pinned plan. Unknown fields, legacy/new cursor mixing and
head/backfill mixing are rejected; stale/foreign binding returns fence mismatch.
A future persisted depth column must retain exactly this cursor meaning.

Opt-in first-page `totals: {items, bytes}` use the same units as D-105: manifests
plus unique objects (including large objects), and their raw sizes. Head totals
cover H only. Backfill totals cover strict ancestors and their new objects after
H/earlier-group deduplication; they exclude H and all its objects. They are not
a count of snapshots alone. An empty backfill has zero totals. Both are
nonnegative JCS-safe integers. Totals never appear without opt-in or on cursor
pages and never authorize skipping content checks.

The existing per-repository DownloadCache keeps immutable plans for 30 seconds,
keyed by account/work/H/**mode**, with at most four entries shared across modes.
Backfill reads ancestors, edges and object metadata once per cold plan, computes
longest depths/order in memory without recursion, and caches only when the
combined snapshot/edge/object-reference metadata is at most 100,000 rows.
Oversized plans are recomputed cold for each page, with no history cutoff and
no unbounded persistent cache entry. Head uses direct H metadata only. No
payload bytes, mutable availability or access decisions are cached.

Every page, including warm-cache and empty terminal pages, opens a read-only
repeatable-read PostgreSQL transaction. It checks H's account/work ownership,
active-work and deletion visibility. Each touched snapshot is checked in the
same scope; all its references (also H's references, large objects and deduped
objects) must still be account-owned, available, present and size-consistent.
New-mode pages fail with account-scoped 404 rather than silently skipping an
unavailable object and closing its group. Selected payloads are re-read,
size/digest checked and returned from that page's consistent database view.
Authentication and scope headers are checked on every HTTP request as before.

Backfill has a dedicated global semaphore with **one permit**, separate from
the two foreground download permits. A second concurrent backfill returns the
canonical retryable 503 with `Retry-After: 1`, without waiting on authentication
or PostgreSQL. Head and legacy initial imports retain their foreground permits;
backfill cannot occupy them. No deployment or client acceptance is implied by
this server contract step.
