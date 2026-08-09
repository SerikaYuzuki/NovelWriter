#!/bin/bash
# ローカル検証スクリプト(D-014: CI/CD はローカル実行のみ)
# マージ前に必ずこのスクリプトを通すこと。全チェックが通ると "All checks passed" を表示する。
set -euo pipefail
cd "$(dirname "$0")/.."

echo "==> SwiftFormat (lint)"
swiftformat --lint .

echo "==> SwiftLint"
swiftlint --quiet

echo "==> Codex sidecar protocol (Node)"
./Scripts/check-codex-sidecar.sh

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
./Scripts/check-ai-target-separation.sh
xcodebuild test \
  -project FUMINIWA.xcodeproj \
  -scheme FUMINIWA \
  -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO

echo "==> FUMINIWAExperimental app test (macOS, XcodeGen)"
xcodebuild test \
  -project FUMINIWA.xcodeproj \
  -scheme FUMINIWAExperimental \
  -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO

echo "==> Select iPhone Simulator for iOS tests"
ios_simulator_id="$(xcrun simctl list devices available -j | jq -r '
  [.devices[][] | select(.isAvailable == true and (.name | startswith("iPhone")))] |
  first | .udid // empty
')"
if [[ -z "$ios_simulator_id" ]]; then
  echo "error: an available iPhone Simulator is required for iOS tests" >&2
  exit 1
fi

echo "==> EditorKit test (iOS Simulator)"
(cd NovelKit && xcodebuild test \
  -scheme NovelKit-Package \
  -destination "platform=iOS Simulator,id=$ios_simulator_id" \
  -only-testing:EditorKitTests \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO)

echo "==> FUMINIWA iOS app test (XcodeGen)"
xcodebuild test \
  -project FUMINIWA.xcodeproj \
  -scheme FUMINIWAIOS \
  -destination "platform=iOS Simulator,id=$ios_simulator_id" \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO

echo "==> All checks passed"
