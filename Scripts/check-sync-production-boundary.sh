#!/bin/bash
# D-076 R5a/R5c: normal app composition must not expose or implement the legacy
# Work transport from the Runtime directory. The package target split is
# intentionally a later R5 step; test/compatibility runtimes may still inject
# WorkSyncTransport explicitly from DeviceSync/Legacy.
set -euo pipefail

cd "$(dirname "$0")/.."

mac_runtime="NovelApp/DeviceSync/Runtime/DeviceSyncProductionRuntime.swift"
ios_runtime="NovelAppIOS/DeviceSync/Runtime/IOSDeviceSyncProductionRuntime.swift"
mac_transport="NovelApp/DeviceSync/Runtime/DeviceSyncProductionRuntime+Transport.swift"
ios_transport="NovelAppIOS/DeviceSync/Runtime/IOSDeviceSyncProductionRuntime+Transport.swift"
legacy_files=(
  "NovelApp/DeviceSync/Legacy/DeviceSyncProductionRuntime+LegacyTransport.swift"
  "NovelApp/DeviceSync/Legacy/DeviceSyncProductionRuntime+LegacyBindings.swift"
  "NovelAppIOS/DeviceSync/Legacy/IOSDeviceSyncProductionRuntime+LegacyTransport.swift"
  "NovelAppIOS/DeviceSync/Legacy/IOSDeviceSyncProductionRuntime+LegacyBindings.swift"
)

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

for file in "$mac_runtime" "$ios_runtime"; do
  if rg -F -q 'EpisodeSyncTransport, WorkSyncTransport' "$file"; then
    echo "error: production runtime must not implement WorkSyncTransport in Runtime: $file" >&2
    exit 1
  fi
done

for file in "$mac_transport" "$ios_transport"; do
  if rg -q 'Work(RemoteSnapshot|Revision|PublishRequest|PublishResult)|WorkSyncTransport' "$file"; then
    echo "error: legacy Work transport leaked into Runtime transport extension: $file" >&2
    exit 1
  fi
done

for file in "${legacy_files[@]}"; do
  if [[ ! -f "$file" ]] || ! rg -F -q 'WorkSyncTransport' "$file"; then
    echo "error: expected compatibility Work transport boundary is missing: $file" >&2
    exit 1
  fi
done

echo "D-076 sync production boundary check passed"
