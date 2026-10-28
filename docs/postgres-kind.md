# Set up staging in kind

Run commands from the deployment repository root. Install Docker Desktop, kind,
kubectl, Python 3, and the [validation tools](validation.md) first. Commands target
cluster `argocd-postgres`, context `kind-argocd-postgres`.

For an existing cluster, follow the [repository upgrade](repository-upgrade.md)
instead of recreating it. Postgres and app Pods are separate; one existing Argo CD
Application manages both in namespace `default`.

## 1. Create the cluster with persistent storage and ingress

```sh
mkdir -p "$HOME/.local/share/myfastapiapp/postgres"
cp -n kind/postgres-config.example.yaml kind/postgres-config.local.yaml
printf '%s/.local/share/myfastapiapp/postgres\n' "$HOME"
```

Edit the ignored `kind/postgres-config.local.yaml`: replace `hostPath` with that
absolute laptop path. kind does not expand `$HOME` or `~` in YAML. Docker Desktop
must allow sharing this directory. Preserve the supplied node label and
`containerPath`; the app's PV refers to them.

The configuration also maps `127.0.0.1:80` to NodePort `30080`, so new clusters
need no gateway container. Port 80 must be free. Both host mounts and port mappings
are set at cluster creation.

```sh
kind create cluster --name argocd-postgres --config kind/postgres-config.local.yaml
kubectl --context kind-argocd-postgres get nodes --show-labels
```

The storage path is:

```text
Postgres Pod -> PVC -> local PV -> kind /mnt/myfastapiapp-postgres -> laptop directory
```

The PV is reserved for `default/myfastapiapp-postgres-pvc`, uses `Retain`, and has
Argo CD deletion/pruning protection. Its `1Gi` capacity is an allocation value,
not a filesystem quota. Use a separate directory and PV for each future database.
See [kind configuration](https://kind.sigs.k8s.io/docs/user/configuration/) and
[Kubernetes local volumes](https://kubernetes.io/docs/concepts/storage/volumes/#local).

## 2. Install Argo CD before deploying apps

On a fresh cluster, install the pinned Argo CD version:

```sh
kubectl --context kind-argocd-postgres create namespace argocd
kubectl --context kind-argocd-postgres -n argocd apply --server-side \
  -f https://raw.githubusercontent.com/argoproj/argo-cd/v3.5.5/manifests/install.yaml
kubectl --context kind-argocd-postgres -n argocd \
  rollout status deployment/argocd-server --timeout=300s
kubectl --context kind-argocd-postgres -n argocd \
  rollout status deployment/argocd-applicationset-controller --timeout=300s
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
credential. The ApplicationSet uses this same repository, so use a repository
credential without a project scope. This is separate from GHCR authentication.
See [Argo CD installation](https://argo-cd.readthedocs.io/en/stable/getting_started/)
and [Git generator credentials](https://argo-cd.readthedocs.io/en/stable/operator-manual/applicationset/Generators-Git/#repository-credentials-for-applicationsets).

## 3. Provision credentials

Follow [configuration and credentials](credentials.md) to create:

| Ignored file or credential | Secret in namespace `default` |
| --- | --- |
| `apps/myfastapiapp/app-secrets.yaml` | `myfastapiapp-secrets` with `AUTH_DATABASE_URL` |
| `apps/myfastapiapp/postgres/postgres-secrets.yaml` | `myfastapiapp-postgres-secrets` with `POSTGRES_PASSWORD` |
| GitHub package token, entered interactively | `registry-credentials` for private image pulls |

For the database files:

```sh
cp -n apps/myfastapiapp/app-secrets.example.yaml apps/myfastapiapp/app-secrets.yaml
cp -n apps/myfastapiapp/postgres/postgres-secrets.example.yaml \
  apps/myfastapiapp/postgres/postgres-secrets.yaml
chmod 600 apps/myfastapiapp/app-secrets.yaml \
  apps/myfastapiapp/postgres/postgres-secrets.yaml
git check-ignore apps/myfastapiapp/app-secrets.yaml \
  apps/myfastapiapp/postgres/postgres-secrets.yaml
```

Choose one password and enter it in both local files in your editor. Set
`POSTGRES_PASSWORD` to the password and `AUTH_DATABASE_URL` to
`postgresql://myfastapiapp:YOUR_PASSWORD@myfastapiapp-postgres-service:5432/myfastapiapp`.
A hex password from a password manager or `openssl rand -hex 24` avoids URL escaping.
For special characters, URL-encode the password in the URL and keep the original
value in `POSTGRES_PASSWORD`.

```sh
kubectl --context kind-argocd-postgres -n default apply \
  -f apps/myfastapiapp/app-secrets.yaml \
  -f apps/myfastapiapp/postgres/postgres-secrets.yaml
```

Secrets are provisioned separately from Argo CD. Keep filled files out of both
Git and Kustomize. Kubernetes Secret base64 encoding is reversible.

## 4. Make the app image available

The selected image tag in `apps/myfastapiapp/kustomization.yaml` applies to both
the API and migration Job. Publish the image from the separate app repository
before deploying that tag. When updating its project version, refresh and commit
its lockfile with `uv lock --project ../apps/myfastapiapp`; the image build uses
`uv sync --locked`.

Confirm its image publishing job succeeded. If a failed release skipped publication:

```sh
gh workflow run ci.yaml --repo pquarg/myfastapiapp --ref main
gh run list --repo pquarg/myfastapiapp --workflow ci.yaml --limit 3
```

For a local build instead, load the exact selected image into kind:

```sh
APP_IMAGE="$(kubectl kustomize apps/myfastapiapp |
  awk '$1 == "image:" && $2 ~ /myfastapiapp:/ { image = $2 } END { print image }')"
docker build --provenance=false -t "$APP_IMAGE" ../apps/myfastapiapp
kind load docker-image "$APP_IMAGE" --name argocd-postgres
```

Use a new image tag for every code release. `IfNotPresent` can reuse a previously
loaded image with the same tag. Existing Compose databases and Kubernetes storage
are independent; this setup does not copy existing records.

## 5. Validate, publish and register staging

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
manages the existing app registration, shared Traefik registration, and new-app
ApplicationSet. The app Application applies storage, waits for Postgres, runs
Alembic migrations, and rolls out the API. There is no separate kubectl deployment
sequence. Root **Synced** means registrations were applied; wait for the app's
own **Synced / Healthy** status before testing it.

```sh
kubectl --context kind-argocd-postgres -n default \
  rollout status deployment/myfastapiapp-deployment --timeout=300s
kubectl --context kind-argocd-postgres -n default get pvc,pods
kubectl --context kind-argocd-postgres get pv myfastapiapp-postgres-pv
curl -fsS http://myfastapiapp.localhost/health
curl -fsS http://myfastapiapp.localhost/ready
```

Open http://myfastapiapp.localhost/api/v1/docs/, register a test account, and log
in. The route is localhost port 80 -> kind node port 30080 -> Traefik -> the app
Service -> FastAPI. Docker Desktop and the cluster must remain running.

For a direct connection while diagnosing ingress:

```sh
kubectl --context kind-argocd-postgres -n default \
  port-forward service/myfastapiapp-service 18000:80
```

Open http://localhost:18000/api/v1/docs/. Inspect Pod events and migration logs
if rollout fails. Routine releases now follow the [release runbook](releases.md).

## Recovery after a cluster rebuild

Replacing the Postgres Pod preserves its PVC and laptop data. Deleting the kind
cluster preserves the laptop directory, but removes Kubernetes objects and
Secrets. Recreate the cluster with the same storage mount and node label,
provision the same Secrets, make the selected image available, reinstall Argo CD,
connect its Git credential, and bootstrap staging again.

Postgres reuses `pgdata`; `POSTGRES_PASSWORD` only initializes a new database.
Changing that Secret does not rotate an existing database role's password. Keep
the original password with your recovery information, or explicitly change the
role password inside Postgres. Keep the database major version pinned when
reusing its files.

Do not delete the PVC for a rollout. A retained PV can remain `Released` with the
old claim UID after PVC deletion and require deliberate recovery. PV/PVC retention
does not protect against deleting the laptop folder or disk failure. Back up
important data and verify an actual restore. Only one Postgres server may use a
data directory at a time. See [PV retention](https://kubernetes.io/docs/concepts/storage/persistent-volumes/#retain).
