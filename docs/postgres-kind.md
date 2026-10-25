# Postgres in kind with data on your laptop

Run commands from the `deploy` repository root. This walkthrough uses one kind
cluster, `argocd-postgres`, containing FastAPI, Postgres, Argo CD, and Traefik.
The app is available at `myfastapiapp.localhost` and Argo CD at `localhost:8080`.
For an already configured cluster, skip creation and installation steps; use Git
and Argo CD sync for routine changes.

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
| `overlays/kind-postgres/database-env.yaml` | Required app database environment variable |
| `overlays/kind-postgres/kustomization.yaml` | Combines the base app and database |
| `myfastapiapp/deployment.yaml` | App image `0.1.5`, probes, and resource settings |
| `argocd/myfastapiapp.yaml` | Argo CD Application targeting the overlay |

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
kubectl config use-context kind-argocd-postgres
kubectl --context kind-argocd-postgres get nodes --show-labels
```

Host mounts are configured at cluster creation. Applying Kubernetes YAML to an
existing cluster cannot add this Docker mount. Create the cluster with the
configuration above so the data directory is available from its first deployment.
See [kind extra mounts](https://kind.sigs.k8s.io/docs/user/configuration/#extra-mounts).

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

These are the app and database Secret files for the single cluster. The app
does not use the legacy `API_USERNAME` and `API_PASSWORD` keys. The `cp -n`
commands preserve existing files.

A password manager can generate a hex password, or you can run
`openssl rand -hex 24`. Hex avoids URL escaping issues. If you use special
characters instead, URL-encode the password in `AUTH_DATABASE_URL` while keeping
the original password in `POSTGRES_PASSWORD`.

Apply both files to the cluster:

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
a different app version, update `image` in `myfastapiapp/deployment.yaml` and
the build/load commands below to match it.

The Deployment selects `ghcr.io/pquarg/myfastapiapp:0.1.5`. Ensure that version has been
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
the cluster using the [registry authentication instructions](../README.md#registry-authentication).

For a local image build instead, the following uses the adjacent app repository
and loads the exact image name selected by the Deployment:

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
This is a direct app connection for the initial check. Step 7 sets up
`myfastapiapp.localhost` through the cluster's shared gateway.

Replace the database Pod:

```sh
kubectl --context kind-argocd-postgres -n default delete pod \
  myfastapiapp-postgres-statefulset-0
kubectl --context kind-argocd-postgres -n default get pods --watch
```

Once the replacement database Pod shows `1/1 Running`, press Ctrl+C to stop the
watch and log in with the same account. It should still exist. This verifies that
data is stored outside the replaced Pod.

## 7. Install Argo CD and expose the app

Commit and push the manifests, example files, scripts, and documentation. Review
staged changes; filled Secret files and the local kind configuration stay ignored.
There is one app registration, `argocd/myfastapiapp.yaml`, targeting the complete
`overlays/kind-postgres` deployment.

```sh
git add -A
git diff --cached
git commit -m "Consolidate local deployment onto one kind cluster"
git push
```

On a fresh cluster, install Argo CD following its
[installation guide](https://argo-cd.readthedocs.io/en/stable/getting_started/#1-install-argo-cd).
The commands below pin `v3.5.5`. Skip installation if Argo CD is already running.

```sh
kubectl --context kind-argocd-postgres create namespace argocd
kubectl --context kind-argocd-postgres -n argocd apply --server-side \
  -f https://raw.githubusercontent.com/argoproj/argo-cd/v3.5.5/manifests/install.yaml
kubectl --context kind-argocd-postgres -n argocd rollout status \
  deployment/argocd-server --timeout=300s
kubectl --context kind-argocd-postgres -n argocd \
  port-forward service/argocd-server 8080:443
```

Keep the port-forward running and open https://localhost:8080. Sign in as `admin`,
using this cluster's password. Retrieve the initial password on a fresh install
as described in [Open the app and Argo CD](../README.md#open-the-app-and-argo-cd).
Connect `git@github.com:pquarg/deploy.git` under **Settings -> Repositories**, using
a read-only Git credential that can access this repository.

Register the app, then set up the shared controller and gateway:

```sh
kubectl --context kind-argocd-postgres apply -f argocd/myfastapiapp.yaml
kubectl --context kind-argocd-postgres -n argocd wait \
  --for=jsonpath='{.status.sync.status}'=Synced \
  application/myfastapiapp-postgres-application --timeout=300s
./scripts/setup-ingress-kind.sh
kubectl --context kind-argocd-postgres -n argocd get applications
```

The app Application retains the name `myfastapiapp-postgres-application`. It
manages FastAPI and Postgres together. Argo CD applies storage first, waits for
Postgres to become healthy, then applies the app. The Secrets must already exist.
The separate `traefik` Application manages the shared Ingress controller.

Open http://myfastapiapp.localhost/api/v1/docs/ or verify:

```sh
curl http://myfastapiapp.localhost/health
curl http://myfastapiapp.localhost/api/v1/docs/openapi.json
```

Routine changes now go through Git and Argo CD sync. The gateway publishes
localhost port 80 and forwards to `argocd-postgres-control-plane`. Keep Docker
Desktop and the cluster running. A separate Compose database used for app
development has its own volume and is independent of this Kubernetes database.

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
