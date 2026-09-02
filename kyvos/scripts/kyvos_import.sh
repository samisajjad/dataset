#!/usr/bin/env bash
# Runs ON the Kyvos server, invoked remotely by Cloud Build over SSH/IAP.
# Deploys the object files Cloud Build just scp'd in to the target
# environment's Kyvos instance.
set -euo pipefail

ENV=""
IN_DIR=""
KYVOS_UTIL_HOME="${KYVOS_UTIL_HOME:-/opt/kyvos/cicd-utility}"
PROJECT_ID="${PROJECT_ID:?PROJECT_ID env var must be set}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --env) ENV="$2"; shift 2 ;;
    --in-dir) IN_DIR="$2"; shift 2 ;;
    *) echo "Unknown arg: $1" >&2; exit 1 ;;
  esac
done

: "${ENV:?--env is required}"
: "${IN_DIR:?--in-dir is required}"

KYVOS_HOST="$(gcloud secrets versions access latest --secret="kyvos-${ENV}-host" --project="$PROJECT_ID")"
KYVOS_USER="$(gcloud secrets versions access latest --secret="kyvos-${ENV}-user" --project="$PROJECT_ID")"
KYVOS_PASSWORD="$(gcloud secrets versions access latest --secret="kyvos-${ENV}-password" --project="$PROJECT_ID")"

"$KYVOS_UTIL_HOME/KyvosCICDUtility.sh" \
  -operation import \
  -host "$KYVOS_HOST" \
  -username "$KYVOS_USER" \
  -password "$KYVOS_PASSWORD" \
  -configFile "$KYVOS_UTIL_HOME/config/import-${ENV}.properties" \
  -importPath "$IN_DIR"
