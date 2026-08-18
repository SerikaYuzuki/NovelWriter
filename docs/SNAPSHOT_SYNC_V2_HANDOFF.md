# Snapshot Sync v2 implementation handoff

- Last updated: 2026-08-18
- Status: implementation and device verification in progress; release NO-GO
- Branch: `codex/snapshot-sync-v2`
- Implementation baseline before this handoff: `71ee6e8a0`
  (`fix: accept lowercase auth response UUIDs`)

This file is the current implementation handoff for Snapshot Sync v2. The
normative design remains [SNAPSHOT_SYNC_V2.md](SNAPSHOT_SYNC_V2.md),
[DECISIONS.md](DECISIONS.md) D-080 through D-085, and
[`docs/sync/v2/`](sync/v2/). The old
[SNAPSHOT_SYNC_HANDOFF.md](SNAPSHOT_SYNC_HANDOFF.md) is v1 history and must not
be used as the v2 implementation status.

## 1. Product boundary that must remain true

- SQLite v2 is the sole live local authority. Ordinary editing, autosave,
  navigation, and termination do not read or write `.novelpkg`.
- A local checkpoint commits the document, immutable Snapshot and objects,
  local head and generation, recovery metadata, and durable remote work in one
  SQLite transaction. HTTP starts only after that commit and never blocks the
  editor or navigation.
- Remote data enters SQLite Inbox/staging before it can reach an editor. IME,
  session, generation, unsaved-change, pending-intent, and document-operation
  gates remain mandatory.
- macOS and iOS use the shared NovelKit v2 domain, store, worker, conflict, and
  status projection. Platform apps keep only capture, navigation, IME, and
  platform UI concerns.
- Sign in with Apple maps to an immutable FUMINIWA AccountID and FUMINIWA
  access/refresh session. Apple tokens are not synchronization bearer tokens.
- Account scope is exact. Data from another AccountID or stale account fence
  must not be listed, downloaded, adopted, or used to clear pending work.
- The live path must not restore CloudKit or the old Note/Work/Episode sync,
  v1 SQLite, v1 server schemas, or dual-read compatibility adapters.
- No-op synchronization and an unchanged manual save are successful states,
  not user-facing failures.

## 2. Verified current state

The following evidence was observed on the current branch. It is narrower than
release acceptance and must not be generalized beyond the stated boundary.

### Shared local and server implementation

- Snapshot Sync v2 domain, canonical JSON/Snapshot IDs, SQLite journal,
  Outbox/sealed-command replay, Inbox graph, conflict primitives, restore
  records, and application facade exist in NovelKit.
- macOS and iOS production/test compositions are compile-time separated.
  Focused app-host tests verified that test runs use temporary SQLite, fake
  transport, isolated defaults, and test vaults without creating production v2
  SQLite/WAL/SHM files.
- Rust v2 is account-scoped and transaction-based. Canonical manifest bytes are
  stored as bytes rather than reserialized JSON identity. PostgreSQL runtime,
  migrator, bootstrap, and provisioning roles are separated and fail closed
  against an unrecognized database.
- Rust/Swift canonical fixtures and focused store/auth/application tests have
  passed during implementation. These are component evidence only.

### Real iPhone authentication and LAN staging

- The signed iOS app reached the staging endpoint at
  `https://192.168.11.5:8443` after the current Caddy root was installed and
  trusted on the device.
- Sign in with Apple completed on a physical iPhone. The observed phases were
  challenge creation, native Apple authorization, and server exchange.
- A cold app restart restored the FUMINIWA session; the sign-in button did not
  return.
- The server response contract was correct. The final client-side failure was
  caused by treating a valid lowercase wire UUID as if Swift's uppercase
  `UUID.uuidString` were the canonical spelling. Commit `71ee6e8a0` removed
  that typed-value false rejection while retaining raw canonical-wire checks.
- Stale challenge/exchange journals, a stuck account-transition lease, and
  duplicate edge `no-store` headers were fixed in the commits immediately
  preceding `71ee6e8a0`.
- At the time of this handoff the live Compose project was observed as
  `fuminiwa-sync-v2-role-split`, with edge container
  `fuminiwa-sync-v2-role-split-edge`. Re-read Docker state before operating;
  [SNAPSHOT_SYNC_V2_STAGING.md](SNAPSHOT_SYNC_V2_STAGING.md) still contains
  generic example names.
- The staging CA fingerprint observed on 2026-08-18 was
  `8E:1F:4F:B0:3C:ED:32:9F:34:4F:5B:E4:09:C3:F7:F0:B6:30:CE:21:D0:E6:04:4F:9F:E2:F3:89:F7:EC:43:EC`.
  Caddy trust can rotate; export and compare the live public root again instead
  of assuming this fingerprint is permanent.

Do not put an SSH password, Apple private key, `.env` contents, refresh token,
vault key, or CA private key in source, this handoff, logs, or a command line.

## 3. Known regressions and blockers

### P0: restore the existing iOS product UI on top of v2

The current v2 iOS live path presents a minimal shell and has regressed the
previous writing experience. The user explicitly reported that the prior
writing-screen requirements, navigation, and polished project UI appear to
have disappeared. This is not an intentional product redesign.

Current live presentation files include:

- `NovelAppIOS/Features/Writing/IOSWorkbenchViewV2.swift`
- `NovelAppIOS/Library/IOSProjectHomeViewV2.swift`
- `NovelAppIOS/Library/IOSLibraryViewV2.swift`

Useful visual and interaction references remain under the legacy/retired iOS
paths, but only presentation and product behavior may be adapted. Do not copy
their CloudKit, Note/Work/Episode sync, document authority, or storage logic
back into the live target. Preserve the current v2 application-service calls
and account/session safety gates while restoring the established editor,
project-home cards, shelf navigation, history/conflict entry points, and
accessibility behavior.

Acceptance is a signed physical-device walkthrough, not merely a SwiftUI
preview or successful build.

### P0: a new signed-in work remains local-only

On the real iPhone, a new work named `V2実機確認` with a small test body was
created while signed in. The shelf projected `端末のみ　同期を再試行できます`
instead of pending and then synchronized. Treat this text as a disposable test
artifact, not manuscript authority.

Trace the complete path from
`IOSDocumentStore.makeNewDocument()` through the shared application/store:

1. create the new WorkID and document locally;
2. checkpoint atomically;
3. create or require an explicit AccountID binding according to the v2
   contract;
4. seal the exact create/register/publish commands;
5. resume the worker after local commit;
6. read back the remote head and project `同期待ち` then `同期済み`.

Do not solve this by automatic adoption of arbitrary pre-login works. A work
created inside an authenticated new-work flow may be born in the captured
account scope; an existing unbound work still needs the explicit online-save
or clone boundary required by D-080.

### P1: the standard repository gate is not green

The latest complete `./Scripts/check.sh` attempt stopped at D-076 because:

```text
NovelAppIOS/DocumentLifecycle/IOSDocumentStore+AuthenticationV2.swift
822 lines: new large Swift file (>800 lines) requires a D-076 debt entry
```

The conformance and fixture stages before that point passed. Split the auth
file by responsibility instead of recording fresh debt when practical, then
run the standard gate to `All checks passed`. Do not claim the gate passed
from focused auth tests alone.

### Release and real-device gates still open

- Mac to iPhone and iPhone to Mac round-trip for the same AccountID.
- Offline edit of the same work on both devices producing exactly one active
  conflict.
- All three choices on real devices: this device, server, and keep both.
- Confirmation that the pre-resolution local candidate remains restorable.
- Snapshot history and restore on both platforms.
- Process-kill/lost-response restart with exact operation replay.
- Offline launch/open/edit/autosave/close without waiting for network.
- Remote-only download and open.
- No-op sync and unchanged save remaining successful in both UIs.
- Account switch/fence rotation without cross-account listing or adoption.
- VoiceOver, Dynamic Type, IME, hardware keyboard, scene/background, and
  termination checks after the iOS UI is restored.
- Full `./Scripts/check.sh`, authenticated staging read-back, and backup/restore
  evidence after the above behavior is stable.

Snapshot Sync v2 is therefore not complete even though Apple authentication
and several focused test suites have passed.

## 4. Next-session implementation order

Follow this order unless a new concrete failure changes the dependency:

1. Re-read this file, `SNAPSHOT_SYNC_V2.md`, D-080 through D-085, and
   `git status`. Keep the untracked `NovelApp 2026-07-16 23-51-50/` backup out
   of all commits.
2. Restore the established iOS writing/project/shelf UI while retaining the v2
   WorkID session, shared application facade, document gate, IME boundary, and
   account-scope CAS checks.
3. Add focused UI/navigation tests for the restored routes and a signed iPhone
   smoke test. Verify that the workbench is the product UI, not the minimal v2
   diagnostic shell.
4. Reproduce and fix the signed-in new-work local-only path. Add restart and
   no-network tests proving local save succeeds before upload, and an account
   test proving another AccountID cannot see the work.
5. Split `IOSDocumentStore+AuthenticationV2.swift` below the D-076 threshold
   without changing the auth wire or account-transition semantics.
6. Run focused NovelKit, macOS, iOS, Rust, canonical fixture, and deployment
   boundary tests; then run `./Scripts/check.sh` to completion.
7. Deploy only the resulting v2 staging image/project. Read back TLS,
   unauthenticated auth capabilities, authenticated sync capabilities, account
   scope, and a published head. Do not infer readiness from container health.
8. Ask the user for the physical Mac/iPhone walkthrough: create, round-trip,
   offline divergence, each conflict choice, restore, restart, and account
   switch. Record exact results before declaring completion.

## 5. User priorities and legacy-data scope

- Product behavior and the established writing UI take priority over further
  compatibility or archive engineering.
- The user explicitly said old works and legacy data may be discarded and does
  not want more time spent maintaining the old implementation. Do not build
  dual-read, conversion shims, or legacy runtime fallback merely to preserve
  them.
- No legacy deletion was performed in the session represented by this
  handoff. If deletion is useful later, resolve exact legacy-only targets first
  and keep the current v2 database, current source tree, credentials, and the
  untracked backup folder out of scope. Never use a broad or unresolved path.
- The user is available to operate the physical devices when a test reaches an
  Apple sheet, trust setting, app action, or other step that cannot be driven
  safely from the development environment.

## 6. Git and resumption checklist

At handoff creation, local and remote were aligned before the documentation
commit, and the only untracked path was the existing backup folder. A new
session should verify rather than assume this remains true:

```sh
git switch codex/snapshot-sync-v2
git status --short --branch
git log -12 --oneline
git rev-parse HEAD
git rev-parse origin/codex/snapshot-sync-v2
```

The most recent authentication repair sequence at the implementation baseline
is:

```text
71ee6e8a0 fix: accept lowercase auth response UUIDs
c10a2b0fa fix: recover stuck iOS Apple sign-in retry
e07e1abef fix: recover stale Apple challenge lanes
dc7fee947 fix: avoid duplicate sync cache headers at caddy edge
50b81d0e0 fix: add safe Apple authentication phase diagnostics
```

Use `project.yml` and `Scripts/generate-project.sh` as the Xcode project
authority. Rediscover connected device identifiers at test time; do not encode
one session's device ID into source or scripts.

## 7. Definition of the next useful handoff

The next session should leave a smaller, evidence-backed handoff containing:

- which prior UI routes were restored and which still differ;
- why authenticated new-work upload failed and the exact invariant that fixed
  it;
- the final `./Scripts/check.sh` result;
- staging image/project identity and authenticated read-back;
- one row per physical Mac/iPhone scenario with pass/fail and no manuscript
  content;
- any remaining release NO-GO item.

Do not replace this with a generic “tests pass” statement. Preserve the
distinction between component tests, staging integration, and actual device
acceptance.
