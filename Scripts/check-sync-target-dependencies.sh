#!/bin/bash
# D-079: CloudKit is retired from the product. SQLite local state and the
# Rust Snapshot Sync server are the only current synchronization route.
set -euo pipefail

cd "$(dirname "$0")/.."

package_file="NovelKit/Package.swift"
project_file="project.yml"

if [[ ! -f "$package_file" || ! -f "$project_file" ]]; then
  echo "error: package or project definition is missing" >&2
  exit 1
fi

if rg -n -F 'NovelSyncCloudKit' "$package_file" "$project_file"; then
  echo "error: the retired NovelSyncCloudKit product remains in the build graph" >&2
  exit 1
fi

if rg -n -F 'NovelSyncCloudKit' NovelApp NovelAppIOS NovelKit/Sources NovelKit/Tests; then
  echo "error: application or package source still references NovelSyncCloudKit" >&2
  exit 1
fi

if [[ -e NovelKit/Sources/NovelSyncCloudKit || -e NovelKit/Tests/NovelSyncCloudKitTests ]]; then
  echo "error: retired CloudKit source or test directory remains" >&2
  exit 1
fi

if rg -n -e '(^|[^A-Za-z])import[[:space:]]+CloudKit|CKSyncEngine|CloudKitSyncDiagnostic' \
  NovelApp NovelAppIOS NovelKit/Sources NovelKit/Tests; then
  echo "error: direct CloudKit runtime code remains in the current targets" >&2
  exit 1
fi

echo "D-079 CloudKit removal audit passed"
