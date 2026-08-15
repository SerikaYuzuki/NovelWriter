#!/bin/bash
# D-076 R5a: normal app composition must not expose the legacy Work transport.
# The package target split is intentionally a later R5 step; test/compatibility
# runtimes may still inject WorkSyncTransport explicitly.
set -euo pipefail

cd "$(dirname "$0")/.."

mac_runtime="NovelApp/DeviceSync/Runtime/DeviceSyncProductionRuntime.swift"
ios_runtime="NovelAppIOS/DeviceSync/Runtime/IOSDeviceSyncProductionRuntime.swift"

for file in "$mac_runtime" "$ios_runtime"; do
  if [[ ! -f "$file" ]]; then
    echo "error: expected production runtime is missing: $file" >&2
    exit 1
  fi
  if ! rg -F -q 'workTransport: nil' "$file"; then
    echo "error: production runtime must pass workTransport: nil: $file" >&2
    exit 1
  fi
  if rg -F -q 'workTransport: runtimeBox' "$file"; then
    echo "error: production runtime still injects the legacy Work transport: $file" >&2
    exit 1
  fi
done

echo "D-076 sync production boundary check passed"
