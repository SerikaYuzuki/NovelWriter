#!/bin/bash
# ローカル検証スクリプト(D-014: CI/CD はローカル実行のみ)
# マージ前に必ずこのスクリプトを通すこと。全チェックが通ると "All checks passed" を表示する。
set -euo pipefail
cd "$(dirname "$0")/.."

echo "==> SwiftFormat (lint)"
swiftformat --lint .

echo "==> SwiftLint"
swiftlint --quiet

echo "==> swift test (NovelKit)"
(cd NovelKit && swift test)

echo "==> iOS compile check (NovelKit)"
(cd NovelKit && xcodebuild build \
  -scheme NovelKit-Package \
  -destination 'generic/platform=iOS' \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO)

echo "==> All checks passed"
