# Upgrade an existing staging installation

Every app now follows the same convention: `apps/<app>` is discovered by the
ApplicationSet, Application `staging-<app>` deploys into namespace `<app>`, and
local database PVs use node label `staging.local/postgres-storage: "true"`.
The root Application manages only the ApplicationSet and shared Traefik registration.

Fresh clusters can follow [setup](setup.md). An existing `myfastapiapp` in
`default` needs the one-time cutover below. Editing Git does not move its PVC,
Secrets or data. The bootstrap script refuses to register the new configuration
while the old Application or its PVC still exists.

## Rename the root Application

The root Application is named `staging-root`. Existing clusters may still have
`staging-bootstrap`. Kubernetes resource names cannot be changed in place;
replace only the root registration and preserve its managed resources.
Complete this rename before starting the namespace migration below.

Pause the old root and wait for any active sync to finish in Argo CD:

```sh
kubectl --context kind-argocd-postgres -n argocd patch application staging-bootstrap \
  --type merge -p '{"spec":{"syncPolicy":{"automated":{"enabled":false}}}}'
```

Remove its deletion finalizers and delete it without cascading, then register
the new root. Do not use a cascading deletion in the Argo CD UI:

```sh
kubectl --context kind-argocd-postgres -n argocd patch application staging-bootstrap \
  --type merge -p '{"metadata":{"finalizers":null}}'
kubectl --context kind-argocd-postgres -n argocd delete application staging-bootstrap \
  --cascade=orphan
kubectl --context kind-argocd-postgres -n argocd apply -f root/staging.yaml
kubectl --context kind-argocd-postgres -n argocd wait \
  --for=jsonpath='{.status.sync.status}'=Synced application/staging-root --timeout=300s
```

The new root adopts the existing registrations. Child Applications, workloads,
Secrets and storage remain in place. It still deploys the revision published on
GitHub `main`; renaming the root does not publish local changes. Verify the root
and child Applications show **Synced / Healthy**.

## Move myfastapiapp out of default

This procedure requires downtime. It keeps the PostgreSQL 17 data directory at
`/mnt/myfastapiapp-postgres`, recreates its Kubernetes storage objects with the
new binding, and replaces `myfastapiapp-postgres-application` with the generated
`staging-myfastapiapp`. Keep the app image unchanged during this cutover.

If the root is still named `staging-bootstrap`, complete
[the root rename](#rename-the-root-application) first. The final bootstrap step
requires that the old root registration has been removed.

Run commands from this repository root in a shell with `set -euo pipefail`.
Complete steps 1–5 before pushing this change to `main`: Argo CD reads GitHub
and could otherwise attempt the cutover before storage is ready. Preserve the
original database password and laptop storage directory throughout.

### 1. Pause registration and application sync

If `staging-root` already exists, disable its auto-sync and wait for any
active root sync to finish. If no root Application is registered, skip this
command:

```sh
kubectl --context kind-argocd-postgres -n argocd patch application staging-root \
  --type merge -p '{"spec":{"syncPolicy":{"automated":{"enabled":false}}}}'
```

Pause the old app, wait for its active sync to finish, and temporarily stop
ApplicationSet reconciliation. Existing Applications for other apps continue
running; avoid other registration changes during this maintenance window.

```sh
kubectl --context kind-argocd-postgres -n argocd patch application \
  myfastapiapp-postgres-application --type merge \
  -p '{"spec":{"syncPolicy":{"automated":{"enabled":false}}}}'
kubectl --context kind-argocd-postgres -n argocd scale \
  deployment/argocd-applicationset-controller --replicas=0
kubectl --context kind-argocd-postgres -n argocd wait --for=delete pod \
  -l app.kubernetes.io/name=argocd-applicationset-controller --timeout=120s
```

Confirm in Argo CD that both root and old app have no running sync before
continuing. If a different parent manages the old Application, pause that parent
as well so it cannot recreate or resume the old app.

### 2. Copy credentials into the app namespace

Create namespace `myfastapiapp` if it does not exist. Copy the three existing
Secrets directly between namespaces; this command prints only resource names:

```sh
kubectl --context kind-argocd-postgres create namespace myfastapiapp
kubectl --context kind-argocd-postgres -n default get secret \
  myfastapiapp-secrets myfastapiapp-postgres-secrets registry-credentials -o json |
  python3 -c '
import json
import sys
secrets = json.load(sys.stdin)
for secret in secrets["items"]:
    secret["metadata"] = {"name": secret["metadata"]["name"], "namespace": "myfastapiapp"}
json.dump(secrets, sys.stdout)
' | kubectl --context kind-argocd-postgres create -f -
```

If the namespace or any target Secrets already exist, inspect their names and
types first and deliberately reconcile them with the original credentials.
Set `metadata.namespace: myfastapiapp` in the two ignored local Secret files
for future updates. Their passwords and connection URL stay the same: the
database Service keeps its name in the new namespace.

### 3. Stop writers and back up the database

Stop any external database writers as well as the API. Wait for any migration
Job to finish, then remove the completed Job so it cannot be restarted against
the old namespace.

```sh
kubectl --context kind-argocd-postgres -n default scale \
  deployment/myfastapiapp-deployment --replicas=0
kubectl --context kind-argocd-postgres -n default wait --for=delete pod \
  -l app=myfastapiapp-pod --timeout=120s
kubectl --context kind-argocd-postgres -n default delete job myfastapiapp-migrate \
  --ignore-not-found
NAMESPACE=default ./apps/myfastapiapp/postgres/backup.sh
```

Record the backup location and verify recovery by restoring into a disposable
database before continuing. The backup script's archive read check alone does
not test restoration. Keep writers stopped after this backup.

Shut down PostgreSQL cleanly and wait for its Pod to disappear:

```sh
kubectl --context kind-argocd-postgres -n default scale \
  statefulset/myfastapiapp-postgres-statefulset --replicas=0
kubectl --context kind-argocd-postgres -n default wait --for=delete pod \
  -l app=myfastapiapp-postgres-pod --timeout=180s
```

### 4. Release the old registration and storage binding

Remove the old Application without cascading deletion, then remove its stopped
resources. The updated app Kustomization omits `metadata.namespace`, so the
explicit `-n default` below selects the old namespaced resources. The PV is
cluster-scoped. Confirm its reclaim policy is `Retain` before deleting it:

```sh
kubectl --context kind-argocd-postgres get pv myfastapiapp-postgres-pv \
  -o 'custom-columns=NAME:.metadata.name,RECLAIM:.spec.persistentVolumeReclaimPolicy,PATH:.spec.local.path,CLAIM:.spec.claimRef.namespace'
kubectl --context kind-argocd-postgres -n argocd patch application \
  myfastapiapp-postgres-application --type merge -p '{"metadata":{"finalizers":null}}'
kubectl --context kind-argocd-postgres -n argocd delete application \
  myfastapiapp-postgres-application
kubectl --context kind-argocd-postgres -n default delete -k apps/myfastapiapp \
  --ignore-not-found --wait=true --timeout=180s
```

This deletes the old PV/PVC objects and workloads. It keeps the retained local
data directory and the original Secrets. Do not delete the laptop directory,
remove its mount, or start another PostgreSQL server against it. Recreating the
PV allows both its claim namespace and storage node affinity to change without
patching an existing bound volume.

See [Argo CD non-cascading deletion](https://argo-cd.readthedocs.io/en/stable/user-guide/app_deletion/)
and [Kubernetes retained volumes](https://kubernetes.io/docs/concepts/storage/persistent-volumes/#retain).

### 5. Label the existing storage node

Add the shared label to the node that already hosts the database directory:

```sh
kubectl --context kind-argocd-postgres label nodes \
  -l myfastapiapp.local/postgres-storage=true \
  staging.local/postgres-storage=true --overwrite
kubectl --context kind-argocd-postgres get nodes \
  -l staging.local/postgres-storage=true --show-labels
```

Confirm the selected node exposes the original data at
`/mnt/myfastapiapp-postgres/pgdata`. If no node matches the old label, identify
the actual storage node and label that node explicitly. Update the ignored kind
config to use the shared label for subsequent rebuilds; the existing mount can
stay in place until the planned storage upgrade below.

### 6. Publish, bootstrap and verify

Run `./scripts/validate.sh` and `git diff --check`, then review, commit and push
the configuration. Keep the root paused and ApplicationSet controller stopped
until the commit is available on `main`. Resume registration:

```sh
kubectl --context kind-argocd-postgres -n argocd scale \
  deployment/argocd-applicationset-controller --replicas=1
./scripts/bootstrap-kind.sh
```

The bootstrap command applies the root manifest, whose explicit
`automated.enabled: true` restores root auto-sync after the maintenance pause. The
ApplicationSet creates `staging-myfastapiapp`; it binds the retained directory
to the new PVC, starts Postgres, runs migrations and deploys the API.
Keep the existing ingress path for this namespace cutover. Clusters without the
direct localhost port mapping can adopt it during the planned rebuild below;
`setup-ingress-kind.sh` requires that mapping.

Wait for **Synced / Healthy**, then follow the app's
[verification instructions](../apps/myfastapiapp/README.md#verify-the-deployment).
Confirm the PV claim namespace is `myfastapiapp`, existing accounts still work,
and the expected records remain. Keep the backup and old Secrets until recovery
is verified. Afterwards, remove the obsolete node label and the two app-specific
Secrets in `default`; keep `registry-credentials` if another workload uses it.

If verification fails, pause the new Application and root, inspect logs, and
keep traffic stopped while recovering from the retained data or verified dump.
Stop the new Postgres before any attempt to resume the old deployment. Returning
to the old namespace requires recreating its PV/PVC binding and credentials;
reverting Git alone does not move storage back.

## Shared storage at the next rebuild

The kind example mounts one laptop parent into `/mnt`. Each app owns a
`<app>-postgres/` subdirectory. An older cluster with an app-specific mount can
complete the namespace migration above without changing that mount.

During a later planned rebuild:

1. Pause sync, stop writers, back up and verify recovery, then shut down Postgres.
   Record and preserve the original host directory and database credentials.
2. With Postgres stopped, copy its complete data directory, including `pgdata`
   and permissions, into `myfastapiapp-postgres/` under a shared laptop parent
   such as `$HOME/.local/share/staging/postgres`. Keep the original copy.
3. Copy `kind/cluster.example.yaml` to the ignored `kind/cluster.local.yaml`.
   Set the absolute parent `hostPath`, keep `/mnt`, the shared storage label and
   the direct `127.0.0.1:80` to `30080` port mapping. Editing YAML does not change
   an existing cluster. Free port 80, including any old ingress container.
4. Recreate the cluster using [setup](setup.md), provision Secrets in each app's
   namespace and verify the original data before resuming traffic.

Afterwards, each new database needs only its subdirectory and app-owned PV/PVC;
the kind mount stays the same. These repository changes do not rebuild the
cluster or move data automatically.
