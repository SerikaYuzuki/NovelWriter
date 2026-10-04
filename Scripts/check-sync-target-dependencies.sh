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

# D-090: only current v2 modules belong to the build graph.
if rg -n 'name: "(NovelSync|NovelSyncLegacy|NovelSyncTesting|NovelLibrary|NovelLocalStore)"|product: (NovelSync|NovelSyncLegacy|NovelSyncTesting|NovelLibrary|NovelLocalStore)$' "$package_file" "$project_file"; then
  echo "error: retired synchronization module returned to the build graph" >&2
  exit 1
fi

# D-111: workspace services never compose storage, runtime or explicit transfer.
workspace_package="$(mktemp -t fuminiwa-workspace-dependencies)"
trap 'rm -f "$workspace_package"' EXIT
swift package --package-path NovelKit dump-package > "$workspace_package"
jq -e '
  def dependencies($package; $name):
    [$package.targets[] | select(.name == $name) | .dependencies[]? |
      (.byName[0] // .target[0] // .product[0])];
  def closure($package; $roots):
    reduce range(0; ($package.targets | length)) as $_
      ($roots; (. + [.[] as $name | dependencies($package; $name)[]]) | unique);
  . as $package |
  ([.targets[] | select(.name == "NovelWorkspace")] | length == 1) and
  (dependencies($package; "NovelWorkspace") | all(. as $dependency |
    ["NovelCore", "NovelSyncV2", "NovelSyncV2Application", "NovelAuth", "NovelAuthApple",
     "EditorKit", "NovelWritingSupport", "NovelWritingProgress", "NovelTextAnalysis",
     "NovelThumbnail", "NovelTiming"] | index($dependency) != null)) and
  (closure($package; ["NovelWorkspace"]) | all(. as $dependency |
    ["NovelSyncV2Runtime", "NovelSyncV2Store", "NovelSyncV2PortableBridge", "NovelStorage"] |
    index($dependency) == null))
' "$workspace_package" >/dev/null || {
  echo "error: NovelWorkspace crossed the D-111 dependency boundary" >&2
  exit 1
}

echo "D-090 current synchronization dependency audit passed"
