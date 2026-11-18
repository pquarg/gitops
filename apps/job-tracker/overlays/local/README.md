# Local job tracker release

Run from the GitOps checkout. This overlay is local only, uses context
`kind-deployment`, and is discovered automatically from published `main`.
The app is at http://job-tracker.localhost. Traefik sends `/api/` unchanged to
FastAPI and `/` to the static frontend; demo-api and Mailpit keep their routes.

The Mantine release updates the UI and the dashboard query API together. It
uses the existing database schema and provider settings. For an existing
installation, build and load both images, run the database probe and validation,
then publish and verify the release. Keep the existing namespace and Secret.

## Prepare before publication

1. Follow [local setup](../../../../docs/local/setup.md) for the existing platform.
   Do not rebuild kind or reset PostgreSQL. Provision the dedicated database/login
   using the infra [tracker database runbook](https://github.com/pquarg/infra/blob/main/environments/local/docs/job-tracker.md).
2. Build both images from the separate app checkout with the exact tags selected
   in [kustomization.yaml](kustomization.yaml), then load into the existing cluster:

   ```sh
   docker build --provenance=false -t ghcr.io/pquarg/job-tracker-backend:0.1.0-m4.6 ../apps/job-tracker/backend
   docker build --provenance=false -t ghcr.io/pquarg/job-tracker-frontend:0.1.0-m4.4 ../apps/job-tracker/frontend
   kind load docker-image ghcr.io/pquarg/job-tracker-backend:0.1.0-m4.6 ghcr.io/pquarg/job-tracker-frontend:0.1.0-m4.4 --name deployment
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
4. This release selects per-user ChatGPT plan authentication. Preserve the existing
   private deployment env file and database URL. From the app checkout run:

   ```sh
   python3 scripts/prepare-chatgpt.py --env-file /absolute/private/job-tracker/deployment.env
   ```

   This creates the encryption key and stable host ID once and retains a private
   copy of previous settings. Keep the pair for installation recovery; do not
   regenerate it during upgrades. Follow the app's
   [ChatGPT connection runbook](https://github.com/pquarg/job-tracker/blob/main/docs/chatgpt-plan.md).
   For this additive schema release, first pause auto-sync and **both** writers,
   then take/verify a backup as described below. With writers stopped:

   ```sh
   ./scripts/configure-job-tracker.py --environment local --context kind-deployment --env-file /absolute/private/job-tracker/deployment.env
   ```

   The mode-600 env file must be outside Git. The helper validates the private
   key/host pair and loopback callback, preserves unrelated Secret fields and
   never executes shell expressions or prints values. No API key is needed in
   plan mode, and a filled key is never used as fallback. Without a connected
   account, selected model and approved disclosure, manual review remains available.
   Existing API-key installations can explicitly select `JT_AI_AUTH=api_key` in
   the Secret; then `OPENAI_API_KEY` and `JT_AI_MODEL` control that mode.
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

## Connect a user after rollout

From the app checkout keep `python3 scripts/chatgpt-callback.py --environment local
--context kind-deployment` running. This loopback-only tunnel handles no tokens
and checks the backend callback before opening the tracker. The UI also checks
readiness before sign-in. The callback must stay exactly HTTP `127.0.0.1` with
path `/auth/callback`; the default local port is 1456. No public Gateway callback
route is added. Users authorize, select an account-eligible model, review ChatGPT
usage/credit controls and approve processing. The preview lacks hard output/token
and hosted-tool caps. Usage exhaustion pauses durably until explicit Resume.
Connection/model changes cancel pending AI work and require new consent.

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
before resuming workers. The infra tracker restore helper also clears restored
ChatGPT credentials and pending authorizations, and invalidates AI approvals.
Users reconnect and approve processing again; raw pg_restore alone does not do
this. Back up the stable installation key/host separately from the encrypted DB.
Keep private connection/provider settings and password
files as well as backups: source Git cannot recover them.

After kind replacement, PostgreSQL remains in its existing external volume.
Recreate the namespace/private Secrets, load both exact images, run the Pod probe,
then allow registration/full sync. No database mount belongs in the cluster.


## Gateway routing

This overlay uses HTTPRoute `job-tracker` attached to shared Gateway
`traefik/traefik-gateway`, listener `web`. The `/api/` PathPrefix selects
`job-tracker-api:80`; `/` selects `job-tracker-frontend:80`. Paths are preserved.
An Exact `/api` rule preserves the previous frontend fallback; `/api/` and
nested API paths select the API, while `/apix` selects the frontend.
During a Gateway routing cutover,
verify the new route's current-generation Accepted/ResolvedRefs status, then
explicitly prune only the old job-tracker Ingress. Auto-sync does not prune it.

Follow [local Gateway cutover](../../../../docs/local/gateway-cutover.md) for
verification evidence, staged publication, namespace permissions and rollback.

Check the live path contract after sync/pruning:

```sh
python3 scripts/check-job-tracker-routing.py --environment local --context kind-deployment --kubeconfig "$HOME/.kube/config"
```

This integration check catches the trailing-slash matching difference observed
during migration: Gateway PathPrefix matches `/api` even when the configured
prefix is `/api/`; the previous Traefik Ingress sent bare `/api` to the frontend.
