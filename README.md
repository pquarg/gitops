# Local Kubernetes deployment

This repository runs FastAPI and Postgres in one kind cluster, `argocd-postgres`.
The cluster contains one Argo CD installation and one shared Traefik controller.
One Argo CD Application, `myfastapiapp`, manages FastAPI and its dedicated Postgres
database together. FastAPI runs in a Pod managed by a Deployment; Postgres runs
in a separate Pod managed by a StatefulSet with persistent storage.
Postgres data lives in a laptop directory mounted into the kind node. Application
code and Dockerfiles belong in the separate `../apps/myfastapiapp` repository.

For a fresh setup or cluster rebuild, follow the [Postgres walkthrough](docs/postgres-kind.md).
Commands here run from this deployment repository's root. Docker Desktop, kind,
kubectl, and Docker Compose are required.

| Setting | Value |
| --- | --- |
| kind cluster | `argocd-postgres` |
| kubectl context | `kind-argocd-postgres` |
| Application namespace | `default` |
| FastAPI and Postgres Argo CD Application | `myfastapiapp` |
| Argo CD source path | `overlays/kind-postgres` |
| App URL | http://myfastapiapp.localhost/api/v1/docs/ |
| Argo CD UI | https://localhost:8080 |

```text
myfastapiapp/                 # App image, configuration, Service, and Ingress
  deployment.yaml            # App image, database Secret reference, and resource settings
  kustomization.yaml         # Base resources imported by the Postgres overlay
overlays/kind-postgres/       # Complete app and database deployment
  kustomization.yaml
  app-secrets.example.yaml   # Blank app Secret template
  postgres-secrets.example.yaml
  postgres-storage.yaml      # Laptop-backed PV/PVC with retention
  postgres-statefulset.yaml
  postgres-service.yaml
argocd/
  myfastapiapp.yaml           # Registers the app and Postgres overlay
  traefik.yaml                # Registers the shared Ingress controller
kind/
  postgres-config.example.yaml
  postgres-config.local.yaml # Git-ignored laptop storage path
  compose.yaml               # Gateway on localhost port 80
  haproxy.cfg
scripts/
  deploy-kind.sh             # Manual bootstrap of the complete overlay
  setup-ingress-kind.sh      # Traefik and the app gateway
```

The deployment entry point is `overlays/kind-postgres`. Both helper scripts
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

`myfastapiapp/configmap.yaml` supplies `APP_MESSAGE`. The app's image and memory
settings live in `myfastapiapp/deployment.yaml`. The Deployment reads
`AUTH_DATABASE_URL` from the `myfastapiapp-secrets` Secret. The overlay adds its
dedicated Postgres database and persistent storage.

Provision these local files separately from Argo CD:

| Git-ignored file | Kubernetes Secret | Required value |
| --- | --- | --- |
| `overlays/kind-postgres/app-secrets.yaml` | `myfastapiapp-secrets` | `AUTH_DATABASE_URL` |
| `overlays/kind-postgres/postgres-secrets.yaml` | `myfastapiapp-postgres-secrets` | `POSTGRES_PASSWORD` |

Follow [Create the database secrets](docs/postgres-kind.md#3-create-the-database-secrets)
for the templates and matching password. Keep filled files at mode `600` and out
of Kustomize and Git.

Apply an edited local Secret with:

```sh
kubectl --context kind-argocd-postgres -n default apply \
  -f overlays/kind-postgres/app-secrets.yaml \
  -f overlays/kind-postgres/postgres-secrets.yaml
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
`HEAD`, and renders `overlays/kind-postgres`. The Application is named
`myfastapiapp` and provides one place to review, sync, and check the health of
both FastAPI and Postgres.

After committing and pushing the deployment files, connect the private repository
under Argo CD **Settings -> Repositories**. Its Git credential is separate from
the app image's `registry-credentials` Secret. See
[Argo CD repository access](https://argo-cd.readthedocs.io/en/stable/user-guide/private-repositories/).

On an existing cluster with `myfastapiapp-postgres-application`, follow
[Rename the existing Application](#rename-the-existing-application) first.
For a fresh cluster, register the app once its Secrets and image are available:

```sh
kubectl --context kind-argocd-postgres apply -f argocd/myfastapiapp.yaml
kubectl --context kind-argocd-postgres -n argocd get applications
```

Automatic sync applies committed changes; `selfHeal: true` restores managed
resources that drift from Git. The `traefik` Application manages the shared
controller separately. On a fresh cluster, follow the
[installation steps](docs/postgres-kind.md#7-install-argo-cd-and-expose-the-app).

### Rename the existing Application

Changing `metadata.name` creates a new Application registration. If your cluster
still uses `myfastapiapp-postgres-application`, replace that registration before
applying `argocd/myfastapiapp.yaml`:

1. Commit and push these manifests, then let any active sync finish.
2. In the Argo CD UI, delete `myfastapiapp-postgres-application` with
   **Non-Cascading (Orphan)**. This preserves the running workloads and storage.
   See [Argo CD non-cascading deletion](https://argo-cd.readthedocs.io/en/stable/user-guide/app_deletion/#3-non-cascading-orphan).
3. Apply `argocd/myfastapiapp.yaml` using the command above. Let `myfastapiapp`
   sync and adopt the existing FastAPI and Postgres resources.

The UI should then show `myfastapiapp` for the product and `traefik` for the shared
Ingress controller. The Deployment, StatefulSet, Services, PV, and PVC keep their
existing names.

## Manual deployment and validation

For initial bootstrap before Argo CD manages the app:

```sh
./scripts/deploy-kind.sh
```

The script deploys `overlays/kind-postgres`, waits for Postgres, then waits for
FastAPI. It accepts an optional kind cluster name; that cluster must have the
storage mount and separately provisioned Secrets. Once Argo CD owns the app,
use Git commits and sync for routine changes.

To preview and validate resources without persisting changes:

```sh
kubectl kustomize overlays/kind-postgres
kubectl --context kind-argocd-postgres -n default \
  apply --dry-run=server -k overlays/kind-postgres
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
2. Update `image` in `myfastapiapp/deployment.yaml` to that version.
3. Commit and push this deployment repository, then wait for Argo CD to sync.

Use a new image tag for each code release. Manifest-only edits, such as resource
settings, replicas, and Ingress rules, need only a deployment-repository commit.
FastAPI keeps its app release version; PostgreSQL has its own image version in
`overlays/kind-postgres/postgres-statefulset.yaml`. Both are deployed through the
same Application.
See [image publishing](docs/postgres-kind.md#4-make-the-app-image-available)
if a failed release skipped image publication.
