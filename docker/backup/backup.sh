#!/bin/sh
set -euo pipefail

# Required env vars:
#   DATABASE_URL   — postgres connection string
#   S3_BUCKET      — target bucket name (e.g. my-umami-backups)
#   AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY, AWS_DEFAULT_REGION
#
# Optional:
#   S3_PREFIX      — path prefix inside the bucket (default: "umami")
#   RETAIN_DAYS    — how many days of backups to keep (default: 30)

S3_PREFIX="${S3_PREFIX:-umami}"
RETAIN_DAYS="${RETAIN_DAYS:-30}"
TIMESTAMP="$(date -u +%Y-%m-%dT%H-%M-%SZ)"
FILENAME="backup-${TIMESTAMP}.sql.gz"
S3_KEY="${S3_PREFIX}/${FILENAME}"

echo "[backup] starting — ${TIMESTAMP}"

pg_dump "${DATABASE_URL}" \
    --no-password \
    --format=plain \
    --no-owner \
    --no-acl \
    | gzip -9 \
    | aws s3 cp - "s3://${S3_BUCKET}/${S3_KEY}"

echo "[backup] uploaded s3://${S3_BUCKET}/${S3_KEY}"

# Remove backups older than RETAIN_DAYS
CUTOFF="$(date -u -d "${RETAIN_DAYS} days ago" +%Y-%m-%dT%H-%M-%SZ 2>/dev/null \
    || date -u -v-"${RETAIN_DAYS}d" +%Y-%m-%dT%H-%M-%SZ)"

echo "[backup] pruning backups older than ${RETAIN_DAYS} days (cutoff: ${CUTOFF})"

aws s3 ls "s3://${S3_BUCKET}/${S3_PREFIX}/" \
    | awk '{print $4}' \
    | while read -r key; do
        # filename format: backup-YYYY-MM-DDTHH-MM-SSZ.sql.gz
        file_ts="${key#backup-}"
        file_ts="${file_ts%.sql.gz}"
        if [ "${file_ts}" \< "${CUTOFF}" ]; then
            aws s3 rm "s3://${S3_BUCKET}/${S3_PREFIX}/${key}"
            echo "[backup] deleted s3://${S3_BUCKET}/${S3_PREFIX}/${key}"
        fi
    done

echo "[backup] done"
