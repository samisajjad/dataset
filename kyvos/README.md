# Kyvos CI/CD (Cloud Build)

Versioned Kyvos objects (`kyvos/dev`, `kyvos/qa`, `kyvos/prod`) plus a Cloud
Build pipeline that promotes them dev -> qa -> prod through the Kyvos CICD
Utility.

**Assumption**: the Kyvos server is a GCE VM in the same GCP project as
Cloud Build, reached over IAP (no public IP, no manually-managed SSH keys).
If that's wrong (on-prem server, different cloud, etc.), the `copy-objects`
/ `run-import` steps in `cloudbuild/cloudbuild-cd.yaml` need to change to a
different transport (e.g. a Cloud Build private pool peered into your VPC,
or a self-hosted runner) -- everything else in this runbook still applies.

## How it works day to day

1. Someone changes an object in the Kyvos DEV UI.
2. They run the export script **on the Kyvos server** and commit the result:
   ```
   PROJECT_ID=<your-project> kyvos/scripts/kyvos_export.sh --env dev --out-dir /tmp/kyvos-dev-export
   # copy /tmp/kyvos-dev-export contents into kyvos/dev/ in this repo
   git add kyvos/dev && git commit -m "kyvos: describe the change" && git push
   ```
3. Push to `dev` branch triggers **CI** (`cloudbuild-ci.yaml`): validates the
   exported files are well-formed.
4. CI passing triggers **CD** (`cloudbuild-cd.yaml`, `_ENV=dev`): copies
   `kyvos/dev/` to the server and runs the import utility against the DEV
   Kyvos instance -- this keeps DEV itself in sync with what's in Git, so
   Git is always the source of truth.
5. When ready to promote: open a PR `dev` -> `qa`. Merging triggers CI+CD
   for QA, gated by a manual approval (see below). Same for `qa` -> `prod`.
6. **Rollback**: `git revert` (or check out an older commit) on the target
   branch and push -- CD re-deploys that older version.

## One-time GCP setup

Run these once (replace `PROJECT_ID`, `VM_NAME`, `VM_ZONE`, `REPO_OWNER` /
connection name with your real values).

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
Copy `kyvos/scripts/` and `kyvos/config/` from this repo onto the VM at
`/opt/kyvos/cicd-utility/{scripts,config}`, alongside the existing
`KyvosCICDUtility.sh` installation (adjust `KYVOS_UTIL_HOME` in the scripts
if yours lives elsewhere). `gcloud secrets` CLI must be installed/available
on the VM (it ships with the Cloud SDK).

### 6. Connect the GitHub repo and create triggers
```bash
# One-time: connect the repo via Console (Cloud Build > Repositories) or:
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
- `objects.list` in `config/export-dev.properties` and the `-operation`,
  `-configFile`, `-exportPath`/`-importPath` flag names in the two scripts
  are based on commonly documented `KyvosCICDUtility.sh` usage. Confirm
  against `KyvosCICDUtility.sh -help` on your server and adjust if the
  flag names differ on your installed version.
- `targetSchema` values in `config/import-*.properties` are placeholders --
  set them to your real DEV/QA/PROD schema names.
