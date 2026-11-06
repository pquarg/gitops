# Consolidate deployment repositories without rebuilding

This checkout replaces `deploy-local` and `deploy-aws` with one `gitops` repository.
It preserves the local Git history; AWS history is retained on the local branch
`history/deploy-aws`. Original complete checkouts, including their Git metadata and
ignored files, are preserved in the timestamped `gitops-consolidation-*` directory
under the workspace's `.repo-backups/`. Treat those backups as private because
ignored local Secret files are included. Ignore policies also protect their new
local overlay locations. No cluster, Secret, database directory or Terraform state
is changed by this filesystem consolidation.

## Publish before switching either cluster

The expected remote is `git@github.com:pquarg/gitops.git`. Create that repository
with the required visibility/access, review the local changes, commit them and
push `main`. Do not publish filled Secret files or backups. If choosing a different
remote, change `repoURL` consistently in both `root/*.yaml` and both
`argocd/*/apps.yaml` before validation and publication. The checked-out `origin`
points to the expected remote; that alone does not create or publish it.

```sh
./scripts/validate.sh --ready
git diff --check
git status --short
git check-ignore apps/myfastapiapp/overlays/local/app-secrets.yaml \
  apps/myfastapiapp/overlays/local/postgres/postgres-secrets.yaml
```

Configure read access to the published GitOps repository in each Argo CD installation
and confirm a successful repository connection. Old repository-scoped deploy keys
may need new permissions or replacement keys. Keep the old remotes and their read
access available until both environments have completed cutover.

## Switch an existing environment

Use one environment at a time. Local defaults to `kind-argocd-postgres`; choose the
actual EKS alias explicitly for AWS. Verify that the live names are already
`staging-root`/`staging-apps`/`staging-myfastapiapp` locally and
`aws-root`/`aws-apps`/`aws-myfastapiapp` on AWS, with namespace `myfastapiapp`.
Older local identities require the [legacy upgrade guide](local/repository-upgrade.md).
Export existing root, ApplicationSet and Application definitions privately so the
old repository URLs, paths and revision can be restored if needed. Retain existing
Secrets and data in place. A verified database backup remains prudent before a
release; no data migration is part of this repository move.

For local, temporarily pause the root and app automatic sync:

```sh
kubectl --context kind-argocd-postgres -n argocd patch application staging-root \
  --type=merge -p '{"spec":{"syncPolicy":{"automated":{"enabled":false}}}}'
kubectl --context kind-argocd-postgres -n argocd patch application staging-myfastapiapp \
  --type=merge -p '{"spec":{"syncPolicy":{"automated":{"enabled":false}}}}'
```

For AWS, pause root sync while inspecting; app sync already remains manual:

```sh
kubectl --context aws-deployment-project -n argocd patch application aws-root \
  --type=merge -p '{"spec":{"syncPolicy":{"automated":{"enabled":false}}}}'
```

Run the matching bootstrap command from the published checkout:

```sh
./scripts/bootstrap.sh --environment local --context kind-argocd-postgres
# Separately, after verifying AWS's context and prerequisites:
./scripts/bootstrap.sh --environment aws --context aws-deployment-project
```

Bootstrap updates the **existing** root Application in place, restoring its normal
automatic registration sync. It changes the root source to `argocd/local` or
`argocd/aws`; the same existing ApplicationSet then discovers the environment's
overlays. Its generated app keeps the same name and namespace. The app source
becomes `apps/myfastapiapp/overlays/local` or `apps/myfastapiapp/overlays/aws`.
The ApplicationSet preserves a temporary pause of app automatic sync.

Review the app's desired/live diff in Argo CD before resuming any app sync. Resource
names, selectors, image, migration hooks/waves, local storage paths/retention, AWS
TLS settings and ingress settings were preserved by the refactor. Any unexpected
resource removal or replacement needs investigation before continuing. Do not
delete/recreate Applications or ApplicationSets as a way to change source paths;
deleting an Application can cascade to its managed resources.

Resume local app sync after review:

```sh
kubectl --context kind-argocd-postgres -n argocd patch application staging-myfastapiapp \
  --type=merge -p '{"spec":{"syncPolicy":{"automated":{"enabled":true,"selfHeal":true}}}}'
```

For AWS, keep manual sync and use the app release procedure when a full sync is
needed. Full syncs run migration hooks; Git rollback does not undo schema changes.
Verify each app's Synced/Healthy status, endpoints, existing records and authentication
using the environment's app runbook. Root Synced alone proves only registration.

## Roll back the registration change

Pause app/root automatic sync as above. Restore the privately exported root and
ApplicationSet source settings (old repository URLs, paths and revisions), leaving
resource names and namespaces intact. Keep the app paused until its restored desired
state is reviewed, then restore its previous sync policy and verify health/data.
No cluster rebuild, storage deletion or database reset is required.

The original GitHub deployment repositories remain usable until intentionally retired.
Only retire their remote access after both clusters are verified against GitOps.
