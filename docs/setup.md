# Set up local app deployment

Run commands from `deploy-local` unless stated otherwise. The default cluster
is `argocd-postgres`, context `kind-argocd-postgres`. For an existing cluster,
follow [the upgrade guide](repository-upgrade.md) before publishing the split.

## 1. Prepare the platform with infra-local

Follow [infra-local's README](../../infra-local/README.md) to configure the kind
storage parent and localhost port mapping, create the cluster, install Argo CD
and register shared Traefik. Its scripts run from that separate repository:

```sh
cd ../infra-local
./scripts/create-cluster.sh
./scripts/bootstrap-kind.sh
cd ../deploy-local
```

Create the ignored kind config and storage directory as documented there first.
Skip cluster creation for an existing cluster. Do not rebuild or move database
files merely to adopt the repository split.

The platform must provide:

- Argo CD in namespace `argocd`, with Application and ApplicationSet CRDs ready.
- Shared Traefik in namespace `traefik` and IngressClass `traefik`.
- `127.0.0.1:80` mapped to Traefik's NodePort `30080`.
- Laptop storage parent mounted at `/mnt`, with node label
  `staging.local/postgres-storage: "true"`.

App-owned local PVs use `/mnt/<app>-postgres`; create the corresponding host
subdirectory before first sync. The platform owns the parent mount while each
app owns its database data, PV/PVC, backup and recovery.

## 2. Connect the deployment Git repository

Open the Argo CD UI following [infra-local's sign-in instructions](../../infra-local/README.md#2-install-argo-cd-and-shared-ingress).
Under **Settings → Repositories**, connect
`git@github.com:pquarg/deploy-local.git` with a read-only Git credential usable
by the `default` project. Argo CD must show the repository connection as
successful before registration. If using another remote, update every
`repoURL` in `root/staging.yaml` and `argocd/apps.yaml` to match it.

This credential reads deployment manifests. App registry credentials are
separate and belong in each app's namespace. No credential for an `infra-local`
Git remote is required: its platform configuration is applied from disk.

## 3. Prepare the apps

Follow each app's README to provision its namespace, database and registry
Secrets, host storage subdirectory and selected image before automatic sync.
Start with [myfastapiapp](../apps/myfastapiapp/README.md#provision-credentials).
For more apps, follow [adding apps](adding-apps.md) and
[registry credentials](credentials.md#registry-authentication).

The same release image is used for the API and its migration Job. Build and
publish it, or load that exact image into the local kind cluster. Database
credentials and filled Secret files stay outside Git and Kustomize.

## 4. Validate, publish and register staging

Install the [validation tools](validation.md), then run:

```sh
./scripts/validate.sh
git diff --check
```

Review, commit and push the deployment changes. Argo CD reads GitHub `main`;
it cannot deploy files that exist only in this checkout. With the platform and
credentials ready:

```sh
./scripts/bootstrap-kind.sh
kubectl --context kind-argocd-postgres -n argocd get applications
```

The script checks the Argo CD controllers and shared ingress, then applies only
`staging-root`. The root manages the ApplicationSet in `argocd/kustomization.yaml`.
It discovers every `apps/*` directory and creates an independent Application,
including `staging-myfastapiapp` in namespace `myfastapiapp`. Each app applies
its storage, waits for Postgres, runs migrations and rolls out the API. Traefik
is managed separately by `infra-local`.

Root **Synced** means registration was applied; wait for the app's own
**Synced / Healthy** status before testing. Follow its
[verification procedure](../apps/myfastapiapp/README.md#verify-the-deployment).
The HTTP route is localhost port 80 → kind node port 30080 → shared Traefik →
app Service. Docker Desktop and the cluster must remain running.

## Recovery

Use [infra-local's rebuild procedure](../../infra-local/docs/rebuild.md) for
platform replacement. Recreate app Secrets with their original credentials,
preserve the laptop storage parent and use a compatible PostgreSQL major
version. Follow each app's recovery runbook before resuming traffic. App
database releases and recovery remain owned by this repository.
