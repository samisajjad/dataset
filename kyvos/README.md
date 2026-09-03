# Kyvos CI/CD (GCP: Cloud Build, Secret Manager, Scheduler, Artifact Registry)

Two ways Kyvos gets objects out of a deployment, and this repo supports
both -- use whichever you actually have access to today, switch to the
other later with no rework:

| | **Phase 1 -- works today** | **Phase 2 -- needs one more thing** |
|---|---|---|
| Export mechanism | Kyvos UI "Export All Objects" dialog (Entities > Export), manual click, downloads a `.cab` (Cabinet archive) | Official CI/CD Utility (`ExportKyvosEntities.sh`), headless, Java + REST API |
| Where it runs | Your laptop | Cloud Build, on a schedule |
| Versioning | You commit the `.cab` to Git yourself | The utility pushes to Git itself |
| Deploy to QA/PROD | Manual: a Kyvos admin uploads the same `.cab` via the Kyvos UI's Import dialog | Automated: Cloud Build runs `ImportKyvosEntities.sh` on every push to `qa`/`prod` |
| What's missing | Nothing -- usable right now | The Kyvos CI/CD Utility bundle (zip) from Kyvos support -- **check with your Kyvos admin whether your org already has it** |

Both phases share the same Git repo, branches (`dev`/`qa`/`prod`), and CI
validation -- Phase 2 just automates the two manual steps Phase 1 still
has (export-to-git, and import-to-target).

## Layout
```
kyvos/
  cicd-utility/           Phase 2: Dockerfile + build script for the Cloud
                           Build image (Java + git + the Kyvos utility bundle)
  config/
    input-export-dev.json     Phase 2: what to export from DEV, and where to push it
    input-import-qa.json      Phase 2: what to import into QA
    input-import-prod.json    Phase 2: same, for PROD
  cloudbuild/
    cloudbuild-ci.yaml        Both phases: validates entity files (.xml/.cab) on every push
    cloudbuild-export.yaml    Phase 2: runs Export Utility against Kyvos DEV (scheduled)
    cloudbuild-import.yaml    Phase 2: runs Import Utility against QA or PROD (triggered)
  scripts/
    add_export.sh            Phase 1: stages a downloaded .cab into the repo + prints git commands
    validate.sh               Both phases: the actual CI check
  dev/ qa/ prod/             Where exported entities land (.cab and/or .xml), per environment
```

## Phase 1 -- set up now (no vendor bundle needed)

### 1. Enable APIs
```bash
gcloud services enable cloudbuild.googleapis.com --project=PROJECT_ID
```

### 2. Connect the GitHub repo and create CI triggers
```bash
gcloud builds connections create github kyvos-connection --region=REGION --project=PROJECT_ID
gcloud builds repositories create dataset-repo \
  --connection=kyvos-connection --region=REGION --project=PROJECT_ID \
  --remote-uri=https://github.com/samisajjad/dataset.git

for ENV in dev qa prod; do
  gcloud builds triggers create github \
    --name="kyvos-ci-${ENV}" --project=PROJECT_ID --region=REGION \
    --repository=dataset-repo --branch-pattern="^${ENV}$" \
    --build-config=kyvos/cloudbuild/cloudbuild-ci.yaml \
    --substitutions=_ENV=${ENV}
done
```

### 3. Day-to-day workflow (Phase 1)
1. In Kyvos DEV, use Entities > Export > "Export All Objects", fill in
   Name/Author/Version/Description, click **Export & Download** -- a
   `.cab` lands in your Downloads.
2. Stage it into the repo:
   ```
   kyvos/scripts/add_export.sh --env dev --file ~/Downloads/Dev.cab
   ```
3. `git add`, `git commit` (reuse the Description you typed in Kyvos as
   the commit message), `git push` as the script tells you.
4. Push to `dev` triggers **CI** (`cloudbuild-ci.yaml`) -- confirms the
   `.cab` is present and not corrupt.
5. To promote: PR `dev` -> `qa`. After merge, a Kyvos admin manually opens
   the Kyvos QA UI's Import dialog and uploads that same `.cab` (choose
   Overwrite unless you specifically mean to remove objects, in which
   case use the Delete option from the Export dialog when the package was
   created). Same for `qa` -> `prod`.
6. **Rollback**: check out the `.cab` from an older commit and re-import it
   via the UI the same way.

This gets you real version history, PR review, and a validated promotion
path today -- the only manual step left is the actual upload into
QA/PROD, which Phase 2 automates.

## Phase 2 -- once you have the CI/CD Utility bundle

### 1. Get the bundle and build the Cloud Build image
Ask your Kyvos admin for the CI/CD Utility zip (Conf/, Input/, Lib/,
`ExportKyvosEntities.sh`, `ImportKyvosEntities.sh`). It's vendor software,
not committed to this repo -- upload it to a GCS bucket you control, then:
```bash
gcloud services enable secretmanager.googleapis.com artifactregistry.googleapis.com \
  cloudscheduler.googleapis.com --project=PROJECT_ID

BUNDLE_GCS_PATH=gs://your-bucket/kyvos-cicd-utility.zip \
IMAGE=us-central1-docker.pkg.dev/PROJECT_ID/kyvos/cicd-utility:latest \
  kyvos/cicd-utility/build-image.sh
```
Re-run this whenever Kyvos ships a new utility version.

### 2. Confirm network reachability
Both utilities call `<KYVOS_URL>/rest/...` directly from inside the Cloud
Build step -- there's no SSH hop. If your Kyvos server isn't reachable
from Cloud Build's default pool (e.g. it's on a private network), you'll
need a [Cloud Build private pool](https://cloud.google.com/build/docs/private-pools/private-pools-overview)
peered into that network, and to add `pool: {name: ...}` under `options`
in each `cloudbuild-*.yaml`.

### 3. Store credentials in Secret Manager
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

### 4. Create the export/import triggers
```bash
# Import: triggered on push to qa/prod, manual approval required
for ENV in qa prod; do
  gcloud builds triggers create github \
    --name="kyvos-import-${ENV}" --project=PROJECT_ID --region=REGION \
    --repository=dataset-repo --branch-pattern="^${ENV}$" \
    --build-config=kyvos/cloudbuild/cloudbuild-import.yaml \
    --substitutions=_ENV=${ENV},_UTILITY_IMAGE=us-central1-docker.pkg.dev/PROJECT_ID/kyvos/cicd-utility:latest \
    --require-approval
done

# Export: a manual (non-branch) trigger, fired on a schedule
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
Or run the export on demand: `gcloud builds triggers run kyvos-export-dev --branch=dev --region=REGION --project=PROJECT_ID`.

### Day-to-day workflow (Phase 2)
1. The nightly (or on-demand) export job runs `ExportKyvosEntities.sh`
   against Kyvos DEV, which writes XML into `kyvos/dev/` and pushes it
   itself to the `kyvos-dev-export` branch.
2. Review the diff, open a PR into `dev`, merge -- triggers CI.
3. Promote: PR `dev` -> `qa`. Merging triggers CI *and* the **Import**
   pipeline, gated by manual approval -- it calls `ImportKyvosEntities.sh`
   against Kyvos QA using the files Cloud Build just checked out. Same for
   `qa` -> `prod`.
4. **Rollback**: `git revert` (or check out an older commit) on `qa`/`prod`
   and push/re-run the trigger -- Import re-applies that older XML.

## Approving a QA/PROD deploy (Phase 2)
```bash
gcloud builds list --project=PROJECT_ID --filter='status=PENDING_APPROVAL'
gcloud builds approve BUILD_ID --project=PROJECT_ID
```

## What's still unverified in Phase 2 (test on a real run before trusting this in prod)
- **GitHub vs GitLab for the Export Utility's git push**: Kyvos's doc only
  documents GitLab/Bitbucket. The utility appears to just shell out to
  plain `git` with a token-based HTTPS remote, which should work
  identically against GitHub, but this hasn't been confirmed against your
  actual utility build.
- **Exact XML folder layout** the Export Utility writes -- `validate.sh`
  searches recursively (`kyvos/<env>/**/*.xml`) so it doesn't assume a
  specific layout, but confirm after your first real export.
- **Java version**: the Dockerfile uses a Java 11 JRE as a reasonable
  default -- adjust `kyvos/cicd-utility/Dockerfile` if the bundle needs
  something else.
- Whether `${_ENV}` substitution resolves inside
  `availableSecrets.secretManager[].versionName` in your Cloud Build
  version -- if a trigger fails on secret access, hardcode three separate
  `cloudbuild-import-<env>.yaml` files instead of parameterizing.
