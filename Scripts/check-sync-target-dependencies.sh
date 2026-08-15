#!/bin/bash
# D-076 R5e: keep the staged NovelSyncLegacy boundary explicit while the
# mixed CloudKit adapter is being decomposed. This is a dependency audit, not
# a claim that the transitive CloudKit -> Legacy edge has already disappeared.
set -euo pipefail

cd "$(dirname "$0")/.."

package_file="NovelKit/Package.swift"
project_file="project.yml"

if [[ ! -f "$package_file" || ! -f "$project_file" ]]; then
  echo "error: package or project definition is missing" >&2
  exit 1
fi

# Normal app targets must not link the compatibility product directly. The
# current CloudKit target still has a transitional dependency on it; that
# edge is intentionally checked below and is removed only with its source
# migration.
if rg -n -F 'product: NovelSyncLegacy' "$project_file" >/dev/null; then
  echo "error: normal Xcode targets must not directly link NovelSyncLegacy" >&2
  exit 1
fi

# The live domain and deterministic test fake must not import the compatibility
# module. This catches an accidental reverse dependency even when SwiftPM's
# target graph is edited at the same time.
if rg -n '^import NovelSyncLegacy$' NovelKit/Sources/NovelSync NovelKit/Sources/NovelSyncTesting >/dev/null; then
  echo "error: NovelSync or NovelSyncTesting imports NovelSyncLegacy" >&2
  exit 1
fi

# Files moved in R5d must not silently reappear in the live target.
for legacy_path in \
  NovelKit/Sources/NovelSyncLegacy/FileEpisodeSyncJournal.swift \
  NovelKit/Sources/NovelSyncLegacy/FileWorkSyncJournal.swift; do
  if [[ ! -f "$legacy_path" ]]; then
    echo "error: expected legacy source is missing: $legacy_path" >&2
    exit 1
  fi
done

for live_path in \
  NovelKit/Sources/NovelSync/FileEpisodeSyncJournal.swift \
  NovelKit/Sources/NovelSync/FileWorkSyncJournal.swift; do
  if [[ -e "$live_path" ]]; then
    echo "error: legacy filesystem journal returned to NovelSync: $live_path" >&2
    exit 1
  fi
done

# Keep the transitional edge visible until the CloudKit Episode/Work adapter
# is split. Removing this dependency before that migration would produce a
# misleading green build or leave the mixed adapter without its contracts.
if ! rg -n -F 'name: "NovelSyncCloudKit"' "$package_file" >/dev/null \
  || ! rg -n -F 'dependencies: ["NovelSync", "NovelSyncLegacy", "NovelCore"]' "$package_file" >/dev/null; then
  echo "error: expected transitional NovelSyncCloudKit -> NovelSyncLegacy edge is missing" >&2
  exit 1
fi

echo "D-076 sync target dependency audit passed (CloudKit -> Legacy remains transitional)"
