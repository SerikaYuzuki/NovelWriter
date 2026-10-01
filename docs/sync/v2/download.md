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
