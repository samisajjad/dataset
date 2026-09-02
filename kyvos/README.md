# Kyvos CI/CD (Cloud Build)

Versioned Kyvos capsules (`kyvos/dev`, `kyvos/qa`, `kyvos/prod`, each holding
`.cap` files) plus a Cloud Build pipeline that deploys them dev -> qa -> prod
through the Kyvos CICD Utility.

**Assumption**: the Kyvos server is a GCE VM in the same GCP project as
Cloud Build, reached over IAP (no public IP, no manually-managed SSH keys).
If that's wrong, the `copy-objects` / `run-import` steps in
`cloudbuild/cloudbuild-cd.yaml` need a different transport (a Cloud Build
private pool peered into your VPC, or a self-hosted runner) -- everything
else in this runbook still applies.

## Current reality: export is manual, import can be automated

Today, exporting an object out of Kyvos only works through the web UI
(Entities > pick an object > Export), which downloads a `.cap` capsule file
to your laptop. There is no CLI export command in use yet. So the pipeline
is split into two phases:

- **Phase 1 (works right now, no CLI needed): version what you export.**
  Every `.cap` you download gets committed to Git. That alone gives you
  history, diffable commit messages, and a rollback point -- the biggest
  win, and it needs nothing below.
- **Phase 2 (needs one thing from you): automate the deploy.** The Kyvos
  CICD Utility is installed on the server and can very likely run
  headless (that's the whole point of a "CICD utility" vs. the UI) -- we
  just don't have its exact command syntax yet. Get it once, and CD to
  QA/PROD becomes a Cloud Build trigger instead of you clicking Import in
  the UI three times.

### Getting the CLI syntax (do this once)
SSH into the Kyvos server and find the utility (likely alongside the
Kyvos install, e.g. `/opt/kyvos/...`), then run its help:
```bash
find / -iname "*cicd*util*" 2>/dev/null
/path/to/KyvosCICDUtility.sh -help
```
Paste that output back so `kyvos/scripts/kyvos_import.sh` and
`kyvos/config/import-*.properties` can be corrected -- right now the
`-operation`, `-capFile`, `-configFile` flags in that script are
placeholders.

## Day-to-day workflow

**Phase 1 -- today:**
1. Export an object from the Kyvos UI -> `.cap` lands in your Downloads.
2. Run the helper to place it correctly and print the git commands:
   ```
   kyvos/scripts/add_export.sh --env dev --cap-file ~/Downloads/whatever.cap
   ```
3. `git add`, `git commit` (describe what changed), `git push` as it tells you.
4. Push to `dev` triggers **CI** (`cloudbuild-ci.yaml`): confirms a real,
   non-empty capsule was committed.
5. To promote: open a PR `dev` -> `qa`, then `qa` -> `prod`. For now, after
   merging, manually import that same `.cap` via the Kyvos UI into QA/PROD
   (until Phase 2 is wired up).

**Phase 2 -- once you have the real CLI flags:**
6. Merging to `qa` or `prod` also triggers **CD** (`cloudbuild-cd.yaml`):
   Cloud Build copies `kyvos/<env>/*.cap` to the server over IAP and runs
   `kyvos_import.sh`, which calls the utility once per capsule -- gated by
   a manual approval on qa/prod (see setup below).
7. **Rollback**: `git revert` (or check out an older commit) on the target
   branch, push, and CD re-imports that older `.cap`.

## One-time GCP setup (Phase 2)

Run these once (replace `PROJECT_ID`, `VM_NAME`, `VM_ZONE`).

### 1. Enable APIs
```bash
gcloud services enable cloudbuild.googleapis.com secretmanager.googleapis.com \
  iap.googleapis.com compute.googleapis.com --project=PROJECT_ID
```

### 2. Store Kyvos credentials per environment
```bash
for ENV in dev qa prod; do
  echo -n "kyvos.internal.example.com" | gcloud secrets create kyvos-${ENV}-host --data-file=- --project=PROJECT_ID
  echo -n "cicd_service_user"          | gcloud secrets create kyvos-${ENV}-user --data-file=- --project=PROJECT_ID
  echo -n "REPLACE_WITH_REAL_PASSWORD" | gcloud secrets create kyvos-${ENV}-password --data-file=- --project=PROJECT_ID
done
```

### 3. Let the Kyvos VM read its own secrets
```bash
VM_SA=$(gcloud compute instances describe VM_NAME --zone=VM_ZONE \
  --project=PROJECT_ID --format='value(serviceAccounts[0].email)')

for ENV in dev qa prod; do
  for SECRET in kyvos-${ENV}-host kyvos-${ENV}-user kyvos-${ENV}-password; do
    gcloud secrets add-iam-policy-binding $SECRET \
      --member="serviceAccount:${VM_SA}" \
      --role="roles/secretmanager.secretAccessor" \
      --project=PROJECT_ID
  done
done
```

### 4. Let Cloud Build SSH into the VM over IAP (no keys to manage)
```bash
CB_SA=$(gcloud projects describe PROJECT_ID --format='value(projectNumber)')@cloudbuild.gserviceaccount.com

gcloud projects add-iam-policy-binding PROJECT_ID \
  --member="serviceAccount:${CB_SA}" --role="roles/iap.tunnelResourceAccessor"
gcloud projects add-iam-policy-binding PROJECT_ID \
  --member="serviceAccount:${CB_SA}" --role="roles/compute.osLogin"
gcloud projects add-iam-policy-binding PROJECT_ID \
  --member="serviceAccount:${CB_SA}" --role="roles/compute.viewer"

# Enable OS Login on the VM if not already:
gcloud compute instances add-metadata VM_NAME --zone=VM_ZONE \
  --project=PROJECT_ID --metadata enable-oslogin=TRUE

# Firewall rule allowing IAP's SSH forwarding range:
gcloud compute firewall-rules create allow-iap-ssh \
  --project=PROJECT_ID --network=default --direction=INGRESS \
  --action=ALLOW --rules=tcp:22 --source-ranges=35.235.240.0/20
```

### 5. Put the utility + scripts on the Kyvos VM
Copy `kyvos/scripts/kyvos_import.sh` and `kyvos/config/import-*.properties`
from this repo onto the VM at `/opt/kyvos/cicd-utility/{scripts,config}`,
alongside the existing `KyvosCICDUtility.sh` install (adjust
`KYVOS_UTIL_HOME` in the script if yours lives elsewhere).
`gcloud secrets` (Cloud SDK) must be available on the VM.

### 6. Connect the GitHub repo and create triggers
```bash
gcloud builds connections create github kyvos-connection --region=REGION --project=PROJECT_ID
gcloud builds repositories create dataset-repo \
  --connection=kyvos-connection --region=REGION --project=PROJECT_ID \
  --remote-uri=https://github.com/samisajjad/dataset.git

# CI trigger per branch
for ENV in dev qa prod; do
  gcloud builds triggers create github \
    --name="kyvos-ci-${ENV}" --project=PROJECT_ID --region=REGION \
    --repository=dataset-repo --branch-pattern="^${ENV}$" \
    --build-config=kyvos/cloudbuild/cloudbuild-ci.yaml \
    --substitutions=_ENV=${ENV}
done

# CD trigger per branch -- qa and prod require manual approval
gcloud builds triggers create github \
  --name="kyvos-cd-dev" --project=PROJECT_ID --region=REGION \
  --repository=dataset-repo --branch-pattern="^dev$" \
  --build-config=kyvos/cloudbuild/cloudbuild-cd.yaml \
  --substitutions=_ENV=dev,_VM_NAME=VM_NAME,_VM_ZONE=VM_ZONE,_VM_PROJECT=PROJECT_ID

for ENV in qa prod; do
  gcloud builds triggers create github \
    --name="kyvos-cd-${ENV}" --project=PROJECT_ID --region=REGION \
    --repository=dataset-repo --branch-pattern="^${ENV}$" \
    --build-config=kyvos/cloudbuild/cloudbuild-cd.yaml \
    --substitutions=_ENV=${ENV},_VM_NAME=VM_NAME,_VM_ZONE=VM_ZONE,_VM_PROJECT=PROJECT_ID \
    --require-approval
done
```

## Approving a QA/PROD deploy
After the `qa` or `prod` CD trigger fires, the build sits in `PENDING`
until approved:
```bash
gcloud builds list --project=PROJECT_ID --filter='status=PENDING_APPROVAL'
gcloud builds approve BUILD_ID --project=PROJECT_ID
```
or approve it from the Cloud Build console (Console > Cloud Build >
History > the pending build > Approve).

## What's still a placeholder here
- The `-operation`, `-capFile`, `-configFile` flags in
  `kyvos/scripts/kyvos_import.sh` are guesses based on commonly documented
  Kyvos CICD Utility usage. Get the real ones from `KyvosCICDUtility.sh
  -help` on your server (see "Getting the CLI syntax" above) and update
  the script.
- `targetSchema` values in `config/import-*.properties` are placeholders --
  set them to your real DEV/QA/PROD schema names.
