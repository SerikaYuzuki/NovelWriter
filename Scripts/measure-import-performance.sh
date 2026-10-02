#!/bin/bash
# Synthetic data only; normal swift test skips this benchmark.
set -euo pipefail
cd "$(dirname "$0")/../NovelKit"
FUMINIWA_IMPORT_BENCHMARK=1 swift test -c release --filter syntheticImportPerformance "$@"
