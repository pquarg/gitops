# Configuration and credentials

The existing `myfastapiapp` deployment uses namespace `default`. For a new app,
create its namespace before provisioning Secrets, and use that namespace in both
the Secret metadata and kubectl commands. Image pull Secrets must exist in every
namespace that consumes them. See [adding apps](adding-apps.md).

## App configuration and database credentials

`apps/myfastapiapp/kustomization.yaml` supplies staging's `APP_MESSAGE` override.
The staging image version is `images[].newTag` in that same file;
Kustomize applies it to both the API Deployment and migration Job. The base
manifests reference the image without a tag; the consuming overlay selects the
release. Deploy through `apps/myfastapiapp` so that selection is applied.
Memory settings live in `apps/myfastapiapp/base/deployment.yaml`. The Deployment
reads `AUTH_DATABASE_URL` from the `myfastapiapp-secrets` Secret. The overlay adds its
dedicated Postgres database and persistent storage.

Provision these local files separately from Argo CD:

| Git-ignored file | Kubernetes Secret | Required value |
| --- | --- | --- |
| `apps/myfastapiapp/app-secrets.yaml` | `myfastapiapp-secrets` | `AUTH_DATABASE_URL` |
| `apps/myfastapiapp/postgres/postgres-secrets.yaml` | `myfastapiapp-postgres-secrets` | `POSTGRES_PASSWORD` |

Follow [Create the database secrets](postgres-kind.md#3-provision-credentials)
for the templates and matching password. Keep filled files at mode `600` and out
of Kustomize and Git.

Apply an edited local Secret with:

```sh
kubectl --context kind-argocd-postgres -n default apply \
  -f apps/myfastapiapp/app-secrets.yaml \
  -f apps/myfastapiapp/postgres/postgres-secrets.yaml
```

Changing a Secret or ConfigMap does not refresh environment variables in running
Pods. After applying a Secret change or syncing a ConfigMap change, restart the
app through Argo CD's Restart action or run:

```sh
kubectl --context kind-argocd-postgres -n default \
  rollout restart deployment/myfastapiapp-deployment
kubectl --context kind-argocd-postgres -n default \
  rollout status deployment/myfastapiapp-deployment --timeout=180s
```

`POSTGRES_PASSWORD` initializes a new database. For existing data, changing that
Secret alone does not rotate the database role's password; follow the
[recovery guidance](postgres-kind.md#recovery-after-a-cluster-rebuild).

### Move to AWS CSI later

For a later AWS Secrets Store CSI Driver integration, retain Secret name
`myfastapiapp-secrets` and key `AUTH_DATABASE_URL`. Add a `SecretProviderClass`
with AWS references, configure its `secretObjects` mapping, mount the CSI volume
in the app Pod, and configure workload IAM access. The volume mount is required
even when the app consumes the synchronized Secret as environment variables.
Plan the handover from manually provisioned Secrets because CSI manages their
lifecycle. See [CSI Secret synchronization](https://secrets-store-csi-driver.sigs.k8s.io/topics/sync-as-kubernetes-secret).

## Registry authentication

The Deployment references a Kubernetes Secret with these settings:

| Setting | Value |
| --- | --- |
| Cluster context | `kind-argocd-postgres` |
| Secret name | `registry-credentials` |
| Namespace | `default` (the same namespace as the app) |
| Secret type | `kubernetes.io/dockerconfigjson` |
| Registry | `ghcr.io` |

This Secret is provisioned separately from Argo CD. It lets the cluster download
the private app image; Argo CD's Git repository credentials let it read deployment
manifests. Each credential is configured separately.

Create a GitHub **personal access token (classic)** with `read:packages`, using an
account that has read access to the app's GHCR package. If the package belongs to
an organization that requires SSO, authorize the token for that organization.
Store the PAT in a password manager outside this repository. See
[GitHub's GHCR authentication instructions](https://docs.github.com/en/packages/working-with-a-github-packages-registry/working-with-the-container-registry#authenticating-to-the-container-registry).

After creating the cluster, run the following in an interactive terminal with
Python 3 and kubectl available. Replace `YOUR_GITHUB_USERNAME` with the account
that owns the PAT. The command prompts for the PAT without echoing it and pipes
the generated Secret directly to kubectl, keeping the PAT out of command
arguments, shell history, and saved files. Use the same command to update an
existing `registry-credentials` Secret.

```sh
python3 -c '
import base64
import getpass
import json
import sys

username = sys.argv[1]
token = getpass.getpass("GitHub PAT (read:packages): ")
if not token:
    raise SystemExit("PAT cannot be empty")
auth = base64.b64encode(f"{username}:{token}".encode()).decode()
config = json.dumps({"auths": {"ghcr.io": {"auth": auth}}})
secret = {
    "apiVersion": "v1",
    "kind": "Secret",
    "metadata": {"name": "registry-credentials", "namespace": "default"},
    "type": "kubernetes.io/dockerconfigjson",
    "data": {".dockerconfigjson": base64.b64encode(config.encode()).decode()},
}
json.dump(secret, sys.stdout)
' YOUR_GITHUB_USERNAME |
  kubectl --context kind-argocd-postgres -n default apply -f -
```

To confirm the Secret exists without displaying its credentials:

```sh
kubectl --context kind-argocd-postgres -n default get secret registry-credentials \
  -o 'custom-columns=NAME:.metadata.name,NAMESPACE:.metadata.namespace,TYPE:.type'
```

This confirms the Secret's presence and type; a successful image pull confirms
the credential works. Recreate the Secret after deleting and rebuilding the kind
cluster. When the PAT expires or is rotated, rerun the setup command with the new
PAT. For a planned rotation, update the Secret before revoking the old PAT.
Existing running containers keep running; future pulls use the updated Secret.
For a different cluster or app namespace, update the context and namespace in
both the generated Secret and the kubectl commands.

Commit these instructions and the Deployment's `imagePullSecrets` reference.
Keep the PAT and generated Secret JSON/YAML outside Git, including private
repositories: a Kubernetes Secret's base64 encoding is reversible. See
[Kubernetes image pull Secrets](https://kubernetes.io/docs/tasks/configure-pod-container/pull-image-private-registry/).

