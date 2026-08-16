# R0 conformance harness

`Scripts/conformance-r0.sh` is the first executable slice of the reviewed v1
contract. It is intentionally independent of the application and server
serializers, and runs the same shared fixture checks in Python, Swift, and
Rust.

The current slice verifies:

- every sync/auth JSON fixture is strict UTF-8 and valid JSON;
- duplicate object keys and non-finite JSON numbers are rejected by the
  dependency-free fixture gate;
- fixture `cases`/`steps` identifiers are unique within their list;
- every `expectedCanonicalUtf8` vector agrees on UTF-8 byte count, optional
  hexadecimal bytes, and SHA-256 digest in all three runners.
- the OpenAPI document has resolvable local references and unique operation
  IDs, and its embedded `SnapshotManifest`/`PublishHeadCommand` schemas are
  structurally equivalent to the external JSON Schema authorities after the
  contract's prescribed inlining and annotation removal.
- scenario records carry the reviewed-contract marker, unique scenario IDs,
  non-empty safety descriptions, the three conflict choices, the four publish
  wire fields, and the account-fenced remote-presence key where applicable.
- the `intent-attempt-lost-ack-exact-retry` scenario is replayed far enough to
  prove that the sealed canonical command digest is stable, the server head
  advances once, exact retry does not advance it again, and local Intent/
  SealedAttempt are cleared only after read-back.

This is a required early gate, not a claim that the entire R0 state-machine
contract has passed. This is the first executable scenario replay; the full
client/server state-machine matrix, including all three conflict choices and
Apple authentication vectors, is a subsequent conformance slice. Shared
fixtures remain the authority; generated code is never used to produce
expected values.

Run from the repository root:

```sh
Scripts/conformance-r0.sh
```
