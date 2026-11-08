# Set up AWS deployments

For the complete infrastructure-to-public-HTTPS walkthrough, use
[deploy from start to finish](deploy-from-scratch.md). This page is the shorter
cluster/application setup reference. For removal, use [teardown](teardown.md).

Run commands from this repository root. Install AWS CLI v2, kubectl, Python 3,
and the [validation tools](validation.md). Complete the
[infrastructure contract](infrastructure.md) in `infra/environments/aws/dev` first.

GitOps `--environment aws` currently maps to infrastructure `--environment aws/dev`.

## 1. Select the project and cluster

Confirm the selected Region in **AWS Settings > View all projects > Overview >
Additional Info > Region**, and plan/spend status in **AWS Settings > Billing**.
Your existing `aws-project` profile selects `eu-north-1`; use the confirmed values:

```sh
EKS_CONTEXT=aws-deployment-project

aws sts get-caller-identity --profile aws-project --region eu-north-1
aws freetier get-account-plan-state --profile aws-project --region eu-north-1
aws eks update-kubeconfig --name deployment-project-dev --region eu-north-1 \
  --profile aws-project --alias "$EKS_CONTEXT"
kubectl --context "$EKS_CONTEXT" get nodes
```

The cluster name must come from `infra/environments/aws/dev`; `EKS_CONTEXT` is a local alias. Use the
same alias in every later command. If AWS credentials have expired, authenticate
the configured profile before continuing. Check service availability for the
project's plan before provisioning.

## 2. Verify platform components and Git access

`infra/environments/aws/dev` must already have installed Argo CD, its ApplicationSet controller, and
the AWS Load Balancer Controller. This repository does not install those again.
The bootstrap script validates before registration and checks their rollouts and the `alb` IngressClass.

Keep the Argo CD UI private and access it through a port forward:

```sh
kubectl --context "$EKS_CONTEXT" -n argocd \
  port-forward service/argocd-server 8081:443
```

Open https://localhost:8081 and use the administrator credentials established by
the Argo CD installation. Configure a read-only repository connection to
`git@github.com:pquarg/gitops.git` in the `default` project. Keep SSH host verification
enabled and provision the private key outside Git. See
[Argo CD private repositories](https://argo-cd.readthedocs.io/en/stable/user-guide/private-repositories/).

## 3. Configure the app

Check the frontend security-group ID in `apps/myfastapiapp/overlays/aws/ingress.yaml` against
`terraform -chdir=../infra/environments/aws/dev/foundation output myfastapiapp_alb_security_group`. Its scheme must
remain `internal`, with the HTTP port 80 listener and controller-managed backend
rules. No custom hostname or ACM certificate is needed for this origin.
Provision its namespace, database connection and
image pull credentials using the [app runbook](../../apps/myfastapiapp/overlays/aws/README.md).
Confirm the selected image is published and the RDS database is available.

The public RDS CA bundle is already committed. Kustomize generates a ConfigMap
and both the API and migration Job mount it for database certificate verification.
There is no Postgres Pod, PVC or laptop storage to provision here.

## 4. Validate, publish and bootstrap

```sh
./scripts/validate.sh
./scripts/validate.sh --environment aws --ready
git diff --check
```

Review, commit and push the configuration to `gitops/main`. Argo CD reads
GitHub and cannot deploy unpushed local changes. Then register the root Application:

```sh
./scripts/bootstrap.sh --environment aws --context "$EKS_CONTEXT"
```

The `root` Application automatically reconciles the ApplicationSet. The ApplicationSet creates
`aws-myfastapiapp`, but **does not sync the app automatically**. Root **Synced**
only confirms its registrations; it does not prove the app is deployed or healthy.

## 5. Sync and verify the app

Follow the [first deployment](../../apps/myfastapiapp/overlays/aws/README.md#first-deployment) runbook.
Sync the entire `aws-myfastapiapp` Application so the migration hook runs. After
the internal ALB is Active with healthy targets, follow the
[CloudFront provisioning batch](public-access.md#4-provision-cloudfront-through-terraform).
Then verify the assigned public HTTPS address, `/health`, `/ready`, redirects,
registration and login. The private ALB hostname is not reachable from the public
internet and is not the final app URL.

Kubernetes changes that create an ALB incur AWS charges. Stopping a local terminal
or port forward does not remove EKS, RDS, load balancers or networking resources.
For a disposable environment, plan cleanup in `infra/environments/aws/dev` and confirm what data must
be retained before destroying resources.

The common entry point accepts `--kubeconfig /absolute/file` and requires an
explicit context. All Kubernetes commands use the selected file/context consistently.
