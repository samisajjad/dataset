#!/usr/bin/env bash
# CI check: runs inside Cloud Build (not on the Kyvos server).
# .cap files are a binary/proprietary format, so this can't validate their
# *content* -- it just confirms something real was committed for this
# environment before CD tries to deploy it.
set -euo pipefail

ENV="${1:?usage: validate.sh <env>}"
ENV_DIR="kyvos/${ENV}"

if [ ! -d "$ENV_DIR" ]; then
  echo "Missing folder: $ENV_DIR" >&2
  exit 1
fi

shopt -s nullglob
caps=("$ENV_DIR"/*.cap)
if [ ${#caps[@]} -eq 0 ]; then
  echo "No .cap files found under $ENV_DIR" >&2
  exit 1
fi

fail=0
for f in "${caps[@]}"; do
  size=$(stat -c%s "$f" 2>/dev/null || stat -f%z "$f")
  if [ "$size" -eq 0 ]; then
    echo "Empty file: $f" >&2
    fail=1
    continue
  fi
  # Many capsule/package formats are zip containers under the hood. If
  # `unzip` recognizes it, verify the archive isn't corrupt; if it's not
  # a zip at all, this is just a non-fatal heads-up.
  if command -v unzip >/dev/null 2>&1 && ! unzip -tq "$f" >/dev/null 2>&1; then
    echo "Note: $f does not validate as a zip archive (may not be zip-based -- not necessarily an error)"
  fi
  echo "OK (${size} bytes): $f"
done

if [ "$fail" -ne 0 ]; then
  echo "Validation FAILED for $ENV_DIR" >&2
  exit 1
fi

echo "Validation passed for $ENV_DIR"
