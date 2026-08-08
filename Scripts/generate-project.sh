#!/bin/bash
# FUMINIWA の XcodeGen プロジェクトを生成する唯一の入口。
# 改名前の生成物が残っていても、誤って古い scheme を開かないよう安全に退避する。
set -euo pipefail
cd "$(dirname "$0")/.."

readonly current_project="FUMINIWA.xcodeproj"
readonly stale_project="NovelWriter.xcodeproj"

if ! command -v xcodegen >/dev/null 2>&1; then
  echo "error: xcodegen is required. Install it with: brew install xcodegen" >&2
  exit 1
fi

if [[ ! -f "project.yml" ]]; then
  echo "error: project.yml was not found at the repository root" >&2
  exit 1
fi

if [[ -d "$stale_project" ]]; then
  readonly task_temporary_root="${TMPDIR:-/tmp}"
  readonly stale_archive_root="${task_temporary_root%/}/FUMINIWA-Stale-Xcode-Projects"
  mkdir -p "$stale_archive_root"

  stale_archive_path="$stale_archive_root/NovelWriter.xcodeproj"
  stale_archive_index=2
  while [[ -e "$stale_archive_path" ]]; do
    stale_archive_path="$stale_archive_root/NovelWriter-${stale_archive_index}.xcodeproj"
    ((stale_archive_index += 1))
  done

  mv "$stale_project" "$stale_archive_path"
  echo "==> Stale NovelWriter.xcodeproj moved to:"
  echo "    $stale_archive_path"
  echo "    Close any old Xcode window and open $current_project instead."
fi

xcodegen generate

if [[ ! -d "$current_project" ]]; then
  echo "error: xcodegen did not create $current_project" >&2
  exit 1
fi

echo "==> Generated $current_project (scheme: FUMINIWA)"
