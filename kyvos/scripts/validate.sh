#!/usr/bin/env bash
# CI check: runs inside Cloud Build. Confirms every entity file committed
# for this environment is present and well-formed before anything deploys.
#
# Two formats can show up here, depending on which Kyvos export path was
# used (see kyvos/README.md):
#   - *.xml   -- from the official Export Utility (Phase 2, CLI bundle)
#   - *.cab   -- from the Kyvos UI's "Export All Objects" dialog (Phase 1,
#                works today without the CLI bundle). A .cab is a Microsoft
#                Cabinet archive, not a zip -- validated with `cabextract`
#                if available, otherwise just a size/presence check.
set -euo pipefail

ENV="${1:?usage: validate.sh <env>}"
ENV_DIR="kyvos/${ENV}"

if [ ! -d "$ENV_DIR" ]; then
  echo "Missing folder: $ENV_DIR" >&2
  exit 1
fi

shopt -s globstar nullglob
xmls=("$ENV_DIR"/**/*.xml)
cabs=("$ENV_DIR"/**/*.cab)

if [ ${#xmls[@]} -eq 0 ] && [ ${#cabs[@]} -eq 0 ]; then
  echo "No entity files (.xml or .cab) found under $ENV_DIR" >&2
  exit 1
fi

fail=0

for f in "${xmls[@]}"; do
  if ! python3 -c "import xml.dom.minidom as m,sys; m.parse(sys.argv[1])" "$f"; then
    echo "Invalid XML: $f" >&2
    fail=1
  fi
done

for f in "${cabs[@]}"; do
  size=$(stat -c%s "$f" 2>/dev/null || stat -f%z "$f")
  if [ "$size" -eq 0 ]; then
    echo "Empty file: $f" >&2
    fail=1
    continue
  fi
  if command -v cabextract >/dev/null 2>&1; then
    if ! cabextract -t "$f" >/dev/null 2>&1; then
      echo "Corrupt cabinet file: $f" >&2
      fail=1
      continue
    fi
  fi
  echo "OK (${size} bytes): $f"
done

if [ "$fail" -ne 0 ]; then
  echo "Validation FAILED for $ENV_DIR" >&2
  exit 1
fi

echo "Validation passed for $ENV_DIR (${#xmls[@]} XML, ${#cabs[@]} CAB)"
