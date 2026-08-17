#!/bin/bash
# Independent Snapshot Sync v2 conformance gate.  It never opens a production
# SQLite root or server: the PostgreSQL integration test is run with its opt-in
# URL removed and therefore emits an explicit SKIP.
set -euo pipefail
cd "$(dirname "$0")/.."

echo "==> v2 independent canonical fixture integrity (Python)"
python3 Scripts/conformance-v2.py

echo "==> v2 production/test boundary (static)"
./Scripts/check-sync-v2-boundary.sh

echo "==> v2 canonical fixture integrity (Swift)"
swift_scratch="$(mktemp -d "${TMPDIR:-/private/tmp}/fuminiwa-v2-swift.XXXXXX")"
trap 'rm -rf "$swift_scratch"' EXIT
mkdir -p "$swift_scratch/cache" "$swift_scratch/clang"
(
  cd NovelKit
  env -u FUMINIWA_V2_TEST_DATABASE_URL \
    CLANG_MODULE_CACHE_PATH="$swift_scratch/clang" \
    swift test \
      --disable-sandbox \
      --scratch-path "$swift_scratch" \
      --cache-path "$swift_scratch/cache" \
      --manifest-cache local \
      --filter NovelSyncV2ConformanceTests
)

echo "==> v2 canonical fixture integrity (Rust)"
env -u FUMINIWA_V2_TEST_DATABASE_URL \
  cargo test --manifest-path SyncServerV2/Cargo.toml --tests

echo "==> v2 PostgreSQL integration (explicitly disabled in local gate)"
echo "SKIP: FUMINIWA_V2_TEST_DATABASE_URL is intentionally unset; no production or LAN database is reachable"

echo "Snapshot Sync v2 independent conformance gate passed"
