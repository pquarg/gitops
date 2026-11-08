# Migrate Argo CD registration names

Both clusters now use the same registration chain in namespace `argocd`:

| Resource | Previous local name | Previous AWS name | New name |
| --- | --- | --- | --- |
| Application | `root` | `root` | `bootstrap` |
| ApplicationSet | `staging-apps` | `aws-apps` | `apps` |
| App Application | `staging-<app>` | `aws-<app>` | `<app>` |

Kubernetes object names cannot be edited in place. This procedure replaces only
the Argo CD registrations, retaining Deployments, Services, Ingresses, namespaces,
Secrets and databases. The new app Applications adopt the existing workloads on
their first full sync. Their sync history starts again under the new names.
Local apps still sync automatically; AWS apps still require manual full syncs.
No Terraform apply or cluster rebuild is required.

The same change moves the neutral `Hello from FastAPI!` greeting into the shared
ConfigMap. Existing Pods read this environment variable at startup; after adoption,
restart the Deployment if it still serves the old greeting. This restart is
separate from changing the Argo CD registration names.

**Start before publishing the naming change.** The old `root` watches the same
`argocd/<environment>` path, so publishing first can create `apps` alongside the
old ApplicationSet and leave duplicate Applications reconciling the same resources.
If already published, pause both registration chains and inspect ownership and
active operations before proceeding; do not run this sequence blindly.

Argo CD documents [ApplicationSet resource preservation](https://argo-cd.readthedocs.io/en/stable/operator-manual/applicationset/Application-Deletion/)
and [non-cascading Application deletion](https://argo-cd.readthedocs.io/en/stable/user-guide/app_deletion/).
`--cascade=orphan` preserves Kubernetes dependents, but an Argo CD resources
finalizer can still delete workloads. Check and remove that finalizer from each
Application before deleting its registration.

## 1. Select one cluster and record the current deployment

Run from `gitops` in Bash, with the usual platform/app prerequisites satisfied.
AWS execution requires an explicitly scoped AWS task. For local:

```sh
MIGRATION_ENVIRONMENT=local
MIGRATION_CONTEXT=kind-deployment
OLD_APPSET=staging-apps
OLD_APPS=(staging-myfastapiapp)
kube=(kubectl --context="$MIGRATION_CONTEXT" --kubeconfig="$HOME/.kube/config")
```

For an authorized AWS migration, use `MIGRATION_ENVIRONMENT=aws`, the verified
EKS context, `OLD_APPSET=aws-apps` and `OLD_APPS=(aws-myfastapiapp)` instead.
Select one kubeconfig file if yours differs. Inventory **all** Applications;
add every generated old app name to `OLD_APPS` before continuing.

```sh
./scripts/validate.sh --ready
git diff --check
"${kube[@]}" -n argocd get applications,applicationsets -o wide
"${kube[@]}" -n argocd get application root "${OLD_APPS[@]}" -o yaml
"${kube[@]}" -n argocd get applicationset "$OLD_APPSET" -o yaml
"${kube[@]}" -n myfastapiapp get deployments,pods,services,ingresses
```

Verify `root.spec.source.path` is `argocd/$MIGRATION_ENVIRONMENT` and the old
ApplicationSet discovers only the matching overlays. Check the old app's selected
release and source path. Save these registration manifests privately outside Git
with restrictive permissions. Record current workload health and complete the
app's normal database backup procedure before any full sync.

Resolve failed syncs first. If an app is intentionally paused for maintenance,
postpone the migration: the replacement local Application enables automatic sync.
Inspect deletion timestamps and finalizers. Stop for terminating registrations
or finalizers other than Argo CD's `resources-finalizer.argocd.argoproj.io`
(including its `/background` variant).

## 2. Detach the old parents and pause app reconciliation

Pause `root` and wait for any active sync to finish. Confirm `.operation` is absent
and `.status.operationState.phase` is absent or terminal (`Succeeded`, `Failed`
or `Error`) before removing it:

```sh
"${kube[@]}" -n argocd patch application root --type=merge \
  -p '{"spec":{"syncPolicy":{"automated":{"enabled":false}}}}'
"${kube[@]}" -n argocd get application root -o yaml
```

After that check, remove the parent registrations without deleting dependents:

```sh
"${kube[@]}" -n argocd patch application root --type=merge \
  -p '{"metadata":{"finalizers":null}}'
"${kube[@]}" -n argocd delete application root --cascade=orphan
"${kube[@]}" -n argocd delete applicationset "$OLD_APPSET" --cascade=orphan
for app in "${OLD_APPS[@]}"; do
  "${kube[@]}" -n argocd patch application "$app" --type=merge \
    -p '{"spec":{"syncPolicy":{"automated":{"enabled":false}}}}'
done
"${kube[@]}" -n argocd get applications -o yaml
"${kube[@]}" -n myfastapiapp get jobs,pods
```

Wait until every old app has no pending/active operation and all migration Jobs
have finished. A parent pause does not stop its children or an operation already
running. Deleting the old ApplicationSet first prevents it from undoing these
app pauses. Recheck workload health before continuing.

## 3. Publish and replace the app registrations

Review and publish the validated naming change to `gitops/main`. Verify the
remote commit contains `bootstrap/<environment>.yaml` and ApplicationSet `apps`
with unprefixed app names. Do not publish unrelated image, schema or workload
changes as part of this handoff.

Once publication is confirmed and the old apps are idle, remove only their
registrations, retaining their workloads:

```sh
for app in "${OLD_APPS[@]}"; do
  "${kube[@]}" -n argocd patch application "$app" --type=merge \
    -p '{"metadata":{"finalizers":null}}'
  "${kube[@]}" -n argocd delete application "$app" --cascade=orphan
done
./scripts/bootstrap.sh --environment "$MIGRATION_ENVIRONMENT" \
  --context "$MIGRATION_CONTEXT" --kubeconfig "$HOME/.kube/config"
```

Bootstrap refuses remaining `root`, prefixed ApplicationSets or legacy app
Applications. Resolve these through the same non-cascading handoff, rather than
creating new registrations alongside them.

## 4. Verify adoption and app health

```sh
"${kube[@]}" -n argocd get applications,applicationsets -o wide
"${kube[@]}" -n argocd get application myfastapiapp -o yaml
"${kube[@]}" -n myfastapiapp rollout status \
  deployment/myfastapiapp-deployment --timeout=300s
"${kube[@]}" -n myfastapiapp get jobs,pods,services,ingresses
```

Expect Applications `bootstrap` and `myfastapiapp`, and ApplicationSet `apps`,
with no old registrations or environment labels on the new registrations.
Check the new app's owner reference points at `apps`, its overlay matches the
selected environment, and Argo CD reports no shared-resource ownership warnings.
Check every additional app in the same way.

Locally, wait for the automatic full sync, migration and rollout. On AWS, review
and manually sync the **entire** `myfastapiapp` Application to update resource
tracking and run the migration hook. The new registration's initial health alone
does not establish successful adoption. Renaming an Application changes its
[resource tracking identity](https://argo-cd.readthedocs.io/en/stable/user-guide/resource_tracking/);
a full sync records the new owner on the retained resources.

Follow the selected app's [local verification](../apps/myfastapiapp/overlays/local/README.md#verify-the-deployment)
or [AWS verification](../apps/myfastapiapp/overlays/aws/README.md#first-deployment),
including database readiness and existing-record/login checks. Do not claim the
migration is complete from `bootstrap` **Synced** alone.

## Interrupted handoff and rollback

If validation/publication fails after detaching the old parents, leave the old
apps paused while correcting the configuration; retained workloads continue to
run. Before publication, the saved old registrations can restore the old chain.
Preserve any intentional pauses when restoring them.

After publication, restore the old manifests in Git before recreating the old
chain. Pause/detach any new parents and remove new app registrations using the
same finalizer checks and non-cascading deletion sequence first. At every stage,
one Application owns each workload. Restoring registration names does not undo
a database migration; use the app's recovery procedure if a full sync changed
its schema. Preserve all Secrets, databases and infrastructure throughout.
