#!/usr/bin/env bash
# Export and verify the public Caddy CA for the isolated Snapshot Sync v2 LAN
# staging edge. This script never exports a private key or installs trust.
set -euo pipefail

usage() {
    cat <<'USAGE'
Usage: export-sync-v2-staging-ca.sh [options]

Options:
  --output PATH       CA PEM destination (default: /tmp/fuminiwa-sync-v2-root.crt)
  --host HOST         SSH/HTTPS host (default: 192.168.11.5)
  --port PORT         HTTPS port (default: 8443)
  --ssh-user USER     SSH user (default: recky)
  --force             Replace an existing output file
  -h, --help          Show this help

The script may prompt SSH/sudo interactively, but never reads or stores the
password itself. A public CA is staged briefly under the remote user's `/tmp`
and removed on exit.
USAGE
}

fail() {
    echo "error: $*" >&2
    exit 1
}

output_path="/tmp/fuminiwa-sync-v2-root.crt"
staging_host="192.168.11.5"
staging_port="8443"
ssh_user="recky"
force=0

while (($# > 0)); do
    case "$1" in
        --output)
            (($# >= 2)) || fail "--output requires a path"
            output_path="$2"
            shift 2
            ;;
        --host)
            (($# >= 2)) || fail "--host requires a value"
            staging_host="$2"
            shift 2
            ;;
        --port)
            (($# >= 2)) || fail "--port requires a value"
            staging_port="$2"
            shift 2
            ;;
        --ssh-user)
            (($# >= 2)) || fail "--ssh-user requires a value"
            ssh_user="$2"
            shift 2
            ;;
        --force)
            force=1
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            fail "unknown option: $1"
            ;;
    esac
done

command -v ssh >/dev/null || fail "ssh is required"
command -v scp >/dev/null || fail "scp is required"
command -v openssl >/dev/null || fail "openssl is required"
command -v curl >/dev/null || fail "curl is required"
command -v jq >/dev/null || fail "jq is required"
[[ "$staging_host" == "192.168.11.5" ]] || fail "staging host must be 192.168.11.5"
[[ "$staging_port" =~ ^[0-9]+$ ]] || fail "port must be numeric"
[[ "$staging_port" -ge 1 && "$staging_port" -le 65535 ]] || fail "port is out of range"
[[ "$output_path" == /* ]] || fail "--output must be an absolute path"

if [[ -e "$output_path" && "$force" -ne 1 ]]; then
    fail "output already exists; use --force only after reviewing its fingerprint"
fi
output_dir="$(dirname "$output_path")"
mkdir -p "$output_dir"
[[ -d "$output_dir" ]] || fail "output directory is not a directory"

work_dir="$(mktemp -d "${TMPDIR:-/tmp}/fuminiwa-sync-v2-ca.XXXXXX")"
root_pem="$work_dir/root.crt"
leaf_pem="$work_dir/leaf.crt"
leaf_chain="$work_dir/leaf-chain.txt"
capabilities_json="$work_dir/capabilities.json"
remote_temp="/tmp/fuminiwa-sync-v2-ca.$$.crt"

cleanup_remote() {
    ssh -o BatchMode=yes -o ConnectTimeout=10 "$ssh_user@$staging_host" \
        "rm -f -- '$remote_temp'" >/dev/null 2>&1 || true
}
trap 'cleanup_remote; rm -rf "$work_dir"' EXIT

# The exact v2 edge container and path are intentional. --user 0 is needed
# because Caddy's public CA is owned by the container root; no old container or
# volume name is accepted by this command.
ssh -tt -o ConnectTimeout=10 "$ssh_user@$staging_host" \
    "umask 077; sudo docker exec --user 0 fuminiwa-sync-v2-edge cat /data/caddy/pki/authorities/local/root.crt > '$remote_temp' && chmod 0644 '$remote_temp'" \
    || fail "could not stage the v2 Caddy root"
scp -q -o ConnectTimeout=10 "$ssh_user@$staging_host:$remote_temp" "$root_pem" \
    || fail "could not copy the staged v2 Caddy root"
cleanup_remote

openssl x509 -in "$root_pem" -noout >/dev/null \
    || fail "remote CA is not a valid X.509 certificate"
root_subject="$(openssl x509 -in "$root_pem" -noout -subject)"
root_fingerprint="$(openssl x509 -in "$root_pem" -noout -fingerprint -sha256 | cut -d= -f2-)"
root_constraints="$(openssl x509 -in "$root_pem" -noout -text | grep -F 'CA:TRUE' || true)"
[[ -n "$root_constraints" ]] || fail "remote certificate is not a CA certificate"

# Inspect the leaf SAN separately. The HTTP read-back below uses the exported
# CA with curl --cacert; no -k/--insecure mode is used.
openssl s_client -connect "$staging_host:$staging_port" \
    -servername "$staging_host" -showcerts < /dev/null \
    > "$leaf_chain" 2>/dev/null || true
awk '
    /-----BEGIN CERTIFICATE-----/ { capturing = 1 }
    capturing { print }
    /-----END CERTIFICATE-----/ && capturing { exit }
' "$leaf_chain" > "$leaf_pem"
openssl x509 -in "$leaf_pem" -noout >/dev/null \
    || fail "could not read the staging leaf certificate"
leaf_san="$(openssl x509 -in "$leaf_pem" -noout -text 2>/dev/null \
    | grep -A1 -F 'Subject Alternative Name' || true)"
printf '%s\n' "$leaf_san" | grep -Eq 'IP Address:192\.168\.11\.5([,[:space:]]|$)' \
    || fail "staging leaf SAN does not contain IP Address:192.168.11.5"
leaf_fingerprint="$(openssl x509 -in "$leaf_pem" -noout -fingerprint -sha256 | cut -d= -f2-)"

curl --fail --silent --show-error --location \
    --cacert "$root_pem" \
    --header 'x-fuminiwa-client-version: 0.1.0' \
    --output "$capabilities_json" \
    --write-out '%{http_code}' \
    "https://$staging_host:$staging_port/v1/auth/capabilities" \
    > "$work_dir/status" || fail "HTTPS auth capabilities read-back failed"
[[ "$(<"$work_dir/status")" == "200" ]] || fail "auth capabilities did not return HTTP 200"
jq -e '
    .authProtocolNamespace == "com.fuminiwa.auth" and
    .syncProtocolNamespace == "com.fuminiwa.snapshot-sync"
' "$capabilities_json" >/dev/null \
    || fail "auth capabilities namespace read-back did not match v2"

temporary_output="$output_dir/.$(basename "$output_path").$$.tmp"
install -m 0644 "$root_pem" "$temporary_output"
mv -f "$temporary_output" "$output_path"

printf 'exported CA: %s\n' "$output_path"
printf 'root subject: %s\n' "$root_subject"
printf 'root SHA-256 fingerprint: %s\n' "$root_fingerprint"
printf 'leaf SHA-256 fingerprint: %s\n' "$leaf_fingerprint"
printf 'leaf SAN: IP Address:192.168.11.5\n'
printf 'HTTPS auth capabilities: HTTP 200 (v2 namespaces verified)\n'
