# Upgrade an existing staging installation

Use this guide only for older root names, namespaces, mounted databases or
platform ownership. For the recent deployment-repository consolidation, use
[repository cutover](../repository-migration.md). Fresh installations use
[setup](setup.md).

Examples use `deployment` / `kind-deployment`. For an older `argocd-postgres`
cluster, use [existing-cluster selection](../../../infra-local/README.md#existing-clusters)
and substitute its actual name/context in every command.

The current contract is Application `root` → ApplicationSet
`staging-apps` → Application `staging-<app>`, with workloads in namespace `<app>`.
Terraform in `infra-local` owns Argo CD and shared Traefik. The active local app
overlay connects to separate Compose PostgreSQL; it does not deploy a database,
PV or PVC. See [database cutover](database-migration.md).

Older versions of this guide assumed the local overlay still included
`./postgres` and that `infra-local/argocd` could be applied with Kustomize. Those
assumptions no longer hold. Do not use the current app overlay to recreate a
legacy PostgreSQL installation or apply `../infra-local/argocd` with kubectl.
For legacy manifest recovery, use a reviewed revision containing the database
resources; original checkouts remain privately preserved under the workspace's
`.repo-backups/`.

## Before any upgrade

Inspect context `kind-deployment`, actual root/child Application sources,
parents, finalizers and sync policies, both controllers' ownership, app namespaces,
Secrets, database endpoint, PV/PVC bindings and the live kind mounts. Record Git
revisions and export configuration/credentials privately outside Git. Check
existing login, records, readiness and database backup restoration.

Pause affected root/app auto-sync and finish active syncs and migration Jobs
before changing ownership. Pause ApplicationSet reconciliation when replacing
child registrations, recording its prior replica count. Stop traffic and all
writers before a database cutover. Keep the original database files, mount paths,
credentials and backups until separately authorized retirement. A Git revert
cannot move storage or restore a changed schema.

The bootstrap guard still rejects `staging-bootstrap`,
`myfastapiapp-postgres-application` or `default/myfastapiapp-postgres-pvc`. It does
not perform those migrations for you. Do not bypass it by deleting live storage
before the data recovery and ownership plan is reviewed.

## Rename the root Application

The current root is `root`. An installation using `staging-root` follows the
[root handover](../root-application-migration.md). For an installation still using
`staging-bootstrap`, replace only that registration and preserve its managed
resources. Before registering the current root, pause its affected child apps
and verify they are ready for the current overlay, including the separate
database. Otherwise the new root can initiate an unintended app cutover.

Run from `gitops`. Pause the old root and wait for any active sync to finish:

```sh
kubectl --context kind-deployment -n argocd patch application staging-bootstrap \
  --type merge -p '{"spec":{"syncPolicy":{"automated":{"enabled":false}}}}'
```

Privately preserve the registration, inspect its finalizers and then remove only
the root registration without cascading deletion:

```sh
kubectl --context kind-deployment -n argocd patch application staging-bootstrap \
  --type merge -p '{"metadata":{"finalizers":null}}'
kubectl --context kind-deployment -n argocd delete application staging-bootstrap \
  --cascade=orphan
```

Once the required namespace/database and controller ownership work is complete,
register the published current root using the explicit-environment bootstrap
command in [setup](setup.md#4-validate-publish-and-register-staging). Restore any
paused ApplicationSet controller to its recorded replica count first. Root
Synced confirms registration only; verify the app and its data separately.

## Move myfastapiapp out of default

This needs a maintenance window and a plan for the actual legacy installation.
The current destination is namespace `myfastapiapp` with an external database;
copying a namespace or applying the current overlay does not transfer records.

1. Pause the old root/app and ApplicationSet reconciliation as above. Privately
   preserve the original connection, PostgreSQL and registry Secrets from
   `default`. Keep the old app image and PostgreSQL major version recorded.
2. Stop API/external writers and wait for migration Jobs. Back up the old
   database from its actual namespace:

   ```sh
   NAMESPACE=default ./apps/myfastapiapp/overlays/local/postgres/backup.sh deployment
   ```

   Keep writers stopped. Follow steps 2–3 of the
   [database cutover](database-migration.md#2-prepare-and-test-the-separate-database)
   to verify a restore, restore into separate Compose storage, create namespace
   `myfastapiapp`, and provision its new app connection and registry Secrets.
   Use `default` for operations on the **old** PostgreSQL workload and
   `myfastapiapp` for the new app and connectivity probe. Do not copy the old
   database Service URL into the new app connection Secret.
3. After the restore and Pod connectivity probe succeed, stop the old database
   cleanly. Keep its laptop files and original Secrets. Detach
   `myfastapiapp-postgres-application` without cascading deletion, after checking
   its parents/finalizers. Review removal of the stopped old API, completed
   migration Job, ingress and Service so they cannot receive traffic or restart
   against stale data.
4. The bootstrap also requires the obsolete `default/myfastapiapp-postgres-pvc`
   to be absent. Before removing old storage **objects**, verify the actual PV's
   `Retain` reclaim policy and host path, take private object snapshots, and
   explicitly review that removal scope. Preserve the retained data directory,
   mount and original credentials. Do not use `kubectl delete -k` on the current
   app overlay for this: it no longer includes the old database or storage.
5. Complete controller adoption and Git source cutover, restore the recorded
   ApplicationSet replica count, then bootstrap local GitOps. Keep the new app
   paused until its desired/live diff and connection are reviewed. Perform a
   full app sync with Prune, Force and Replace off; verify migration logs,
   readiness, expected records and existing login before restoring traffic and
   the normal automatic app sync policy.

Do not delete original Secrets or storage files as part of namespace migration.
If the new database has received writes or migrations, the old database is stale.
Use the [cutover recovery procedure](database-migration.md#recovery-if-cutover-fails)
instead of simply restarting the old app. For a deliberate recovery into the
legacy Kubernetes layout, select compatible manifests and review the PV/PVC
binding separately; current `main` will not recreate them.

## Shared storage at the next rebuild

Fresh clusters using Compose PostgreSQL need no database mount. Existing `/mnt`
mounts and `/mnt/<app>-postgres` directories remain available for unmigrated apps
and legacy recovery. Changing Git or kind YAML cannot change a running node's
mounts or published ports.

Only if a planned rebuild still needs legacy storage, use
`infra-local/kind/cluster-storage.example.yaml` as the reference. The ordinary
`cluster.example.yaml` has no database mount or storage label. Preserve existing
ignored configuration; set the absolute laptop parent, `/mnt`, label
`staging.local/postgres-storage: "true"` and `127.0.0.1:80` → `30080` mapping.

Before any data relocation, stop PostgreSQL and writers, back up and verify
restoration, and preserve the complete original directory and permissions. Follow
[legacy platform rebuild](../../../infra-local/docs/rebuild.md#legacy-kubernetes-database-rebuild)
for the separately authorized cluster replacement. Do not rebuild or relocate
storage merely to adopt the repository split or external database.

## Split local infrastructure from app deployment

The current split assigns kind, controllers and Compose PostgreSQL to
`infra-local`; app definitions, connection Secrets and migration Jobs stay here.
For an older installation whose root still owns a Traefik Application:

1. Preserve existing ignored kind files, host mounts, local Terraform states,
   Git/registry/database credentials and app maintenance pauses. Inspect actual
   state and releases before any platform bootstrap.
2. Connect the published `git@github.com:pquarg/gitops.git` remote in Argo CD and
   follow [repository cutover](../repository-migration.md), reviewing the local
   database prerequisite before resuming app sync. Switch existing registration
   sources in place, then use the root handover if its old name remains. The new
   root contains only app discovery; keep pruning
   off so removing its Traefik registration cannot delete controller workloads.
3. Follow [Terraform adoption](../../../infra-local/docs/terraform.md#adopt-an-existing-installation)
   to transfer controller ownership. It covers both manifest-based Argo CD and
   Traefik managed through an Application. Detach the Traefik Application without
   cascading deletion and adopt/import real Helm releases into
   `infra-local/terraform/platform`. An import alone cannot convert manifests
   into a Helm release. Do not re-register the retired Traefik Application.
4. Review the combined platform plan, then verify controller readiness, Git
   access, unchanged app identities, localhost routing and retained data/login.
   Restore recorded sync policies only after verification. Keep original state
   backups until recovery and the one-owner rule are checked.

Platform setup reads `infra-local` from disk; no infrastructure Git credential or
platform Git-watching Application is required. A controller change takes effect
through a reviewed Terraform apply. App changes require publication to GitOps.

## Consolidate platform Helm ownership

The active root is `infra-local/terraform/platform`, owning Argo CD and Traefik.
The old `terraform/argocd` directory is retained only for private state recovery.
Use the [adoption guide](../../../infra-local/docs/terraform.md#adopt-an-existing-installation)
for all state/Helm ownership steps; do not initialize or apply the retired root.
After migration, the app registration entry point is:

```sh
./scripts/bootstrap.sh --environment local --context kind-deployment
```

This registers apps on the prepared platform. It neither installs controllers
nor transfers database records. Configuration checks are separate from successful
live migration; follow the [app verification](../../apps/myfastapiapp/overlays/local/README.md#verify-the-deployment)
and [platform adoption acceptance checks](../../../infra-local/docs/terraform.md#recovery-and-validation-limits).
