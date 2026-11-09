# demo-api local deployment

The desired namespace is `demo-api`, while the existing PostgreSQL database/login
remain `myfastapiapp`. Existing installations need the
[app rename handoff](../../../../docs/app-rename.md) before publication or sync.

Run commands from `gitops`. Source, image builds and Alembic revisions live in
the separate `../apps/demo-api` repository; the deployment database is
provisioned by `infra/environments/local`.

| Setting | Value |
| --- | --- |
| Cluster context | `kind-deployment` |
| Namespace | `demo-api` |
| Argo CD Application | `demo-api` |
| URL | http://demo-api.localhost/api/v1/docs/ |
| Database endpoint from Pods | `host.docker.internal:5433` (Docker Desktop) |

The local and AWS overlays use the same API Deployment and migration Job. Both
connect to an already provisioned external PostgreSQL database through
`demo-api-secrets`. Local uses a separate Compose container; AWS uses RDS.
The local overlay contains app configuration and Traefik ingress, with no
PostgreSQL workload or storage in the app sync.

## Provision credentials

Complete these steps before registering the app: local sync automatically
runs migrations and deploys the API. Argo CD's Git credential, the GHCR PAT
and the database password are separate credentials.

### 1. Start the deployment database

First follow [database provisioning](../../../../../infra/environments/local/docs/database.md#first-setup).
From `infra/environments/local`, `./scripts/local-database.sh status` must show a healthy
PostgreSQL service. The app password is in `app-password` under the directory
configured by `LOCAL_DB_SECRETS_DIR` in `infra/environments/local/database/.env`; the suggested
directory is `$HOME/.local/share/infra-local/database-secrets`.
Missing configuration/password files on a fresh setup mean database first
setup is incomplete. For an existing database, preserve its credentials and
follow the [database lifecycle guide](../../../../../infra/environments/local/docs/database.md#lifecycle-and-credentials).

### 2. Create the namespace and registry Secret

Return to `gitops`. Create the namespace if it does not already exist:

```sh
kubectl --context kind-deployment create namespace demo-api
```

For private GHCR pulls, create a **classic** GitHub PAT with `read:packages` and
read access to the package. A useful name is `kind-deployment-ghcr-pull`.
Run the helper and enter the PAT at its hidden prompt:

```sh
python3 scripts/configure-ghcr-credentials.py kind-deployment pquarg
```

Use the GitHub account that owns the PAT in place of `pquarg` if different.
See [registry credentials](../../../../docs/local/credentials.md#registry-authentication)
for token expiry, rotation and verification. Signing into Argo CD or configuring
its Git repository does not create this Secret.

### 3. Configure the database connection Secret

The namespace needs both Secrets:

| Ignored file or credential | Secret |
| --- | --- |
| `apps/demo-api/overlays/local/app-secrets.yaml` | `demo-api-secrets` with `AUTH_DATABASE_URL` |
| GitHub package token, entered interactively | `registry-credentials` |

```sh
cp -n apps/demo-api/overlays/local/app-secrets.example.yaml apps/demo-api/overlays/local/app-secrets.yaml
chmod 600 apps/demo-api/overlays/local/app-secrets.yaml
git check-ignore apps/demo-api/overlays/local/app-secrets.yaml
```

Edit the ignored file and set `stringData.AUTH_DATABASE_URL` using the Compose
**app** password, URL-encoded, and its configured published port (default 5433):

```text
postgresql://myfastapiapp:ENCODED_PASSWORD@host.docker.internal:5433/myfastapiapp?sslmode=disable
```

This endpoint is for kind Pods on Docker Desktop; host clients use localhost.
Local TLS is disabled; AWS retains verified TLS and its RDS CA mounts.
Use the existing `app-password`, not the admin password or GHCR PAT. Passwords
generated with `openssl rand -hex 24` need no URL encoding; URL-encode special
characters in other passwords.

`cp -n` preserves an existing file. If reusing one, review its connection value:
`myfastapiapp-postgres-service:5432` is the old in-cluster address and will not
reach the separate Compose database. Update the host, port and password to
match the current database before applying it.
If the existing file stores the connection as `data.AUTH_DATABASE_URL`, that
value is base64-encoded. Replace that entry with the example's `stringData`
entry to edit the URL as plain text.

```sh
kubectl --context kind-deployment -n demo-api apply -f apps/demo-api/overlays/local/app-secrets.yaml
```

Confirm that both Secret names and types are present without displaying their
contents:

```sh
kubectl --context kind-deployment -n demo-api get secrets \
  -o 'custom-columns=NAME:.metadata.name,TYPE:.type'
```

Expect `registry-credentials` of type `kubernetes.io/dockerconfigjson` and
`demo-api-secrets` of type `Opaque`. This checks their presence, not whether
the credentials work. Filled Secret files stay outside Git and Kustomize.

### 4. Check image access and database connectivity

[Make the selected image available](#make-the-app-image-available), then check
the actual Pod-to-database path before registering or syncing the app:

```sh
./scripts/check-demo-api-local-database.py --environment local --context kind-deployment
```

This temporary Job uses the selected app image and connection Secret, verifies
restricted app privileges and rolls back a small DDL/data probe. It leaves the
schema unchanged and does not require an existing API Deployment or migration.
It needs a ready cluster, namespace, Secret and image. Do not proceed if it fails.
`job.batch/local-db-check-... created` only means the Job was submitted.
Wait for:

```text
Database connectivity, app privileges and transactional DDL passed.
```

The helper waits for completion for up to 120 seconds, including when the Job
has already failed. If it looks stuck, inspect the Job in a second terminal
using [troubleshooting](#troubleshoot-the-first-sync) before it is cleaned up.
Once the probe passes, continue with [validation and registration](../../../../docs/local/setup.md#4-validate-publish-and-register-apps).

## Update configuration or credentials

Apply edited connection Secrets with the command above. Environment variables do
not refresh in running Pods. Restart the API through Argo CD or explicitly:

```sh
kubectl --context kind-deployment -n demo-api rollout restart deployment/demo-api
kubectl --context kind-deployment -n demo-api rollout status deployment/demo-api --timeout=180s
```

Changing a password file or Kubernetes Secret does not rotate an existing database
role. Follow [database credential rotation](../../../../../infra/environments/local/docs/database.md#lifecycle-and-credentials),
then run the connectivity probe and verify readiness/login.

## Make the app image available

The selected image tag in `apps/demo-api/overlays/local/kustomization.yaml` applies to both
the API and migration Job. Publish the image from the separate app repository
before deploying that tag. When updating its project version, refresh and commit
its lockfile with `uv lock --project ../apps/demo-api`; the image build uses
`uv sync --locked`.

Confirm its image publishing job succeeded. If a failed release skipped publication:

```sh
gh workflow run ci.yaml --repo pquarg/myfastapiapp --ref main
gh run list --repo pquarg/myfastapiapp --workflow ci.yaml --limit 3
```

For a local build instead, load the exact selected image into kind:

```sh
APP_IMAGE="$(kubectl kustomize apps/demo-api/overlays/local |
  awk '$1 == "image:" && $2 ~ /demo-api:/ { image = $2 } END { print image }')"
docker build --provenance=false -t "$APP_IMAGE" ../apps/demo-api
kind load docker-image "$APP_IMAGE" --name deployment
```

Use a new image tag for every code release. `IfNotPresent` can reuse a previously
loaded image with the same tag. The app repository’s development Compose database
and infra/environments/local’s deployment database are independent; neither copies records automatically.

## Verify the deployment

After [bootstrap](../../../../docs/local/setup.md#4-validate-publish-and-register-apps),
wait for app sync and migration completion. Then:

```sh
kubectl --context kind-deployment -n demo-api logs job/demo-api-migrate
kubectl --context kind-deployment -n demo-api rollout status deployment/demo-api --timeout=300s
kubectl --context kind-deployment -n demo-api exec deployment/demo-api -- python -m alembic current --check-heads
curl -fsS http://demo-api.localhost/health
curl -fsS http://demo-api.localhost/ready
```

`/health` checks the API process; `/ready` checks database connectivity. Confirm
Argo CD reports **Synced / Healthy** for `demo-api` and the intended
revision. Both HTTP checks should return `{"status":"ok"}`. Bootstrap **Synced**
alone does not establish app health: migration wave `0` must succeed before
the API in wave `1` rolls out.
Test new registration and login in the [API docs](http://demo-api.localhost/api/v1/docs/),
plus existing login and records after updates. These are the final functional
checks after the deployment checks above pass.
Docker Desktop, the separate database and kind must all remain running.
Renew the GHCR PAT before expiry so future image pulls continue to work.

The route is localhost port 80 → kind node port 30080 → shared Traefik → app
Service → FastAPI. For a direct diagnostic connection:

```sh
kubectl --context kind-deployment -n demo-api port-forward service/demo-api 18000:80
```

Open http://localhost:18000/api/v1/docs/. Inspect migration logs and Pod events
if rollout fails.

## Troubleshoot the first sync

Start with the current Pods, Jobs and recent events:

```sh
kubectl --context kind-deployment -n demo-api get pods,jobs
kubectl --context kind-deployment -n demo-api get events --sort-by=.lastTimestamp
```

Events retain earlier errors; match them to the current Pod and its timestamp.

| Symptom | Check and correction |
| --- | --- |
| GHCR `401 Unauthorized`, `ImagePullBackOff` or `FailedToRetrieveImagePullSecret` | Check `registry-credentials` exists in `demo-api`. Rerun the [registry helper](../../../../docs/local/credentials.md#registry-authentication) with a valid classic PAT with `read:packages` and package access. |
| `CreateContainerConfigError` with `secret "demo-api-secrets" not found` | Apply the filled connection Secret from [credential setup](#3-configure-the-database-connection-secret). |
| `failed to resolve host 'myfastapiapp-postgres-service'` | The connection still uses the old in-cluster address. Update the ignored Secret file to `host.docker.internal:5433`, use the current Compose app password and apply it again. |
| Connection refused or timed out | Check Docker Desktop, PostgreSQL health, the configured host port and the Pod-to-host route. See [database setup](../../../../../infra/environments/local/docs/database.md#first-setup). |
| Password authentication failed | Use the existing Compose password for the `myfastapiapp` database login. Replacing a password file does not rotate an initialized database; follow [credential rotation](../../../../../infra/environments/local/docs/database.md#lifecycle-and-credentials). |
| Database probe appears to hang after `job.batch/... created` | Inspect the Job status and logs below. The helper waits up to 120 seconds for success even if the Job has failed. |

For a waiting database probe, copy its `local-db-check-...` name from the
helper output. In a second terminal, replace `JOB_NAME` with that name:

```sh
kubectl --context kind-deployment -n demo-api get job JOB_NAME
kubectl --context kind-deployment -n demo-api logs job/JOB_NAME
```

The helper deletes its temporary Job when it exits, so inspect it while the
helper is waiting. The migration Job is retained for inspection:

```sh
kubectl --context kind-deployment -n demo-api logs job/demo-api-migrate
```

After correcting the cause, rerun the database probe. If it passes, allow a
pending automatic sync retry to run. If the earlier sync has exhausted its
retries, sync the **entire** `demo-api` Application in Argo CD with
Prune, Force and Replace off. Selective sync skips migration hooks. Run the
[deployment verification](#verify-the-deployment) afterward. Applying an
ignored Secret needs no commit or push; manifest changes must be published.

## Release

1. Build and publish a new image from the app repository, or build and load it
   into `deployment` for local use. Keep the app version and lockfile in sync.
2. Update `images[].newTag` in
   `apps/demo-api/overlays/local/kustomization.yaml`. This selects the same
   release for the API and migration Job. This is the only deployment image
   version to edit for local; AWS has its own overlay image selection. The shared
   workload manifests contain no release tags.
3. For a database change, follow the backup and controlled sync steps below
   before pushing. For other changes, commit and push, then wait for Argo CD to sync.

Use a new image tag for each code release. Manifest-only edits, such as resource
settings, replicas, and Ingress rules, need only a deployment-repository commit.
FastAPI keeps its app release version; PostgreSQL has its own image version in
`infra/environments/local/database/compose.yaml` in the sibling repository. PostgreSQL is
provisioned separately; app sync does not upgrade or restart it.
See [image publishing](#make-the-app-image-available)
if a failed release skipped image publication.

## Back up and release a database change

1. Disable auto-sync on `demo-api` in Argo CD and wait for active
   syncs/migration Jobs to finish. The ApplicationSet preserves this live pause.
2. Follow [backup and restore verification](../../../../../infra/environments/local/docs/database.md#backup-and-restore).
   Run the Compose backup helper from `infra/environments/local`. Keep writers paused when
   the recovery point must preserve every write through the change.
3. Validate and review before publishing:

   ```sh
   ./scripts/validate.sh --no-placeholders
   ./scripts/validate-server.sh demo-api --environment local --context kind-deployment
   ./scripts/check-demo-api-local-database.py --environment local --context kind-deployment
   git diff --check
   ```

4. Commit/push the release selection, refresh Argo CD and sync the **entire**
   Application with Prune, Force and Replace off. Selective sync skips hooks.
   Like AWS, wave `0` runs the migration Job against the existing database;
   wave `1` rolls out the API only after migration success. No database provisioning
   happens in this sync. The Job uses the same selected image and Secret as the API.
5. Run [verification](#verify-the-deployment), including existing login and records,
   then re-enable automatic sync. The latest migration Job/logs remain until the
   next sync; Alembic skips already applied revisions.

If migrations succeed but the API fails, the schema has already changed. Review
compatibility before reverting the app image; Git rollback does not undo migrations.
For deliberate disposable-data resets, follow the
[Compose reset procedure](../../../../../infra/environments/local/docs/database.md#deliberately-reset-disposable-app-data).

## Recovery after a cluster rebuild

The database continues running outside kind, with its Docker volume and roles
unchanged. Follow [platform rebuild](../../../../../infra/environments/local/docs/rebuild.md),
recreate the app namespace, app connection Secret, registry/Git credentials and
selected image, then run the Pod connectivity probe before registration.
No database directory or storage mount is required for this app on a fresh cluster.

Database recovery is independent of cluster recreation. Follow
[backup/restore](../../../../../infra/environments/local/docs/database.md#backup-and-restore)
and verify actual app behaviour before traffic. Password files only initialize
empty storage; keep the passwords matching the existing database roles.
