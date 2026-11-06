# Set up local app deployment

Run commands from `gitops` unless stated otherwise. The default cluster
is `argocd-postgres`, context `kind-argocd-postgres`. For an existing cluster,
follow [repository cutover](../repository-migration.md). Older pre-split installations
also need [the legacy upgrade guide](repository-upgrade.md).

Existing Kubernetes databases must also follow the [database cutover](database-migration.md)
before publishing the new local overlay. The current app sync connects to an
already provisioned database; it does not create PostgreSQL or mount its storage.

## 1. Prepare the platform with infra-local

Follow [infra-local's README](../../../infra-local/README.md) to provision separate
Compose PostgreSQL, configure the kind localhost port mapping, create the cluster, install Argo CD
and install shared Traefik through Terraform Helm. Its scripts run from that separate repository:

```sh
cd ../infra-local
./scripts/create-cluster.sh
./scripts/bootstrap-kind.sh
cd ../gitops
```

Create the ignored kind config and private database settings as documented there first.
Skip cluster creation for an existing cluster. Do not rebuild or move database
files merely to consolidate the deployment repositories.

The platform must provide:

- Argo CD in namespace `argocd`, with Application and ApplicationSet CRDs ready.
- Shared Traefik in namespace `traefik` and IngressClass `traefik`.
- `127.0.0.1:80` mapped to Traefik's NodePort `30080`.
- A running separate PostgreSQL database reachable from kind Pods at
  `host.docker.internal:5433` using the restricted app login (Docker Desktop).

Fresh clusters need no app database mount. Preserve existing `/mnt` mounts,
node labels and laptop directories for unmigrated databases and legacy recovery.

## 2. Connect the deployment Git repository

Open the Argo CD UI following [infra-local's sign-in instructions](../../../infra-local/README.md#2-install-argo-cd-and-shared-ingress).
Under **Settings → Repositories**, connect
`git@github.com:pquarg/gitops.git` with a read-only Git credential usable
by the `default` project. Argo CD must show the repository connection as
successful before registration. If using another remote, update every
`repoURL` in `root/staging.yaml` and `argocd/local/apps.yaml` to match it.

This credential reads deployment manifests. App registry credentials are
separate and belong in each app's namespace. No credential for an `infra-local`
Git remote is required: its platform configuration is applied from disk.

## 3. Prepare the apps

Follow each app's README to provision its namespace, connection and registry
Secrets and selected image before automatic sync. Run its Pod-to-database
connectivity probe before registration.
Start with [myfastapiapp](../../apps/myfastapiapp/overlays/local/README.md#provision-credentials).
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
./scripts/bootstrap.sh --environment local --context kind-argocd-postgres
kubectl --context kind-argocd-postgres -n argocd get applications
```

The script validates first, checks the Argo CD controllers and shared ingress, then applies only
`staging-root`. The root manages the ApplicationSet in `argocd/local/kustomization.yaml`.
It discovers every `apps/*/overlays/local` entry point and creates an independent Application,
including `staging-myfastapiapp` in namespace `myfastapiapp`. Each app runs
migrations against the existing database and rolls out the API. Traefik
is managed separately by `infra-local`.

Root **Synced** means registration was applied; wait for the app's own
**Synced / Healthy** status before testing. Follow its
[verification procedure](../../apps/myfastapiapp/overlays/local/README.md#verify-the-deployment).
The HTTP route is localhost port 80 → kind node port 30080 → shared Traefik →
app Service. Docker Desktop and the cluster must remain running.

## Recovery

The current Compose database survives kind replacement independently. Follow
[platform rebuild](../../../infra-local/docs/rebuild.md#rebuild-with-the-external-compose-database)
and [database backup/restore](../../../infra-local/docs/database.md#backup-and-restore).
Recreate Kubernetes Secrets/images and verify Pod connectivity before registration;
verify existing records and login afterward.

**Legacy Kubernetes databases only:** the following retained methods apply to
the original laptop directory. `--delete-database` does not remove or reset the
new Compose volume. Never use legacy data removal as part of routine cutover.

For platform replacement, choose [keep the database](../../../infra-local/README.md#method-1-keep-the-database)
or [destroy the database](../../../infra-local/README.md#method-2-destroy-the-database).
Both methods recreate Kubernetes objects and Secrets. Retained data needs the
original database credentials, storage mount and a compatible PostgreSQL major
version; fresh data may use new matching credentials. Follow each app's recovery
or removal runbook before resuming traffic. App database releases and recovery
remain owned by this repository.

For a fresh local database, `infra-local/scripts/teardown-kind.sh --delete-database`
also calls myfastapiapp's app-owned deletion helper after removing the cluster.
Preview with `--dry-run` and follow the
[database removal instructions](../../apps/myfastapiapp/overlays/local/postgres/reset.md#combined-cluster-and-database-teardown).
Other apps' laptop data is preserved.

The common entry point also accepts `--kubeconfig /absolute/path`. It requires an
explicit context and uses the same file/context for every Kubernetes command.
`scripts/bootstrap-kind.sh [cluster]` remains a compatibility wrapper. Shared
Traefik is a Terraform Helm release; Argo CD reconciles application resources.
