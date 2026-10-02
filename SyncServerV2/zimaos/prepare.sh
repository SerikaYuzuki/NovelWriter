#!/bin/sh
# Server-side only. No stop/recreate/rename/update of any running container.
set -eu
umask 077
zimaos_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_dir=$(CDPATH= cd -- "$zimaos_dir/../.." && pwd)
base=/DATA/AppData/fuminiwa-sync-v2-role-split
server_tag=${1:-role-split-20261003}
ops_tag=${2:-ops-ui-20261003}
output=${3:-$base/ops/zimaos-app-compose.yml}
for tag in "$server_tag" "$ops_tag"; do
  case "$tag" in ''|*[!A-Za-z0-9_.-]*|-*|.*) echo 'Invalid image tag' >&2; exit 1;; esac
  [ "${#tag}" -le 128 ] || exit 1
done
export DOCKER_CONFIG=${FUMINIWA_PREPARE_DOCKER_CONFIG:-$base/ops/docker-config}
mkdir -p "$DOCKER_CONFIG" "$(dirname -- "$output")"
chmod 700 "$DOCKER_CONFIG"
# The CLI looks for plugins under this new config and its system directories.
# The prior server trial found the default /DATA/.docker inaccessible.
docker compose version >/dev/null
docker buildx version >/dev/null
docker inspect fuminiwa-registry | python3 -c '
import json,sys
r=json.load(sys.stdin)[0]
ok=(r["State"]["Running"] and r["HostConfig"]["RestartPolicy"]["Name"]=="unless-stopped"
    and r["HostConfig"]["PortBindings"].get("5000/tcp")==[{"HostIp":"127.0.0.1","HostPort":"5000"}]
    and any(m.get("Name")=="fuminiwa-registry-data" and m["Destination"]=="/var/lib/registry" for m in r["Mounts"]))
sys.exit(0 if ok else "Registry must be running, loopback-only, persistent and unless-stopped")'
server_id=$(docker inspect fuminiwa-sync-v2-role-split-server --format '{{.Image}}')
case "$server_id" in sha256:*) ;; *) echo 'Missing server image ID' >&2; exit 1;; esac
server_ref=127.0.0.1:5000/fuminiwa-sync-v2-server:$server_tag
ops_ref=127.0.0.1:5000/fuminiwa-sync-v2-ops:$ops_tag
# Only ops is built. Server is exactly the captured running image ID.
docker build -f "$repo_dir/SyncServerV2/ops/Dockerfile" -t "$ops_ref" "$repo_dir"
docker tag "$server_id" "$server_ref"
docker push "$server_ref"
docker push "$ops_ref"
python3 "$zimaos_dir/render_app_compose.py" --server-image "$server_ref" \
  --ops-image "$ops_ref" --output "$output"
printf 'Prepared only; import/migration is a separate UI operation. Compose: %s\n' "$output"
