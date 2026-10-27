# Staging deployment

This is the staging deployment repository for `myfastapiapp`. Staging currently
runs FastAPI and Postgres in the existing kind cluster, `argocd-postgres`.
The cluster contains one Argo CD installation and one shared Traefik controller.
One Argo CD Application, `myfastapiapp-postgres-application`, manages FastAPI and
its dedicated Postgres database together. Its existing name is retained to
preserve resource ownership. FastAPI runs in a Pod managed by a Deployment;
Postgres runs in a separate Pod managed by a StatefulSet with persistent storage.
Postgres data lives in a laptop directory mounted into the kind node. Application
code and Dockerfiles belong in the separate `../apps/myfastapiapp` repository.

For a fresh setup or cluster rebuild, follow the [Postgres walkthrough](docs/postgres-kind.md).
Commands here run from this deployment repository's root. Docker Desktop, kind,
kubectl, Docker Compose, and Python 3 are required.

The reusable app base lives under `apps/myfastapiapp/base`. The staging overlay
selects the release version and adds this environment's database and storage.
A future production repository can import the base at a pinned Git commit and
supply its own overlay. The staging overlay and laptop storage belong to staging.

| Setting | Value |
| --- | --- |
| Environment | `staging` |
| kind cluster | `argocd-postgres` |
| kubectl context | `kind-argocd-postgres` |
| Application namespace | `default` |
| FastAPI and Postgres Argo CD Application | `myfastapiapp-postgres-application` |
| Argo CD source path | `apps/myfastapiapp/overlays/staging` |
| App URL | http://myfastapiapp.localhost/api/v1/docs/ |
| Argo CD UI | https://localhost:8080 |

```text
apps/myfastapiapp/
  base/                      # API and migration Job shared by deployment variants
    deployment.yaml
    migration-job.yaml
    configmap.yaml
    service.yaml
    ingress.yaml
    kustomization.yaml
  overlays/staging/          # Complete staging deployment
    kustomization.yaml       # Imports the base; selects the API and Job image tag
    app-secrets.example.yaml
    postgres-secrets.example.yaml
    postgres-storage.yaml    # Laptop-backed PV/PVC with retention
    postgres-statefulset.yaml
    postgres-service.yaml
argocd/
  myfastapiapp.yaml           # Registers the existing Application at the staging path
  traefik.yaml                # Registers the shared Ingress controller
kind/
  postgres-config.example.yaml
  postgres-config.local.yaml # Git-ignored laptop storage path
  compose.yaml               # Gateway on localhost port 80
  haproxy.cfg
scripts/
  backup-postgres.sh         # Database backup and archive read check
  deploy-kind.sh             # Manual bootstrap of the complete overlay
  setup-ingress-kind.sh      # Traefik and the app gateway
```

The deployment entry point is `apps/myfastapiapp/overlays/staging`. The helper scripts
select `argocd-postgres` by default. The base directory is included by the overlay;
register `argocd/myfastapiapp.yaml` to manage FastAPI and Postgres together.

## Open the app and Argo CD

Select the cluster:

```sh
kubectl config use-context kind-argocd-postgres
```

With Argo CD and the app deployed, start or refresh the app gateway:

```sh
./scripts/setup-ingress-kind.sh
```

Open http://myfastapiapp.localhost/api/v1/docs/. The request follows this route:

```text
myfastapiapp.localhost:80
  -> Docker HAProxy gateway
  -> argocd-postgres-control-plane:30080
  -> Traefik
  -> myfastapiapp-service:80
  -> FastAPI Pod:8000
```

To open Argo CD, keep this running in a terminal:

```sh
kubectl --context kind-argocd-postgres -n argocd \
  port-forward service/argocd-server 8080:443
```

Open https://localhost:8080 and sign in as `admin`. Use the password belonging to
this cluster. On a fresh installation, retrieve its initial password with:

```sh
kubectl --context kind-argocd-postgres -n argocd \
  get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d
printf '\n'
```

If you have changed the admin password, use the replacement password. The UI
port-forward and the app's HTTP gateway are independent connections.

## App configuration and credentials

`apps/myfastapiapp/base/configmap.yaml` supplies `APP_MESSAGE`. The staging image
version is `images[].newTag` in `apps/myfastapiapp/overlays/staging/kustomization.yaml`;
Kustomize applies it to both the API Deployment and migration Job. Memory settings
live in `apps/myfastapiapp/base/deployment.yaml`. The Deployment reads
`AUTH_DATABASE_URL` from the `myfastapiapp-secrets` Secret. The overlay adds its
dedicated Postgres database and persistent storage.

Provision these local files separately from Argo CD:

| Git-ignored file | Kubernetes Secret | Required value |
| --- | --- | --- |
| `apps/myfastapiapp/overlays/staging/app-secrets.yaml` | `myfastapiapp-secrets` | `AUTH_DATABASE_URL` |
| `apps/myfastapiapp/overlays/staging/postgres-secrets.yaml` | `myfastapiapp-postgres-secrets` | `POSTGRES_PASSWORD` |

Follow [Create the database secrets](docs/postgres-kind.md#3-create-the-database-secrets)
for the templates and matching password. Keep filled files at mode `600` and out
of Kustomize and Git.

Apply an edited local Secret with:

```sh
kubectl --context kind-argocd-postgres -n default apply \
  -f apps/myfastapiapp/overlays/staging/app-secrets.yaml \
  -f apps/myfastapiapp/overlays/staging/postgres-secrets.yaml
```

Changing a Secret or ConfigMap does not refresh environment variables in running
Pods. After applying a Secret change or syncing a ConfigMap change, restart the
app through Argo CD's Restart action or run:

```sh
kubectl --context kind-argocd-postgres -n default \
  rollout restart deployment/myfastapiapp-deployment
kubectl --context kind-argocd-postgres -n default \
  rollout status deployment/myfastapiapp-deployment --timeout=180s
```

`POSTGRES_PASSWORD` initializes a new database. For existing data, changing that
Secret alone does not rotate the database role's password; follow the
[recovery guidance](docs/postgres-kind.md#what-happens-on-a-cluster-rebuild).

### Move to AWS CSI later

For a later AWS Secrets Store CSI Driver integration, retain Secret name
`myfastapiapp-secrets` and key `AUTH_DATABASE_URL`. Add a `SecretProviderClass`
with AWS references, configure its `secretObjects` mapping, mount the CSI volume
in the app Pod, and configure workload IAM access. The volume mount is required
even when the app consumes the synchronized Secret as environment variables.
Plan the handover from manually provisioned Secrets because CSI manages their
lifecycle. See [CSI Secret synchronization](https://secrets-store-csi-driver.sigs.k8s.io/topics/sync-as-kubernetes-secret).

## Registry authentication

The Deployment references a Kubernetes Secret with these settings:

| Setting | Value |
| --- | --- |
| Cluster context | `kind-argocd-postgres` |
| Secret name | `registry-credentials` |
| Namespace | `default` (the same namespace as the app) |
| Secret type | `kubernetes.io/dockerconfigjson` |
| Registry | `ghcr.io` |

This Secret is provisioned separately from Argo CD. It lets the cluster download
the private app image; Argo CD's Git repository credentials let it read deployment
manifests. Each credential is configured separately.

Create a GitHub **personal access token (classic)** with `read:packages`, using an
account that has read access to the app's GHCR package. If the package belongs to
an organization that requires SSO, authorize the token for that organization.
Store the PAT in a password manager outside this repository. See
[GitHub's GHCR authentication instructions](https://docs.github.com/en/packages/working-with-a-github-packages-registry/working-with-the-container-registry#authenticating-to-the-container-registry).

After creating the cluster, run the following in an interactive terminal with
Python 3 and kubectl available. Replace `YOUR_GITHUB_USERNAME` with the account
that owns the PAT. The command prompts for the PAT without echoing it and pipes
the generated Secret directly to kubectl, keeping the PAT out of command
arguments, shell history, and saved files. Use the same command to update an
existing `registry-credentials` Secret.

```sh
python3 -c '
import base64
import getpass
import json
import sys

username = sys.argv[1]
token = getpass.getpass("GitHub PAT (read:packages): ")
if not token:
    raise SystemExit("PAT cannot be empty")
auth = base64.b64encode(f"{username}:{token}".encode()).decode()
config = json.dumps({"auths": {"ghcr.io": {"auth": auth}}})
secret = {
    "apiVersion": "v1",
    "kind": "Secret",
    "metadata": {"name": "registry-credentials", "namespace": "default"},
    "type": "kubernetes.io/dockerconfigjson",
    "data": {".dockerconfigjson": base64.b64encode(config.encode()).decode()},
}
json.dump(secret, sys.stdout)
' YOUR_GITHUB_USERNAME |
  kubectl --context kind-argocd-postgres -n default apply -f -
```

To confirm the Secret exists without displaying its credentials:

```sh
kubectl --context kind-argocd-postgres -n default get secret registry-credentials \
  -o 'custom-columns=NAME:.metadata.name,NAMESPACE:.metadata.namespace,TYPE:.type'
```

This confirms the Secret's presence and type; a successful image pull confirms
the credential works. Recreate the Secret after deleting and rebuilding the kind
cluster. When the PAT expires or is rotated, rerun the setup command with the new
PAT. For a planned rotation, update the Secret before revoking the old PAT.
Existing running containers keep running; future pulls use the updated Secret.
For a different cluster or app namespace, update the context and namespace in
both the generated Secret and the kubectl commands.

Commit these instructions and the Deployment's `imagePullSecrets` reference.
Keep the PAT and generated Secret JSON/YAML outside Git, including private
repositories: a Kubernetes Secret's base64 encoding is reversible. See
[Kubernetes image pull Secrets](https://kubernetes.io/docs/tasks/configure-pod-container/pull-image-private-registry/).

## Publish manifests and connect Argo CD

The repository is [pquarg/deploy](https://github.com/pquarg/deploy). The Application
in `argocd/myfastapiapp.yaml` uses `git@github.com:pquarg/deploy.git`, follows
`main`, and renders `apps/myfastapiapp/overlays/staging`. The Application is named
`myfastapiapp-postgres-application`, labeled `environment: staging`, and provides
one place to review, sync, and check the health of both FastAPI and Postgres.

After committing and pushing the deployment files, connect the private repository
under Argo CD **Settings -> Repositories**. Its Git credential is separate from
the app image's `registry-credentials` Secret. See
[Argo CD repository access](https://argo-cd.readthedocs.io/en/stable/user-guide/private-repositories/).

Once the Secrets and image are available and these manifests are pushed, create
or update the staging Application registration:

```sh
kubectl --context kind-argocd-postgres apply -f argocd/myfastapiapp.yaml
kubectl --context kind-argocd-postgres -n argocd get applications
```

Automatic sync applies committed changes; `selfHeal: true` restores managed
resources that drift from Git. The `traefik` Application manages the shared
controller separately. On a fresh cluster, follow the
[installation steps](docs/postgres-kind.md#7-install-argo-cd-and-expose-the-app).

The Application's source path is a live setting. Pushing changes to its YAML file
does not update that registration because the Application does not manage its
own `argocd/` directory. Apply the registration after pushing a source-path change,
then refresh Argo CD and confirm **Synced / Healthy**. Applying the file also enables
automatic sync as declared in it. To keep auto-sync disabled while changing the
source path, edit only **App Details -> Source -> Path** in the UI instead.

## Manual deployment and validation

For initial bootstrap before Argo CD manages the app:

```sh
./scripts/deploy-kind.sh
```

The script renders `apps/myfastapiapp/overlays/staging`, applies supporting resources,
waits for Postgres, runs and waits for the migration Job, then applies and waits
for FastAPI. Plain kubectl does not interpret Argo's hook annotations or waves,
so the script performs this ordering explicitly. It accepts an optional kind
cluster name; that cluster must have the storage mount and separately provisioned
Secrets. Once Argo CD owns the app,
use Git commits and sync for routine changes.

To preview and validate resources without persisting changes:

```sh
kubectl kustomize apps/myfastapiapp/overlays/staging
kubectl --context kind-argocd-postgres -n default \
  apply --dry-run=server -k apps/myfastapiapp/overlays/staging
```

To refresh or stop the HTTP gateway directly:

```sh
KIND_NODE=argocd-postgres-control-plane docker compose \
  --project-name kind-ingress-argocd-postgres -f kind/compose.yaml up -d

KIND_NODE=argocd-postgres-control-plane docker compose \
  --project-name kind-ingress-argocd-postgres -f kind/compose.yaml down
```

The setup script installs Traefik from chart `42.0.0`, starts this gateway, and
applies the initial app Ingress. Docker Desktop and the cluster must stay running.
The Ingress rules in Git select app Services by hostname, allowing more apps to
share the same controller and gateway.

## Release an app change

1. Build and publish a new image from the app repository, or build and load it
   into `argocd-postgres` for local use. Keep the app version and lockfile in sync.
2. Update `images[].newTag` in
   `apps/myfastapiapp/overlays/staging/kustomization.yaml`. This selects the same
   release for the API and migration Job; leave the base image defaults alone.
3. For a database change, follow the backup and controlled sync steps below
   before pushing. For other changes, commit and push, then wait for Argo CD to sync.

Use a new image tag for each code release. Manifest-only edits, such as resource
settings, replicas, and Ingress rules, need only a deployment-repository commit.
FastAPI keeps its app release version; PostgreSQL has its own image version in
`apps/myfastapiapp/overlays/staging/postgres-statefulset.yaml`. Both are deployed
through the same Application.
See [image publishing](docs/postgres-kind.md#4-make-the-app-image-available)
if a failed release skipped image publication.

### Back up and release a database change

1. Disable auto-sync in the live Application's Argo CD **App Details** and let
   any active sync finish. Select `myfastapiapp-postgres-application`. Editing
   `argocd/myfastapiapp.yaml` alone does not change the live policy. Reapplying
   its current configuration enables auto-sync again.
2. During a quiet window, run the backup script and continue only if it succeeds:

   ```sh
   ./scripts/backup-postgres.sh
   ```

   The script explicitly targets context `kind-argocd-postgres`, namespace
   `default`, and database `myfastapiapp`. It uses `pg_dump` and `pg_restore`
   inside the existing Postgres Pod, so local PostgreSQL tools are unnecessary.
   It writes a custom-format archive under
   `$HOME/.local/share/myfastapiapp/backups` with mode `600`, outside Git. It
   removes incomplete files if the dump or archive read check fails. The read
   check renders the full archive to `/dev/null` without connecting to a
   database; it does not test an actual restore. Verify recovery by restoring
   into a disposable database before relying on a backup. Keep writes paused
   through verification if recovery must preserve every write since the backup.
   See [pg_dump](https://www.postgresql.org/docs/17/app-pgdump.html) and
   [pg_restore](https://www.postgresql.org/docs/17/app-pgrestore.html).

   To select another kind cluster or destination:

   ```sh
   ./scripts/backup-postgres.sh argocd-postgres /absolute/path/outside-the-repo/backups
   ```

3. Validate the overlay, review the diff, then commit and push the release image
   selection and any manifest changes together:

   ```sh
   kubectl kustomize apps/myfastapiapp/overlays/staging > /dev/null
   kubectl --context kind-argocd-postgres -n default \
     apply --dry-run=server -k apps/myfastapiapp/overlays/staging
   git diff --check
   ```

4. Refresh Argo CD and run a full Application sync, with Force and Replace off.
   Resource-selective sync skips hooks. Sync waves apply storage at `-2`, wait
   for Postgres at `-1`, run the migration Job at `0`, and roll out FastAPI at `1`.
   The Job uses the app's database Secret and the new app image to run
   `python -m alembic upgrade head`. A failed migration blocks the app rollout.
   The latest Job and logs remain until the next sync replaces them. Hooks may
   run again on later syncs; Alembic skips already applied revisions.
   See [Argo CD sync phases and waves](https://argo-cd.readthedocs.io/en/latest/user-guide/sync-waves/).
5. Check the Job logs, revision, rollout, and health:

   ```sh
   kubectl --context kind-argocd-postgres -n default logs job/myfastapiapp-migrate
   kubectl --context kind-argocd-postgres -n default \
     exec myfastapiapp-postgres-statefulset-0 -c postgres -- \
     psql -U myfastapiapp -d myfastapiapp \
     -c 'SELECT version_num FROM alembic_version;'
   kubectl --context kind-argocd-postgres -n default \
     rollout status deployment/myfastapiapp-deployment --timeout=180s
   curl -fsS http://myfastapiapp.localhost/health
   ```

   For v0.1.8, expect revision `002_account_email`. Confirm Argo CD shows
   **Synced / Healthy**, test existing login and registration with email, then
   re-enable auto-sync in the UI.

If migration fails, inspect the Job logs before retrying. If migration succeeds
but the app rollout fails, the database has already changed. Check schema
compatibility before reverting the app image. Git rollback does not undo
migrations; the v0.1.8 email downgrade deletes the email column and its data.
