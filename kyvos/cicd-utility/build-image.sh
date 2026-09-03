#!/usr/bin/env bash
# One-time build (re-run whenever Kyvos ships a new utility version) of the
# Cloud Build image that bundles the Kyvos CI/CD Utility + Java + git.
#
# The utility zip is Kyvos vendor software and is intentionally NOT
# committed to this repo. Download it from your Kyvos support portal,
# upload it to a GCS bucket you control, and point BUNDLE_GCS_PATH at it.
set -euo pipefail

: "${BUNDLE_GCS_PATH:?set BUNDLE_GCS_PATH, e.g. gs://your-bucket/kyvos-cicd-utility.zip}"
: "${IMAGE:?set IMAGE, e.g. us-central1-docker.pkg.dev/PROJECT_ID/kyvos/cicd-utility:2023.5}"

cd "$(dirname "$0")"
rm -rf bundle && mkdir bundle
gsutil cp "$BUNDLE_GCS_PATH" ./utility.zip
unzip -q utility.zip -d bundle
rm utility.zip

# The zip may extract into a single nested folder (e.g. bundle/CICD_Utility_2023.5/...)
# -- flatten it so bundle/ directly contains Conf/, Input/, Lib/, *.sh.
if [ "$(find bundle -mindepth 1 -maxdepth 1 | wc -l)" -eq 1 ] && [ -d "$(find bundle -mindepth 1 -maxdepth 1)" ]; then
  inner="$(find bundle -mindepth 1 -maxdepth 1)"
  mv "$inner"/* bundle/
  rmdir "$inner"
fi

docker build -t "$IMAGE" .
docker push "$IMAGE"

echo "Pushed $IMAGE"
