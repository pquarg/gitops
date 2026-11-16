# Add an app

Create `apps/<app>/base/kustomization.yaml` for portable Kubernetes resources.
Use a lowercase DNS label of at most 63 characters. Reserve `argocd`, `traefik`,
`default`, `apps`, `bootstrap`, `root` and names starting with `kube-`.

Add `apps/<app>/overlays/local/kustomization.yaml` and/or
`apps/<app>/overlays/aws/kustomization.yaml`. Each overlay includes `../../base`,
selects its release image and adds the environment's configuration and HTTPRoutes.
An app can opt into one or both environments; creating a base alone deploys nothing.
Local Gateway attachment also requires its namespace in infra's allowed-route
selector. Use demo-api's HTTPRoute parentRefs and a unique hostname. AWS overlays
also need a same-namespace Gateway and both AWS configuration resources.

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - ../../base
  - httproute.yaml
images:
  - name: ghcr.io/pquarg/billing-api
    newTag: "0.1.0"
```

Local discovery matches `apps/*/overlays/local`; AWS matches `apps/*/overlays/aws`.
The app name is path segment 1, not the overlay directory name. This produces
`<app>` targeting namespace `<app>` in its respective cluster.
See [Argo CD Git directory parameters](https://argo-cd.readthedocs.io/en/stable/operator-manual/applicationset/Generators-Git/#git-generator-directories) for path-segment semantics.
No per-app registration file is needed. Base/resources stay inside this Git
repository, so Argo CD can render them without sibling checkouts or extra remotes.

Keep Kubernetes names stable and selectors consistent. Shared settings include
container ports, probes, Service, migration command and compatible security/resource
settings. Keep environment differences in overlays; see demo-api for an example
that applies container security and verified database TLS in an AWS patch.

Provision local deployment databases separately through `infra/environments/local`, outside
kind. Keep connection Secrets and schema migration Jobs in GitOps. Each app must
have its own database, restricted login and independent backup/recovery plan.
Use [demo-api's database setup](https://github.com/pquarg/infra/blob/main/environments/local/docs/database.md) as the current
example.

AWS databases and other cloud resources belong in `infra/environments/aws/dev`. The AWS overlay
contains connection configuration, verified database TLS and an ALB Gateway and HTTPRoute.
Use each app's own frontend security group and ALB name. Provision CloudFront after
the controller creates a healthy ALB. Follow the [AWS infrastructure contract](aws/infrastructure.md).

Before publishing a new local overlay, create its namespace and required Secrets
and make its release image available: local app sync is automatic. AWS app sync
remains manual. Filled Secret files are ignored and must not be in Kustomize.
Keep release, backup, verification and recovery instructions beside each overlay.

Run `./scripts/validate.sh --no-placeholders`, review both renders, commit and publish. For a
database release, use the app's full-sync procedure and migration/backup checks;
selective sync skips hooks. Each environment may promote image versions separately.

Removing an overlay deletes its generated Application. Existing
`preserveResourcesOnDeletion: true` keeps its resources, and pruning remains disabled.
Retire workloads and cloud dependencies deliberately after backups; deleting a Git
directory does not remove database data or guarantee load balancer cleanup.

Follow [Gateway API routing and cutover](gateway-api.md) for route status checks,
publication order, CRD prerequisites and recovery. Local controller support must
be applied before publishing HTTPRoutes. AWS app sync remains manual.
