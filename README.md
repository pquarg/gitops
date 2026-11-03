# Local app deployments

Deploy apps to the local kind cluster `argocd-postgres` using Argo CD and
Kustomize. Application code and Dockerfiles live in separate app repositories.
The sibling [infra-local repository](../infra-local/README.md) creates the
cluster and owns Argo CD installation, host storage/port mappings and shared
Traefik. This repository owns app discovery, app manifests and releases.
Cloud deployments have their own parallel infrastructure/deployment repositories.

| App | Namespace | Argo CD Application | URL |
| --- | --- | --- | --- |
| `myfastapiapp` | `myfastapiapp` | `staging-myfastapiapp` | http://myfastapiapp.localhost/api/v1/docs/ |
| New apps | App directory name | `staging-<app>` | Defined by the app's Ingress |

Each app directory is a complete local staging deployment; no environment
overlays are needed. One root Argo CD Application manages the app-discovery
ApplicationSet. It discovers `apps/*`; each app syncs independently into its
own namespace. Apps own their database workloads, storage claims, credentials,
migrations, backups and recovery procedures.

```text
apps/
  myfastapiapp/
    deployment.yaml
    service.yaml
    configmap.yaml
    ingress.yaml
    migration-job.yaml
    postgres/               # App-owned database, retained storage, backup and reset
    kustomization.yaml      # Complete deployment and release image
    app-secrets.example.yaml
    README.md
argocd/
  kustomization.yaml        # App registrations managed by staging-root
  apps.yaml                # Discovers every app under apps/*
root/staging.yaml          # Root Argo CD Application; apply once per cluster
scripts/                   # Register apps and validate deployments
docs/
```

## Set up and deploy

1. Prepare the platform using [infra-local](../infra-local/README.md). It
   supplies the cluster, Argo CD and shared ingress before app registration.
2. Follow [deployment setup](docs/setup.md) to connect the deployment Git
   credential, provision each app's Secrets and make its selected image available.
3. Validate, review and publish these manifests to `main`, then register apps:

   ```sh
   ./scripts/validate.sh
   git diff --check
   ./scripts/bootstrap-kind.sh
   ```

Argo CD reads `git@github.com:pquarg/deploy-local.git`; it cannot deploy unpushed
local changes. App sync is automatic and includes database migrations, so
prepare credentials and retained data before registration. The bootstrap script
requires the platform and only registers this repository's root Application.
Use `kubectl --context kind-argocd-postgres` to target local staging explicitly.

For existing clusters, follow [the infrastructure ownership transfer](docs/repository-upgrade.md#split-local-infrastructure-from-app-deployment).
Older installations of `myfastapiapp` in `default` also require the
[one-time namespace migration](docs/repository-upgrade.md#move-myfastapiapp-out-of-default).
Moving files between repositories does not rebuild clusters or move data.

## Releases and recovery

Update `images[].newTag` in an app's root Kustomization and follow its release
runbook. Database changes require the app's controlled backup and sync procedure.
Manifest-only changes need a deployment-repository commit; platform changes
belong in `infra-local`.

- [Set up deployment](docs/setup.md)
- [Upgrade an existing checkout and cluster](docs/repository-upgrade.md)
- [Add an app](docs/adding-apps.md)
- [Configure app credentials](docs/credentials.md)
- [Release, back up and recover myfastapiapp](apps/myfastapiapp/README.md)
- [Reset disposable myfastapiapp data](apps/myfastapiapp/postgres/reset.md)
- [Local and CI validation](docs/validation.md)
- [Rebuild the platform](../infra-local/docs/rebuild.md)

Each database uses `<app>-postgres/` under the laptop storage parent mounted at
`/mnt`. Create that subdirectory before deploying a new database; apps require no
additional kind mount. Preserve the original data directory and passwords when
rebuilding, and restore Secrets before registering app discovery.

To open the Argo CD UI, keep this running and open https://localhost:8080:

```sh
kubectl --context kind-argocd-postgres -n argocd \
  port-forward service/argocd-server 8080:443
```

Initial sign-in and platform maintenance instructions are in `infra-local`.
