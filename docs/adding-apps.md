# Add an app

Create `apps/<app>/base/kustomization.yaml` for portable Kubernetes resources.
Use a lowercase DNS label of at most 63 characters. Reserve `argocd`, `traefik`,
`default`, `bootstrap`, `root` and names starting with `kube-`.

Add `apps/<app>/overlays/local/kustomization.yaml` and/or
`apps/<app>/overlays/aws/kustomization.yaml`. Each overlay includes `../../base`,
selects its release image and adds the environment's configuration and ingress.
An app can opt into one or both environments; creating a base alone deploys nothing.

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - ../../base
  - ingress.yaml
images:
  - name: ghcr.io/pquarg/billing-api
    newTag: "0.1.0"
```

Local discovery matches `apps/*/overlays/local`; AWS matches `apps/*/overlays/aws`.
The app name is path segment 1, not the overlay directory name. This produces
`staging-<app>` or `aws-<app>` targeting namespace `<app>` in its respective cluster.
See [Argo CD Git directory parameters](https://argo-cd.readthedocs.io/en/stable/operator-manual/applicationset/Generators-Git/#git-generator-directories) for path-segment semantics.
No per-app registration file is needed. Base/resources stay inside this Git
repository, so Argo CD can render them without sibling checkouts or extra remotes.

Keep Kubernetes names stable and selectors consistent. Shared settings include
container ports, probes, Service, migration command and compatible security/resource
settings. Keep environment differences in overlays; see myfastapiapp for an example
that preserves its existing AWS security settings in an AWS patch.

Provision local deployment databases separately through `infra-local`, outside
kind. Keep connection Secrets and schema migration Jobs in GitOps. Each app must
have its own database, restricted login and independent backup/recovery plan.
Use [myfastapiapp's database setup](../../infra-local/docs/database.md) as the current
example. Legacy PV/PVC manifests and laptop paths under `/mnt/<app>-postgres`
remain only for unmigrated installations and recovery.

AWS databases and other cloud resources belong in `infra-aws`. The AWS overlay
contains connection configuration, verified database TLS and an ALB Ingress.
Use each app's own frontend security group and ALB name. Provision CloudFront after
the controller creates a healthy ALB. Follow the [AWS infrastructure contract](aws/infrastructure.md).

Before publishing a new local overlay, create its namespace and required Secrets
and make its release image available: local app sync is automatic. AWS app sync
remains manual. Filled Secret files are ignored and must not be in Kustomize.
Keep release, backup, verification and recovery instructions beside each overlay.

Run `./scripts/validate.sh --ready`, review both renders, commit and publish. For a
database release, use the app's full-sync procedure and migration/backup checks;
selective sync skips hooks. Each environment may promote image versions separately.

Removing an overlay deletes its generated Application. Existing
`preserveResourcesOnDeletion: true` keeps its resources, and pruning remains disabled.
Retire workloads and cloud dependencies deliberately after backups; deleting a Git
directory does not remove database data or guarantee load balancer cleanup.
