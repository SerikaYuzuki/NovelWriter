# FUMINIWA Codex Sidecar Protocol v1

> Historical design record. D-075 removed the Swift/Node sidecar implementation,
> fixtures, and Experimental target. This document is not a current runtime or
> reuse contract; a future provider integration requires a new Decision.

This protocol is the private transport boundary between `FUMINIWAExperimental`
and the Codex Node sidecar. It is not a provider prompt format and none of the
transport-only fields may be appended to the application prompt or response
schema.

## Framing

- UTF-8 JSON, one object per line, terminated by a single LF (`0x0A`).
- A frame is at most 262,144 bytes, excluding the LF. The byte buffer before an
  LF may never exceed that limit.
- Empty lines, CR/CRLF, BOM, invalid UTF-8, malformed or partial JSON at EOF,
  duplicate JSON member names, unknown versions, types, fields, or enum values
  are protocol errors. `readline`-style CRLF normalization is forbidden.
- JSON integer fields use plain base-10 integer tokens only: no negative zero,
  fraction, exponent, or leading zero. Values must be safe integers
  (`0 ... 9,007,199,254,740,991`) and then pass their narrower field limits.
- JSON object/array nesting depth is at most 64. Escaped UTF-16 surrogate code
  units must form valid high/low pairs; unpaired surrogates are rejected.
- One process handles one request. It accepts exactly one `hello`, then exactly
  one `start`, and, while running, at most one matching `cancel`.
- Total stdin and stdout accepted for one process are each capped at 524,288
  bytes. The native host terminates the process if stderr exceeds 16,384 bytes;
  a conforming sidecar keeps stderr empty and never forwards SDK stderr.
- `stdout` contains protocol frames only. Prompt, schema, provider output, raw
  SDK errors, paths, environment values, and credentials must not be written to
  `stderr` or ordinary logs.

## Content-free runtime attestation

The manuscript-bearing `start` command is forbidden until this handshake has
completed. Attestation detects packaging or runtime drift; it is not a security
boundary against a compromised sidecar. The native host also verifies packaged
artifacts independently before spawn.

### `hello`

Allowed keys: `version`, `type`, and `request_id`. `type` is `"hello"` and the
ID is the local canonical lowercase UUID for this process. No prompt, schema,
model, path, environment value, or credential is included.

### `ready`

Allowed keys: `version`, `type`, `request_id`, and `runtime`. `type` is
`"ready"`; the ID matches `hello`. Runtime keys are exactly:

```text
mode, sidecar_version, sidecar_bundle_sha256,
node_version, node_sha256, architecture,
sdk_version, sdk_integrity, cli_version, cli_sha256
```

- `mode` is `"mock"` or `"codex_sdk"`; architecture is `"arm64"` or `"x64"`.
- Runtime version and integrity strings are 1 to 256 bytes of visible ASCII
  (`0x21 ... 0x7E`). Hash fields retain their narrower lowercase SHA-256 rule.
- Hashes are lowercase 64-character SHA-256 strings. `sdk_integrity` is the
  exact npm SRI string from the lock/manifest. `sidecar_bundle_sha256` is the
  digest of a canonical deployment manifest covering sidecar source, lockfile,
  and the installed SDK/dependency file tree; SRI alone is not evidence of the
  bytes actually loaded at runtime.
- [`MANIFEST.md`](MANIFEST.md) defines manifest v1. Checkpoint B3 adds a fixed
  21-file arm64 packager and an Experimental native verifier, but the returned
  root digest is only a build-time identity candidate. The self manifest is not
  authoritative, and no compile-time native allowlist consumes the candidate
  yet. A `codex_sdk` implementation remains forbidden until the exact Node
  runtime, independently approved digest, complete loaded-artifact containment,
  and immutable verification-to-import/path-based-spawn boundary are fixed.
  Merely hashing `package-lock.json`, trusting the self manifest, or hashing the
  package directory name does not satisfy attestation.
- Mock mode uses `null` for artifact hashes and SDK/CLI identity. Codex SDK mode
  requires every identity and hash to be non-null and to exactly match the
  build-time allowlist. A mismatch terminates before `start` is encoded or sent.
- `request_id` and runtime identity are local transport values. FUMINIWA and
  the sidecar must not copy them into provider prompt, schema, SDK options or
  metadata, or model input. This does not claim that the SDK/CLI emits no
  independently generated client, platform, or runtime telemetry.

## Commands

### `start`

The allowed keys are exactly:

```text
version, type, request_id, provider_id, model_id,
application_instruction_id, application_prompt,
application_response_schema_id, application_response_schema,
budget, input_character_count, input_utf8_byte_count
```

- `version` is the integer `1` and `type` is `"start"`.
- `request_id` is a canonical lowercase UUID used only for local routing.
- `provider_id` is exactly `"codex"`.
- `model_id` is the model already shown in the application preview. It is 1 to
  128 visible ASCII bytes and matches `[A-Za-z0-9][A-Za-z0-9._:/-]*`; blank or
  whitespace IDs may not fall back to an SDK default model.
- Application prompt, schema, their IDs, budget, and input counts are copied
  from the confirmed `AIApplicationPayload`; the sidecar must not rebuild or
  append to them.
- Instruction and schema IDs match
  `[a-z0-9][a-z0-9._-]{0,127}`. Prompt and schema are nonempty and contain at
  least one scalar outside protocol v1's fixed whitespace set: U+0009...U+000D,
  U+0020, U+0085, U+00A0, U+1680, U+2000...U+200A, U+2028, U+2029, U+202F,
  U+205F, U+3000, and U+FEFF. U+200B is not whitespace. These checks do not
  authorize the sidecar to normalize or reconstruct their content.
- Counts equal the sums for `application_prompt` plus
  `application_response_schema`.
- Character count is sealed by Swift's `String.count` in the preview.
  JavaScript validates its safe range and budget but must not recalculate it
  with UTF-16 length or code-point count. Both peers independently recalculate
  and compare the UTF-8 byte count.
- Budget keys are exactly:

```text
maximum_input_characters, maximum_input_utf8_bytes,
maximum_output_characters, maximum_output_utf8_bytes,
maximum_output_tokens, maximum_warnings, timeout_seconds
```

All budget values are positive integers. Protocol v1 fixes the absolute maxima
independently of either implementation so drift is testable:

```text
maximum_input_characters: 20,000
maximum_input_utf8_bytes: 80,000
maximum_output_characters: 20,000
maximum_output_utf8_bytes: 80,000
maximum_output_tokens: 8,192
maximum_warnings: 20
timeout_seconds: 120
```

### `cancel`

Allowed keys are exactly `version`, `type`, and `request_id`. The ID must match
the active request. A cancel accepted before the terminal transition produces
one `failed` event with code `cancelled`; later completion is ignored. There is
no separate cancel acknowledgement. If provider completion or another fixed
failure has already won inside the sidecar before it reads cancel, that terminal
remains the valid wire result. The host accepts it for process draining but,
after local consumer cancellation, never delivers its result to UI/domain.

## Events

After a valid `start` is accepted, exactly two request events are emitted: one
`started`, followed by exactly one terminal `completed` or `failed`. An invalid
`start` is a protocol error and exits without pretending that provider work
started. Protocol v1 streams lifecycle events but deliberately transports no
partial replacement text: Codex SDK 0.147.0 does not expose a stable token-delta
contract. The Experimental UI must disclose that result text appears only after
completion.

### `started`

Allowed keys: `version`, `type`, `request_id`.

### `completed`

Allowed keys: `version`, `type`, `request_id`, `structured_output`, and `usage`.
`structured_output` is the raw JSON text returned for the confirmed response
schema. The sidecar does not construct an `AIResult`. Usage keys are exactly
`input_tokens` and `output_tokens`; input may be `null`, output is a nonnegative
integer. FUMINIWA performs final schema, character, byte, warning-count, and
token validation again before showing a result.

### `failed`

Allowed keys: `version`, `type`, `request_id`, `code`. No free-form error text
is allowed. `code` is one of:

```text
cancelled, timed_out, authentication_required, offline, rate_limited,
quota_exceeded, provider_unavailable, refused, invalid_response,
provider_mismatch
```

Malformed input before a valid request ID is accepted terminates the process
without a protocol event. Once an ID is accepted, an internal or SDK failure is
redacted to one of the fixed codes above.

The Swift adapter maps fixed codes only to the corresponding `AIError` cases
(`timed_out` -> `timedOut`, and so on). A protocol/frame/SDK parse/resource
violation maps to `invalid_response`; process exit without a terminal maps to
`provider_unavailable`. Unknown codes never reach UI and fail closed as
`invalid_response`.

## State and process lifecycle

```text
awaitingHello -> attested -> running -> terminal
```

- `hello` emits one `ready`. Only after the host validates exact runtime
  identity may it send `start`.
- `start` emits `started` before the provider is allowed its first external
  side effect. The upstream cancellation hook is registered before that side
  effect.
- Cancel and provider completion are linearized by the session state machine;
  the first terminal transition wins. Duplicate or late events never produce
  another terminal frame.
- Timeout produces `failed/timed_out`, requests upstream cancellation, and
  begins bounded shutdown. EOF while running performs the same cancellation;
  it may omit the frame if the parent is no longer readable.
- Loss of the parent output channel aborts upstream immediately, clears the
  timeout, emits no further frame to the broken channel, and enters the same
  bounded kill/wait path. Later provider completion is ignored.
- Normal terminal completion closes stdin, waits for the direct child, and
  exits. Provider exit without a terminal result becomes
  `failed/provider_unavailable`.
- The production host must enforce a bounded grace period followed by
  process-group termination, direct-child wait/reap, and a bounded post-reap
  group-state check. A macOS parent cannot wait/reap grandchildren, and a
  same-process supervisor cannot clean up after parent SIGKILL/crash or members
  that escape the group. Public Codex SDK 0.147.0 only signals its direct child,
  retains stderr without a hard cap, and parses unbounded JSONL lines;
  therefore this mock transport alone does not satisfy the Codex runtime
  feasibility or orphan-free release Gate. SDK wiring remains forbidden until
  an audited supervisor/wrapper and OS containment prove each narrower
  lifecycle property. The native B2 boundary is specified in SUPERVISOR.md.

The only model-visible values that FUMINIWA or the sidecar may derive from
`start` are the exact confirmed application prompt, parsed exact response
schema, and previewed model. The SDK also receives fixed non-content isolation
options from an allowlist: request empty cwd, dedicated `CODEX_HOME`,
`skipGitRepoCheck`, environment allowlist, network/tool policy, and
cancellation signal. The sidecar must not copy transport IDs,
instruction/schema IDs, counts, budgets, paths, or runtime identity into
provider metadata or hidden prompt content. Exact-version wire capture must
separately inventory SDK/CLI-generated telemetry and system/cwd context; a
prohibited identity or path fails the feasibility Gate. In particular,
`maximum_output_tokens` must not become an unpreviewed instruction when the SDK
cannot enforce it upstream.

Credentials are not protocol fields. A future authenticated runtime is spawned
without a key in argv or inherited environment. If a request credential is
required, it completes independent artifact verification and `ready`, then
receives that credential through a separate one-shot anonymous pipe owned by
the native supervisor. That channel is closed after delivery, is inherited only
by the intended process tree, and is covered by redaction, lifecycle, and crash
tests before SDK feasibility can pass.

## Golden fixtures

`fixtures/protocol-v1` is consumed by both Node and Swift tests. The start
fixture uses the real `proofreading-selection-v1` instruction and
`proofreading-result-v1` schema with a tiny synthetic selection, so it tests the
sealed bridge instead of a domain-invalid placeholder. The Swift suite anchors
that frame to a production `NovelAI` preview. Node deliberately treats the
prompt, schema, and IDs as opaque confirmed values: it preserves their exact
decoded String values and their UTF-8 re-encoding, and must not normalize or
reconstruct them. Outer JSON escaping and object key order need not be byte
identical. Fixtures must never use a real manuscript, API key, filesystem path,
or raw provider error. Both suites cover duplicate JSON members, unsafe integer
spellings, budget zero/max/max+1, BOM/CRLF/partial EOF, and over-limit buffers.
