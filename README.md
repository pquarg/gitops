# Staging deployments

This repository deploys apps to the local kind cluster `argocd-postgres` using
Argo CD and Kustomize. Application code and Dockerfiles live in separate app
repositories. One shared Traefik controller routes requests by hostname.

| App | Namespace | Argo CD Application | URL |
| --- | --- | --- | --- |
| `myfastapiapp` | `default` | `myfastapiapp-postgres-application` | http://myfastapiapp.localhost/api/v1/docs/ |
| New apps | App directory name | `staging-<app>` | Defined by the app's Ingress |

The existing app retains its namespace and Application name to preserve its
Postgres volume binding and resource ownership. Each new app gets its own namespace.

```text
apps/
  myfastapiapp/
    base/                   # Reusable API, Service, configuration and migration Job
    postgres/               # App-owned staging database and retained storage
    ingress.yaml            # Staging hostname and routing
    kustomization.yaml      # Complete staging deployment and release image
    app-secrets.example.yaml
  <app>/                    # Each app has a root kustomization.yaml
argocd/
  kustomization.yaml        # Registrations managed from Git by staging-bootstrap
  apps.yaml                 # ApplicationSet discovers new apps under apps/*
  myfastapiapp.yaml          # Existing app registration, explicitly preserved
  traefik.yaml              # Shared ingress controller
bootstrap/staging.yaml      # Root Argo CD Application; apply once per cluster
kind/
  postgres-config.example.yaml # Storage mount and direct localhost port mapping
  legacy/                   # Gateway fallback for clusters without the mapping
scripts/
docs/
```

Commands run from this repository root. Use
`kubectl --context kind-argocd-postgres` to target staging explicitly.

- [Fresh cluster setup and recovery](docs/postgres-kind.md)
- [Upgrade an existing checkout and cluster](docs/repository-upgrade.md)
- [Add an app](docs/adding-apps.md)
- [Configure credentials](docs/credentials.md)
- [Release, back up and verify the existing app](docs/releases.md)
- [Reset disposable development data](docs/database-reset.md)
- [Run local and CI validation](docs/validation.md)

After installing Argo CD, connecting its Git credential, and pushing the manifests:

```sh
./scripts/bootstrap-kind.sh
./scripts/setup-ingress-kind.sh
```

Argo CD manages app registration, database readiness, migrations and rollouts.
New clusters map `127.0.0.1:80` directly to Traefik's NodePort. Existing clusters
can keep the legacy gateway until their next planned rebuild. Apps supply their
own Ingress through their Kustomization.

To open the Argo CD UI, keep this running:

```sh
kubectl --context kind-argocd-postgres -n argocd \
  port-forward service/argocd-server 8080:443
```

Open https://localhost:8080. Initial sign-in instructions are in the setup guide.
For app releases, edit `images[].newTag` in the app's root Kustomization and follow
its release runbook. Database changes require the controlled backup and sync procedure.
