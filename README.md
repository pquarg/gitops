# Kubernetes deployments

An independent Git repository containing Kubernetes manifests and local platform
configuration. Application code and Dockerfiles belong in separate application
repositories.

For Postgres in kind with data stored in a laptop directory, follow the
[Postgres walkthrough](docs/postgres-kind.md). It uses a separate overlay and a
second cluster, `argocd-postgres`, so the existing `argocd-demo` setup can keep
running. The base manifests below do not provision a database.

```text
.github/workflows/
  validate.yaml          # Configuration checks on GitHub-hosted runners
myfastapiapp/
  configmap.yaml         # Non-secret application configuration
  secrets.example.yaml   # Blank template for the local credential file
  secrets.yaml           # Git-ignored credentials; apply separately
  deployment.yaml        # Image, replica count, probes, and resource settings
  service.yaml           # Service port 80 -> app container port 8000
  ingress.yaml           # myfastapiapp.localhost -> app Service
  kustomization.yaml     # Includes ConfigMap, Deployment, Service, and Ingress
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

## Names and lookups

Each Kubernetes object has a suffix describing its role. Names only need to
match where a field explicitly references them:

| Definition | Value | What uses it |
| --- | --- | --- |
| Argo CD Application `metadata.name` | `myfastapiapp-application` | Identifies the app in Argo CD; its `source.path` selects the manifest directory. |
| Deployment `metadata.name` | `myfastapiapp-deployment` | The deploy script waits for this Deployment's rollout. |
| Pod template label `app` | `myfastapiapp-pod` | Both the Deployment's `selector.matchLabels.app` and the Service's `selector.app` match this value. |
| Container `name` | `myfastapiapp-container` | Identifies the container inside each Pod, for example when selecting logs. |
| ConfigMap `metadata.name` | `myfastapiapp-config` | The Deployment's `env[].valueFrom.configMapKeyRef.name` references this ConfigMap. |
| Application credential Secret name | `myfastapiapp-secrets` | The Deployment's `envFrom[].secretRef.name` references this separately provisioned Secret. |
| Service `metadata.name` | `myfastapiapp-service` | The Ingress's `backend.service.name` and the port-forward command reference this Service. |
| Ingress `metadata.name` | `myfastapiapp-ingress` | The Ingress setup script waits for this Ingress. |

The Service finds Pods using their labels; it does not look up the Deployment or
container by name. `myfastapiapp-pod` is a label value; Kubernetes generates actual
Pod names from the Deployment name. The Service sends traffic from port `80` to
the container port named `http` (`8000` in `deployment.yaml`).

Three other values have separate purposes: Argo CD's `source.path: myfastapiapp`
looks up the `myfastapiapp/` directory in this repository;
`ghcr.io/pquarg/myfastapiapp:0.1.1` identifies the published container image; and
`myfastapiapp.localhost` is the request hostname matched by the Ingress.

If a cluster already uses the original unsuffixed names, these renames create new
resources. Retire the old Argo CD Application and its Deployment, Service, and
Ingress as part of the transition, so two Applications do not manage the same
directory and two Ingresses do not claim the same hostname. Editing these files
alone does not change the cluster.

## Application configuration

`myfastapiapp/configmap.yaml` stores `APP_MESSAGE`. The Deployment reads that key
from `myfastapiapp-config` into the container's `APP_MESSAGE` environment variable.
Kustomize includes the ConfigMap alongside the Deployment, Service, and Ingress,
so both Argo CD and the manual deploy script apply it in the app's namespace.

Edit the ConfigMap file, then commit and push for Argo CD to sync it. Once the
updated ConfigMap has synced, use [Argo CD's Restart action](https://argo-cd.readthedocs.io/en/stable/operator-manual/resource_actions_builtin/) on
`myfastapiapp-deployment` to make existing Pods pick up the new environment value.
For a manual deployment without Argo CD, run:

```sh
kubectl --context kind-argocd-demo -n default apply -k myfastapiapp
kubectl --context kind-argocd-demo -n default rollout restart deployment/myfastapiapp-deployment
kubectl --context kind-argocd-demo -n default rollout status deployment/myfastapiapp-deployment --timeout=120s
```

This ConfigMap has a fixed name. Changing its data alone does not trigger a
Deployment rollout, and running
containers keep their previous environment values until their Pods are replaced.
See [Kubernetes ConfigMap updates](https://kubernetes.io/docs/concepts/configuration/configmap/#mounted-configmaps-are-updated-automatically).

## Application credentials

Store local credentials in `myfastapiapp/secrets.yaml`, which `.gitignore`
excludes from Git. Apply it manually to create the `myfastapiapp-secrets` Secret
in namespace `default`. The Deployment imports its keys as environment variables
through `envFrom`. The file contains plaintext credentials, so restrict its
permissions to your user.

On a fresh clone, create the local file from the blank template. The `-n` flag
preserves an existing file if you rerun this command:

```sh
cp -n myfastapiapp/secrets.example.yaml myfastapiapp/secrets.yaml
chmod 600 myfastapiapp/secrets.yaml
git check-ignore myfastapiapp/secrets.yaml
```

The last command should print `myfastapiapp/secrets.yaml`. Edit that file in your
editor and fill in `stringData.API_USERNAME` and `stringData.API_PASSWORD`.
The base Deployment stays on `0.1.1`. The newer account-based application uses
Postgres through `AUTH_DATABASE_URL`; its overlay has separate local Secret files
as described in the [walkthrough](docs/postgres-kind.md#3-create-the-database-secrets).
Keep the metadata name `myfastapiapp-secrets` and namespace `default` so they
match the Deployment. Only the blank `secrets.example.yaml` belongs in Git.

Apply the local file after filling in the values, before syncing the Deployment
change or running `./scripts/deploy-kind.sh`:

```sh
kubectl --context kind-argocd-demo -n default apply -f myfastapiapp/secrets.yaml
kubectl --context kind-argocd-demo -n default get secret myfastapiapp-secrets \
  -o 'custom-columns=NAME:.metadata.name,NAMESPACE:.metadata.namespace,TYPE:.type'
```

The second command checks presence and type without displaying credentials.
The Secret must exist before new app Pods can start. Argo CD manages the
Deployment's reference; the Secret is provisioned separately. Keep both the
local file and the example out of `myfastapiapp/kustomization.yaml`: Argo CD
cannot read an untracked file, and the example has empty values. GitHub Actions
continues to validate the tracked configuration without needing local secrets.

After creating the Secret, commit and push the Deployment reference if it is not
already published, then wait for Argo CD to sync it. The app code must read
`API_USERNAME` and `API_PASSWORD` to use the credentials; this repository
supplies the environment variables. To verify their presence without printing
the values:

```sh
kubectl --context kind-argocd-demo -n default rollout status deployment/myfastapiapp-deployment --timeout=120s
kubectl --context kind-argocd-demo -n default exec deployment/myfastapiapp-deployment -- \
  python -c 'import os; print("Credentials present:", all(os.environ.get(k) for k in ("API_USERNAME", "API_PASSWORD")))'
```

When credentials change, edit the local file and rerun the apply command. Once
it succeeds, use Argo CD's Restart action on `myfastapiapp-deployment`, or run:

```sh
kubectl --context kind-argocd-demo -n default rollout restart deployment/myfastapiapp-deployment
kubectl --context kind-argocd-demo -n default rollout status deployment/myfastapiapp-deployment --timeout=120s
```

Editing the file alone does not update Kubernetes, and updating the Secret does
not refresh environment variables in existing containers. Reapply the file after
rebuilding the kind cluster. For another cluster or namespace, update the context
and namespace in the file and commands as appropriate. See
[Kubernetes Secret environment variables](https://kubernetes.io/docs/tasks/inject-data-application/distribute-credentials-secure/).

### Move to AWS CSI later

For a later AWS Secrets Store CSI Driver integration, retain Secret name
`myfastapiapp-secrets` and keys `API_USERNAME` and `API_PASSWORD`. Add a
`SecretProviderClass` containing AWS references, configure its `secretObjects`
mapping to create that Kubernetes Secret, and mount its CSI volume in the Pod.
Secret synchronization requires the CSI volume mount even when the app only
uses environment variables. Configure the AWS provider and workload IAM access
for the target cluster. See the
[CSI Secret synchronization documentation](https://secrets-store-csi-driver.sigs.k8s.io/topics/sync-as-kubernetes-secret).

Stop manually applying the local Secret before CSI takes ownership.
Plan the ownership handover: CSI manages the synced Secret's lifecycle and may
require recreating the existing manually created Secret. The app's environment
variable names and code can remain the same. If `secrets.yaml` becomes a
reference-only `SecretProviderClass` manifest, remove its `.gitignore` entry
before committing it, and ensure its contents contain references only.

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
   register the Application:

   ```sh
   kubectl --context kind-argocd-demo apply -f argocd/myfastapiapp.yaml
   kubectl --context kind-argocd-demo -n argocd get applications
   ```

The Application is named `myfastapiapp-application` and manages the manifests in
`myfastapiapp/`. Its `automated` sync policy applies committed changes, and
`selfHeal: true` restores managed resources that drift from Git. Push the
manifests and connect this deployment repo before changing the old app
repository's published layout. If replacing an existing unsuffixed Application,
follow the transition note under [Names and lookups](#names-and-lookups).

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
  -> myfastapiapp-ingress rule: backend.service.name
  -> myfastapiapp-service:80: selector app=myfastapiapp-pod
  -> matching Pod:8000 / myfastapiapp-container
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
