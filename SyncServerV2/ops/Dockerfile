FROM alpine:3.23

# All dependencies are Alpine binaries; no pip, compiler or Rust build.
RUN apk add --no-cache python3 py3-cryptography docker-cli supercronic tzdata \
    && addgroup -g 1000 ops \
    && adduser -D -H -u 999 -G ops -h /tmp -s /sbin/nologin ops

ENV TZ=Asia/Tokyo BACKUP_TIME=03:17 PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1 DOCKER_CONFIG=/tmp/docker-config
WORKDIR /opt/fuminiwa-ops
COPY Scripts/operations/backup.py ./backup.py
COPY SyncServerV2/ops/ops.py ./ops.py
COPY SyncServerV2/ops/ops_web.py ./ops_web.py
COPY SyncServerV2/ops/entrypoint SyncServerV2/ops/run-backup SyncServerV2/ops/ops-healthcheck /usr/local/bin/
RUN chmod 755 /usr/local/bin/entrypoint /usr/local/bin/run-backup /usr/local/bin/ops-healthcheck

# Only the entrypoint starts as root to set the supplementary socket group.
# Before any scheduler/job starts, ops.py permanently drops to 999:1000.
HEALTHCHECK --interval=5m --timeout=10s --start-period=30s --retries=1 CMD ["ops-healthcheck"]
ENTRYPOINT ["entrypoint"]
