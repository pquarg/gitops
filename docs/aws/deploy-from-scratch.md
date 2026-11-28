# Deploy from start to finish

Run app commands from `gitops`, alongside the actual `../infra/environments/aws/dev` checkout.
This runbook provisions a fresh environment/database.
Editing configuration does not apply changes or rebuild infrastructure.
Use explicit Kubernetes contexts and review every saved Terraform plan.

## 1. Check tools, credentials and backend

Install Terraform `1.17.x`, AWS CLI v2, kubectl, Python 3, Node.js and the
[validation tools](validation.md). Authenticate profile `aws-project`; verify
account `245361883993` and Region `eu-north-1`:

```sh
aws sts get-caller-identity --profile aws-project --region eu-north-1
```

Create the protected S3 state bucket using
[backend setup](https://github.com/pquarg/infra/blob/main/docs/state.md#create-the-aws-state-backend).
If it already exists, verify its ownership and state keys before initializing.
Never create fresh local state over an existing remote installation. Inspect
which stages/resources exist before proceeding. Keep state/Secret backups outside
Git. For existing data, follow the app's backup/recovery procedure rather than
assuming a fresh RDS database will restore it.

## 2. Apply foundation

Prepare `../infra/environments/aws/dev/config/operator.tfvars` from its checked-in example. Enter
the approved operator IPv4 `/32` allowlist; foundation and edge use that one file.
Then:

```sh
../infra/scripts/plan.sh --environment aws/dev --stage foundation
terraform -chdir=../infra/environments/aws/dev/foundation apply stage.tfplan
terraform -chdir=../infra/environments/aws/dev/foundation output eks_cluster_name
terraform -chdir=../infra/environments/aws/dev/foundation output database
terraform -chdir=../infra/environments/aws/dev/foundation output myfastapiapp_alb_security_group
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
../infra/scripts/plan.sh --environment aws/dev --stage platform --context "$EKS_CONTEXT"
terraform -chdir=../infra/environments/aws/dev/platform apply stage.tfplan
```

Add `--kubeconfig /absolute/file` to the AWS update-kubeconfig and stage command
when selecting another file, and every subsequent Kubernetes/bootstrap command.
The database and registry Python helpers accept a context but no `--kubeconfig`
option; select the same single file through `KUBECONFIG=/absolute/file` when
invoking those helpers. The checker verifies the endpoint matches EKS and Pod Identity prerequisites are
available. Platform installs pinned Argo CD and load balancer controller releases.
Their pins/values live in `../infra/environments/aws/dev/argocd/` and
`../infra/environments/aws/dev/load-balancer-controller/`. Platform uses AWS token-based Helm auth;
it reads EKS metadata without another root's sensitive state.

## 4. Prepare credentials, images and Git

Follow [setup](setup.md#2-verify-platform-components-and-git-access) to open the
private Argo CD UI and configure read access to
`git@github.com:pquarg/gitops.git`. Keep SSH host verification enabled.
Follow the [app runbook](../../apps/demo-api/overlays/aws/README.md) and
[credential guide](credentials.md) to provision:

- Namespace `demo-api`, its RDS app login/schema permissions and database
  Secret. The database helper uses AWS discovery; it does not read Terraform state.
- `registry-credentials` for the selected published GHCR image. Preserve the
  existing release tag and worker architecture; publish a new image in the app repo
  for a new release rather than changing infrastructure pins.
- The LoadBalancerConfiguration security-group list in `apps/demo-api/overlays/aws/load-balancer-configuration.yaml`, using foundation's
  `myfastapiapp_alb_security_group` output. Keep ALB name `dev-demo-api`,
  internal IPv4 scheme, HTTP listener, IP targets and `/ready` checks unchanged.

The RDS CA bundle is committed public material. Passwords, filled Secret files,
Git keys, tokens, real `.tfvars`, plans and state stay outside Git.

## 5. Validate, publish and register

```sh
./scripts/validate.sh
./scripts/validate.sh --environment aws --no-placeholders
git diff --check
# After reviewing and publishing the deployment manifests to dev:
./scripts/bootstrap.sh --environment aws --context "$EKS_CONTEXT"
```

The bootstrap validates first, verifies CRDs/controllers/GatewayClass and applies
only the `bootstrap` registration. Bootstrap Synced confirms registration, not app health or
migration success. App `demo-api` remains **manually synced**. Perform a
full sync with Force/Replace off so its migration hook runs; verify logs, Alembic
revision, app readiness and database access using the app runbook.

## 6. Wait for the app ALB and apply edge

```sh
../infra/environments/aws/dev/scripts/check-stage.sh edge --context "$EKS_CONTEXT"
../infra/scripts/plan.sh --environment aws/dev --stage edge --context "$EKS_CONTEXT"
terraform -chdir=../infra/environments/aws/dev/edge apply stage.tfplan
terraform -chdir=../infra/environments/aws/dev/edge output myfastapiapp_vpc_origin
terraform -chdir=../infra/environments/aws/dev/edge output myfastapiapp_https
```

The checks require an Active controller-created ALB with healthy targets. Edge
looks it up; never import it into Terraform. The full edge plan provisions VPC
origin, distribution, functions, headers and encrypted access-log delivery.
CloudFront log-delivery resources stay explicitly `us-east-1`; the bucket and
all VPC resources stay Stockholm. Review retained-log choices if a log bucket
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

Follow [Gateway API routing and cutover](../gateway-api.md) for route status checks,
publication order, CRD prerequisites and recovery. Local controller support must
be applied before publishing HTTPRoutes. AWS app sync remains manual.
