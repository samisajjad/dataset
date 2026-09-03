# Kyvos CI/CD POC -- Quick Start (one pipeline, `dev` only)

This is the minimum setup to prove the pipeline works: export an object
from Kyvos, version it in Git, have Cloud Build validate it automatically.
No QA/PROD branches, no Kyvos CI/CD Utility bundle needed -- everything
here uses what you already have access to.

```
Kyvos DEV UI --Export All Objects--> .cab downloaded to your laptop
      |
      v
kyvos/scripts/add_export.sh   (stages the .cab into kyvos/dev/, prints git commands)
      |
      v
git push (dev branch)
      |
      v
Cloud Build trigger "kyvos-ci-dev" runs cloudbuild-ci.yaml
      |
      v
validate.sh confirms the .cab is present and not corrupt
```

Replace `PROJECT_ID` below with your real GCP project ID. Region:
`europe-west1`.

## One-time setup

### 1. Enable the API
```bash
gcloud services enable cloudbuild.googleapis.com --project=PROJECT_ID
```

### 2. Connect this GitHub repo to Cloud Build
```bash
gcloud builds connections create github kyvos-connection \
  --region=europe-west1 --project=PROJECT_ID
# Follow the printed URL to authorize the connection in GitHub if prompted.

gcloud builds repositories create dataset-repo \
  --connection=kyvos-connection --region=europe-west1 --project=PROJECT_ID \
  --remote-uri=https://github.com/samisajjad/dataset.git
```

### 3. Create the CI trigger for `dev`
```bash
gcloud builds triggers create github \
  --name="kyvos-ci-dev" --project=PROJECT_ID --region=europe-west1 \
  --repository=dataset-repo --branch-pattern="^dev$" \
  --build-config=kyvos/cloudbuild/cloudbuild-ci.yaml \
  --substitutions=_ENV=dev
```

That's the entire setup. No Secret Manager, no Artifact Registry, no
Scheduler -- those only come in with Phase 2 (see `kyvos/README.md`).

### 4. Create the `dev` branch if it doesn't exist yet
```bash
git checkout -b dev origin/master   # or your actual default branch
git push -u origin dev
```

## Proving it works end to end
1. In Kyvos, Entities > Export > "Export All Objects" -> fill Name/Author/
   Version/Description -> **Export & Download**. A `.cab` lands in Downloads.
2. Stage it into the repo:
   ```bash
   kyvos/scripts/add_export.sh --env dev --file ~/Downloads/Dev.cab
   ```
3. Commit and push exactly as the script tells you:
   ```bash
   git add kyvos/dev/Dev.cab
   git commit -m "kyvos(dev): <paste the Description you typed in Kyvos>"
   git push origin dev
   ```
4. Watch the build:
   ```bash
   gcloud builds list --project=PROJECT_ID --region=europe-west1 --limit=1
   ```
   or check the Cloud Build console. It should go green, and the log should
   show `validate.sh` reporting the `.cab` size and "Validation passed".

That's the POC, proven: an object changed in Kyvos, versioned in Git,
automatically validated by Cloud Build. From here, `kyvos/README.md`
covers extending this to `qa`/`prod` branches and (once available)
automating the actual deploy step with the official CI/CD Utility.
