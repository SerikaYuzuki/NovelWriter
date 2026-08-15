# Canonical invalid case matrix

This directory is the negative-design matrix for the independent Swift, Rust,
and C# fixture harnesses. The base model is
[`../canonical-valid/minimal-root.json`](../canonical-valid/minimal-root.json).
An implementation must reject the original received bytes; it must never
canonicalize an invalid wire document and silently accept the resulting ID.

`cases.json` records mutations rather than pretending every invalid input can
be represented by a parsed JSON model. In particular, duplicate keys, invalid
UTF-8, and unpaired surrogates must be constructed as raw octets by each
independent harness.

| Case | Validation stage | Required rejection |
| --- | --- | --- |
| `duplicate-key` | I-JSON parse | A second `schemaVersion` member is present. |
| `unknown-field` | JSON Schema | Root member `capturedAt` is not part of Snapshot identity. |
| `noncanonical-whitespace` | JCS byte comparison | Otherwise valid JSON contains insignificant spaces. |
| `noncanonical-escape` | JCS byte comparison | A printable character is encoded with an unnecessary `\u` escape. |
| `noncanonical-key-order` | JCS byte comparison | Object members are not in RFC 8785 order. |
| `float-for-integer` | integer-token policy / JCS byte comparison | `byteCount` is `71.0`, not an integer token, even though it is mathematically integral. |
| `unsafe-integer` | I-JSON limits | An integer exceeds `2^53 - 1`. |
| `uppercase-uuid` | JSON Schema | UUID text is not lowercase hyphenated form. |
| `uppercase-digest` | JSON Schema | SHA-256 text contains uppercase hex. |
| `invalid-utf8` | UTF-8 decode | A string contains octet `ff`. |
| `unpaired-surrogate` | I-JSON parse | A string contains the escape `\ud800` without a valid pair. |
| `parent-order` | Snapshot semantics | Two parent IDs are not in digest order. |
| `entry-order` | Snapshot semantics | Two entries are not in EntityKey UTF-8 byte order. |
| `duplicate-entity-key` | Snapshot semantics | Two entries use the same EntityKey with different ObjectIDs. |
| `missing-mandatory-work-singleton` | JSON Schema | One of the nine mandatory work singleton/order entries is absent. |
| `impossible-document-created-at` | Snapshot semantics | The lexical timestamp matches the shape but is not a real calendar date. |
| `changed-work-document-after-root` | Snapshot semantics | A child changes the immutable portable document identity or creation time. |
| `object-size-exceeded` | JSON Schema / object finalize | `byteCount` exceeds 250 MiB. |
| `entity-payload-size-exceeded` | Snapshot registration in the structured-entry context | Canonical structured-entity bytes exceed 16 MiB; bytes-only object finalize cannot classify their use. |

This matrix is part of the reviewed design contract, not proof that any
implementation passed the R0 conformance gate. Each independent harness must
exercise the raw inputs and assert the typed error names from `errors.md`.
