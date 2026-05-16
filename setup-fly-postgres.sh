#!/usr/bin/env bash
# Sets up a self-hosted (unmanaged) PostgreSQL app on fly.io.
# Run this script once from your local machine with the fly CLI installed and authenticated.
set -euo pipefail

POSTGRES_APP="${POSTGRES_APP:-umami-db}"
MAIN_APP="${MAIN_APP:-umami-falling-waterfall-1667}"
REGION="${REGION:-fra}"
VOLUME_SIZE="${VOLUME_SIZE:-3}"  # GB

if [ -z "${POSTGRES_PASSWORD:-}" ]; then
  echo "ERROR: Set POSTGRES_PASSWORD before running this script."
  echo "  export POSTGRES_PASSWORD=<your-secure-password>"
  exit 1
fi

echo "==> Creating postgres app: $POSTGRES_APP"
fly apps create "$POSTGRES_APP" --org personal

echo "==> Creating persistent volume ($VOLUME_SIZE GB) in $REGION"
fly volumes create umami_pgdata \
  --region "$REGION" \
  --size "$VOLUME_SIZE" \
  --app "$POSTGRES_APP"

echo "==> Setting postgres password secret"
fly secrets set POSTGRES_PASSWORD="$POSTGRES_PASSWORD" --app "$POSTGRES_APP"

echo "==> Deploying postgres"
fly deploy --config fly.postgres.toml --app "$POSTGRES_APP"

echo "==> Setting DATABASE_URL on main app"
fly secrets set \
  DATABASE_URL="postgresql://umami:${POSTGRES_PASSWORD}@${POSTGRES_APP}.internal:5432/umami" \
  --app "$MAIN_APP"

echo ""
echo "Done. Deploy the main app to apply the new DATABASE_URL:"
echo "  fly deploy --config fly.toml"
