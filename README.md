# GitOps application deployments

One repository deploys the same applications to local kind and AWS EKS.
Kustomize combines a shared app base with an environment overlay. Each cluster's
Argo CD reads only its own registrations and overlays from this Git repository.
Application source and image builds live in the
[demo-api repository](https://github.com/pquarg/myfastapiapp/blob/main/README.md); platform provisioning lives in
the independent [infrastructure repository](https://github.com/pquarg/infra/blob/main/README.md).

| Environment | Platform | Database | App sync |
| --- | --- | --- | --- |
| Local | kind and shared Traefik | Separate Compose PostgreSQL | Automatic |
| AWS | EKS, internal ALB and CloudFront | Private RDS with verified TLS | Manual |

The AWS configuration restricts public access to operator IPs and uses one app
replica and single-AZ RDS. See the [architecture guide](docs/aws/architecture.md)
for request flow, resource ownership and migration order.

## Get the companion repositories

Setup commands use this workspace layout. Clone into a new directory:

```sh
mkdir -p deployment-project/apps
cd deployment-project
git clone git@github.com:pquarg/myfastapiapp.git apps/demo-api
git clone git@github.com:pquarg/gitops.git gitops
git clone git@github.com:pquarg/infra.git infra
cd gitops
```

Repository access is required. The app checkout is needed when developing or
publishing images; deployment can use an already published image. Platform
setup reads the infrastructure checkout, while Argo CD reads published GitOps
Git and needs no sibling checkouts inside the cluster.

## Repository layout

```text
apps/demo-api/
  base/                         # Shared Deployment, Service, ConfigMap and migration Job
  overlays/local/               # Local release, configuration and Traefik
  overlays/aws/                 # AWS release, configuration, ALB and verified RDS TLS
argocd/local/                   # apps: discovers apps/*/overlays/local
argocd/aws/                     # apps: discovers apps/*/overlays/aws
bootstrap/local.yaml            # bootstrap Application on kind, local registrations only
bootstrap/aws.yaml              # bootstrap Application on EKS, AWS registrations only
scripts/                        # Common validation/bootstrap and credential helpers
docs/local/                     # Local setup, credentials and recovery
docs/aws/                       # AWS setup, infrastructure contract and recovery
```

Both clusters use Application `bootstrap`, ApplicationSet `apps` and Applications
named `<app>` in namespace `argocd`. Environment identity stays in Git overlay
paths and explicit command/context selection, without prefixes or environment
labels on the registrations. The expected remote
is `git@github.com:pquarg/gitops.git`; publish it and configure read access in
Argo CD before registration. Local apps sync automatically; AWS apps sync manually.

The app greeting is also shared: `Hello from FastAPI!`. Platform-specific database,
ingress and TLS settings remain in overlays.

## Set up an environment

Follow [local setup](docs/local/setup.md) or [AWS setup](docs/aws/setup.md), including
platform preparation, Git access, app credentials and image availability.
For a fresh AWS environment, use the [complete deployment walkthrough](docs/aws/deploy-from-scratch.md),
starting with state backend setup.

For local setup, finish the [app prerequisites](docs/local/setup.md#3-prepare-the-apps)
before registration: healthy Compose PostgreSQL, both app Secrets and a passing
Pod database probe. Argo CD's Git credential does not authenticate GHCR image
pulls. Use the
[first-sync troubleshooting](apps/demo-api/overlays/local/README.md#troubleshoot-the-first-sync)
if a migration or image pull is blocked.

On a prepared cluster, register only the chosen environment:

```sh
./scripts/bootstrap.sh --environment local --context kind-deployment
./scripts/bootstrap.sh --environment aws --context aws-deployment-project
```

These commands target separate clusters; run the one you intend to configure.
`--kubeconfig /absolute/file` selects one kubeconfig file consistently.
Bootstrap sync confirms registration, not app, migration or endpoint health.

## Change and promote an app

Change portable workload settings in `apps/<app>/base/`. Change routing, database
integration or environment configuration in that app's overlay. Every environment
using the base receives its next published changes according to its sync policy.
A shared base change can therefore affect AWS as well as local; review both renders.

The selected release is in each overlay's `kustomization.yaml`. Both environments
initially select `0.1.13`. Test a new image locally, then promote the same image tag
(or preferably immutable digest) to the AWS overlay without rebuilding it. API
and migration Job use the same selected image within each environment. Database
contents and credentials remain independent; switching an image does not reverse
a schema migration. Follow the environment's app release and backup runbook.

```sh
kubectl kustomize apps/demo-api/overlays/local
kubectl kustomize apps/demo-api/overlays/aws
./scripts/validate.sh --no-placeholders
git diff --check
```

The validator checks both environments, bootstrap safety, credential-helper tests
and Kubernetes/Argo CD schemas. It needs kubectl, kubeconform, Python 3 and internet
access, but no running cluster or AWS credentials. Use `--environment local` or
`--environment aws` to select one environment's schema validation. See
[validation](docs/validation.md) for limits and explicit-context server dry-runs.

- [Job tracker local release](apps/job-tracker/overlays/local/README.md)
- [Add an app](docs/adding-apps.md)
- [Local app releases, database backups and recovery](apps/demo-api/overlays/local/README.md)
- [AWS app releases, RDS and recovery](apps/demo-api/overlays/aws/README.md)
- [Local platform](https://github.com/pquarg/infra/blob/main/environments/local/README.md)
- [AWS platform](https://github.com/pquarg/infra/blob/main/environments/aws/dev/README.md)

Local PostgreSQL is provisioned separately by `infra/environments/local`, outside kind,
just as RDS is provisioned outside EKS. App sync runs migrations and rolls out the
API against an existing database in both environments.

Filled Secret files remain ignored and outside Kustomize. Keep database files,
backups, credentials, Terraform state and saved plans outside version control.

Local apps now use HTTPRoutes through shared Traefik Gateway API routing. See
[local cutover and rollback](docs/local/gateway-cutover.md) for route verification,
namespace attachment permissions and the separate Ingress-provider cleanup.

- [Reaction Explorer local release](apps/reaction-explorer/overlays/local/README.md)
