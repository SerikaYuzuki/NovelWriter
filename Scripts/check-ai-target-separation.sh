#!/bin/bash
# D-046: 通常版と個人用AI実験版のbuild graphを機械検査する。
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
  echo "error: generate FUMINIWA.xcodeproj before the AI separation audit" >&2
  exit 1
fi

audit_tmp="$(mktemp -t fuminiwa-ai-target-audit)"
package_tmp="$(mktemp -t fuminiwa-ai-package-audit)"
module_cache="$(mktemp -d -t fuminiwa-ai-module-cache)"
trap 'rm -f "$audit_tmp" "$package_tmp"; rm -rf "$module_cache"' EXIT
plutil -convert json -o "$audit_tmp" "$project_file"

jq -e '
  def target($objects; $name):
    $objects | to_entries[] |
      select(.value.isa == "PBXNativeTarget" and .value.name == $name) |
      .value;
  def packageProducts($objects; $name):
    [target($objects; $name).packageProductDependencies[]? as $id |
      $objects[$id].productName] | sort;
  .objects as $objects |
  packageProducts($objects; "NovelApp") ==
    ["EditorKit", "NovelCore", "NovelExport", "NovelStorage", "NovelUI"] and
  packageProducts($objects; "FUMINIWAIOS") ==
    ["EditorKit", "NovelCore", "NovelExport", "NovelStorage", "NovelUI"] and
  packageProducts($objects; "FUMINIWAExperimental") ==
    ["EditorKit", "NovelAI", "NovelCore", "NovelExport", "NovelStorage", "NovelUI"] and
  packageProducts($objects; "NovelAppTests") == [] and
  packageProducts($objects; "FUMINIWAIOSTests") == [] and
  packageProducts($objects; "FUMINIWAExperimentalTests") == []
' "$audit_tmp" >/dev/null

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
    .INFOPLIST_FILE == "NovelApp/Info.plist"
  )) and
  (configurationSettings($objects; "FUMINIWAExperimental") | all(
    .PRODUCT_NAME == "FUMINIWAExperimental" and
    .PRODUCT_MODULE_NAME == "FUMINIWAExperimental" and
    .PRODUCT_BUNDLE_IDENTIFIER == "dev.serikayuzuki.fuminiwa.experimental" and
    .INFOPLIST_FILE == "NovelAppExperimental/Info.plist"
  )) and
  (configurationSettings($objects; "FUMINIWAIOS") | all(
    .PRODUCT_NAME == "FUMINIWA" and
    .PRODUCT_MODULE_NAME == "FUMINIWAIOS" and
    .PRODUCT_BUNDLE_IDENTIFIER == "dev.serikayuzuki.fuminiwa.ios" and
    .INFOPLIST_FILE == "NovelAppIOS/Info.plist"
  )) and
  (configurationSettings($objects; "NovelAppTests") | all(
    .TEST_HOST == "$(BUILT_PRODUCTS_DIR)/FUMINIWA.app/Contents/MacOS/FUMINIWA" and
    .BUNDLE_LOADER == "$(TEST_HOST)"
  )) and
  (configurationSettings($objects; "FUMINIWAIOSTests") | all(
    .TEST_HOST == "$(BUILT_PRODUCTS_DIR)/FUMINIWA.app/FUMINIWA" and
    .BUNDLE_LOADER == "$(TEST_HOST)"
  )) and
  (configurationSettings($objects; "FUMINIWAExperimentalTests") | all(
    .TEST_HOST == "$(BUILT_PRODUCTS_DIR)/FUMINIWAExperimental.app/Contents/MacOS/FUMINIWAExperimental" and
    .BUNDLE_LOADER == "$(TEST_HOST)"
  ))
' "$audit_tmp" >/dev/null

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
  (conditions($objects; "FUMINIWAExperimental") | all(contains("FUMINIWA_ENABLE_EXPERIMENTAL_AI")))
' "$audit_tmp" >/dev/null

jq -e '
  def target($objects; $name):
    $objects | to_entries[] |
      select(.value.isa == "PBXNativeTarget" and .value.name == $name) |
      .value;
  def descendants($objects):
    . as $id |
      [$id] + (($objects[$id].children // []) | map(descendants($objects)) | add // []);
  def buildFileRefs($objects; $name):
    [target($objects; $name).buildPhases[] as $phase |
      $objects[$phase].files[]? as $buildFile |
      $objects[$buildFile].fileRef];
  .objects as $objects |
  ([ $objects | to_entries[] |
      select(.value.isa == "PBXGroup" and .value.path == "NovelAppExperimental") |
      .key ][0] | descendants($objects)) as $experimentalTree |
  [buildFileRefs($objects; "NovelApp")[] as $fileRef |
    select($experimentalTree | index($fileRef))] | length == 0
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
  [buildFileRefs($objects; "NovelApp")[] | refLabel($objects; .)] |
  all(test("NovelAI|Experimental|node_modules|sidecar|Codex"; "i") | not)
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
  [buildFileRefs($objects; "FUMINIWAIOS")[] | refLabel($objects; .)] |
  all(test("NovelAI|Experimental|node_modules|sidecar|Codex"; "i") | not)
' "$audit_tmp" >/dev/null

standard_scheme="FUMINIWA.xcodeproj/xcshareddata/xcschemes/FUMINIWA.xcscheme"
experimental_scheme="FUMINIWA.xcodeproj/xcshareddata/xcschemes/FUMINIWAExperimental.xcscheme"
ios_scheme="FUMINIWA.xcodeproj/xcshareddata/xcschemes/FUMINIWAIOS.xcscheme"
for scheme in "$standard_scheme" "$experimental_scheme" "$ios_scheme"; do
  if [[ ! -f "$scheme" ]]; then
    echo "error: expected shared scheme is missing: $scheme" >&2
    exit 1
  fi
done
rg -F -q 'BlueprintName = "NovelApp"' "$standard_scheme"
rg -F -q 'BlueprintName = "NovelAppTests"' "$standard_scheme"
if rg -F -q 'FUMINIWAExperimental' "$standard_scheme"; then
  echo "error: the standard scheme references an Experimental target" >&2
  exit 1
fi
rg -F -q 'BlueprintName = "FUMINIWAExperimental"' "$experimental_scheme"
rg -F -q 'BlueprintName = "FUMINIWAExperimentalTests"' "$experimental_scheme"
rg -F -q 'BlueprintName = "FUMINIWAIOS"' "$ios_scheme"
rg -F -q 'BlueprintName = "FUMINIWAIOSTests"' "$ios_scheme"
if rg -F -q 'FUMINIWAExperimental' "$ios_scheme"; then
  echo "error: the iOS scheme references an Experimental target" >&2
  exit 1
fi

if [[ "$(plutil -extract CFBundleDocumentTypes.0.LSHandlerRank raw NovelApp/Info.plist)" != "Owner" ]]; then
  echo "error: the standard app must remain the document owner" >&2
  exit 1
fi
if [[ "$(plutil -extract CFBundleDocumentTypes.0.LSHandlerRank raw NovelAppExperimental/Info.plist)" != "Alternate" ]]; then
  echo "error: the Experimental app must not replace the standard document owner" >&2
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
if rg -n 'URLSession|Network\.framework|NWConnection|OpenRouter|codex_sdk' NovelAppIOS; then
  echo "error: the iOS app contains a provider or network callsite" >&2
  exit 1
fi

env \
  SWIFTPM_MODULECACHE_OVERRIDE="$module_cache/swiftpm" \
  CLANG_MODULE_CACHE_PATH="$module_cache/clang" \
  swift package dump-package --package-path NovelKit > "$package_tmp"
jq -e '
  def dependencies($package; $name):
    [$package.targets[] |
      select(.name == $name) |
      .dependencies[]? |
      (.byName[0] // .target[0] // .product[0])];
  def transitiveClosure($package; $roots):
    reduce range(0; ($package.targets | length)) as $_
      ($roots; (. + [.[] as $name | dependencies($package; $name)[]]) | unique);
  . as $package |
  (transitiveClosure($package; ["NovelCore", "NovelStorage", "EditorKit", "NovelUI", "NovelExport"])
    | index("NovelAI") == null) and
  (dependencies($package; "NovelAI") == [])
' "$package_tmp" >/dev/null

echo "==> Standard, iOS and Experimental AI build graph separation verified"
