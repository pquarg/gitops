# Credentials

Each app documents its required Secrets in its own README. Keep filled Secret
files outside Git and Kustomize, with mode `600`; commit only empty examples.
Create the app's namespace before provisioning Secrets. Image pull Secrets must
exist in every namespace that consumes them. See [adding apps](adding-apps.md).

Database credentials and connection settings belong to the app. Start with
[demo-api credentials](../../apps/demo-api/overlays/aws/README.md#provision-credentials).
The shared Git credential used by Argo CD is configured during
[cluster setup](setup.md#2-verify-platform-components-and-git-access).

## Registry authentication

The Deployment references a Kubernetes Secret with these settings:

| Setting | Value |
| --- | --- |
| Cluster context | `$EKS_CONTEXT` (explicit EKS context) |
| Secret name | `registry-credentials` |
| Namespace | The same namespace as the app; `demo-api` in the example below |
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

Run the helper from this repository root in an interactive terminal with Python 3
and kubectl available. Replace `YOUR_GITHUB_USERNAME` with the account that owns
the PAT. It prompts without echoing the token and sends the generated Secret to
kubectl over stdin, keeping the token out of command arguments, shell history
and saved files. It refuses a prompt that cannot hide input. The helper uses
server-side apply to create or update `registry-credentials`, without storing
a client-side last-applied copy of the credential.

```sh
python3 scripts/configure-ghcr-credentials.py aws-deployment-project YOUR_GITHUB_USERNAME
```

The default namespace is `demo-api`; pass `--namespace OTHER_NAMESPACE` for
another app. Replace the explicit context when targeting another cluster.
Secret creation alone does not verify the PAT's scope, package access or expiry.

To confirm the Secret exists without displaying its credentials:

```sh
kubectl --context aws-deployment-project -n demo-api get secret registry-credentials \
  -o 'custom-columns=NAME:.metadata.name,NAMESPACE:.metadata.namespace,TYPE:.type'
```

This confirms the Secret's presence and type; a successful image pull confirms
the credential works. Test the pinned app image using this temporary Pod; it only
prints a message and does not start the API or run migrations:

```sh
kubectl --context aws-deployment-project -n demo-api \
  delete pod demo-api-image-pull-check --ignore-not-found
kubectl --context aws-deployment-project apply -f scripts/image-pull-check.yaml &&
kubectl --context aws-deployment-project -n demo-api \
  wait --for=jsonpath='{.status.phase}'=Succeeded \
  pod/demo-api-image-pull-check --timeout=180s &&
kubectl --context aws-deployment-project -n demo-api \
  logs pod/demo-api-image-pull-check &&
kubectl --context aws-deployment-project -n demo-api \
  delete pod demo-api-image-pull-check
```

`imagePullPolicy: Always` requires registry resolution even when the image is
cached on a worker. Expect `GHCR image pull OK`. If the wait fails, inspect
`kubectl --context aws-deployment-project -n demo-api describe pod demo-api-image-pull-check`
before retrying. The Pod has a five-minute deadline and no service account token
or database credentials. Its image tag should match the app's Kustomize release
when testing a future release.

Recreate the Secret after deleting and rebuilding the EKS
cluster. When the PAT expires or is rotated, rerun the setup command with the new
PAT. For a planned rotation, update the Secret before revoking the old PAT.
Existing running containers keep running; future pulls use the updated Secret.
For a different cluster or app namespace, update the context and namespace in
the creation argument and verification commands.

Commit these instructions and the Deployment's `imagePullSecrets` reference.
Keep the PAT and generated Secret JSON/YAML outside Git, including private
repositories: a Kubernetes Secret's base64 encoding is reversible. See
[Kubernetes image pull Secrets](https://kubernetes.io/docs/tasks/configure-pod-container/pull-image-private-registry/).
