# Rename myfastapiapp to demo-api

The desired app is now `demo-api`, with source in `apps/demo-api`, Python package
`demo_api`, image `ghcr.io/pquarg/demo-api:0.1.13`, Application/namespace `demo-api`,
Deployment/Service/Ingress `demo-api`, container `api` and label `app: demo-api`.
The connection Secret is `demo-api-secrets`; the migration Job is `demo-api-migrate`.
The local hostname is `demo-api.localhost`; the AWS ALB is `dev-demo-api`.

This is a configuration change, not a completed live migration. Existing clusters,
Secrets and workloads have not been changed. **Prepare the handoff before publishing
GitOps:** the existing ApplicationSet watches the same branch and discovers the
new app automatically. The bootstrap script rejects a remaining `myfastapiapp`
registration, but cannot prevent an already running controller from reading Git.

## Retained identities

Both databases and their restricted login remain `myfastapiapp`. Preserve the
existing connection URL, password, schema and data. The app repository keeps
Compose project `myfastapiapp-dev-test` and volume `myfastapiapp_postgres-data`.
Local deployment keeps Compose project `deployment-project-local-db`, volume
`deployment-project-myfastapiapp-postgres`, ports and external credential/backup
paths. Existing ignored Secret files moved with the app directory; their contents
were not edited. Review their old object name/namespace privately before reuse.

The source Git remote remains `git@github.com:pquarg/myfastapiapp.git`; the new
package/image name does not require a GitHub repository rename. Infrastructure
keeps Terraform resource addresses, security-group identities, CloudFront resource
names and the existing `myfastapiapp_*` outputs to preserve state bindings. EKS,
kind, RDS, backend buckets/keys and provider locks retain their existing identities.

## Prepare one environment

Use explicit context `kind-deployment` for local. A live AWS handoff needs its own
AWS task scope and verified EKS context. These steps describe a planned maintenance
window; do not delete a cluster, namespace, Secret, database or storage volume.

1. Record current app health, release, replicas, sync policies, resource ownership
   and active operations. Back up and verify the database using its existing
   runbook. Keep private copies of the app/registry/Git credentials and Terraform
   state outside Git. If registrations still have `root` or environment prefixes,
   first resolve the [earlier registration handoff](registration-migration.md).
2. Pause automatic sync on Application `bootstrap` and the old app. Record the
   ApplicationSet controller replica count, stop that controller during publication,
   and wait for active reconciliations, app syncs and migration Jobs to finish.
   Pausing a parent alone does not pause its generated apps. Leave the other
   environment untouched.
3. Publish the source release first and verify that GHCR has `demo-api:0.1.13`
   for both supported architectures. Configure the new package's visibility or
   read access independently of the old image. For local, loading the exact new
   image into the existing kind cluster is also supported by the app runbook.
4. Create namespace `demo-api`. Configure `registry-credentials` there and prepare
   `demo-api-secrets` using the **existing** database URL/password from the old
   namespace. Preserve the old Secret. A new namespace does not inherit Secrets.
   Update ignored Secret files' metadata privately; their connection URL remains
   unchanged. Follow the selected [local](../apps/demo-api/overlays/local/README.md#provision-credentials)
   or [AWS](../apps/demo-api/overlays/aws/README.md) credential procedure.

On AWS, seed the new connection Secret from the old one **before** using
`bootstrap-demo-api-rds.py`. With no Secret, that helper generates a new password
and changes the existing database login. It refuses this when the previous
connection Secret is detected; preserve the password before retrying. Password
rotation is unsuitable for a rename while the old app still uses its current password. Retain the password across this
handoff. Check RDS TLS and the new namespace's image-pull access.

## Publish and switch the app

1. Validate both overlays with `./scripts/validate.sh --no-placeholders` and
   `git diff --check`. Review the new namespace, resource names, selectors, image
   and connection-Secret references. Publish GitOps while the selected registration
   chain is paused.
2. Detach the old Application without deleting its workloads: inspect finalizers
   and active operations first, remove only its Argo CD resources finalizer if
   present, then remove the registration non-cascading. Preserve the old namespace,
   Secrets, workload manifests and data for rollback. Review the finalizer rules
   in the [registration handoff](registration-migration.md).
3. Stop traffic and scale the old API to zero after recording its replicas.
   Confirm its writers and migration Jobs have stopped before running the new
   release's migration. On AWS, leave the old Ingress/ALB available for rollback;
   CloudFront still points at that origin until a reviewed edge apply switches it.
4. Restore the ApplicationSet controller's recorded replica count and bootstrap's
   previous sync policy. Reconcile `bootstrap`, then verify Application `demo-api`
   targets only the selected overlay and namespace. Local starts a full automatic
   sync; AWS needs a full manual sync including its migration Job.
5. Verify migration completion, Deployment rollout, `/health`, `/ready`, existing
   records and login. Local now uses `http://demo-api.localhost`; the old hostname
   is not a health check for the new app. AWS continues with the origin handoff
   below before public endpoint acceptance.

## AWS origin and operator settings

The ALB name is selected together by GitOps's Ingress, infrastructure's edge
lookup and its edge prerequisite checker. Create the new `demo-api` Ingress and
wait for controller-owned ALB `dev-demo-api` to be Active with healthy targets.
Editing the old Ingress's name annotation is not the migration procedure. Keep
the existing Terraform-managed frontend security group; do not import either ALB.

In the ignored `infra/environments/aws/dev/config/operator.tfvars`, rename
`eks_admin_cidrs` to `admin_ipv4_cidrs`, preserving its exact addresses. Foundation
and edge still share this allowlist. Replace output consumers of `aws_project_id`
with `aws_account_id`; saved state receives the new output on a reviewed apply.
These output/variable renames do not rename managed infrastructure.

Plan using `infra/scripts/plan.sh --environment aws/dev --stage foundation`, and
plan edge with `--stage edge --context CONTEXT` after the new ALB is healthy.
Review each complete saved plan. The edge update switches the VPC origin from
the old ALB to the new one and may replace that origin; inspect the actual plan
and allow for a maintenance window. Apply only under the authorized AWS scope.
Verify the deployed CloudFront origin, allowed/denied access, HTTPS, redirects,
authentication and log delivery using [public access checks](aws/public-access.md).

## Rollback and completion

If the new app fails, keep its sync paused and writers stopped. The retained old
namespace, Secrets, workload manifests and image allow restoring the old app's
recorded replicas under one reconciler. Restore the corresponding GitOps revision
and registration policy deliberately; do not leave both apps writing to the same
database. On AWS, inspect the deployed CloudFront origin and use a reviewed edge
plan to switch back if it changed. A Git revert does not reverse schema changes;
this release has no schema migration changes, but verify the database revision.

Keep old Ingresses, workloads, namespace and credentials until acceptance. Removing
them is a separately reviewed cleanup; deleting an old namespace also deletes its
Secrets and workloads. Never delete database volumes or reset schema for a name
change. Record live acceptance separately from passing configuration validation.
