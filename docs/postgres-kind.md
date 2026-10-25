# Postgres in kind with data on your laptop

Run commands from the `deploy` repository root. This walkthrough creates a second
cluster named `argocd-postgres`; your existing `argocd-demo` cluster and Compose
database can keep running. Docker Desktop needs enough resources for both clusters.

The new database starts empty. Existing Compose records stay in that database's
named Docker volume; they are not copied by these manifests.

## What a Secret does

`AUTH_DATABASE_URL` is still an environment variable inside FastAPI. A Kubernetes
Secret supplies its value without embedding the password in the tracked Deployment
or ConfigMap. For example, the overlay adds this to the Deployment:

```yaml
env:
  - name: AUTH_DATABASE_URL
    valueFrom:
      secretKeyRef:
        name: myfastapiapp-secrets
        key: AUTH_DATABASE_URL
```

The hostname, port, and database name are ordinary configuration. The complete URL
also contains a password, so we store the complete value in a Secret. You could
separate those fields, but the current app expects a single URL. Secret values are
not automatically encrypted at rest; keep the filled files out of Git too. See
[Kubernetes Secret environment variables](https://kubernetes.io/docs/tasks/inject-data-application/distribute-credentials-secure/)
and [Secrets](https://kubernetes.io/docs/concepts/configuration/secret/).

## How the storage fits together

```mermaid
flowchart TD
    app[FastAPI Pod] -->|Service on port 5432| db[Postgres Pod]
    db -->|mounts data volume| pvc[PersistentVolumeClaim]
    pvc -->|claims| pv[PersistentVolume]
    pv --> node[kind node: /mnt/myfastapiapp-postgres]
    node -->|kind extraMounts| disk[Laptop folder outside Git]
```

The PVC is the request for storage. The PV describes the actual storage, including
which node can access it. kind's host mount connects that node directory to your
laptop directory. A StatefulSet replaces the database Pod while reusing its PVC.

The overlay uses one fixed local PV, reserved for one named PVC in `default`.
`storageClassName: ""` prevents the default provisioner from allocating a different
directory. The node label in the kind configuration matches the PV's node affinity.
The `1Gi` capacity is a Kubernetes allocation value, not a filesystem quota on the
laptop folder. See [local volumes](https://kubernetes.io/docs/concepts/storage/volumes/#local).

| File | Purpose |
| --- | --- |
| `kind/postgres-config.example.yaml` | Laptop directory mount and storage node label |
| `overlays/kind-postgres/postgres-storage.yaml` | Fixed PV and PVC; `Retain` policy |
| `overlays/kind-postgres/postgres-service.yaml` | Internal database DNS name and port |
| `overlays/kind-postgres/postgres-statefulset.yaml` | Postgres 17, probes, and data mount |
| `overlays/kind-postgres/database-env.yaml` | App database environment variable and memory settings |
| `overlays/kind-postgres/kustomization.yaml` | Combines the base app and database; selects app image `0.1.5` |
| `argocd/myfastapiapp-postgres.yaml` | Argo CD Application targeting the overlay |

## 1. Choose the laptop directory

```sh
mkdir -p "$HOME/.local/share/myfastapiapp/postgres"
cp -n kind/postgres-config.example.yaml kind/postgres-config.local.yaml
```

Edit `kind/postgres-config.local.yaml`. Replace `hostPath` with the absolute path
to that directory; on this laptop that is:

```yaml
hostPath: /Users/admin/.local/share/myfastapiapp/postgres
```

Leave `containerPath` and the node label as supplied. kind does not expand `$HOME`
or `~` inside YAML. Docker Desktop must allow file sharing for the chosen folder.
The local config is Git-ignored because its path belongs to your machine.

## 2. Create a cluster with the mount

```sh
kind create cluster --name argocd-postgres --config kind/postgres-config.local.yaml
kubectl --context kind-argocd-postgres get nodes --show-labels
```

Host mounts are configured at cluster creation. Applying Kubernetes YAML to an
existing cluster cannot add this Docker mount. The walkthrough uses a new cluster
to avoid rebuilding the working one. See [kind extra mounts](https://kind.sigs.k8s.io/docs/user/configuration/#extra-mounts).

## 3. Create the database secrets

```sh
cp -n overlays/kind-postgres/app-secrets.example.yaml \
  overlays/kind-postgres/app-secrets.yaml
cp -n overlays/kind-postgres/postgres-secrets.example.yaml \
  overlays/kind-postgres/postgres-secrets.yaml
chmod 600 overlays/kind-postgres/app-secrets.yaml \
  overlays/kind-postgres/postgres-secrets.yaml
git check-ignore overlays/kind-postgres/app-secrets.yaml \
  overlays/kind-postgres/postgres-secrets.yaml
```

Choose one password and enter it in both local files in your editor:

- `postgres-secrets.yaml`: set `stringData.POSTGRES_PASSWORD`.
- `app-secrets.yaml`: set `stringData.AUTH_DATABASE_URL` to
  `postgresql://myfastapiapp:YOUR_PASSWORD@myfastapiapp-postgres-service:5432/myfastapiapp`.

These files are separate from `myfastapiapp/secrets.yaml`, which belongs to the
existing cluster. The current authentication code does not use the legacy
`API_USERNAME` and `API_PASSWORD` keys. The `cp -n` commands preserve existing files.

A password manager can generate a hex password, or you can run
`openssl rand -hex 24`. Hex avoids URL escaping issues. If you use special
characters instead, URL-encode the password in `AUTH_DATABASE_URL` while keeping
the original password in `POSTGRES_PASSWORD`.

Apply both files to the new cluster:

```sh
kubectl --context kind-argocd-postgres -n default apply \
  -f overlays/kind-postgres/app-secrets.yaml \
  -f overlays/kind-postgres/postgres-secrets.yaml
```

These files are excluded from Kustomize and Git. Argo CD manages references to the
Secrets; you provision the actual Secrets separately.

## 4. Make the app image available

After changing the app version in `pyproject.toml`, refresh its lockfile before
building or publishing:

```sh
uv lock --project ../apps/myfastapiapp
```

Docker uses `uv sync --locked`, which fails if the lockfile still records an older
project version. Commit the refreshed lockfile with the app release. If you choose
a different app version, update `images[].newTag` in the overlay's
`kustomization.yaml` and the build/load commands below to match it.

The overlay selects `ghcr.io/pquarg/myfastapiapp:0.1.5`. Ensure that version has been
published: a successful checks job can still have a skipped image job. If a version
bump failed CI and a later lockfile fix passed, use the app repository's **CI ->
Run workflow** action on `main` to retry publishing that version after all checks
pass. Commit and push the app repository's CI recovery change before running this
command; manual publication is restricted to `main`.
From the command line:

```sh
gh workflow run ci.yaml --repo pquarg/myfastapiapp --ref main
gh run list --repo pquarg/myfastapiapp --workflow ci.yaml --limit 3
```

Confirm the **Build image and publish version changes** job succeeds before
relying on the registry. For a private image, provision `registry-credentials` in
the new cluster using the [registry authentication instructions](../README.md#registry-authentication),
changing the context in those instructions to `kind-argocd-postgres`.

If the existing cluster's registry credential is still valid, you can copy it
directly without printing or saving its value:

```sh
kubectl --context kind-argocd-demo -n default get secret registry-credentials -o json |
  python3 -c '
import json
import sys

source = json.load(sys.stdin)
secret = {key: source[key] for key in ("apiVersion", "kind", "type", "data")}
secret["metadata"] = {"name": "registry-credentials", "namespace": "default"}
json.dump(secret, sys.stdout)
' |
  kubectl --context kind-argocd-postgres -n default apply -f -
```

For a local image build instead, the following uses the adjacent app repository
and loads the exact image name selected by the overlay:

```sh
docker build --provenance=false -t ghcr.io/pquarg/myfastapiapp:0.1.5 ../apps/myfastapiapp
kind load docker-image ghcr.io/pquarg/myfastapiapp:0.1.5 --name argocd-postgres
```

The local build uses a single platform without provenance attestations for
loading into kind. This setting is for the local test build.

Use a new version tag for subsequent code changes. `IfNotPresent` can reuse a
previously loaded or downloaded image with the same tag.

## 5. Apply and inspect the resources

Before registering this app with Argo CD, do one manual deployment:

```sh
kubectl kustomize overlays/kind-postgres
kubectl --context kind-argocd-postgres -n default apply --dry-run=server \
  -k overlays/kind-postgres
kubectl --context kind-argocd-postgres -n default apply \
  -k overlays/kind-postgres
kubectl --context kind-argocd-postgres -n default rollout status \
  statefulset/myfastapiapp-postgres-statefulset --timeout=180s
kubectl --context kind-argocd-postgres -n default rollout status \
  deployment/myfastapiapp-deployment --timeout=180s
kubectl --context kind-argocd-postgres -n default get pv,pvc,pods
```

Both PV and PVC should show `Bound`, and both application and database Pods should
be ready. The app can restart while Postgres initially starts; its startup connects
to the database and creates the tables. For troubleshooting, inspect Pod events
with `kubectl --context kind-argocd-postgres -n default describe pod POD_NAME`.

Postgres writes to the `pgdata` subdirectory of your laptop folder. This matches
the [Postgres 17 image's data location](https://hub.docker.com/_/postgres); keep the
major version pinned when reusing existing database files.

To move existing Compose records into this new database, take a `pg_dump` backup
and restore it before creating new accounts here. Stop the new app during that
restore. The existing Compose volume remains independent of this setup.

## 6. Test the app and Pod replacement

In another terminal, keep this running:

```sh
kubectl --context kind-argocd-postgres -n default \
  port-forward service/myfastapiapp-service 18000:80
```

Open http://localhost:18000/api/v1/docs/. Register a test account, then log in.
This port-forward targets the new cluster; `myfastapiapp.localhost` still points
through your existing gateway to the original cluster.

Replace the new database Pod:

```sh
kubectl --context kind-argocd-postgres -n default delete pod \
  myfastapiapp-postgres-statefulset-0
kubectl --context kind-argocd-postgres -n default get pods --watch
```

Once the replacement database Pod shows `1/1 Running`, press Ctrl+C to stop the
watch and log in with the same account. It should still exist. This verifies that
data is stored outside the replaced Pod.

## 7. Let Argo CD manage the overlay

First commit and push the new overlay and its Argo CD Application, together with
the example files and documentation you want to keep. Review the staged changes;
the filled Secret files and machine-specific kind config must remain ignored.
The original Application still targets the base path `myfastapiapp`; this new
Application targets `overlays/kind-postgres` in the new cluster.

The base Deployment stays on the existing cluster's working `0.1.1` image and
resource settings. Stage this setup with:

```sh
git add .github/workflows/validate.yaml .gitignore README.md \
  argocd/myfastapiapp-postgres.yaml docs/postgres-kind.md \
  kind/postgres-config.example.yaml \
  overlays/kind-postgres
git diff --cached
git commit -m "Add Postgres kind overlay with laptop-backed storage"
git push
```

The overlay selects the Postgres app image and memory settings independently of
the base Deployment. Publishing it does not upgrade the existing cluster's app.

Install Argo CD into the new cluster following its [installation guide](https://argo-cd.readthedocs.io/en/stable/getting_started/#1-install-argo-cd),
using `--context kind-argocd-postgres` on each kubectl command. These commands pin
`v3.5.5`, matching the existing cluster:

```sh
kubectl --context kind-argocd-postgres create namespace argocd
kubectl --context kind-argocd-postgres -n argocd apply --server-side \
  -f https://raw.githubusercontent.com/argoproj/argo-cd/v3.5.5/manifests/install.yaml
kubectl --context kind-argocd-postgres -n argocd rollout status \
  deployment/argocd-server --timeout=300s
kubectl --context kind-argocd-postgres -n argocd \
  port-forward service/argocd-server 18080:443
```

Keep the port-forward running and open https://localhost:18080. Follow the Argo CD
guide to retrieve the initial admin password and log in. Connect
`git@github.com:pquarg/deploy.git` under **Settings -> Repositories**, using a
read-only Git credential that can access this repository. The new Argo CD install
does not inherit the old install's repository credentials.

In another terminal, install the existing Traefik configuration into this cluster
so it can handle the overlay's Ingress and report its address:

```sh
kubectl --context kind-argocd-postgres apply -f argocd/traefik.yaml
kubectl --context kind-argocd-postgres -n argocd wait \
  --for=jsonpath='{.status.sync.status}'=Synced application/traefik --timeout=300s
kubectl --context kind-argocd-postgres -n traefik rollout status \
  deployment/traefik --timeout=300s
```

Next, register the application:

```sh
kubectl --context kind-argocd-postgres apply -f argocd/myfastapiapp-postgres.yaml
kubectl --context kind-argocd-postgres -n argocd get applications
```

Argo CD applies storage first, waits for Postgres to become healthy, then applies
the app. The Secrets must already exist. Routine changes now go through Git and
Argo CD sync. Avoid registering both app Applications in the same cluster:
they would manage the same base resources.

Continue using port-forward for app access. If you later want
`myfastapiapp.localhost` to target the new cluster, stop the original Docker gateway
and run `./scripts/setup-ingress-kind.sh argocd-postgres`. Only one gateway can
publish localhost port 80. The existing Compose database is unrelated to that
gateway.

## What happens on a cluster rebuild

The database survives deletion of its Pod. The laptop directory also survives
deletion of the kind cluster, but the Kubernetes objects and Secrets do not.
To rebuild, create the cluster with the same host directory and node label, apply
the same Secrets, make the image available, and deploy the same overlay again.
Postgres will reuse `pgdata` instead of initializing a new database. Reinstall Argo
CD and reconnect its Git repository if it managed the deleted cluster.

Keep the database password with your recovery information. `POSTGRES_PASSWORD`
initializes a new database; changing that Secret alone does not change an existing
Postgres role's password. Rebuilding with existing data requires the original
password, or an explicit password change inside Postgres.

The PV uses `persistentVolumeReclaimPolicy: Retain`. Both PV and PVC also have
`Prune=false,Delete=false` annotations so Argo CD preserves them when pruning or
deleting its Application. These controls do not protect against deleting the
laptop folder. See [PV retention](https://kubernetes.io/docs/concepts/storage/persistent-volumes/#retain)
and [Argo CD deletion options](https://argo-cd.readthedocs.io/en/stable/user-guide/sync-options/#no-resource-deletion).

If you delete and recreate only the PVC in an existing cluster, a retained PV
can remain `Released` with the old claim UID. Rebinding it requires deliberate
manual recovery; deleting the PVC is not part of normal rollout or restart.

Only one Postgres server should use this data directory at a time. Use another
laptop directory if you create another database cluster. Take `pg_dump` backups
for data you want to preserve beyond laptop or disk failure.
