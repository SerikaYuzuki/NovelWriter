#!/bin/sh
set -eu

# Prepare a v2-only runtime copy of the operator-owned secrets.  Compose
# mounts file-backed secrets as bind mounts on this deployment, so the source
# file's ownership is visible inside the container.  The server image runs as
# numeric uid/gid 10001 and must not depend on world-readable host files.
#
# Usage (as root on the staging host):
#   prepare-runtime-secrets.sh SOURCE_DIR RUNTIME_DIR
#
# SOURCE_DIR is never modified.  RUNTIME_DIR must be a separate directory;
# the ten files are replaced atomically and remain mode 0400, owned by
# 10001:10001.  Do not put either directory in the repository.

if [ "$#" -ne 2 ]; then
    echo "usage: $0 SOURCE_DIR RUNTIME_DIR" >&2
    exit 64
fi

source_dir=$1
runtime_dir=$2

if [ ! -d "$source_dir" ]; then
    echo "secret source directory does not exist" >&2
    exit 66
fi
if [ "$source_dir" = "$runtime_dir" ]; then
    echo "source and runtime secret directories must differ" >&2
    exit 65
fi
if [ -L "$runtime_dir" ]; then
    echo "runtime secret directory must not be a symlink" >&2
    exit 65
fi

secret_names='postgres-init-password
bootstrap-admin-password
bootstrap-password
migration-owner-password
runtime-password
auth-vault-key
auth-vault-keyring
auth-subject-hmac-key
auth-token-hmac-key
apple-sign-in-key.p8'

# Validate every input before replacing any runtime copy.  A rotation with a
# missing file must fail without leaving a mixed generation behind.
for name in $secret_names; do
    source_file="$source_dir/$name"
    if [ ! -f "$source_file" ] || [ -L "$source_file" ]; then
        echo "missing or symlinked secret: $name" >&2
        exit 66
    fi
done

mkdir -p "$runtime_dir"
chmod 700 "$runtime_dir"

for name in $secret_names; do
    source_file="$source_dir/$name"
    target_file="$runtime_dir/$name"
    temporary_file="$runtime_dir/.$name.tmp.$$"
    trap 'rm -f "$temporary_file"' EXIT HUP INT TERM
    install -o 10001 -g 10001 -m 0400 "$source_file" "$temporary_file"
    mv -f "$temporary_file" "$target_file"
    trap - EXIT HUP INT TERM
done

chmod 700 "$runtime_dir"
