#!/bin/bash
# D-079: keep the pre-retirement source inventory as an audit artifact. The
# listed CloudKit paths are expected to be absent from the current build.
set -euo pipefail

cd "$(dirname "$0")/.."

inventory="docs/D-076-R5-LEGACY-INVENTORY.md"
if [[ ! -f "$inventory" ]]; then
  echo "error: D-076 R5 legacy inventory is missing: $inventory" >&2
  exit 1
fi

legacy_path_count=0
while IFS= read -r path; do
  case "$path" in
    ''|'#'*) continue ;;
  esac
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

echo "D-079 legacy inventory retained ($legacy_path_count retired source paths)"
