#!/usr/bin/env bash
# CI check: runs inside Cloud Build (not on the Kyvos server).
# Confirms the environment folder exists and every exported object file
# is well-formed, before anything gets deployed.
set -euo pipefail

ENV="${1:?usage: validate.sh <env>}"
ENV_DIR="kyvos/${ENV}"

if [ ! -d "$ENV_DIR" ]; then
  echo "Missing folder: $ENV_DIR" >&2
  exit 1
fi

fail=0

while IFS= read -r -d '' f; do
  if ! python3 -c "import json,sys; json.load(open(sys.argv[1]))" "$f"; then
    echo "Invalid JSON: $f" >&2
    fail=1
  fi
done < <(find "$ENV_DIR" -name '*.json' -print0)

while IFS= read -r -d '' f; do
  if ! python3 -c "import xml.dom.minidom as m,sys; m.parse(sys.argv[1])" "$f"; then
    echo "Invalid XML: $f" >&2
    fail=1
  fi
done < <(find "$ENV_DIR" -name '*.xml' -print0)

if [ "$fail" -ne 0 ]; then
  echo "Validation FAILED for $ENV_DIR" >&2
  exit 1
fi

echo "Validation passed for $ENV_DIR"
