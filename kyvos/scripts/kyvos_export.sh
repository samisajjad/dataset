#!/usr/bin/env bash
# Runs ON the Kyvos server. Exports objects from a Kyvos environment into a
# folder that Cloud Build later copies back to Git for versioning.
#
# Credentials/host are never passed in as CLI args (they'd show in shell
# history / process list) -- they are pulled from Secret Manager at runtime,
# using the VM's own service account.
set -euo pipefail

ENV=""
OUT_DIR=""
KYVOS_UTIL_HOME="${KYVOS_UTIL_HOME:-/opt/kyvos/cicd-utility}"
PROJECT_ID="${PROJECT_ID:?PROJECT_ID env var must be set}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --env) ENV="$2"; shift 2 ;;
    --out-dir) OUT_DIR="$2"; shift 2 ;;
    *) echo "Unknown arg: $1" >&2; exit 1 ;;
  esac
done

: "${ENV:?--env is required}"
: "${OUT_DIR:?--out-dir is required}"

KYVOS_HOST="$(gcloud secrets versions access latest --secret="kyvos-${ENV}-host" --project="$PROJECT_ID")"
KYVOS_USER="$(gcloud secrets versions access latest --secret="kyvos-${ENV}-user" --project="$PROJECT_ID")"
KYVOS_PASSWORD="$(gcloud secrets versions access latest --secret="kyvos-${ENV}-password" --project="$PROJECT_ID")"

mkdir -p "$OUT_DIR"

"$KYVOS_UTIL_HOME/KyvosCICDUtility.sh" \
  -operation export \
  -host "$KYVOS_HOST" \
  -username "$KYVOS_USER" \
  -password "$KYVOS_PASSWORD" \
  -configFile "$KYVOS_UTIL_HOME/config/export-${ENV}.properties" \
  -exportPath "$OUT_DIR"
