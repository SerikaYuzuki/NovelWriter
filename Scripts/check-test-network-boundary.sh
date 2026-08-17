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
  if ! rg -F -q 'buildConfiguration = "Debug-Test"' "$scheme_file"; then
    echo "error: $scheme Test action does not use the isolated Debug-Test configuration" >&2
    exit 1
  fi
  if rg -F -q 'FUMINIWA_TEST_NETWORK_DISABLED' "$scheme_file"; then
    echo "error: $scheme still relies on an environment-variable network switch" >&2
    exit 1
  fi
done

if [[ "$(rg -F -c 'SWIFT_ACTIVE_COMPILATION_CONDITIONS: "$(inherited) FUMINIWA_TEST_COMPOSITION"' project.yml)" -ne 4 ]]; then
  echo "error: both app hosts and both test bundles require the compile-time test composition" >&2
  exit 1
fi

test_branch() {
  awk '
    /#if FUMINIWA_TEST_COMPOSITION/ && !started { started = 1; next }
    started && /#else/ { exit }
    started { print }
  ' "$1"
}

production_branch() {
  awk '
    /#if FUMINIWA_TEST_COMPOSITION/ && !started { started = 1; next }
    started && /#else/ { production = 1; next }
    production && /#endif/ { exit }
    production { print }
  ' "$1"
}

for app_main in NovelApp/Application/FuminiwaApp.swift NovelAppIOS/Application/FuminiwaIOSApp.swift; do
  isolated_source="$(test_branch "$app_main")"
  production_source="$(production_branch "$app_main")"
  if [[ "$isolated_source" != *"TestRuntimeConfiguration"* ]]; then
    echo "error: $app_main has no explicit TestRuntimeConfiguration in its Test build" >&2
    exit 1
  fi
  if rg -q 'ProductionRuntimeConfiguration|Keychain|UserDefaults\.standard|makeProductionDependencies' <<< "$isolated_source"; then
    echo "error: $app_main Test build can construct a production dependency" >&2
    exit 1
  fi
  if [[ "$production_source" != *"UserDefaults.standard"* ]]; then
    echo "error: $app_main production build has no explicit production defaults root" >&2
    exit 1
  fi
  if rg -q 'TestRuntimeConfiguration|makeTestDependencies|runtimeComposition: \.test' <<< "$production_source"; then
    echo "error: $app_main production build contains a Test composition path" >&2
    exit 1
  fi
done

for defaults_boundary in \
  'NovelApp|NovelApp/Application/FuminiwaApp.swift' \
  'NovelAppIOS|NovelAppIOS/Application/FuminiwaIOSApp.swift'; do
  source_root="${defaults_boundary%%|*}"
  expected_source="${defaults_boundary#*|}"
  standard_defaults="$(
    rg -n 'UserDefaults\.standard' "$source_root" \
      --glob '*.swift' \
      --glob '!**/Legacy/**' \
      --glob '!**/Retired*/**' || true
  )"
  standard_count="$(printf '%s\n' "$standard_defaults" | awk 'NF { count += 1 } END { print count + 0 }')"
  if [[ "$standard_count" -ne 1 ]] || [[ "$standard_defaults" != "$expected_source":* ]]; then
    echo "error: active $source_root sources may use UserDefaults.standard only in the production app entry point" >&2
    printf '%s\n' "$standard_defaults" >&2
    exit 1
  fi
done

if rg -n 'userDefaults:[[:space:]]*UserDefaults[[:space:]]*=' \
  NovelApp/Application/AppDependencies.swift \
  NovelAppIOS/DocumentLifecycle/IOSDocumentStore.swift; then
  echo "error: app dependencies must require an explicit UserDefaults domain" >&2
  exit 1
fi

# Treat code outside a FUMINIWA_TEST_COMPOSITION conditional as present in the
# Test app too. Production constructors are allowed only in a compile-time
# false branch, so the hosted test executable cannot open Keychain, production
# SQLite roots, or a production HTTP origin through an app-level constructor.
while IFS= read -r source; do
  if awk '
    function test_build_active(    level) {
      for (level = 1; level <= depth; level += 1) {
        if (is_test_condition[level] && !test_side[level]) {
          return 0
        }
      }
      return 1
    }
    /^[[:space:]]*#if[[:space:]]+/ {
      depth += 1
      is_test_condition[depth] = 0
      test_side[depth] = 1
      if ($0 ~ /#if[[:space:]]+FUMINIWA_TEST_COMPOSITION/) {
        is_test_condition[depth] = 1
      } else if ($0 ~ /#if[[:space:]]+!FUMINIWA_TEST_COMPOSITION/) {
        is_test_condition[depth] = 1
        test_side[depth] = 0
      }
      next
    }
    /^[[:space:]]*#elseif[[:space:]]+/ {
      if (is_test_condition[depth]) {
        test_side[depth] = 0
      }
      next
    }
    /^[[:space:]]*#else/ {
      if (is_test_condition[depth]) {
        test_side[depth] = !test_side[depth]
      }
      next
    }
    /^[[:space:]]*#endif/ {
      delete is_test_condition[depth]
      delete test_side[depth]
      depth -= 1
      next
    }
    test_build_active() &&
      $0 ~ /(ProductionRuntimeConfiguration|ProductionHTTPSOrigin|FuminiwaHTTPAuthTransport|FuminiwaRuntimeEnvironment|Keychain[A-Za-z0-9_]*)[[:space:]]*\(/ {
      print FNR ":" $0
      invalid = 1
    }
    END { exit invalid }
  ' "$source"; then
    :
  else
    echo "error: $source exposes a production constructor to an app-hosted Test build" >&2
    exit 1
  fi
done < <(
  rg --files NovelApp NovelAppIOS NovelAppTests NovelAppIOSTests \
    --glob '*.swift' \
    --glob '!**/Legacy/**' \
    --glob '!**/Retired*/**'
)

while IFS= read -r source; do
  if awk '
    function production_build_active(    level) {
      for (level = 1; level <= depth; level += 1) {
        if (is_test_condition[level] && !production_side[level]) {
          return 0
        }
      }
      return 1
    }
    /^[[:space:]]*#if[[:space:]]+/ {
      depth += 1
      is_test_condition[depth] = 0
      production_side[depth] = 1
      if ($0 ~ /#if[[:space:]]+FUMINIWA_TEST_COMPOSITION/) {
        is_test_condition[depth] = 1
        production_side[depth] = 0
      } else if ($0 ~ /#if[[:space:]]+!FUMINIWA_TEST_COMPOSITION/) {
        is_test_condition[depth] = 1
      }
      next
    }
    /^[[:space:]]*#elseif[[:space:]]+/ {
      if (is_test_condition[depth]) {
        production_side[depth] = 0
      }
      next
    }
    /^[[:space:]]*#else/ {
      if (is_test_condition[depth]) {
        production_side[depth] = !production_side[depth]
      }
      next
    }
    /^[[:space:]]*#endif/ {
      delete is_test_condition[depth]
      delete production_side[depth]
      depth -= 1
      next
    }
    production_build_active() &&
      /SnapshotSyncV2[A-Za-z0-9]*Override|snapshotSyncV2[A-Za-z0-9]*Override/ {
      print FNR ":" $0
      invalid = 1
    }
    END { exit invalid }
  ' "$source"; then
    :
  else
    echo "error: $source exposes a test override to the production build" >&2
    exit 1
  fi
done < <(
  rg -l 'SnapshotSyncV2[A-Za-z0-9]*Override|snapshotSyncV2[A-Za-z0-9]*Override' NovelApp \
    --glob '*.swift' \
    --glob '!**/Legacy/**' \
    --glob '!**/Retired*/**'
)

# The LAN development endpoint belongs only to the runtime resolver. App
# composition must never embed a fallback URL that bypasses the test gate.
if rg -n '192\.168\.11\.5:18080' NovelApp NovelAppIOS; then
  echo "error: app target embeds the development sync endpoint" >&2
  exit 1
fi

echo "test runtime composition boundary check passed"
