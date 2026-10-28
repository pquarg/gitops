# Add an app

Each immediate directory under `apps/` is a deployable app with a root
`kustomization.yaml`. The `staging-apps` ApplicationSet discovers `apps/*` from
`main` and creates an independent Application named `staging-<directory>` in
namespace `argocd`, targeting a workload namespace named `<directory>`.
Adding an app requires no individual registration file or central list edit.

Use a lowercase DNS label of at most 63 characters, such as `billing-api`. Reserve
`argocd`, `traefik`, `default`, `bootstrap`, `root`, and names beginning `kube-`.
`root` is reserved because `staging-root` names the root Application.
Use a name that is not already present under `apps/`.

## App files

```text
apps/billing-api/
  deployment.yaml
  service.yaml
  ingress.yaml
  kustomization.yaml
  app-secrets.example.yaml    # Optional, empty values only
  postgres/                   # Optional app-owned database, storage and backup
  README.md                   # Setup, release, verification and recovery
```

A root Kustomization might look like:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - deployment.yaml
  - service.yaml
  - ingress.yaml
images:
  - name: ghcr.io/pquarg/billing-api
    newTag: "0.1.0"
```

Keep the staging workloads, configuration, hostnames and image selection in the
app root. The generated Application supplies the destination namespace, so app
manifests can omit `metadata.namespace`. Production uses a separate repository.
An Ingress using class `traefik` and host `billing-api.localhost` shares the
existing controller and localhost port. Set CPU/memory requests and limits and
meaningful probes in the workload manifests. Keep resource selectors consistent.

The app may include an optional `postgres/` directory and migration Job. Keep its
database, migration and rollout in the same Application so sync waves can enforce
ordering. Database schema migrations belong in the app image. Keep its backup
script and database runbooks under the app directory.

On clusters created with `kind/cluster.example.yaml`, the laptop storage parent
is mounted once at `/mnt`. Before deploying a database, create `<app>-postgres/`
inside that laptop parent. For example, `billing-api-postgres/` becomes
`/mnt/billing-api-postgres` in the kind node. Its PV should use that path and
node affinity for `staging.local/postgres-storage: "true"`. No new kind mount or
cluster rebuild is needed for each database. See [cluster setup](setup.md).

Use a unique cluster-wide PV name, its own PVC, `storageClassName: ""`, and a
`claimRef.namespace` matching the app namespace. Preserve data resources with
`persistentVolumeReclaimPolicy: Retain` and
`argocd.argoproj.io/sync-options: Prune=false,Delete=false`. Local PV capacity is
not a filesystem quota. Give each app its own PV name and data path. Older
clusters with an app-specific mount need a planned
[storage upgrade](repository-upgrade.md#shared-storage-at-the-next-rebuild)
before using this convention.

New apps share the cluster's existing Argo CD `default` project. Namespaces organise
namespaced resources; they do not by themselves enforce network or tenant isolation.
Add AppProjects, RBAC, quotas or NetworkPolicies when access or capacity needs require them.

## Automatic registration

The shared `argocd/apps.yaml` template supplies the repository, revision,
namespace creation and sync policy. Each generated Application points directly
at its app directory. Only immediate directories match `apps/*`, so nested
directories such as `postgres/` stay part of their owning app.

`myfastapiapp` follows this same convention: Application `staging-myfastapiapp`
targets namespace `myfastapiapp`.

## Provision credentials and deploy

Before pushing an auto-deployed app that needs Secrets, create its namespace:

```sh
kubectl --context kind-argocd-postgres create namespace billing-api
```

Copy the app's empty Secret example to `app-secrets.yaml`, set its namespace to
`billing-api`, fill it in your editor, set mode `600`, and check it is ignored.
Provision `registry-credentials` in the same namespace for private images using
the [credential instructions](credentials.md). Secret values stay outside Kustomize.
Apps without Secrets can let the Application create their namespace on first sync;
create it beforehand if using the server-side validation command below.

```sh
git check-ignore apps/billing-api/app-secrets.yaml
./scripts/validate.sh
kubectl --context kind-argocd-postgres -n billing-api \
  apply --dry-run=server -k apps/billing-api
```

Review, commit and push the app directory. CI renders every app's root
Kustomization and the shared registrations. Once the ApplicationSet discovers
the directory, check the `staging-billing-api` Application's sync/health and test
its hostname. Keep its release/backup runbook in its own directory.

For database releases, pause the live Application's automatic sync and resume it
after verification. The ApplicationSet preserves the pause through
`ignoreApplicationDifferences`. See
[Argo CD's ApplicationSet maintenance pauses](https://argo-cd.readthedocs.io/en/stable/operator-manual/applicationset/Controlling-Resource-Modification/#allow-temporarily-toggling-auto-sync).

## Retire an app

Automatic resource pruning is disabled for the root and app Applications.
Removing an app directory does cause the ApplicationSet to delete that generated
Application. `preserveResourcesOnDeletion: true` keeps its workloads and data in
the cluster. To retire an app, pause sync, back up its data as needed, remove its
directory from Git, and deliberately clean up the remaining workloads and
credentials. Deleting only a generated Application while its directory remains
in Git causes the ApplicationSet to recreate it. See
[ApplicationSet deletion behaviour](https://argo-cd.readthedocs.io/en/stable/operator-manual/applicationset/Application-Deletion/).

## Move to a managed database later

Keep the database connection in an app-owned Secret used by both the workload
and migration Job. `myfastapiapp` uses `AUTH_DATABASE_URL`. When moving to RDS,
provision the database through infrastructure tooling, migrate or recreate its
data, configure network access and TLS, then switch that Secret. Run a full app
sync to apply migrations, restart the workload to refresh its environment, and
verify the deployment. Keep schema migrations and verification app-owned, and
replace the Pod-based backup procedure with one suitable for RDS. See
[RDS PostgreSQL connections](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/USER_ConnectToPostgreSQLInstance.html).

After verifying the cutover, remove the local Postgres resources from the app's
Kustomization and deliberately retire the old StatefulSet, Service and storage.
Auto-pruning is disabled and storage is protected, so removing the Git entries
alone will leave the old resources running. Retain the old data until recovery
has been verified. Provision EKS and RDS through infrastructure tooling when
needed, replacing the kind storage and localhost ingress configuration for AWS.
The app-directory convention and app-owned migrations remain the same.
