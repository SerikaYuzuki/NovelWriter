#!/bin/bash
# D-047: Codex sidecar protocolのNode実装を依存installなしで検証する。
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

node --check src/protocol.mjs
node --check src/session.mjs
node --check src/main.mjs
node --test test/main.test.mjs test/protocol.test.mjs test/session.test.mjs
