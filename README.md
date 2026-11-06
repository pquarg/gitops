# GitOps application deployments

One repository deploys the same applications to local kind and AWS EKS.
Kustomize combines a shared app base with an environment overlay. Each cluster's
Argo CD reads only its own registrations and overlays from this Git repository.
Application source and image builds remain in `../apps/`; platform provisioning
remains in `../infra-local` and `../infra-aws`.

```text
apps/myfastapiapp/
  base/                         # Shared Deployment, Service and migration Job
  overlays/local/               # Local release, configuration and Traefik
  overlays/aws/                 # AWS release, configuration, ALB and verified RDS TLS
argocd/local/                   # staging-apps: discovers apps/*/overlays/local
argocd/aws/                     # aws-apps: discovers apps/*/overlays/aws
root/staging.yaml               # Existing staging-root identity, local registrations only
root/aws.yaml                   # Existing aws-root identity, AWS registrations only
scripts/                        # Common validation/bootstrap and credential helpers
docs/local/                     # Local setup, credentials and legacy recovery
docs/aws/                       # AWS setup, infrastructure contract and recovery
```

## Existing installations

Read [the consolidation and cutover guide](docs/repository-migration.md) first.
The expected remote is `git@github.com:pquarg/gitops.git`. It must be published and
readable by both Argo CD installations before switching registrations. Local
edits alone do not change either cluster. Existing Application, namespace,
workload, PV/PVC and Secret names are preserved by that repository cutover. It
needs no rebuild or data transfer. Moving local PostgreSQL outside kind is a
separate [database cutover](docs/local/database-migration.md) with a verified
dump/restore. Local apps retain automatic self-healing; AWS app sync remains manual.

## Set up an environment

Follow [local setup](docs/local/setup.md) or [AWS setup](docs/aws/setup.md), including
platform preparation, Git access, app credentials and image availability. On a
prepared cluster, register only the chosen environment:

```sh
./scripts/bootstrap.sh --environment local --context kind-argocd-postgres
./scripts/bootstrap.sh --environment aws --context aws-deployment-project
```

These commands target separate clusters; run the one you intend to configure.
`--kubeconfig /absolute/file` selects one kubeconfig file consistently. The
`bootstrap-kind.sh [cluster]` and `bootstrap-eks.sh CONTEXT` wrappers remain
available. Root sync confirms registration, not app, migration or endpoint health.

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
- [Local platform](../infra-local/README.md)
- [AWS platform](../infra-aws/README.md)

Local PostgreSQL is provisioned separately by `infra-local`, outside kind,
just as RDS is provisioned outside EKS. App sync runs migrations and rolls out the
API against an existing database in both environments. Existing local databases
need the [verified cutover](docs/local/database-migration.md) before publishing the
overlay change; legacy manifests/tools remain for recovery and are not included
in the active overlay.

Filled Secret files remain ignored and outside Kustomize. Keep database files,
backups, credentials, Terraform state and saved plans outside version control.
