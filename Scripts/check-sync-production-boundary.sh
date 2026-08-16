#!/bin/bash
# D-077--D-079: the normal applications use SQLite local canonical state and
# the SnapshotSyncWorker/HTTP boundary. The retired CloudKit production
# runtime and Work transport are not part of that composition. Compatibility
# source may remain elsewhere; this gate checks only the current composition
# and the retired production entry points.
set -euo pipefail

repo_root="${FUMINIWA_SYNC_BOUNDARY_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
cd "$repo_root"

package_file="NovelKit/Package.swift"
project_file="project.yml"
mac_composition=(
  "NovelApp/Application/FuminiwaApp.swift"
  "NovelApp/AppState.swift"
)
ios_composition=(
  "NovelAppIOS/DocumentLifecycle/IOSDocumentStore.swift"
)
worker_file="NovelKit/Sources/NovelLocalStore/SnapshotSyncWorker.swift"
current_source_roots=("NovelApp" "NovelAppIOS" "NovelKit/Sources")

for file in "$package_file" "$project_file" "$worker_file" "${mac_composition[@]}" "${ios_composition[@]}"; do
  if [[ ! -f "$file" ]]; then
    echo "error: required Snapshot Sync composition file is missing: $file" >&2
    exit 1
  fi
done

# These paths belonged to the deleted CloudKit production composition. Their
# reappearance is a hard failure; migration/compatibility files are not
# required to exist and are not recreated by this gate.
retired_production_paths=(
  "NovelApp/DeviceSync/Runtime/DeviceSyncProductionRuntime.swift"
  "NovelApp/DeviceSync/Runtime/DeviceSyncProductionRuntime+Transport.swift"
  "NovelAppIOS/DeviceSync/Runtime/IOSDeviceSyncProductionRuntime.swift"
  "NovelAppIOS/DeviceSync/Runtime/IOSDeviceSyncProductionRuntime+Transport.swift"
)
for file in "${retired_production_paths[@]}"; do
  if [[ -e "$file" ]]; then
    echo "error: retired CloudKit production runtime/transport returned: $file" >&2
    exit 1
  fi
done

# No current source may introduce the retired CloudKit module/runtime names.
if rg -n -e 'NovelSyncCloudKit|CKSyncEngine|(^|[^A-Za-z])import[[:space:]]+CloudKit' \
  "${current_source_roots[@]}"; then
  echo "error: retired CloudKit runtime reference remains in current source" >&2
  exit 1
fi

# The current app composition must not carry the old Work transport binding.
if rg -n -e 'DeviceSyncProductionRuntime|IOSDeviceSyncProductionRuntime|WorkSyncTransport|workTransport[[:space:]]*:' \
  "${mac_composition[@]}" "${ios_composition[@]}"; then
  echo "error: legacy Work/CloudKit binding leaked into current app composition" >&2
  exit 1
fi

# Both applications must construct the same local-first worker boundary. The
# macOS worker receives its configured HTTP transport; iOS constructs the
# concrete HTTP transport at its local-store boundary.
if ! rg -F -q 'LocalSnapshotSyncWorker' "${mac_composition[1]}"; then
  echo "error: macOS AppState does not install LocalSnapshotSyncWorker" >&2
  exit 1
fi
if ! rg -F -q 'snapshotSyncTransport: runtimeEnvironment.allowsNetwork' \
  "${mac_composition[0]}" \
  || ! rg -F -q 'FuminiwaHTTPSnapshotSyncTransport(baseURL:' \
    "${mac_composition[0]}"; then
  echo "error: macOS composition does not provide the HTTP Snapshot Sync transport" >&2
  exit 1
fi
if ! rg -F -q 'transport: FuminiwaHTTPSnapshotSyncTransport' \
  "${ios_composition[0]}"; then
  echo "error: iOS composition does not provide the HTTP Snapshot Sync transport" >&2
  exit 1
fi

# Keep the worker's dependency direction explicit: local storage may depend on
# the auth/domain contracts, but not on an app/UI or legacy CloudKit module.
if ! rg -F -q 'name: "NovelLocalStore"' "$package_file" \
  || ! rg -F -q 'dependencies: ["NovelCore", "NovelSync", "NovelAuth", "CSQLite"]' "$package_file"; then
  echo "error: NovelLocalStore dependency boundary is missing or changed" >&2
  exit 1
fi
if rg -n -e 'NovelApp|NovelAppIOS|NovelSyncCloudKit|CloudKit|SwiftUI|AppKit|UIKit' \
  "$worker_file"; then
  echo "error: NovelLocalStore/SnapshotSyncWorker crosses an app or CloudKit boundary" >&2
  exit 1
fi

echo "D-079 Snapshot Sync production boundary check passed"
