#!/usr/bin/env bash
# Phase 1 (works today, no CLI bundle needed): run this on YOUR LAPTOP right
# after using Kyvos's "Export All Objects" dialog (Entities > Export), which
# downloads a .cab package (e.g. "Dev.cab") to your machine. This drops it
# into the right folder in this repo so it can be committed and versioned.
#
# Once the official CI/CD Utility bundle is available (see
# kyvos/cicd-utility/README.md), Phase 2 makes this manual step optional --
# ExportKyvosEntities.sh does the export AND the git push on its own.
set -euo pipefail

ENV=""
FILE=""
REPO_ROOT="$(git rev-parse --show-toplevel)"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --env) ENV="$2"; shift 2 ;;
    --file) FILE="$2"; shift 2 ;;
    *) echo "Unknown arg: $1" >&2; exit 1 ;;
  esac
done

: "${ENV:?--env is required (dev, qa, or prod)}"
: "${FILE:?--file is required, e.g. ~/Downloads/Dev.cab}"

if [ ! -f "$FILE" ]; then
  echo "File not found: $FILE" >&2
  exit 1
fi

DEST_DIR="$REPO_ROOT/kyvos/${ENV}"
mkdir -p "$DEST_DIR"
DEST_FILE="$DEST_DIR/$(basename "$FILE")"
cp "$FILE" "$DEST_FILE"

echo "Copied to $DEST_FILE"
echo
echo "Next steps:"
echo "  cd $REPO_ROOT"
echo "  git add kyvos/${ENV}/$(basename "$FILE")"
echo "  git commit -m \"kyvos(${ENV}): <the Description you typed in the Export dialog>\""
echo "  git push"
echo
echo "Tip: reuse the Name/Version/Description you entered in Kyvos's Export"
echo "dialog as your commit message -- that's the same information, just"
echo "recorded in Git instead of typed into the dialog each time."
