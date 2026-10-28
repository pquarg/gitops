# Validate deployment configuration

Install kubectl and [kubeconform](https://github.com/yannh/kubeconform).
CI pins kubectl `v1.36.1` and kubeconform `v0.8.0`;
use those versions locally for matching results. Homebrew provides kubeconform
with `brew install kubeconform`; pinned binaries are available on its release page.

Run from any directory:

```sh
/path/to/deploy/scripts/validate.sh
```

From this repository root, use `./scripts/validate.sh`. It checks:

- Bash syntax for every script under `scripts/` and `apps/`.
- App directory names and every `apps/*/kustomization.yaml` deployment entry point.
  New apps are discovered automatically and need no individual registration file.
- Rendered app resources, the ApplicationSet, shared registrations and the
  root Application against schemas, with unknown kinds and fields treated
  as failures.

Built-in resources use Kubernetes `1.36.0` schemas by default. Set
`KUBERNETES_VERSION` to another available schema version if targeting a different
cluster. Argo CD resources use the CRD catalog schema source configured in the
script. Validation downloads schemas and requires internet access; adding a new
CRD may require adding its schema source. Validation requires neither Docker nor
Kubernetes API access.

CI runs the same script for pushes and pull requests. Render each app's root
Kustomization so its optional database and release image selection are included.
For a cluster-aware check after provisioning its namespace, use:

```sh
kubectl --context kind-argocd-postgres -n myfastapiapp \
  apply --dry-run=server -k apps/myfastapiapp
```

Schema validation cannot prove image availability, Secret presence, database
compatibility or runtime health. Use the app's release verification for those.
