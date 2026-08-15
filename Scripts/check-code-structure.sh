#!/bin/bash
# D-076 R1: keep source-size debt explicit while the Feature refactor is staged.
set -euo pipefail

cd "$(dirname "$0")/.."

required_swiftlint_version="0.65.0"
actual_swiftlint_version="$(swiftlint version)"
if [[ "$actual_swiftlint_version" != "$required_swiftlint_version" ]]; then
  echo "error: SwiftLint $required_swiftlint_version is required (found $actual_swiftlint_version)" >&2
  exit 1
fi

# Existing cohesive algorithms and transitional coordinators are temporary debt.
# The value is a ceiling, not a target. R3/R5 must remove entries as they split.
# Keep this as a case statement: the system bash on macOS is still bash 3.2.
large_file_ceiling() {
  case "$1" in
    NovelApp/DeviceSync/Legacy/AppState+WorkSync.swift) echo 975 ;;
    NovelApp/DocumentLifecycle/AppState+Lifecycle.swift) echo 814 ;;
    NovelAppIOS/DeviceSync/Legacy/IOSDocumentStore+WorkSync.swift) echo 1086 ;;
    NovelKit/Sources/NovelSync/WorkSnapshotMerger.swift) echo 1224 ;;
    NovelKit/Sources/NovelSync/WorkSyncCoordinator.swift) echo 1195 ;;
    *) echo "" ;;
  esac
}

failure=0
while IFS= read -r file; do
  line_count="$(wc -l < "$file" | tr -d ' ')"
  if (( line_count > 400 )); then
    echo "notice: D-076 responsibility review threshold exceeded: $file ($line_count lines)" >&2
  fi
  if (( line_count > 600 )); then
    echo "warning: D-076 split warning threshold exceeded: $file ($line_count lines)" >&2
  fi
  if (( line_count <= 800 )); then
    continue
  fi

  max_allowed="$(large_file_ceiling "$file")"
  if [[ -z "$max_allowed" ]]; then
    echo "error: new large Swift file (>800 lines) requires a D-076 debt entry: $file ($line_count)" >&2
    failure=1
    continue
  fi
  if (( line_count > max_allowed )); then
    echo "error: D-076 large-file debt grew beyond its ceiling: $file ($line_count > $max_allowed)" >&2
    failure=1
  fi
done < <(
  rg --files NovelApp NovelAppIOS NovelKit/Sources \
    | rg '\.swift$' \
    | sort
)

if (( failure != 0 )); then
  exit 1
fi

echo "D-076 source structure check passed"
