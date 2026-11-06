# myfastapiapp staging deployment

Run commands from `gitops`. Source, image builds and Alembic revisions live in
`apps/myfastapiapp`; the deployment database is provisioned by `infra-local`.

| Setting | Value |
| --- | --- |
| Cluster context | `kind-argocd-postgres` |
| Namespace | `myfastapiapp` |
| Argo CD Application | `staging-myfastapiapp` |
| URL | http://myfastapiapp.localhost/api/v1/docs/ |
| Database endpoint from Pods | `host.docker.internal:5433` (Docker Desktop) |

The local and AWS overlays use the same API Deployment and migration Job. Both
connect to an already provisioned external PostgreSQL database through
`myfastapiapp-secrets`. Local uses a separate Compose container; AWS uses RDS.
The local overlay contains app configuration and Traefik ingress, with no
PostgreSQL workload or storage in the app sync.

Existing Kubernetes databases must follow the [database cutover](../../../../docs/local/database-migration.md)
before publishing this overlay change. Installations still in `default` must
first finish the [legacy namespace migration](../../../../docs/local/repository-upgrade.md#move-myfastapiapp-out-of-default).

## Provision credentials

First follow [database provisioning](../../../../../infra-local/docs/database.md#first-setup).
Keep the database running before app sync, as with RDS on AWS. Provision these
Secrets in namespace `myfastapiapp`:

| Ignored file or credential | Secret |
| --- | --- |
| `apps/myfastapiapp/overlays/local/app-secrets.yaml` | `myfastapiapp-secrets` with `AUTH_DATABASE_URL` |
| GitHub package token, entered interactively | `registry-credentials` |

```sh
kubectl --context kind-argocd-postgres create namespace myfastapiapp
cp -n apps/myfastapiapp/overlays/local/app-secrets.example.yaml apps/myfastapiapp/overlays/local/app-secrets.yaml
chmod 600 apps/myfastapiapp/overlays/local/app-secrets.yaml
git check-ignore apps/myfastapiapp/overlays/local/app-secrets.yaml
```

Set `AUTH_DATABASE_URL` privately in that file using the Compose **app** password,
URL-encoded, and its configured published port (default 5433):

```text
postgresql://myfastapiapp:ENCODED_PASSWORD@host.docker.internal:5433/myfastapiapp?sslmode=disable
```

This endpoint is for kind Pods on Docker Desktop; host clients use localhost.
Local TLS is disabled; AWS retains verified TLS and its RDS CA mounts.

```sh
kubectl --context kind-argocd-postgres -n myfastapiapp apply -f apps/myfastapiapp/overlays/local/app-secrets.yaml
```

Create `registry-credentials` using the shared [registry instructions](../../../../docs/local/credentials.md#registry-authentication).
Make the selected image available as below, then check the actual Pod-to-database
path before registering or syncing the app:

```sh
./scripts/check-local-database.py --environment local --context kind-argocd-postgres
```

This temporary Job uses the selected app image and connection Secret, verifies
restricted app privileges and rolls back a small DDL/data probe. It leaves the
schema unchanged and does not require an existing API Deployment or migration.
It needs a ready cluster, namespace, Secret and image. Do not proceed if it fails.
Filled Secret files stay outside Git and Kustomize.

## Update configuration or credentials

Apply edited connection Secrets with the command above. Environment variables do
not refresh in running Pods. Restart the API through Argo CD or explicitly:

```sh
kubectl --context kind-argocd-postgres -n myfastapiapp rollout restart deployment/myfastapiapp-deployment
kubectl --context kind-argocd-postgres -n myfastapiapp rollout status deployment/myfastapiapp-deployment --timeout=180s
```

Changing a password file or Kubernetes Secret does not rotate an existing database
role. Follow [database credential rotation](../../../../../infra-local/docs/database.md#lifecycle-and-credentials),
then run the connectivity probe and verify readiness/login.

## Make the app image available

The selected image tag in `apps/myfastapiapp/overlays/local/kustomization.yaml` applies to both
the API and migration Job. Publish the image from the separate app repository
before deploying that tag. When updating its project version, refresh and commit
its lockfile with `uv lock --project ../apps/myfastapiapp`; the image build uses
`uv sync --locked`.

Confirm its image publishing job succeeded. If a failed release skipped publication:

```sh
gh workflow run ci.yaml --repo pquarg/myfastapiapp --ref main
gh run list --repo pquarg/myfastapiapp --workflow ci.yaml --limit 3
```

For a local build instead, load the exact selected image into kind:

```sh
APP_IMAGE="$(kubectl kustomize apps/myfastapiapp/overlays/local |
  awk '$1 == "image:" && $2 ~ /myfastapiapp:/ { image = $2 } END { print image }')"
docker build --provenance=false -t "$APP_IMAGE" ../apps/myfastapiapp
kind load docker-image "$APP_IMAGE" --name argocd-postgres
```

Use a new image tag for every code release. `IfNotPresent` can reuse a previously
loaded image with the same tag. The app repository’s development Compose database
and infra-local’s deployment database are independent; neither copies records automatically.

## Verify the deployment

After [bootstrap](../../../../docs/local/setup.md#4-validate-publish-and-register-staging),
wait for app sync and migration completion. Then:

```sh
kubectl --context kind-argocd-postgres -n myfastapiapp logs job/myfastapiapp-migrate
kubectl --context kind-argocd-postgres -n myfastapiapp rollout status deployment/myfastapiapp-deployment --timeout=300s
kubectl --context kind-argocd-postgres -n myfastapiapp exec deployment/myfastapiapp-deployment -- python -m alembic current --check-heads
curl -fsS http://myfastapiapp.localhost/health
curl -fsS http://myfastapiapp.localhost/ready
```

`/health` checks the API process; `/ready` checks database connectivity. Confirm
Argo CD reports Healthy and the intended revision. A fresh installation should
also be Synced; retained legacy resources can cause OutOfSync after migration,
as explained in the [cutover runbook](../../../../docs/local/database-migration.md).
Test new registration and login, plus existing login/records after data migration.
Docker Desktop, the separate database and kind must all remain running.

The route is localhost port 80 → kind node port 30080 → shared Traefik → app
Service → FastAPI. For a direct diagnostic connection:

```sh
kubectl --context kind-argocd-postgres -n myfastapiapp port-forward service/myfastapiapp-service 18000:80
```

Open http://localhost:18000/api/v1/docs/. Inspect migration logs and Pod events
if rollout fails.

## Release

1. Build and publish a new image from the app repository, or build and load it
   into `argocd-postgres` for local use. Keep the app version and lockfile in sync.
2. Update `images[].newTag` in
   `apps/myfastapiapp/overlays/local/kustomization.yaml`. This selects the same
   release for the API and migration Job. This is the only deployment image
   version to edit for local; AWS has its own overlay image selection. The shared
   workload manifests contain no release tags.
3. For a database change, follow the backup and controlled sync steps below
   before pushing. For other changes, commit and push, then wait for Argo CD to sync.

Use a new image tag for each code release. Manifest-only edits, such as resource
settings, replicas, and Ingress rules, need only a deployment-repository commit.
FastAPI keeps its app release version; PostgreSQL has its own image version in
`infra-local/database/compose.yaml` in the sibling repository. PostgreSQL is
provisioned separately; app sync does not upgrade or restart it.
See [image publishing](#make-the-app-image-available)
if a failed release skipped image publication.

## Back up and release a database change

1. Disable auto-sync on `staging-myfastapiapp` in Argo CD and wait for active
   syncs/migration Jobs to finish. The ApplicationSet preserves this live pause.
2. Follow [backup and restore verification](../../../../../infra-local/docs/database.md#backup-and-restore).
   Run the Compose backup helper from `infra-local`, not the legacy Pod backup
   helper under `postgres/`. Keep writers paused when the recovery point must
   preserve every write through the change.
3. Validate and review before publishing:

   ```sh
   ./scripts/validate.sh --ready
   ./scripts/validate-server.sh myfastapiapp --environment local --context kind-argocd-postgres
   ./scripts/check-local-database.py --environment local --context kind-argocd-postgres
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
[Compose reset procedure](../../../../../infra-local/docs/database.md#deliberately-reset-disposable-app-data).
The old [Kubernetes reset runbook](postgres/reset.md) is for unmigrated databases only.

## Recovery after a cluster rebuild

The database continues running outside kind, with its Docker volume and roles
unchanged. Follow [platform rebuild](../../../../../infra-local/docs/rebuild.md),
recreate the app namespace, app connection Secret, registry/Git credentials and
selected image, then run the Pod connectivity probe before registration.
No database directory or storage mount is required for this app on a fresh cluster.
Existing kind mounts, original data files and legacy Secrets remain preserved
until their separate retirement is authorized.

Database recovery is independent of cluster recreation. Follow
[backup/restore](../../../../../infra-local/docs/database.md#backup-and-restore)
and verify actual app behaviour before traffic. Password files only initialize
empty storage; keep the passwords matching the existing database roles.
