#!/bin/bash
# D-047: Codex sidecar protocolとexact SDKの合成captureを検証する。
set -euo pipefail
cd "$(dirname "$0")/../Sidecars/Codex"

command -v node >/dev/null 2>&1 || {
  echo "error: Node.js 18 or later is required for Codex sidecar tests" >&2
  exit 1
}

node_major="$(node -p 'Number(process.versions.node.split(".")[0])')"
if [[ ! "$node_major" =~ ^[0-9]+$ ]] || ((node_major < 18)); then
  echo "error: Node.js 18 or later is required for Codex sidecar tests" >&2
  exit 1
fi

if [[ ! -f node_modules/@openai/codex-sdk/package.json ]]; then
  echo "error: Codex sidecar dependencies are not installed" >&2
  echo "run: (cd Sidecars/Codex && npm ci --ignore-scripts --no-audit --no-fund)" >&2
  exit 1
fi

node --check src/protocol.mjs
node --check src/session.mjs
node --check src/main.mjs
node --check src/deployment-manifest.mjs
node --check src/deployment-packager.mjs
node --check src/codex-sdk-capture.mjs
node --test \
  test/main.test.mjs \
  test/protocol.test.mjs \
  test/session.test.mjs \
  test/deployment-manifest.test.mjs \
  test/deployment-packager.test.mjs \
  test/codex-sdk-capture.test.mjs
