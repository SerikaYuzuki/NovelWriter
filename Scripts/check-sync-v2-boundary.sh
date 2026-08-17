#!/bin/bash
# D-080: Snapshot Sync v2 is a new live namespace.  This static gate audits
# only production composition; archive/migration files may retain historical
# v1 names, but they must not be reachable from the live app or v2 router.
set -euo pipefail

repo_root="${FUMINIWA_V2_BOUNDARY_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
cd "$repo_root"

fail() {
  echo "error: $*" >&2
  exit 1
}

required=(
  "NovelKit/Sources/NovelSyncV2Runtime/SnapshotSyncV2Runtime.swift"
  "NovelKit/Sources/NovelSyncV2Application/RuntimeMode.swift"
  "NovelKit/Sources/NovelSyncV2Store/LocalSyncV2Store.swift"
  "SyncServerV2/src/http.rs"
  "SyncServerV2/src/domain.rs"
  "docs/sync/v2/fixtures/canonical/snapshot.json"
)
for file in "${required[@]}"; do
  [[ -f "$file" ]] || fail "required v2 composition file is missing: $file"
done

# Keep old CloudKit/Note/Work/Episode transports out of production app code.
# The DeviceSync/Legacy tree is an audit/archive boundary and is deliberately
# excluded from this production-only search.
if rg -n --glob '!**/DeviceSync/Legacy/**' \
  -e 'NovelSyncCloudKit|CKSyncEngine|(^|[^A-Za-z])import[[:space:]]+CloudKit' \
  -e 'NoteSync(Client|Coordinator|Transport)?' \
  -e 'WorkSync(Client|Coordinator|Transport)?' \
  -e 'EpisodeSync(Client|Coordinator|Transport)?' \
  NovelApp NovelAppIOS; then
  fail "retired CloudKit/Note/Work/Episode live runtime leaked into app composition"
fi

# Sync v2 routes are /v2 only.  Auth v1 is a separately owned auth wire and is
# intentionally not included in this sync-router scan.
if rg -n -e '/v1(/|"|\x27)' SyncServerV2/src/http.rs NovelApp NovelAppIOS; then
  fail "v1 sync endpoint leaked into v2 production composition"
fi

# App targets must compose the v2 runtime directly and must not link a retired
# sync product.  The block extraction avoids matching package/test targets.
for target in NovelApp FUMINIWAIOS; do
  block="$(awk -v target="$target" '
    $0 == "targets:" { in_targets=1; next }
    !in_targets { next }
    $0 ~ "^  " target ":" { in_target=1; next }
    in_target && $0 ~ /^  [A-Za-z0-9_-]+:/ { exit }
    in_target { print }
  ' project.yml)"
  [[ -n "$block" ]] || fail "project.yml target is missing: $target"
  grep -Fq 'product: NovelSyncV2Runtime' <<<"$block" \
    || fail "$target does not link NovelSyncV2Runtime"
  if grep -Eq 'product: (NovelSync|NovelSyncLegacy|NovelSyncV2Store|NovelSyncV2Application)[[:space:]]*$' <<<"$block"; then
    fail "$target links a non-composed sync product directly"
  fi
done

# Production URL/root construction is typed and v2-only.  Tests must use the
# injected TestRuntimeConfiguration/FakeTransport path instead of production
# roots, URLs, or the LAN development server.
runtime_mode="NovelKit/Sources/NovelSyncV2Application/RuntimeMode.swift"
rg -Fq 'case test(TestRuntimeConfiguration)' "$runtime_mode" \
  || fail "v2 runtime has no typed test composition"
rg -Fq 'case production(ProductionRuntimeConfiguration)' "$runtime_mode" \
  || fail "v2 runtime has no typed production composition"
if rg -n -e '192\.168\.11\.5|postgres(ql)?://|applicationSupportDirectory' \
  NovelKit/Tests/NovelSyncV2Tests NovelKit/Tests/NovelSyncV2StoreTests NovelKit/Tests/NovelSyncV2ApplicationTests; then
  fail "v2 tests contain a production/LAN persistence or server endpoint"
fi

# The opt-in PostgreSQL test is allowed to connect only when the caller
# explicitly supplies a freshly provisioned, marked test database.  The normal
# gate removes the variable before running it, so this script never connects.
integration_test="SyncServerV2/tests/integration_gate.rs"
rg -Fq 'FUMINIWA_V2_TEST_DATABASE_URL' "$integration_test" \
  || fail "Rust integration gate has no explicit opt-in database guard"
rg -Fq 'validate_test_database_url' SyncServerV2/tests/support/mod.rs \
  || fail "Rust integration gate has no isolated database URL validation"

echo "D-080 Snapshot Sync v2 production/test boundary check passed"
