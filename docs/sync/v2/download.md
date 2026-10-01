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
The verified graph still passes the normal Inbox stage/verify/adopt transaction
and work/session/account/generation checks. Downloading does not select a work
or loosen the editor boundary. Failed imports preserve the current manuscript.

Each temporary transport/5xx failure retries only that page with the same root
and cursor, at most five times. Exponential backoff with jitter waits about
31 seconds in total without server guidance; Retry-After (seconds or HTTP date)
is honored up to 30 seconds per wait. Sleeps are cancellable. Requests use a
30-second idle timeout, the session resource timeout is 120 seconds, and the
application limits one complete import attempt to 180 seconds. Expiry returns
a retryable failure. Refreshed credentials are retained for subsequent reads
within the same import and must preserve the original account binding. Authorization, scope, throttling and validation
failures are not silently retried. No history-count cutoff, pruning, lossy
conversion or portable-package shortcut is introduced.

Local import validates persisted inbox bytes again at verification and adoption.
Within one adoption transaction, the already validated immutable graph and its
work/document anchor feed snapshot insertion without decoding the same graph
again. Parent checks, existing-row byte attestation, scope and CAS checks remain
in the transaction; no validation cache survives a call or trusts mutable rows.

A generation-zero local work with no current snapshot is not yet installed,
even if a staged, verified, or rejected inbox remains. Explicit open downloads
and stages a fresh inbox; existing inbox evidence and adopted history remain.
The shelf continues to show this work as remote-only. Application opens and
remote-only renames join one import per WorkID, retained until cancellation
actually finishes. The platform document gate checks the durable generation
before presenting an import result, so a joined rename cannot be overwritten
by the older returned document. Account transition suspension rejects new remote opens and
cancels existing ones. Download-time binding is checked before stage, verify,
and adopt; cancellation is checked at these boundaries and during graph work.
iOS open and rename hold a background task lease whose expiry cancels import.
