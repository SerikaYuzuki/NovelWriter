#!/bin/bash
# Enforce the current Swift responsibility/size boundaries (D-076).
set -euo pipefail

cd "$(dirname "$0")/.."

required_swiftlint_version="0.65.0"
actual_swiftlint_version="$(swiftlint version)"
if [[ "$actual_swiftlint_version" != "$required_swiftlint_version" ]]; then
  echo "error: SwiftLint $required_swiftlint_version is required (found $actual_swiftlint_version)" >&2
  exit 1
fi

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

  echo "error: Swift source exceeds 800 lines; split its responsibility: $file ($line_count)" >&2
  failure=1
done < <(
  rg --files NovelApp NovelAppIOS NovelKit/Sources \
    | rg '\.swift$' \
    | sort
)

if (( failure != 0 )); then
  exit 1
fi

echo "D-076 source structure check passed"
