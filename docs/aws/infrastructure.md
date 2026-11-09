# Infrastructure contract

`infra/environments/aws/dev` creates AWS infrastructure; `gitops` supplies shared application manifests and the AWS overlay.
Each resource has one manager. This repository does not provision EKS or RDS.

| Owner | Resources |
| --- | --- |
| Terraform foundation in `infra/environments/aws/dev/foundation` | VPC, subnets, routes, frontend security group, EKS, managed EC2 node groups, private RDS, and controller IAM/Pod Identity permissions |
| Terraform platform in `infra/environments/aws/dev/platform` | Argo CD and AWS Load Balancer Controller Helm installations, including the `alb` IngressClass |
| Terraform edge in `infra/environments/aws/dev/edge` | CloudFront VPC origin/distribution, functions, response headers and access-log delivery/storage |
| Argo CD from `gitops` | ApplicationSet, app Deployment, Service, ConfigMaps, migration Job and Ingress |
| AWS Load Balancer Controller | ALBs, target groups and related resources reconciled from Ingress resources |
| Separate credential provisioning | Argo CD Git access, app database Secret and GHCR pull Secret |

Terraform must not also manage ALBs or target groups created by the controller,
or app resources managed by Argo CD. Use the controller/chart pins already
selected in `infra/environments/aws/dev`; this repo expects their CRDs to be installed first.

## Required infrastructure

- Use the project's selected Region. Confirm it in **AWS Settings > View all
  projects > Overview > Additional Info > Region**. The existing local
  `aws-project` profile currently selects `eu-north-1`; confirm that before applying
  infrastructure. Check plan type and spend status in **AWS Settings > Billing**.
- Provide private worker/ALB subnets in at least two Availability Zones, tagged
  `kubernetes.io/role/internal-elb=1` for controller discovery, with sufficient
  free IPv4 addresses. Keep database subnets isolated. Public subnets support
  the NAT gateway; the VPC also needs an internet gateway for CloudFront VPC origins.
- Workers need access to GitHub, GHCR and other registries used by cluster
  components. The current image remains `ghcr.io/pquarg/demo-api:0.1.13`.
  Match worker CPU architecture to the published image; do not assume a local
  Apple Silicon build works on an AMD64 worker.
- Provide access from the operator's machine or CI to the EKS API. Script commands
  always take a context explicitly; they never choose the current context implicitly.
- Install self-hosted Argo CD in namespace `argocd`, with Deployments named
  `argocd-server` and `argocd-applicationset-controller`.
- Install the AWS Load Balancer Controller in `kube-system`, with Deployment name
  `aws-load-balancer-controller`. IngressClass `alb` must use controller
  `ingress.k8s.aws/alb`. EKS Auto Mode uses a different integration and needs a
  deliberate manifest/bootstrap change before using this configuration.
- Create RDS PostgreSQL without public access. Allow port 5432 only from the
  application's worker/pod security group as appropriate for the cluster networking.
  Provide database `myfastapiapp` and an app-specific login with the schema permissions
  needed by Alembic. Do not use the RDS administrator login for routine app access.
- Enable RDS backups and choose retention and deletion protection appropriate to
  the environment. Database snapshots and restore operations are managed outside
  these Kubernetes manifests.
- Provision the ALB frontend security group before app sync. The current group
  allows TCP 80 from AWS's CloudFront origin-facing prefix list and TCP 8000
  outbound to the worker group. Pass its ID to the Ingress. The controller manages
  backend ingress using `manage-backend-security-group-rules: "true"`.
- The Ingress creates internal ALB `dev-demo-api`, listening on
  private HTTP port 80, with no host-specific rule or ACM certificate. After it
  becomes Active with healthy targets, Terraform can look it up and provision a
  CloudFront VPC origin and standard distribution. Keep all VPC resources in the
  selected Region; CloudFront is global. Follow [public access](public-access.md).
- CloudFront's default hostname supplies the initial public HTTPS certificate.
  Use an HTTPS-only viewer policy and disable API caching. The private origin
  leg is HTTP; verify forwarded host/scheme behavior and redirects before launch.

The ALB health check uses `/ready`; it must reach the app on port 8000 through the
controller-managed target networking. Kubernetes liveness uses `/health`.

## Values handed to deployment

| Value | Where it is used |
| --- | --- |
| AWS profile and selected Region | AWS CLI and infrastructure commands |
| EKS cluster name and an explicit kubeconfig context | Bootstrap, validation and operational commands |
| ALB frontend security group ID | Ingress `alb.ingress.kubernetes.io/security-groups` annotation |
| Deterministic ALB name | Ingress `load-balancer-name` annotation and later Terraform lookup |
| CloudFront default hostname (after edge provisioning) | Public HTTPS checks; no Ingress host rule required |
| Private RDS endpoint, database name and app login | Ignored `app-secrets.yaml` / Kubernetes Secret |
| Git read credential | Argo CD repository connection for `gitops` |
| GHCR package read credential | `registry-credentials` Secret in each app namespace |

Hostnames and ARNs are configuration and may be committed. Passwords, tokens,
private keys, Terraform state and kubeconfig credentials must stay outside Git.

S3 is not needed by the current app. `infra/environments/aws/dev` can use a separate S3 bucket for
Terraform state with versioning, encryption, restricted access and state locking.
It must bootstrap that backend before configuring Terraform to use it.

A custom domain can be added later through CloudFront aliases, DNS and an ACM
certificate in `us-east-1` for CloudFront. The default address does not require
those resources. Do not change the ALB to internet-facing merely to add a domain.

## References

- [EKS managed node groups](https://docs.aws.amazon.com/eks/latest/userguide/managed-node-groups.html)
- [AWS Load Balancer Controller](https://docs.aws.amazon.com/eks/latest/userguide/aws-load-balancer-controller.html)
- [Controller subnet discovery](https://kubernetes-sigs.github.io/aws-load-balancer-controller/latest/deploy/subnet_discovery/)
- [Ingress annotations](https://kubernetes-sigs.github.io/aws-load-balancer-controller/latest/guide/ingress/annotations/)
- [RDS PostgreSQL TLS](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/PostgreSQL.Concepts.General.SSL.html)
- [CloudFront VPC origins](https://docs.aws.amazon.com/AmazonCloudFront/latest/DeveloperGuide/private-content-vpc-origins.html)

## Output handoff and stage order

Foundation → platform → application registration/manual sync → healthy ALB →
edge. Stage plans are full and independent; no targeted bootstrap sequence is
required. The foundation state keeps `dev/terraform.tfstate`, platform uses
`dev/platform/terraform.tfstate`, edge uses `dev/edge/terraform.tfstate`.

```sh
terraform -chdir=../infra/environments/aws/dev/foundation output eks_cluster_name
terraform -chdir=../infra/environments/aws/dev/foundation output database
terraform -chdir=../infra/environments/aws/dev/foundation output myfastapiapp_alb_security_group
terraform -chdir=../infra/environments/aws/dev/edge output myfastapiapp_https
```

Discovery uses AWS metadata, not another root's sensitive remote state. Read
[teardown](teardown.md) for the reverse dependency order.
