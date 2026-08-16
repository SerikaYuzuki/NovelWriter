#!/bin/bash
set -euo pipefail

repo_root="${FUMINIWA_TEST_BOUNDARY_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
cd "$repo_root"

for scheme in FUMINIWA FUMINIWAIOS; do
  scheme_file="FUMINIWA.xcodeproj/xcshareddata/xcschemes/${scheme}.xcscheme"
  if [[ ! -f "$scheme_file" ]]; then
    echo "error: missing generated test scheme: $scheme_file" >&2
    exit 1
  fi
  if ! rg -F -q 'key = "FUMINIWA_TEST_NETWORK_DISABLED"' "$scheme_file"; then
    echo "error: $scheme test scheme does not disable network access" >&2
    exit 1
  fi
  if ! rg -F -q 'value = "1"' "$scheme_file"; then
    echo "error: $scheme test scheme has no disabled-network value" >&2
    exit 1
  fi
done

# The LAN development endpoint belongs only to the runtime resolver. App
# composition must never embed a fallback URL that bypasses the test gate.
if rg -n '192\.168\.11\.5:18080' NovelApp NovelAppIOS; then
  echo "error: app target embeds the development sync endpoint" >&2
  exit 1
fi

echo "test network boundary check passed"
