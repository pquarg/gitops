# Local job tracker release

Run from the GitOps checkout. This overlay is local only, uses context
`kind-deployment`, and is discovered automatically from published `main`.
The app is at http://job-tracker.localhost. Traefik sends `/api/` unchanged to
FastAPI and `/` to the static frontend; demo-api and Mailpit keep their routes.

## Prepare before publication

1. Follow [local setup](../../../../docs/local/setup.md) for the existing platform.
   Do not rebuild kind or reset PostgreSQL. Provision the dedicated database/login
   using the infra [tracker database runbook](https://github.com/pquarg/infra/blob/main/environments/local/docs/job-tracker.md).
2. Build both images from the separate app checkout with the exact tags selected
   in [kustomization.yaml](kustomization.yaml), then load into the existing cluster:

   ```sh
   docker build --provenance=false -t ghcr.io/pquarg/job-tracker-backend:0.1.0-m4.3 ../apps/job-tracker/backend
   docker build --provenance=false -t ghcr.io/pquarg/job-tracker-frontend:0.1.0-m4.1 ../apps/job-tracker/frontend
   kind load docker-image ghcr.io/pquarg/job-tracker-backend:0.1.0-m4.3 ghcr.io/pquarg/job-tracker-frontend:0.1.0-m4.1 --name deployment
   ```

   These are local loaded releases, not published GHCR packages. Use a new tag
   after any code change. API, worker and migration all select the backend image.
   A replacement cluster needs the images loaded again before sync. Alternatively
   publish both images and provision `registry-credentials` in this namespace;
   then add its `imagePullSecrets` reference to all workloads before publication.
3. Create namespace `job-tracker` if missing. Copy
   [app-secrets.example.yaml](app-secrets.example.yaml) to ignored
   `app-secrets.yaml` or private storage outside Git. Fill `JT_DATABASE_URL` with
   the **tracker** login/password, URL-encoding the password. Apply privately:

   ```sh
   kubectl --context kind-deployment apply -f apps/job-tracker/base/namespace.yaml
   kubectl --context kind-deployment apply -f apps/job-tracker/overlays/local/app-secrets.yaml
   ./scripts/check-job-tracker-local.py --environment local --context kind-deployment
   ```

   The probe uses the selected worker image, checks database/login identity,
   privileges and transactional DDL, and actually parses text in bubblewrap.
   It creates and deletes only its temporary probe Job. Continue only when it
   reports all checks passed. Filled Secrets stay outside Kustomize and Git.
4. Providers are disabled by empty private settings. For live discovery configure
   an Ollama-compatible HTTPS endpoint/model, accurate processing/retention terms
   and Brave key/terms in the Secret; see the app's
   [provider contract](https://github.com/pquarg/job-tracker/blob/main/docs/provider-contracts.md).
   Do not put keys in ConfigMaps, images or frontend variables. Pods use a new
   disclosure revision after restart; each user must approve it. A missing
   provider is displayed as unavailable; no fixture mode exists in the release.
5. Run `./scripts/validate.sh --no-placeholders`,
   `./scripts/validate-server.sh job-tracker --environment local --context kind-deployment`
   and `git diff --check`. Review, commit and push the overlay only after these
   prerequisites pass. No per-app registration is needed.

## Verify

Wait for Application `job-tracker` in `argocd` to report **Synced / Healthy** and
its intended Git revision. The namespace is wave -2, ConfigMap wave 0,
Sync migration hook wave 0, and API/worker/frontend wave 1. A failed migration
blocks rollout. Sync the entire Application: selective sync skips hooks, as
explained in [Argo CD's sync documentation](https://argo-cd.readthedocs.io/en/stable/user-guide/sync-waves/).

```sh
kubectl --context kind-deployment -n argocd get application job-tracker
kubectl --context kind-deployment -n job-tracker logs job/job-tracker-migrate
kubectl --context kind-deployment -n job-tracker get deployments,pods
kubectl --context kind-deployment -n job-tracker exec deployment/job-tracker-api -- python -m alembic current --check-heads
curl -fsS http://job-tracker.localhost/api/health
curl -fsS http://job-tracker.localhost/api/ready
```

Health checks the API process; readiness checks database access and the release's
schema revision. Worker liveness checks a heartbeat with a ten-minute allowance
for bounded research tasks; this is not proof of provider availability. The
worker runs nonroot, without capabilities or a service-account token, with a
read-only root filesystem. Its container alone uses `seccomp: Unconfined` because
rootless bubblewrap needs nested namespace syscalls; API, frontend and migration
retain `RuntimeDefault`. No privileged container or host mount is used. The
parser receives no DB/provider credentials, network or private filesystem mounts.
The unused proc mount was removed to support nested container isolation. This
exception is scoped to this local lab and needs review for any other platform.

Create two **synthetic** browser accounts, select manual processing, upload text,
PDF and DOCX, review/correct/approve evidence and save search profiles. Check the
other account cannot download the first account's original. Reload and restart
API/worker to check persisted data. With configured/approved providers, run a
bounded discovery and save a decision/notes, then repeat after restart. Missing
providers mean that live discovery remains unverified, even when Argo is healthy.
Run independent backup/restore verification after creating test data.

## Releases, credentials and recovery

For schema changes, pause this app's auto-sync, wait for active migration hooks,
stop traffic and scale **both** API and worker to zero. Take and verify a tracker
backup using infra. Publish compatible additive migrations first; API readiness
checks the schema head. Old workers can continue writing during ordinary rolling
updates, so stop writers for data-affecting releases. Update backend image once
in the overlay; update frontend independently when needed. Full-sync, verify
migration, readiness, existing logins/uploads/decisions and provider disclosure,
then resume traffic and automatic sync. Never reset demo-api or its database.

After changing private settings, restart both backend Deployments:

```sh
kubectl --context kind-deployment -n job-tracker rollout restart deployment/job-tracker-api deployment/job-tracker-worker
```

Changing a password file/Secret does not rotate a database role. Coordinate a
separate explicit rotation with stopped writers; never print the connection URL.
Application rollback selects a previous compatible image; it does not undo
migrations or restore deleted records. Recovery restores a verified backup into
an empty tracker schema with writers stopped. Never automatically downgrade or
clear a populated schema. Reconcile account deletions made since the backup
before resuming workers. Keep private connection/provider settings and password
files as well as backups: source Git cannot recover them.

After kind replacement, PostgreSQL remains in its existing external volume.
Recreate the namespace/private Secrets, load both exact images, run the Pod probe,
then allow registration/full sync. No database mount belongs in the cluster.
