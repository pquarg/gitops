# Kubernetes deployments

An independent Git repository containing Kubernetes manifests and local platform
configuration. Application code and Dockerfiles belong in separate application
repositories.

```text
myfastapiapp/
  deployment.yaml        # Image, replica count, probes, and resource settings
  service.yaml           # Service port 80 -> app container port 8000
  ingress.yaml           # myfastapiapp.localhost -> app Service
  kustomization.yaml     # Includes the three resources above
argocd/
  myfastapiapp.yaml       # App registration: this repository, path myfastapiapp
  traefik.yaml            # Shared controller installed from its Helm chart
kind/
  compose.yaml            # Docker gateway publishing localhost port 80
  haproxy.cfg             # TCP forwarding into the kind node
scripts/
  deploy-kind.sh          # Manual local deployment helper
  setup-ingress-kind.sh   # Shared controller, gateway, and initial app route
```

Commands below run from this deployment repository's root. Docker Desktop, kind,
and kubectl are required; Ingress setup also uses Docker Compose. The app image
must be published to GHCR or loaded directly into the target kind cluster. For
the private GHCR image configured in `myfastapiapp/deployment.yaml`, set up
[registry authentication](#registry-authentication) before deploying the app.

## Registry authentication

The Deployment references a Kubernetes Secret with these settings:

| Setting | Value |
| --- | --- |
| Cluster context | `kind-argocd-demo` |
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
    "data": {".dockerconfigjson": base64.b64encode(config.  encode()).decode()},
}
json.dump(secret, sys.stdout)
' YOUR_GITHUB_USERNAME |
  kubectl --context kind-argocd-demo -n default apply -f -
```

To confirm the Secret exists without displaying its credentials:

```sh
kubectl --context kind-argocd-demo -n default get secret registry-credentials \
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

## Publish manifests and connect Argo CD

The GitHub repository is [pquarg/deploy](https://github.com/pquarg/deploy). The
local `origin` remote and `repoURL` in `argocd/myfastapiapp.yaml` are already set
to `git@github.com:pquarg/deploy.git`. The Application uses `path: myfastapiapp`,
relative to this repository's root.

Publishing files does not switch the live Argo CD Application to this repository;
apply its configuration after publishing and connecting the repository below.

1. Commit and push the deployment files:

   ```sh
   git add -A
   git commit -m "Add Kubernetes deployments and local kind infrastructure"
   git push -u origin main
   ```

2. For a private repository, add its credentials in Argo CD under
   **Settings -> Repositories -> Connect Repo**. A read-only GitHub deploy key
   scoped to the previous app repository does not grant access to this new repo.
   See [Argo CD private repository access](https://argo-cd.readthedocs.io/en/stable/user-guide/private-repositories/).
3. Once the manifests are pushed and the repository is accessible to Argo CD,
   switch the live Application:

   ```sh
   kubectl --context kind-argocd-demo apply -f argocd/myfastapiapp.yaml
   kubectl --context kind-argocd-demo -n argocd get applications
   ```

The Application keeps the name `myfastapiapp`, so it can continue managing the
existing Deployment, Service, and Ingress. Its `automated` sync policy applies
committed changes, and `selfHeal: true` restores managed resources that drift
from Git. Push the manifests and connect this deployment repo before changing the
old app repository's published layout, so Argo CD can switch to the new source
first.

If Argo CD needs installing into a fresh cluster, follow the
[Argo CD installation guide](https://argo-cd.readthedocs.io/en/stable/getting_started/).
The existing local `argocd-demo` cluster already has it installed.

## Local deployment without Argo CD

For an initial manual check in a cluster that is not managing this app through
Argo CD:

```sh
./scripts/deploy-kind.sh
```

The default cluster is `argocd-demo` and the namespace is `default`. An optional
argument selects another kind cluster. The script applies `myfastapiapp/` with
Kustomize and waits up to 120 seconds for the Deployment rollout. Once Argo CD
manages the app, use Git commits and sync for routine updates.

To preview the manifests or validate them without persisting resources:

```sh
kubectl kustomize myfastapiapp
kubectl --context kind-argocd-demo -n default apply --dry-run=server -k myfastapiapp
```

## Shared local Ingress

With Argo CD installed and the app running:

```sh
./scripts/setup-ingress-kind.sh
```

An optional argument selects another kind cluster. The script registers a
`traefik` Application using the official Helm chart pinned to `42.0.0`, waits for
its controller, starts the shared Docker gateway, and applies the initial app
Ingress. The setup requires a free localhost port 80.

```text
http://myfastapiapp.localhost
  -> Docker HAProxy gateway:80
  -> kind node:30080
  -> Traefik Ingress controller
  -> myfastapiapp Service / endpoints
  -> FastAPI Pod:8000
```

Open http://myfastapiapp.localhost/api/v1/docs/, or check:

```sh
curl http://myfastapiapp.localhost/health
curl http://myfastapiapp.localhost/api/v1/items
```

Modern browsers resolve `.localhost` to your own machine. `/` returns 404 because
the app has no root route. The gateway runs in the background with restart policy
`unless-stopped`; Docker Desktop and the kind cluster must remain running.
Hostname rules belong in each app's Ingress, allowing multiple apps to share the
same gateway and controller on port 80.

The setup script initially applies the Ingress directly. Once this Git repository
is connected to the app's Argo CD Application, Argo CD manages the route from
`myfastapiapp/kustomization.yaml`. The Application files in `argocd/` are
bootstrapped separately; reapply them after changing their settings. Traefik's
Application fetches its Helm chart from the public chart repository.

To refresh or stop the gateway using this repository's configuration:

```sh
KIND_NODE=argocd-demo-control-plane docker compose \
  --project-name kind-ingress-argocd-demo -f kind/compose.yaml up -d

KIND_NODE=argocd-demo-control-plane docker compose \
  --project-name kind-ingress-argocd-demo -f kind/compose.yaml down
```

## Open the Argo CD UI

```sh
kubectl --context kind-argocd-demo -n argocd \
  port-forward service/argocd-server 8080:443
```

Keep that terminal running and open https://localhost:8080. This local connection
is for the Argo CD UI; it is independent of the application's Ingress access.

## Release an app change

1. Build and load a new image tag from the app's own repository, for example
   `./scripts/build-kind.sh v2` there.
2. Update `image` in this repository's `myfastapiapp/deployment.yaml`.
3. Commit and push the deployment change, then wait for automatic sync or sync in
   Argo CD. Use new image tags for code changes.

Manifest-only changes, such as replica counts, resource requests, or the Ingress
hostname, need only a deployment-repository commit. They do not require rebuilding
the application image.
