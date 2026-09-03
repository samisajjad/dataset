# Kyvos CI/CD (Cloud Build, replacing GitLab+Jenkins)

Kyvos's own CI/CD Utility (Java-based, REST API driven) does the real work:
**Export Utility** pulls entities (Semantic Models, Dataset Relationships,
Datasets, Workbooks) out of a Kyvos deployment as XML and pushes them to
Git; **Import Utility** reads entity XML from a local folder and pushes it
into a target Kyvos deployment over REST. Kyvos's official runbook wires
these up with GitLab + Jenkins. We don't have either -- this repo wires the
same two scripts up with **GitHub + Cloud Build** instead:

- Jenkins's job (detect a push, check out the changed files, run
  `ImportKyvosEntities.sh`) is exactly what a **Cloud Build trigger**
  already does natively -- no Jenkins needed.
- The Export Utility's own `git push` doesn't fire from a git event (Kyvos
  changes happen inside Kyvos, not in the repo) -- it runs on a
  **Cloud Scheduler cadence** instead, pushing to a review branch.

## Layout
```
kyvos/
  cicd-utility/         Dockerfile + build script for the Cloud Build image
                         that carries Java + git + the Kyvos utility bundle
  config/
    input-export-dev.json     what to export from DEV, and where to push it
    input-import-qa.json      what to import into QA (ALL, from the folder Cloud Build checks out)
    input-import-prod.json    same, for PROD
  cloudbuild/
    cloudbuild-ci.yaml        validates entity XML on every push
    cloudbuild-export.yaml    runs Export Utility against Kyvos DEV (scheduled)
    cloudbuild-import.yaml    runs Import Utility against QA or PROD (triggered)
  scripts/validate.sh         the actual CI check
  dev/ qa/ prod/               where exported entity XML lands, per environment
```

## One-time setup

### 1. Get the utility bundle and build the Cloud Build image
The Kyvos CI/CD Utility zip is vendor software -- it's not in this repo.
Download it from your Kyvos support portal, upload it to a GCS bucket you
control, then:
```bash
BUNDLE_GCS_PATH=gs://your-bucket/kyvos-cicd-utility.zip \
IMAGE=us-central1-docker.pkg.dev/PROJECT_ID/kyvos/cicd-utility:latest \
  kyvos/cicd-utility/build-image.sh
```
Re-run this whenever Kyvos ships a new utility version.

### 2. Confirm network reachability
Both the Export Utility (against Kyvos DEV) and Import Utility (against
QA/PROD) call `<KYVOS_URL>/rest/...` directly from inside the Cloud Build
step -- there's no SSH hop. If your Kyvos server isn't reachable from
Cloud Build's default pool (e.g. it's on a private network), you'll need
a [Cloud Build private pool](https://cloud.google.com/build/docs/private-pools/private-pools-overview)
peered into that network, and to add `pool: {name: ...}` under `options`
in each `cloudbuild-*.yaml`.

### 3. Enable APIs
```bash
gcloud services enable cloudbuild.googleapis.com secretmanager.googleapis.com \
  artifactregistry.googleapis.com cloudscheduler.googleapis.com --project=PROJECT_ID
```

### 4. Store credentials in Secret Manager
```bash
for ENV in dev qa prod; do
  # KYVOS_URL must include /rest/, e.g. https://kyvos.yourcompany.com/rest/
  echo -n "https://kyvos-${ENV}.yourcompany.com/rest/" | gcloud secrets create kyvos-${ENV}-url --data-file=- --project=PROJECT_ID
  echo -n "cicd_service_user"                          | gcloud secrets create kyvos-${ENV}-user --data-file=- --project=PROJECT_ID
  echo -n "REPLACE_WITH_REAL_PASSWORD"                  | gcloud secrets create kyvos-${ENV}-password --data-file=- --project=PROJECT_ID
done

# GitHub Personal Access Token (repo scope), used by the Export Utility's own git push
echo -n "REPLACE_WITH_GITHUB_PAT" | gcloud secrets create kyvos-git-token --data-file=- --project=PROJECT_ID

CB_SA=$(gcloud projects describe PROJECT_ID --format='value(projectNumber)')@cloudbuild.gserviceaccount.com
for SECRET in kyvos-dev-url kyvos-dev-user kyvos-dev-password \
              kyvos-qa-url kyvos-qa-user kyvos-qa-password \
              kyvos-prod-url kyvos-prod-user kyvos-prod-password \
              kyvos-git-token; do
  gcloud secrets add-iam-policy-binding $SECRET \
    --member="serviceAccount:${CB_SA}" --role="roles/secretmanager.secretAccessor" \
    --project=PROJECT_ID
done
```
Use a Kyvos account with **administrative privileges** for these (per
Kyvos's own recommendation, needed to import/export all entity types).

### 5. Connect the GitHub repo and create triggers
```bash
gcloud builds connections create github kyvos-connection --region=REGION --project=PROJECT_ID
gcloud builds repositories create dataset-repo \
  --connection=kyvos-connection --region=REGION --project=PROJECT_ID \
  --remote-uri=https://github.com/samisajjad/dataset.git

# CI: validate entity XML on every push, one trigger per branch
for ENV in dev qa prod; do
  gcloud builds triggers create github \
    --name="kyvos-ci-${ENV}" --project=PROJECT_ID --region=REGION \
    --repository=dataset-repo --branch-pattern="^${ENV}$" \
    --build-config=kyvos/cloudbuild/cloudbuild-ci.yaml \
    --substitutions=_ENV=${ENV}
done

# Import: triggered on push to qa/prod, manual approval required
for ENV in qa prod; do
  gcloud builds triggers create github \
    --name="kyvos-import-${ENV}" --project=PROJECT_ID --region=REGION \
    --repository=dataset-repo --branch-pattern="^${ENV}$" \
    --build-config=kyvos/cloudbuild/cloudbuild-import.yaml \
    --substitutions=_ENV=${ENV},_UTILITY_IMAGE=us-central1-docker.pkg.dev/PROJECT_ID/kyvos/cicd-utility:latest \
    --require-approval
done
```

### 6. Schedule the Export job
```bash
# A manual (non-branch) trigger that cloudbuild-export.yaml runs from
gcloud builds triggers create manual \
  --name="kyvos-export-dev" --project=PROJECT_ID --region=REGION \
  --repository=dataset-repo --branch=dev \
  --build-config=kyvos/cloudbuild/cloudbuild-export.yaml

TRIGGER_ID=$(gcloud builds triggers list --project=PROJECT_ID --region=REGION \
  --filter='name=kyvos-export-dev' --format='value(id)')

gcloud scheduler jobs create http kyvos-export-dev-nightly \
  --project=PROJECT_ID --location=REGION \
  --schedule="0 2 * * *" \
  --uri="https://cloudbuild.googleapis.com/v1/projects/PROJECT_ID/locations/REGION/triggers/${TRIGGER_ID}:run" \
  --http-method=POST \
  --oauth-service-account-email="$(gcloud projects describe PROJECT_ID --format='value(projectNumber)')-compute@developer.gserviceaccount.com"
```
Or just run it on demand: `gcloud builds triggers run kyvos-export-dev --branch=dev --region=REGION --project=PROJECT_ID`.

## Day-to-day workflow
1. Someone changes an object in Kyvos DEV.
2. The nightly (or on-demand) export job runs `ExportKyvosEntities.sh`
   against Kyvos DEV, which writes XML into `kyvos/dev/` and pushes it
   itself to the `kyvos-dev-export` branch.
3. Review the diff on `kyvos-dev-export`, open a PR into `dev`, merge.
4. Push to `dev` triggers **CI** (`cloudbuild-ci.yaml`) -- confirms the XML
   is well-formed.
5. Promote: PR `dev` -> `qa`. Merging triggers CI *and* the **Import**
   pipeline (`cloudbuild-import.yaml`, `_ENV=qa`), gated by manual approval
   -- it calls `ImportKyvosEntities.sh` against Kyvos QA using exactly the
   files Cloud Build just checked out into `kyvos/qa/`. Same for `qa` -> `prod`.
6. **Rollback**: `git revert` (or check out an older commit) on `qa`/`prod`
   and push/re-run the trigger -- Import re-applies that older XML.

## Approving a QA/PROD deploy
```bash
gcloud builds list --project=PROJECT_ID --filter='status=PENDING_APPROVAL'
gcloud builds approve BUILD_ID --project=PROJECT_ID
```

## What's still unverified (test on a real run before trusting this in prod)
- **GitHub vs GitLab for the Export Utility's git push**: Kyvos's doc only
  documents GitLab/Bitbucket. The utility appears to just shell out to
  plain `git` with a token-based HTTPS remote, which should work
  identically against GitHub, but this hasn't been confirmed against your
  actual utility build -- test `cloudbuild-export.yaml` once and check
  whether it successfully pushes to `kyvos-dev-export` on GitHub.
- **Exact XML folder layout** Export Utility writes under
  `GIT_LOCAL_REPO_PATH` (e.g. whether it creates `SemanticModels/`,
  `Datasets/` subfolders) -- `validate.sh` searches recursively
  (`kyvos/<env>/**/*.xml`) so it doesn't assume a specific layout, but
  confirm after your first real export.
- **Java version**: the Dockerfile uses a Java 11 JRE as a reasonable
  default for a modern enterprise Java utility -- if the bundle needs a
  different version, adjust the base image in `kyvos/cicd-utility/Dockerfile`.
- Whether `${_ENV}` substitution resolves correctly inside
  `availableSecrets.secretManager[].versionName` in your Cloud Build
  version -- if a trigger fails on secret access, hardcode three separate
  `cloudbuild-import-<env>.yaml` files instead of parameterizing.
