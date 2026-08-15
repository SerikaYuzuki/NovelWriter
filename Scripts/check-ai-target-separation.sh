#!/bin/bash
# D-075: 停止中のprovider実装をbuild graphへ戻さず、確定したclipboard／EditorKit境界だけを残すことを機械検査する。
set -euo pipefail
cd "$(dirname "$0")/.."

command -v jq >/dev/null 2>&1 || {
  echo "error: jq is required to audit the generated Xcode project" >&2
  exit 1
}
command -v rg >/dev/null 2>&1 || {
  echo "error: ripgrep is required to audit the generated Xcode project" >&2
  exit 1
}

project_file="FUMINIWA.xcodeproj/project.pbxproj"
if [[ ! -f "$project_file" ]]; then
  echo "error: generate FUMINIWA.xcodeproj before the AI boundary audit" >&2
  exit 1
fi

audit_tmp="$(mktemp -t fuminiwa-ai-target-audit)"
package_tmp="$(mktemp -t fuminiwa-ai-package-audit)"
module_cache="$(mktemp -d -t fuminiwa-ai-module-cache)"
trap 'rm -f "$audit_tmp" "$package_tmp"; rm -rf "$module_cache"' EXIT
plutil -convert json -o "$audit_tmp" "$project_file"

# The only app targets are the normal macOS and iOS products. Hosted app tests
# do not link the package a second time. CloudKit and the old unhosted Device
# Sync test bundles are intentionally absent after D-079.
jq -e '
  def target($objects; $name):
    $objects | to_entries[] |
      select(.value.isa == "PBXNativeTarget" and .value.name == $name) |
      .value;
  def packageProducts($objects; $name):
    [target($objects; $name).packageProductDependencies[]? as $id |
      $objects[$id].productName] | sort;
  .objects as $objects |
  ([ $objects | to_entries[] |
      select(.value.isa == "PBXNativeTarget") |
      .value.name ] | all(test("Experimental|NovelAI"; "i") | not)) and
  packageProducts($objects; "NovelApp") ==
    ["EditorKit", "NovelAuth", "NovelAuthApple", "NovelCore", "NovelExport", "NovelLibrary", "NovelLocalStore", "NovelStorage", "NovelSync", "NovelUI"] and
  packageProducts($objects; "FUMINIWAIOS") ==
    ["EditorKit", "NovelAuth", "NovelAuthApple", "NovelCore", "NovelExport", "NovelLibrary", "NovelLocalStore", "NovelStorage", "NovelSync", "NovelUI"] and
  packageProducts($objects; "NovelAppTests") == [] and
  packageProducts($objects; "FUMINIWAIOSTests") == []
' "$audit_tmp" >/dev/null

# Keep the standard target identities and hosted test configuration explicit.
jq -e '
  def target($objects; $name):
    $objects | to_entries[] |
      select(.value.isa == "PBXNativeTarget" and .value.name == $name) |
      .value;
  def configurationSettings($objects; $name):
    target($objects; $name).buildConfigurationList as $list |
      [$objects[$list].buildConfigurations[] as $configuration |
        $objects[$configuration].buildSettings];
  .objects as $objects |
  (configurationSettings($objects; "NovelApp") | all(
    .PRODUCT_NAME == "FUMINIWA" and
    .PRODUCT_MODULE_NAME == "FUMINIWA" and
    .PRODUCT_BUNDLE_IDENTIFIER == "dev.serikayuzuki.fuminiwa" and
    .INFOPLIST_FILE == "NovelApp/Info.plist" and
    .CODE_SIGN_ENTITLEMENTS == "NovelApp/NovelApp.entitlements"
  )) and
  (configurationSettings($objects; "FUMINIWAIOS") | all(
    .PRODUCT_NAME == "FUMINIWA" and
    .PRODUCT_MODULE_NAME == "FUMINIWAIOS" and
    .PRODUCT_BUNDLE_IDENTIFIER == "dev.serikayuzuki.fuminiwa.ios" and
    .INFOPLIST_FILE == "NovelAppIOS/Info.plist" and
    .CODE_SIGN_ENTITLEMENTS == "NovelAppIOS/FUMINIWAIOS.entitlements"
  )) and
  (configurationSettings($objects; "NovelAppTests") | all(
    .TEST_HOST == "$(BUILT_PRODUCTS_DIR)/FUMINIWA.app/Contents/MacOS/FUMINIWA" and
    .BUNDLE_LOADER == "$(TEST_HOST)"
  )) and
  (configurationSettings($objects; "FUMINIWAIOSTests") | all(
    .TEST_HOST == "$(BUILT_PRODUCTS_DIR)/FUMINIWA.app/FUMINIWA" and
    .BUNDLE_LOADER == "$(TEST_HOST)"
  ))
' "$audit_tmp" >/dev/null

# No legacy compile flag or removed source may leak into a product target.
jq -e '
  def target($objects; $name):
    $objects | to_entries[] |
      select(.value.isa == "PBXNativeTarget" and .value.name == $name) |
      .value;
  def conditions($objects; $name):
    target($objects; $name).buildConfigurationList as $list |
      [$objects[$list].buildConfigurations[] as $configuration |
        ($objects[$configuration].buildSettings.SWIFT_ACTIVE_COMPILATION_CONDITIONS // "")];
  .objects as $objects |
  (conditions($objects; "NovelApp") | all(contains("FUMINIWA_ENABLE_EXPERIMENTAL_AI") | not)) and
  (conditions($objects; "FUMINIWAIOS") | all(contains("FUMINIWA_ENABLE_EXPERIMENTAL_AI") | not)) and
  (conditions($objects; "NovelAppTests") | all(contains("FUMINIWA_ENABLE_EXPERIMENTAL_AI") | not)) and
  (conditions($objects; "FUMINIWAIOSTests") | all(contains("FUMINIWA_ENABLE_EXPERIMENTAL_AI") | not))
' "$audit_tmp" >/dev/null

jq -e '
  def target($objects; $name):
    $objects | to_entries[] |
      select(.value.isa == "PBXNativeTarget" and .value.name == $name) |
      .value;
  def buildFileRefs($objects; $name):
    [target($objects; $name).buildPhases[] as $phase |
      $objects[$phase].files[]? as $buildFile |
      $objects[$buildFile].fileRef // empty];
  def refLabel($objects; $id):
    ($objects[$id].path // $objects[$id].name // "");
  .objects as $objects |
  (["NovelApp", "FUMINIWAIOS"] | all(. as $name |
    [buildFileRefs($objects; $name)[] | refLabel($objects; .)] |
    all(test("NovelAI|Experimental|node_modules|sidecar|Codex"; "i") | not)
  ))
' "$audit_tmp" >/dev/null

standard_scheme="FUMINIWA.xcodeproj/xcshareddata/xcschemes/FUMINIWA.xcscheme"
ios_scheme="FUMINIWA.xcodeproj/xcshareddata/xcschemes/FUMINIWAIOS.xcscheme"
for scheme in "$standard_scheme" "$ios_scheme"; do
  if [[ ! -f "$scheme" ]]; then
    echo "error: expected shared scheme is missing: $scheme" >&2
    exit 1
  fi
done
if [[ -f "FUMINIWA.xcodeproj/xcshareddata/xcschemes/FUMINIWAExperimental.xcscheme" ]]; then
  echo "error: the removed Experimental scheme is still generated" >&2
  exit 1
fi
rg -F -q 'BlueprintName = "NovelApp"' "$standard_scheme"
rg -F -q 'BlueprintName = "NovelAppTests"' "$standard_scheme"
if rg -F -q 'NovelAppDeviceSyncTests' "$standard_scheme"; then
  echo "error: the removed macOS Device Sync test target is still generated" >&2
  exit 1
fi
if rg -F -q 'FUMINIWAExperimental' "$standard_scheme"; then
  echo "error: the standard scheme references an Experimental target" >&2
  exit 1
fi
rg -F -q 'BlueprintName = "FUMINIWAIOS"' "$ios_scheme"
rg -F -q 'BlueprintName = "FUMINIWAIOSTests"' "$ios_scheme"
if rg -F -q 'FUMINIWADeviceSyncIOSTests' "$ios_scheme"; then
  echo "error: the removed iOS Device Sync test target is still generated" >&2
  exit 1
fi
if rg -F -q 'FUMINIWAExperimental' "$ios_scheme"; then
  echo "error: the iOS scheme references an Experimental target" >&2
  exit 1
fi

if [[ "$(plutil -extract CFBundleDocumentTypes.0.LSHandlerRank raw NovelApp/Info.plist)" != "Owner" ]]; then
  echo "error: the standard app must remain the document owner" >&2
  exit 1
fi
if [[ "$(plutil -extract CFBundleDocumentTypes.0.LSHandlerRank raw NovelAppIOS/Info.plist)" != "Alternate" ]]; then
  echo "error: the iOS app must not replace the macOS document owner" >&2
  exit 1
fi
if [[ "$(plutil -extract LSSupportsOpeningDocumentsInPlace raw NovelAppIOS/Info.plist)" != "false" ]]; then
  echo "error: the iOS MVP must keep external packages copy-in rather than open-in-place" >&2
  exit 1
fi
for entitlements in NovelApp/NovelApp.entitlements NovelAppIOS/FUMINIWAIOS.entitlements; do
  if plutil -convert json -o - "$entitlements" | jq -e \
    'has("com.apple.developer.icloud-container-identifiers") or
     has("com.apple.developer.icloud-services") or
     has("com.apple.developer.icloud-container-environment") or
     has("com.apple.developer.aps-environment") or has("aps-environment")' \
    >/dev/null; then
    echo "error: retired CloudKit/APNs entitlements remain in $entitlements" >&2
    exit 1
  fi
done
if plutil -convert json -o - NovelApp/NovelApp.entitlements | jq -e \
  '."com.apple.security.app-sandbox" == true' >/dev/null; then
  echo "error: Device Sync must not enable App Sandbox for the directly distributed macOS app" >&2
  exit 1
fi
if rg -n 'URLSession|Network\.framework|NWConnection|OpenRouter|codex_sdk' NovelAppIOS; then
  echo "error: the iOS app contains a provider or network callsite" >&2
  exit 1
fi

env \
  SWIFT_MODULECACHE_PATH="$module_cache/swift-module" \
  CLANG_MODULE_CACHE_PATH="$module_cache/clang" \
  swift package \
    --disable-sandbox \
    --cache-path "$module_cache/package-cache" \
    --config-path "$module_cache/config" \
    --security-path "$module_cache/security" \
    --scratch-path "$module_cache/scratch" \
    --manifest-cache local \
    dump-package --package-path NovelKit > "$package_tmp"
jq -e '
  def dependencies($package; $name):
    [$package.targets[] | select(.name == $name) | .dependencies[]? |
      (.byName[0] // .target[0] // .product[0])];
  def transitiveClosure($package; $roots):
    reduce range(0; ($package.targets | length)) as $_
      ($roots; (. + [.[] as $name | dependencies($package; $name)[]]) | unique);
  . as $package |
  (transitiveClosure($package; ["NovelCore", "NovelStorage", "EditorKit", "NovelUI", "NovelExport", "NovelLibrary", "NovelSync"])
    | index("NovelAI") == null) and
  ([$package.targets[].name] | all(test("Experimental|NovelAI"; "i") | not))
' "$package_tmp" >/dev/null

echo "==> Standard macOS/iOS AI boundary and build graph verified"
