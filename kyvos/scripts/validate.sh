#!/usr/bin/env bash
# CI check: runs inside Cloud Build. Confirms every entity XML file the
# Export Utility pushed for this environment is present and well-formed,
# before the Import Utility ever touches it.
set -euo pipefail

ENV="${1:?usage: validate.sh <env>}"
ENV_DIR="kyvos/${ENV}"

if [ ! -d "$ENV_DIR" ]; then
  echo "Missing folder: $ENV_DIR" >&2
  exit 1
fi

shopt -s globstar nullglob
xmls=("$ENV_DIR"/**/*.xml)

if [ ${#xmls[@]} -eq 0 ]; then
  echo "No entity XML files found under $ENV_DIR" >&2
  exit 1
fi

fail=0
for f in "${xmls[@]}"; do
  if ! python3 -c "import xml.dom.minidom as m,sys; m.parse(sys.argv[1])" "$f"; then
    echo "Invalid XML: $f" >&2
    fail=1
  fi
done

if [ "$fail" -ne 0 ]; then
  echo "Validation FAILED for $ENV_DIR" >&2
  exit 1
fi

echo "Validation passed for $ENV_DIR (${#xmls[@]} files)"
