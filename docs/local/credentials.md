# Credentials

Each app documents its required Secrets in its own README. Keep filled Secret
files outside Git and Kustomize, with mode `600`; commit only empty examples.
Create the app's namespace before provisioning Secrets. Image pull Secrets must
exist in every namespace that consumes them. See [adding apps](../adding-apps.md).

These credentials serve different purposes:

| Credential | Used for | Where it is configured |
| --- | --- | --- |
| Argo CD Git credential | Read deployment manifests from GitHub | Argo CD repository settings |
| GHCR classic PAT | Download the private app image | `registry-credentials` in the app namespace |
| Compose app password | Connect the API and migrations to PostgreSQL | Private password file, then `AUTH_DATABASE_URL` in `demo-api-secrets` |

A successful Git connection in Argo CD does not configure either app Secret.

Database credentials and connection settings belong to the app. Start with
[demo-api credentials](../../apps/demo-api/overlays/local/README.md#provision-credentials).
The shared Git credential used by Argo CD is configured during
[deployment Git connection](setup.md#2-connect-the-deployment-git-repository).

## Registry authentication

The Deployment references a Kubernetes Secret with these settings:

| Setting | Value |
| --- | --- |
| Cluster context | `kind-deployment` |
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

For the token's name/note, use something descriptive such as
`kind-deployment-ghcr-pull`. Select `read:packages`; pulling the image does not
need package write/delete permissions. Choose an expiry and arrange a renewal
reminder. The name is only a label; its scope and package access determine
whether it can pull the image.

After creating the cluster and app namespace, run the helper from `gitops` in
an interactive terminal with Python 3 and kubectl available. For a PAT owned
by `pquarg`:

```sh
python3 scripts/configure-ghcr-credentials.py kind-deployment pquarg
```

Replace `pquarg` with the account that owns your PAT if different. The helper
prompts without echoing the PAT and submits the Secret directly to kubectl,
keeping it out of command arguments, shell history and saved files. It defaults
to namespace `demo-api`; use `--namespace OTHER_APP` for another app.
Use the same command to update an existing `registry-credentials` Secret.

To confirm the Secret exists without displaying its credentials:

```sh
kubectl --context kind-deployment -n demo-api get secret registry-credentials \
  -o 'custom-columns=NAME:.metadata.name,NAMESPACE:.metadata.namespace,TYPE:.type'
```

This confirms the Secret's presence and type; a successful image pull confirms
the credential works. Recreate the Secret after deleting and rebuilding the kind
cluster. When the PAT expires or is rotated, rerun the setup command with the new
PAT. For a planned rotation, update the Secret before revoking the old PAT.
Existing running containers keep running; future pulls use the updated Secret.
For a different cluster or app namespace, update the context and namespace in
the helper arguments and verification commands. For GHCR `401 Unauthorized`
or `ImagePullBackOff`, first check that this Secret exists in the app's
namespace, then verify token expiry, `read:packages` and package access.

Commit these instructions and the Deployment's `imagePullSecrets` reference.
Keep the PAT and generated Secret JSON/YAML outside Git, including private
repositories: a Kubernetes Secret's base64 encoding is reversible. See
[Kubernetes image pull Secrets](https://kubernetes.io/docs/tasks/configure-pod-container/pull-image-private-registry/).
