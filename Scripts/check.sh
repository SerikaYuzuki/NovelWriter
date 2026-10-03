#!/bin/bash
# ローカル検証スクリプト(D-014: CI/CD はローカル実行のみ)
# D-086: 保存・共有基盤など重たい検証を選択した変更で実行する。
set -euo pipefail
cd "$(dirname "$0")/.."

echo "==> Snapshot Sync v2 independent conformance"
./Scripts/conformance-v2.sh

echo "==> D-076 source structure"
./Scripts/check-code-structure.sh
./Scripts/check-sync-target-dependencies.sh

echo "==> SwiftFormat (lint)"
swiftformat --lint --cache ignore .

echo "==> SwiftLint"
swiftlint lint --quiet --no-cache --baseline .swiftlint.baseline.yml

echo "==> swift test (NovelKit)"
(cd NovelKit && swift test)

echo "==> iOS compile check (NovelKit)"
(cd NovelKit && xcodebuild build \
  -scheme NovelKit-Package \
  -destination 'generic/platform=iOS' \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO)

echo "==> FUMINIWA app test (macOS, XcodeGen)"
./Scripts/generate-project.sh
./Scripts/check-test-network-boundary.sh
./Scripts/check-ai-target-separation.sh
./Scripts/check-sync-v2-boundary.sh
xcodebuild test \
  -project FUMINIWA.xcodeproj \
  -scheme FUMINIWA \
  -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO

echo "==> Select iPhone Simulator for iOS tests"
ios_simulator_id="${FUMINIWA_IOS_SIMULATOR_ID:-$(xcrun simctl list devices available -j | jq -r '
  [.devices[][] | select(.isAvailable == true and (.name | startswith("iPhone")))] |
  first | .udid // empty
')}"
if [[ -z "$ios_simulator_id" ]]; then
  echo "error: an available iPhone Simulator is required for iOS tests" >&2
  exit 1
fi

# A supplied destination must resolve to an available iPhone. Do not start a
# second test runner while another chat owns a simulator test session.
if ! xcrun simctl list devices available -j | jq -e --arg id "$ios_simulator_id" \
  '[.devices[][] | select(.isAvailable == true and (.name | startswith("iPhone")) and .udid == $id)] | length == 1' >/dev/null; then
  echo "error: selected iPhone Simulator is not available" >&2
  exit 1
fi
wait_for_ios_destination() {
  while pgrep -fl "xcodebuild.*$ios_simulator_id"; do
    echo "==> Selected Simulator is in use; wait before iOS tests"
    sleep 5
  done
}
wait_for_ios_destination

echo "==> EditorKit test (iOS Simulator)"
(cd NovelKit && xcodebuild test \
  -scheme NovelKit-Package \
  -destination "platform=iOS Simulator,id=$ios_simulator_id" \
  -only-testing:EditorKitTests \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO)

wait_for_ios_destination

echo "==> FUMINIWA iOS app test (XcodeGen)"
xcodebuild test \
  -project FUMINIWA.xcodeproj \
  -scheme FUMINIWAIOS \
  -destination "platform=iOS Simulator,id=$ios_simulator_id" \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO

echo "==> All checks passed"
