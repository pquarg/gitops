# Rename an existing root Application

Both clusters now use `Application/root` in namespace `argocd`. The local root
reads `argocd/local`; the AWS root reads `argocd/aws`. Their separate Argo CD
installations keep these identical names independent. ApplicationSets remain
`staging-apps` and `aws-apps`, and app names/namespaces do not change.

Changing `metadata.name` creates a new Application; it does not rename a live
object. Bootstrap therefore stops when `staging-root` or `aws-root` still exists.
This operator-run handover replaces only that registration, preserving its
ApplicationSet, child Applications and workloads. Fresh installations skip it.

## 1. Prepare and select one environment

Run from `gitops`. Validate with `./scripts/validate.sh --ready`, review and publish
the change to `main` before switching a cluster. Confirm Argo CD can read GitOps.
If also moving from an old deployment repository, first complete the Git access
and database prerequisites in [repository cutover](repository-migration.md).
Review the new root's desired ApplicationSet and app sources before continuing.
For older local namespaces/databases/controllers, follow the
[legacy upgrade guide](local/repository-upgrade.md) first.

For local, use the actual context; an older cluster may still use
`kind-argocd-postgres` as explained in
[existing-cluster selection](../../infra-local/README.md#existing-clusters):

```sh
environment=local
context=kind-deployment
old_root=staging-root
appset=staging-apps
```

For AWS, separately, use the verified EKS alias:

```sh
environment=aws
context=aws-deployment-project
old_root=aws-root
appset=aws-apps
```

Select one kubeconfig file explicitly and save registrations privately:

```sh
kubeconfig="$HOME/.kube/config"
kube=(kubectl "--kubeconfig=$kubeconfig" "--context=$context")
umask 077
mkdir -p "$HOME/.local/share/gitops/backups"
backup_dir="$(mktemp -d "$HOME/.local/share/gitops/backups/root-rename.XXXXXX")"
"${kube[@]}" -n argocd get application "$old_root" -o yaml > "$backup_dir/root.yaml"
"${kube[@]}" -n argocd get applicationset "$appset" -o yaml > "$backup_dir/appset.yaml"
"${kube[@]}" -n argocd get applications -o yaml > "$backup_dir/applications.yaml"
"${kube[@]}" -n argocd get application root --ignore-not-found -o name
```

The final command must print nothing. If `root` already exists, inspect both
registrations and their managed resources before proceeding; do not overwrite
an unrelated Application. Keep backups outside the workspace. Record the old
root's resource inventory and the ApplicationSet/child Application UIDs so they
can be compared after handover.

## 2. Pause and detach the old root

Pause the old root, record existing app sync policies and pause local app syncs
as in [repository cutover](repository-migration.md#switch-an-existing-environment).
AWS apps remain manual. Wait for active root/app operations and migration Jobs
to finish; disabling auto-sync does not stop an operation already in progress.
If another parent manages the old root, pause it and remove its old-root
declaration from the published source first so it cannot recreate it.

```sh
"${kube[@]}" -n argocd patch application "$old_root" --type=merge \
  -p '{"spec":{"syncPolicy":{"automated":{"enabled":false}}}}'
"${kube[@]}" -n argocd get application "$old_root" -o yaml
```

Inspect finalizers and the saved resource inventory. Remove the old registration
without cascading to its resources:

```sh
"${kube[@]}" -n argocd patch application "$old_root" --type=merge \
  -p '{"metadata":{"finalizers":null}}'
"${kube[@]}" -n argocd delete application "$old_root" --cascade=orphan --wait=true
"${kube[@]}" -n argocd get applicationset "$appset" -o yaml
```

Verify the ApplicationSet and child Applications still have their original UIDs.
Inspect the preserved ApplicationSet's tracking metadata. If it points to the
retired root, remove its `argocd.argoproj.io/tracking-id` annotation and the
tracking label selected by `application.instanceLabelKey` in `argocd-cm`
(normally `app.kubernetes.io/instance` or `argocd.argoproj.io/instance`). Remove
only markers identifying the old root, leaving its specification unchanged.
The new root will establish its own tracking metadata during sync. Any other
registrations in the old inventory, such as legacy Traefik, need their documented
ownership transfer separately; leave their workloads intact.

## 3. Register and verify the replacement

```sh
./scripts/bootstrap.sh --environment "$environment" --context "$context" \
  --kubeconfig "$kubeconfig"
"${kube[@]}" -n argocd get application root -o yaml
"${kube[@]}" -n argocd get applicationset "$appset" -o yaml
"${kube[@]}" -n argocd get applications
```

Require `root` Synced at the published revision, the expected environment source
path, and the same ApplicationSet/child UIDs. Check that the ApplicationSet is
now tracked by `root`. Review the app diff before restoring each local app's
recorded sync policy; retain intentional maintenance pauses. Keep AWS app sync
manual. Follow the environment's app readiness, endpoint and existing-data/login
checks. This rename needs no cluster rebuild, database migration or Terraform apply.

If handover fails, retain the running workloads and maintenance pauses. Repair
Git access or registration settings and rerun bootstrap. To return to the old
name, first pause/detach any newly created `root` without cascading, clear only
its tracking markers on the preserved ApplicationSet, and recreate the old
registration from the saved specification with auto-sync paused. Omit exported
server metadata/status and deletion finalizers when recreating it. Review
sources and child policies before resuming; do not run two roots over the same
ApplicationSet. A registration rollback does not reverse app/data changes.

References: [Argo CD non-cascading deletion](https://argo-cd.readthedocs.io/en/stable/user-guide/app_deletion/),
[resource tracking](https://argo-cd.readthedocs.io/en/stable/user-guide/resource_tracking/).
