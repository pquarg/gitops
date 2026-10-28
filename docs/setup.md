# Set up staging in kind

Run commands from the deployment repository root. Install Docker Desktop, kind,
kubectl, Python 3, and the [validation tools](validation.md) first. Commands target
cluster `argocd-postgres`, context `kind-argocd-postgres`.

For an existing cluster, follow the [repository upgrade](repository-upgrade.md).
Clusters without the direct localhost port mapping require a planned rebuild.

## 1. Create the cluster with shared storage and ingress

```sh
mkdir -p "$HOME/.local/share/staging/postgres/myfastapiapp-postgres"
cp -n kind/cluster.example.yaml kind/cluster.local.yaml
printf '%s/.local/share/staging/postgres\n' "$HOME"
```

Set `hostPath` in the ignored `kind/cluster.local.yaml` to that absolute parent
path. kind does not expand `$HOME` or `~` in YAML. Docker Desktop must allow
sharing this directory. Each database uses its own `<app>-postgres/` subdirectory
of this parent. Create the subdirectory before deploying that database; no extra
kind mount is needed.

The parent is mounted at `/mnt` in the kind node. For `myfastapiapp`, the path is:

```text
Postgres -> PVC -> local PV -> /mnt/myfastapiapp-postgres
                           -> laptop staging/postgres/myfastapiapp-postgres/
```

Keep both supplied node labels: new PVs use `staging.local/postgres-storage`;
the existing app's PV retains `myfastapiapp.local/postgres-storage`. Its existing
PV path and binding remain unchanged. Local PVs are manually provisioned and
retained. Their capacity declarations do not enforce filesystem quotas.
See [kind mounts](https://kind.sigs.k8s.io/docs/user/configuration/#extra-mounts)
and [Kubernetes local volumes](https://kubernetes.io/docs/concepts/storage/volumes/#local).

The config maps `127.0.0.1:80` to Traefik NodePort `30080`. Port 80 must be free.
Both mounts and port mappings are established at cluster creation.
`setup-ingress-kind.sh` checks this mapping before waiting for Traefik readiness.

```sh
kind create cluster --name argocd-postgres --config kind/cluster.local.yaml
kubectl --context kind-argocd-postgres get nodes --show-labels
```

## 2. Install Argo CD before deploying apps

On a fresh cluster, install the pinned Argo CD version:

```sh
kubectl --context kind-argocd-postgres create namespace argocd
kubectl --context kind-argocd-postgres -n argocd apply --server-side \
  -f https://raw.githubusercontent.com/argoproj/argo-cd/v3.5.5/manifests/install.yaml
kubectl --context kind-argocd-postgres -n argocd \
  rollout status deployment/argocd-server --timeout=300s
```

Keep this running in another terminal:

```sh
kubectl --context kind-argocd-postgres -n argocd \
  port-forward service/argocd-server 8080:443
```

Open https://localhost:8080 and sign in as `admin`. On a fresh installation,
retrieve its initial password:

```sh
kubectl --context kind-argocd-postgres -n argocd \
  get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d
printf '\n'
```

Use your replacement password if it was already changed. Under **Settings ->
Repositories**, connect `git@github.com:pquarg/deploy.git` with a read-only Git
credential usable by the `default` project. This is separate from GHCR authentication.
See [Argo CD installation](https://argo-cd.readthedocs.io/en/stable/getting_started/).

## 3. Prepare the apps

Follow each app's README to provision its namespace, Secrets, storage directory
and selected image before its first automatic sync. Start with
[myfastapiapp](../apps/myfastapiapp/README.md#provision-credentials). For additional
apps, follow [adding apps](adding-apps.md) and [registry credentials](credentials.md).
App setup, database releases and recovery belong in each app directory.

## 4. Validate, publish and register staging

```sh
./scripts/validate.sh
git diff --check
```

Review the changes, then commit and push them. Argo CD reads `main` from GitHub;
it cannot deploy unpushed local files. With the repository credential configured:

```sh
./scripts/bootstrap-kind.sh
./scripts/setup-ingress-kind.sh
kubectl --context kind-argocd-postgres -n argocd get applications
```

`bootstrap-kind.sh` applies only the root registration. The root Application
manages the explicit app and Traefik registrations listed in
`argocd/kustomization.yaml`. Each app Application applies its own resources. For
`myfastapiapp`, it applies storage, waits for Postgres, runs
Alembic migrations, and rolls out the API. There is no separate kubectl deployment
sequence. Root **Synced** means registrations were applied; wait for the app's
own **Synced / Healthy** status before testing it.

Follow the app's verification procedure, starting with
[myfastapiapp](../apps/myfastapiapp/README.md#verify-the-deployment). The HTTP route
is localhost port 80 -> kind node port 30080 -> shared Traefik -> app Service.
Docker Desktop and the cluster must remain running.

## Recovery

A cluster rebuild removes Kubernetes objects and Secrets. Preserve the laptop
storage parent, restore each app's original credentials, keep its PostgreSQL
major version compatible with the data, and follow the app's recovery runbook.
For `myfastapiapp`, use [its recovery procedure](../apps/myfastapiapp/README.md#recovery-after-a-cluster-rebuild).
To change an existing cluster's storage layout or add the direct port mapping,
follow the [planned rebuild guide](repository-upgrade.md#shared-storage-at-the-next-rebuild).
