# Cloud Build image carrying what the Kyvos CI/CD Utility needs: a JRE,
# git (the Export Utility shells out to git itself), and the utility
# bundle (Conf/, Input/, Lib/, ExportKyvosEntities.sh, ImportKyvosEntities.sh)
# obtained from Kyvos.
#
# The bundle is vendor software, not checked into this repo -- build-image.sh
# fetches it from a GCS bucket you control into ./bundle before `docker build`
# runs, so COPY below just picks up whatever build-image.sh staged.
FROM eclipse-temurin:11-jre-jammy

RUN apt-get update && apt-get install -y --no-install-recommends git ca-certificates unzip \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /opt/kyvos-cicd
COPY bundle/ ./
RUN chmod +x ExportKyvosEntities.sh ImportKyvosEntities.sh \
    && git config --global user.email "kyvos-cicd-bot@example.com" \
    && git config --global user.name "kyvos-cicd-bot" \
    && git config --global --add safe.directory '*'
