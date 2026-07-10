#!/bin/bash
# Phase 4.5-3b: 代表パッケージでの保存性能を計測する。
#
# 1 MB 本文・100 MB 添付・20 スナップショットを用意し、上書き保存の wall time を測る。
# 既定の Scripts/check.sh には含めない(ディスクと時間が大きいため)。
#
# 使い方:
#   ./Scripts/measure-save-performance.sh
#
# 成功時は予算内の計測結果を標準出力へ出し、失敗時は非ゼロで終了する。
set -euo pipefail
cd "$(dirname "$0")/.."

echo "==> Save performance measurement (Phase 4.5-3b)"
echo "    Fixture: 1MB body + 100MB attachment + 20 snapshots"
echo "    Budget:  overwrite save <= 15s (see SavePerformanceBudget)"
echo

export NOVELWRITER_PERF_TEST=1

# 計測ログ(print)を確実に見るため、該当テストだけを実行する。
(cd NovelKit && swift test --filter overwriteSaveOfRepresentativePackageStaysWithinBudget)

echo
echo "==> Measurement finished"
