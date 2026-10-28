# Validate deployment configuration

Install kubectl and [kubeconform](https://github.com/yannh/kubeconform) and ensure
Docker Compose is available. CI pins kubectl `v1.36.1` and kubeconform `v0.8.0`;
use those versions locally for matching results. Homebrew provides kubeconform
with `brew install kubeconform`; pinned binaries are available on its release page.

Run from any directory:

```sh
/path/to/deploy/scripts/validate.sh
```

From this repository root, use `./scripts/validate.sh`. It checks:

- Bash syntax for every script under `scripts/`.
- App directory names and every `apps/*/kustomization.yaml` deployment entry point.
- Rendered app resources, Argo CD registrations and the bootstrap Application
  against schemas, with unknown kinds and unknown fields treated as failures.
- The legacy gateway's Compose configuration, without starting containers.

Built-in resources use Kubernetes `1.36.0` schemas by default. Set
`KUBERNETES_VERSION` to another available schema version if targeting a different
cluster. Argo CD resources use the CRD catalog schema source configured in the
script. Validation downloads schemas and requires internet access; adding a new
CRD may require adding its schema source. No Kubernetes API access is needed.

CI runs the same script for pushes and pull requests. Render complete deployment
entry points: bases deliberately omit environment settings and image versions.
For a cluster-aware check after provisioning its namespace, use:

```sh
kubectl --context kind-argocd-postgres -n default \
  apply --dry-run=server -k apps/myfastapiapp
```

Schema validation cannot prove image availability, Secret presence, database
compatibility or runtime health. Use the app's release verification for those.
