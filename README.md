# Staging deployments

This repository deploys apps to the local kind cluster `argocd-postgres` using
Argo CD and Kustomize. Application code and Dockerfiles live in separate app
repositories. One shared Traefik controller routes requests by hostname.
Production deployment configuration belongs in a separate parallel repository.
Each app directory is a complete staging deployment; no environment overlays are needed.

| App | Namespace | Argo CD Application | URL |
| --- | --- | --- | --- |
| `myfastapiapp` | `myfastapiapp` | `staging-myfastapiapp` | http://myfastapiapp.localhost/api/v1/docs/ |
| New apps | App directory name | `staging-<app>` | Defined by the app's Ingress |

Each app gets its own namespace. One root Argo CD Application manages the
app-discovery ApplicationSet and the shared Traefik registration. The
ApplicationSet discovers all apps under `apps/*`; each app syncs independently.

Existing installations of `myfastapiapp` in `default` need the
[one-time namespace migration](docs/repository-upgrade.md#move-myfastapiapp-out-of-default)
before publishing these changes or enabling app discovery.

```text
apps/
  myfastapiapp/
    deployment.yaml
    service.yaml
    configmap.yaml
    ingress.yaml
    migration-job.yaml
    postgres/               # App-owned database, retained storage, backup and reset
    kustomization.yaml      # Complete staging deployment and release image
    app-secrets.example.yaml
    README.md               # App setup, releases, verification and recovery
  <app>/                    # Each app has a root kustomization.yaml
argocd/
  kustomization.yaml        # Registrations managed from Git by staging-root
  apps.yaml                 # Discovers every app under apps/*
  traefik.yaml              # Shared ingress controller
root/staging.yaml           # Root Argo CD Application; apply once per cluster
kind/
  cluster.example.yaml      # One parent storage mount and direct localhost mapping
scripts/
docs/
```

Commands run from this repository root. Use
`kubectl --context kind-argocd-postgres` to target staging explicitly.

- [Fresh cluster setup](docs/setup.md)
- [Upgrade an existing checkout and cluster](docs/repository-upgrade.md)
- [Add an app](docs/adding-apps.md)
- [Configure credentials](docs/credentials.md)
- [Set up, release, back up and recover myfastapiapp](apps/myfastapiapp/README.md)
- [Reset disposable myfastapiapp data](apps/myfastapiapp/postgres/reset.md)
- [Run local and CI validation](docs/validation.md)

After installing Argo CD, connecting its Git credential, and pushing the manifests:

```sh
./scripts/bootstrap-kind.sh
./scripts/setup-ingress-kind.sh
```

Argo CD manages app registration, database readiness, migrations and rollouts.
kind must map `127.0.0.1:80` directly to Traefik's NodePort `30080`. Existing
clusters without this mapping need a [planned rebuild](docs/repository-upgrade.md#shared-storage-at-the-next-rebuild).
Apps supply their own Ingress through their Kustomization.
Add a new app directory and provision any required credentials; no per-app Argo CD
registration or central list edit is needed. See [adding apps](docs/adding-apps.md).

New clusters mount a single laptop storage directory into `/mnt`. Each database
owns a `<app>-postgres/` subdirectory and its own PV/PVC. Create that subdirectory
before deploying a new database; no extra kind mount is required. Existing clusters
keep their current mounts until a planned rebuild.

To open the Argo CD UI, keep this running:

```sh
kubectl --context kind-argocd-postgres -n argocd \
  port-forward service/argocd-server 8080:443
```

Open https://localhost:8080. Initial sign-in instructions are in the setup guide.
For app releases, edit `images[].newTag` in the app's root Kustomization and follow
its release runbook. Database changes require the controlled backup and sync procedure.
