#!/bin/sh
# Host-side wrapper. Never enable shell tracing: the API client handles tokens.
set -eu
umask 077
zimaos_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
export DOCKER_CONFIG=${FUMINIWA_PREPARE_DOCKER_CONFIG:-/DATA/AppData/fuminiwa-sync-v2-role-split/ops/docker-config}
exec python3 "$zimaos_dir/migrate_app.py" "$@"
