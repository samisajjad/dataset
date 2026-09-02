#!/usr/bin/env bash
# Run this on YOUR LAPTOP, right after exporting an object from the Kyvos
# web UI (Entities > pick object > Export). The UI downloads a .cap file
# to your local machine -- this script drops it into the right folder in
# this repo so it can be committed and versioned.
set -euo pipefail

ENV=""
CAP_FILE=""
REPO_ROOT="$(git rev-parse --show-toplevel)"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --env) ENV="$2"; shift 2 ;;
    --cap-file) CAP_FILE="$2"; shift 2 ;;
    *) echo "Unknown arg: $1" >&2; exit 1 ;;
  esac
done

: "${ENV:?--env is required (dev, qa, or prod)}"
: "${CAP_FILE:?--cap-file is required, e.g. ~/Downloads/retail-rso-dv.cap}"

if [ ! -f "$CAP_FILE" ]; then
  echo "File not found: $CAP_FILE" >&2
  exit 1
fi

DEST_DIR="$REPO_ROOT/kyvos/${ENV}"
mkdir -p "$DEST_DIR"
DEST_FILE="$DEST_DIR/$(basename "$CAP_FILE")"
cp "$CAP_FILE" "$DEST_FILE"

echo "Copied to $DEST_FILE"
echo
echo "Next steps:"
echo "  cd $REPO_ROOT"
echo "  git add kyvos/${ENV}/$(basename "$CAP_FILE")"
echo "  git commit -m \"kyvos(${ENV}): describe what changed in this object\""
echo "  git push"
