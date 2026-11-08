# GitOps application deployments

One repository deploys the same applications to local kind and AWS EKS.
Kustomize combines a shared app base with an environment overlay. Each cluster's
Argo CD reads only its own registrations and overlays from this Git repository.
Application source and image builds remain in `../apps/`; platform provisioning
remains in the independent `../infra` repository.

```text
apps/myfastapiapp/
  base/                         # Shared Deployment, Service and migration Job
  overlays/local/               # Local release, configuration and Traefik
  overlays/aws/                 # AWS release, configuration, ALB and verified RDS TLS
argocd/local/                   # staging-apps: discovers apps/*/overlays/local
argocd/aws/                     # aws-apps: discovers apps/*/overlays/aws
root/staging.yaml               # root Application on kind, local registrations only
root/aws.yaml                   # root Application on EKS, AWS registrations only
scripts/                        # Common validation/bootstrap and credential helpers
docs/local/                     # Local setup, credentials and recovery
docs/aws/                       # AWS setup, infrastructure contract and recovery
```

Both clusters use Application `root` in namespace `argocd`. The expected remote
is `git@github.com:pquarg/gitops.git`; publish it and configure read access in
Argo CD before registration. Local apps sync automatically; AWS apps sync manually.

## Set up an environment

Follow [local setup](docs/local/setup.md) or [AWS setup](docs/aws/setup.md), including
platform preparation, Git access, app credentials and image availability.

For local setup, finish the [app prerequisites](docs/local/setup.md#3-prepare-the-apps)
before registration: healthy Compose PostgreSQL, both app Secrets and a passing
Pod database probe. Argo CD's Git credential does not authenticate GHCR image
pulls. Use the
[first-sync troubleshooting](apps/myfastapiapp/overlays/local/README.md#troubleshoot-the-first-sync)
if a migration or image pull is blocked.

On a prepared cluster, register only the chosen environment:

```sh
./scripts/bootstrap.sh --environment local --context kind-deployment
./scripts/bootstrap.sh --environment aws --context aws-deployment-project
```

These commands target separate clusters; run the one you intend to configure.
`--kubeconfig /absolute/file` selects one kubeconfig file consistently.
Root sync confirms registration, not app, migration or endpoint health.

## Change and promote an app

Change portable workload settings in `apps/<app>/base/`. Change routing, database
integration or environment configuration in that app's overlay. Every environment
using the base receives its next published changes according to its sync policy.
A shared base change can therefore affect AWS as well as local; review both renders.

The selected release is in each overlay's `kustomization.yaml`. Both environments
initially select `0.1.12`. Test a new image locally, then promote the same image tag
(or preferably immutable digest) to the AWS overlay without rebuilding it. API
and migration Job use the same selected image within each environment. Database
contents and credentials remain independent; switching an image does not reverse
a schema migration. Follow the environment's app release and backup runbook.

```sh
kubectl kustomize apps/myfastapiapp/overlays/local
kubectl kustomize apps/myfastapiapp/overlays/aws
./scripts/validate.sh --ready
git diff --check
```

The validator checks both environments, bootstrap safety, credential-helper tests
and Kubernetes/Argo CD schemas. It needs kubectl, kubeconform, Python 3 and internet
access, but no running cluster or AWS credentials. Use `--environment local` or
`--environment aws` to select one environment's schema validation. See
[validation](docs/validation.md) for limits and explicit-context server dry-runs.

- [Add an app](docs/adding-apps.md)
- [Local app releases, database backups and recovery](apps/myfastapiapp/overlays/local/README.md)
- [AWS app releases, RDS and recovery](apps/myfastapiapp/overlays/aws/README.md)
- [Local platform](../infra/environments/local/README.md)
- [AWS platform](../infra/environments/aws/dev/README.md)

Local PostgreSQL is provisioned separately by `infra/environments/local`, outside kind,
just as RDS is provisioned outside EKS. App sync runs migrations and rolls out the
API against an existing database in both environments.

Filled Secret files remain ignored and outside Kustomize. Keep database files,
backups, credentials, Terraform state and saved plans outside version control.
