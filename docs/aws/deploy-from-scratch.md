# Deploy from start to finish

Run app commands from `gitops`, alongside the actual `../infra-aws` checkout.
This runbook provisions a fresh environment/database; an existing environment
must complete [state migration](../../../infra-aws/docs/state-migration.md) first.
No migration, apply or destructive rebuild is implied by editing configuration.
Use explicit Kubernetes contexts and review every saved Terraform plan.

## 1. Check tools, credentials and backend

Install Terraform `1.17.x`, AWS CLI v2, kubectl, Python 3, Node.js and the
[validation tools](validation.md). Authenticate profile `aws-project`; verify
account `245361883993` and Region `eu-north-1`:

```sh
aws sts get-caller-identity --profile aws-project --region eu-north-1
```

The existing S3 backend and bootstrap key remain unchanged. If absent, follow
[backend creation](../../../infra-aws/docs/teardown.md#rebuild-after-deleting-the-backend).
Never create fresh local state over an existing remote installation. Inspect
which stages/resources exist before proceeding. Keep state/Secret backups outside
Git. For existing data, follow the app's backup/recovery procedure rather than
assuming a fresh RDS database will restore it.

## 2. Apply foundation

Prepare `../infra-aws/config/operator.tfvars` from its checked-in example. Enter
the approved operator IPv4 `/32` allowlist; foundation and edge use that one file.
Keep old restrictions unchanged during an ownership migration. Then:

```sh
../infra-aws/scripts/plan.sh foundation
terraform -chdir=../infra-aws/terraform/foundation apply stage.tfplan
terraform -chdir=../infra-aws/terraform/foundation output eks_cluster_name
terraform -chdir=../infra-aws/terraform/foundation output database
terraform -chdir=../infra-aws/terraform/foundation output myfastapiapp_alb_security_group
```

This full root owns VPC/EKS/RDS and controller IAM/Pod Identity/frontend SG/rules.
It can plan/apply before any app or ALB exists. No `-target` bootstrap is needed.
Review deletion protection, retained backups and allowed addresses. Outputs
contain metadata and an administrator secret ARN, never the password.

## 3. Apply platform

Select one kubeconfig/context consistently:

```sh
EKS_CONTEXT=aws-deployment-project
aws eks update-kubeconfig --name deployment-project-dev --profile aws-project \
  --region eu-north-1 --alias "$EKS_CONTEXT"
../infra-aws/scripts/plan.sh platform --context "$EKS_CONTEXT"
terraform -chdir=../infra-aws/terraform/platform apply stage.tfplan
```

Add `--kubeconfig /absolute/file` to the AWS update-kubeconfig and stage command
when selecting another file, and every subsequent Kubernetes/bootstrap command.
The database and registry Python helpers accept a context but no `--kubeconfig`
option; select the same single file through `KUBECONFIG=/absolute/file` when
invoking those helpers. The checker verifies the endpoint matches EKS and Pod Identity prerequisites are
available. Platform installs pinned Argo CD and load balancer controller releases.
Their pins/values live in `../infra-aws/argocd/` and
`../infra-aws/load-balancer-controller/`. Platform uses AWS token-based Helm auth;
it reads EKS metadata without another root's sensitive state.

## 4. Prepare credentials, images and Git

Follow [setup](setup.md#2-verify-platform-components-and-git-access) to open the
private Argo CD UI and configure read access to
`git@github.com:pquarg/gitops.git`. Keep SSH host verification enabled.
Follow the [app runbook](../../apps/myfastapiapp/overlays/aws/README.md) and
[credential guide](credentials.md) to provision:

- Namespace `myfastapiapp`, its RDS app login/schema permissions and database
  Secret. The database helper uses AWS discovery; it does not read Terraform state.
- `registry-credentials` for the selected published GHCR image. Preserve the
  existing release tag and worker architecture; publish a new image in the app repo
  for a new release rather than changing infrastructure pins.
- The frontend SG annotation in `apps/myfastapiapp/overlays/aws/ingress.yaml`, using foundation's
  `myfastapiapp_alb_security_group` output. Keep ALB name `deployment-project-dev-app`,
  internal IPv4 scheme, HTTP listener, IP targets and `/ready` checks unchanged.

The RDS CA bundle is committed public material. Passwords, filled Secret files,
Git keys, tokens, real `.tfvars`, plans and state stay outside Git.

## 5. Validate, publish and register

```sh
./scripts/validate.sh
./scripts/validate.sh --environment aws --ready
git diff --check
# After reviewing and publishing the deployment manifests to main:
./scripts/bootstrap.sh --environment aws --context "$EKS_CONTEXT"
```

The bootstrap validates first, verifies CRDs/controllers/IngressClass and applies
only the `root` registration. Existing `aws-root` installations first need the
[root handover](../root-application-migration.md). `bootstrap-eks.sh CONTEXT` remains a
compatibility wrapper. Root Synced confirms registration, not app health or
migration success. App `aws-myfastapiapp` remains **manually synced**. Perform a
full sync with Force/Replace off so its migration hook runs; verify logs, Alembic
revision, app readiness and database access using the app runbook.

## 6. Wait for the app ALB and apply edge

```sh
../infra-aws/scripts/check-stage.sh edge --context "$EKS_CONTEXT"
../infra-aws/scripts/plan.sh edge --context "$EKS_CONTEXT"
terraform -chdir=../infra-aws/terraform/edge apply stage.tfplan
terraform -chdir=../infra-aws/terraform/edge output myfastapiapp_vpc_origin
terraform -chdir=../infra-aws/terraform/edge output myfastapiapp_https
```

The checks require an Active controller-created ALB with healthy targets. Edge
looks it up; never import it into Terraform. The full edge plan provisions VPC
origin, distribution, functions, headers and encrypted access-log delivery.
CloudFront log-delivery resources stay explicitly `us-east-1`; the bucket and
all VPC resources stay Stockholm. Review retained-log choices if an old bucket
survived; import existing resources only with validated provider IDs and a private
ownership ledger, never allow duplicate ownership or a bucket replacement.

## 7. Verify the live result

Wait for CloudFront Deployed. Follow [public access](public-access.md) to verify
HTTPS `/health`, `/ready`, docs/OpenAPI, redirects/headers, login/logout, allowed
and denied networks and actual encrypted log arrival. Database migration success
is checked from the app, separately from registration and controller readiness.
Then run ordinary full plans for every deployed stage and investigate unexpected
drift. A format/schema/validate pass cannot establish deployment success.

When changing the approved allowlist, review/apply foundation and edge using the
same ignored file. The EKS API and viewer restrictions are separate resources;
one stage apply does not update the other. Do not reuse consumed plans.

For removal, use [teardown](teardown.md). Preserve edge → app ALB cleanup while
its controller runs → platform → foundation → optional backend order. Each repo
keeps its own commits; there is no shared root state or repository.
