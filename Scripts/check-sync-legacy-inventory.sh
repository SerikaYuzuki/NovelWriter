#!/bin/bash
# D-076 R5b: keep the legacy-sync source inventory valid while the target split
# is staged. This is an inventory guard, not a claim that the split is complete.
set -euo pipefail

cd "$(dirname "$0")/.."

inventory="docs/D-076-R5-LEGACY-INVENTORY.md"
if [[ ! -f "$inventory" ]]; then
  echo "error: D-076 R5 legacy inventory is missing: $inventory" >&2
  exit 1
fi

legacy_path_count=0
failure=0
while IFS= read -r path; do
  case "$path" in
    ''|'#'*) continue ;;
  esac
  if [[ ! -f "$path" ]]; then
    echo "error: R5 legacy inventory path is missing: $path" >&2
    failure=1
  fi
  legacy_path_count=$((legacy_path_count + 1))
done < <(
  awk '
    /^```text$/ { in_paths = 1; next }
    in_paths && /^```$/ { exit }
    in_paths { print }
  ' "$inventory"
)

if (( legacy_path_count == 0 )); then
  echo "error: R5 legacy inventory contains no source paths" >&2
  failure=1
fi

if (( failure != 0 )); then
  exit 1
fi

echo "D-076 R5 legacy inventory check passed ($legacy_path_count candidate sources)"
