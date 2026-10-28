# Add an app

Each immediate directory under `apps/` is a deployable app with a root
`kustomization.yaml` and an explicit Application registration in
`argocd/<directory>.yaml`. List that registration in `argocd/kustomization.yaml`.
The root `staging-bootstrap` Application manages these registrations from `main`;
each app syncs independently into its own namespace.

Use a lowercase DNS label of at most 63 characters, such as `billing-api`. Reserve
`myfastapiapp`, `argocd`, `traefik`, `default`, `bootstrap`, and names beginning `kube-`; the
existing app has an explicit registration and stays in `default`.

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
namespace: billing-api
resources:
  - deployment.yaml
  - service.yaml
  - ingress.yaml
images:
  - name: ghcr.io/pquarg/billing-api
    newTag: "0.1.0"
```

Keep the staging workloads, configuration, hostnames and image selection in the
app root. Production uses a separate repository. An Ingress using
class `traefik` and host `billing-api.localhost` shares the existing controller
and localhost port. Set CPU/memory requests and limits and meaningful probes in
the workload manifests. Keep the app's resource selectors consistent.

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
not a filesystem quota. The existing app's storage is reserved and must not be
copied unchanged. Older clusters with an app-specific mount need a planned
[storage upgrade](repository-upgrade.md#shared-storage-at-the-next-rebuild)
before using this convention.

New apps share the cluster's existing Argo CD `default` project. Namespaces organise
namespaced resources; they do not by themselves enforce network or tenant isolation.
Add AppProjects, RBAC, quotas or NetworkPolicies when access or capacity needs require them.

## Register the app

Create `argocd/billing-api.yaml`:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: staging-billing-api
  namespace: argocd
  labels:
    environment: staging
spec:
  project: default
  source:
    repoURL: git@github.com:pquarg/deploy.git
    targetRevision: main
    path: apps/billing-api
  destination:
    server: https://kubernetes.default.svc
    namespace: billing-api
  syncPolicy:
    automated:
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
```

Add `- billing-api.yaml` to the `resources` list in `argocd/kustomization.yaml`.
Use `staging-<directory>` for new Application names and `<directory>` for their
destination namespace. Only the root Application manages registrations; child
Applications point directly at their app directory. The root preserves live
auto-sync pauses through `ignoreDifferences` and `RespectIgnoreDifferences=true`.

## Provision credentials and deploy

Before pushing an auto-deployed app, create its namespace and any required Secrets:

```sh
kubectl --context kind-argocd-postgres create namespace billing-api
```

Copy the app's empty Secret example to `app-secrets.yaml`, set its namespace to
`billing-api`, fill it in your editor, set mode `600`, and check it is ignored.
Provision `registry-credentials` in the same namespace for private images using
the [credential instructions](credentials.md). Secret values stay outside Kustomize.

```sh
git check-ignore apps/billing-api/app-secrets.yaml
./scripts/validate.sh
kubectl --context kind-argocd-postgres -n billing-api \
  apply --dry-run=server -k apps/billing-api
```

Review, commit and push the app manifests, Application registration and updated
`argocd/kustomization.yaml` together. CI renders every app's root Kustomization
and the registrations. The root Application creates the app's Application from
Git; no shared ingress script change is needed. Check the
`staging-billing-api` Application's sync/health and test its hostname. Add the app
to the README registry and keep its release/backup runbook in its own directory.

For database releases, pause the live Application's automatic sync and resume it
after verification. The root preserves the pause while updating other fields.
Applying the child registration directly with `kubectl apply` enables its
declared auto-sync policy again; use the root bootstrap for routine setup. See
[Argo CD's child Application difference handling](https://argo-cd.readthedocs.io/en/stable/operator-manual/cluster-bootstrapping/#ignoring-differences-in-child-applications).

Automatic pruning is disabled for the root and app Applications. To retire an
app, pause its sync, remove its registration from `argocd/kustomization.yaml` and
Git, and let the root refresh. Then deliberately delete its live Application and
clean up its workloads, retaining or backing up its data as required. Removing
Git files alone leaves the live Application and workloads in place. Registrations
omit cascading-deletion finalizers, so deleting a registration with `kubectl`
does not delete its workloads.

## Move the existing app to a namespace later

`argocd/myfastapiapp.yaml` retains Application
`myfastapiapp-postgres-application` and its existing volume binding in `default`.
Moving it requires a separate maintenance window: back up and verify recovery,
pause sync and stop writers, plan the retained PV's claim rebinding or restore
into a new volume, provision namespace-scoped credentials, then move workloads
and verify recovery before resuming traffic. Changing only the Application's
destination namespace does not migrate the database or its data.

## Move to a managed database later

Keep the database connection in an app-owned Secret used by both the workload
and migration Job. The existing app uses `AUTH_DATABASE_URL`. When moving to RDS,
provision the database through infrastructure tooling, migrate or recreate its
data, configure network access and TLS, then switch that Secret. Run a full app
sync to apply migrations, restart the workload to refresh its environment, and
verify the deployment. Keep schema migrations and verification app-owned. See
[RDS PostgreSQL connections](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/USER_ConnectToPostgreSQLInstance.html).

After verifying the cutover, remove the local Postgres resources from the app's
Kustomization and deliberately retire the old StatefulSet, Service and storage.
Auto-pruning is disabled and storage is protected, so removing the Git entries
alone will leave the old resources running. Retain the old data until recovery
has been verified. Introduce cloud-specific configuration when it is needed;
the app-directory convention works on EKS or K3s.
