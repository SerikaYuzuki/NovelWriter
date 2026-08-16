#!/bin/bash
# Independent first slice of the reviewed R0 conformance gate.
set -euo pipefail
cd "$(dirname "$0")/.."

echo "==> R0 shared fixture integrity (Python)"
python3 Scripts/conformance-r0.py

echo "==> R0 shared fixture integrity (Swift)"
(cd NovelKit && mkdir -p .build/r0-clang-cache && CLANG_MODULE_CACHE_PATH="$PWD/.build/r0-clang-cache" swift test --disable-sandbox --cache-path .build/r0-cache --manifest-cache local --filter R0ConformanceTests)

echo "==> R0 shared fixture integrity (Rust)"
cargo test --manifest-path SyncServer/Cargo.toml --test r0_conformance

echo "R0 initial conformance slice passed"
