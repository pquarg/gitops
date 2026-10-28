# myfastapiapp staging deployment

Run commands from the deployment repository root. Application code, Dockerfiles
and Alembic revisions live in the separate `myfastapiapp` repository.

| Setting | Value |
| --- | --- |
| Cluster context | `kind-argocd-postgres` |
| Namespace | `myfastapiapp` |
| Argo CD Application | `staging-myfastapiapp` |
| URL | http://myfastapiapp.localhost/api/v1/docs/ |

This app owns its Postgres database, storage, credentials, migrations and backup
procedure. The shared ApplicationSet discovers this directory and creates its
Application and namespace using the same [convention as every app](../../docs/adding-apps.md).
For an installation still running in `default`, complete the
[one-time migration](../../docs/repository-upgrade.md#move-myfastapiapp-out-of-default)
before deploying these manifests.

The root `kustomization.yaml` includes all app and Postgres resources and selects
one release image for both the API and migration Job. Edit `configmap.yaml` for
`APP_MESSAGE`, `deployment.yaml` for resources and probes, and `ingress.yaml` for
routing. Provision the [cluster](../../docs/setup.md) before the first sync.

## Provision credentials

Provision these Secrets in namespace `myfastapiapp` before the first sync:

| Ignored file or credential | Secret in namespace `myfastapiapp` |
| --- | --- |
| `apps/myfastapiapp/app-secrets.yaml` | `myfastapiapp-secrets` with `AUTH_DATABASE_URL` |
| `apps/myfastapiapp/postgres/postgres-secrets.yaml` | `myfastapiapp-postgres-secrets` with `POSTGRES_PASSWORD` |
| GitHub package token, entered interactively | `registry-credentials` for private image pulls |

For the database files:

```sh
kubectl --context kind-argocd-postgres create namespace myfastapiapp
cp -n apps/myfastapiapp/app-secrets.example.yaml apps/myfastapiapp/app-secrets.yaml
cp -n apps/myfastapiapp/postgres/postgres-secrets.example.yaml \
  apps/myfastapiapp/postgres/postgres-secrets.yaml
chmod 600 apps/myfastapiapp/app-secrets.yaml \
  apps/myfastapiapp/postgres/postgres-secrets.yaml
git check-ignore apps/myfastapiapp/app-secrets.yaml \
  apps/myfastapiapp/postgres/postgres-secrets.yaml
```

Choose one password and enter it in both local files in your editor. Set
`POSTGRES_PASSWORD` to the password and `AUTH_DATABASE_URL` to
`postgresql://myfastapiapp:YOUR_PASSWORD@myfastapiapp-postgres-service:5432/myfastapiapp`.
A hex password from a password manager or `openssl rand -hex 24` avoids URL escaping.
For special characters, URL-encode the password in the URL and keep the original
value in `POSTGRES_PASSWORD`.

```sh
kubectl --context kind-argocd-postgres -n myfastapiapp apply \
  -f apps/myfastapiapp/app-secrets.yaml \
  -f apps/myfastapiapp/postgres/postgres-secrets.yaml
```

Create `registry-credentials` using the shared [registry instructions](../../docs/credentials.md#registry-authentication).

Secrets are provisioned separately from Argo CD. Keep filled files out of both
Git and Kustomize. Kubernetes Secret base64 encoding is reversible.

## Update configuration or credentials

Apply edited local database Secrets with the command above. Secret and ConfigMap
values consumed as environment variables do not refresh in running Pods. After
applying a Secret or syncing a ConfigMap, restart the app through Argo CD or run:

```sh
kubectl --context kind-argocd-postgres -n myfastapiapp \
  rollout restart deployment/myfastapiapp-deployment
kubectl --context kind-argocd-postgres -n myfastapiapp \
  rollout status deployment/myfastapiapp-deployment --timeout=180s
```

`POSTGRES_PASSWORD` initializes a new database. Updating the Secret alone does
not rotate an existing database role's password; see [recovery](#recovery-after-a-cluster-rebuild).

## Make the app image available

The selected image tag in `apps/myfastapiapp/kustomization.yaml` applies to both
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
APP_IMAGE="$(kubectl kustomize apps/myfastapiapp |
  awk '$1 == "image:" && $2 ~ /myfastapiapp:/ { image = $2 } END { print image }')"
docker build --provenance=false -t "$APP_IMAGE" ../apps/myfastapiapp
kind load docker-image "$APP_IMAGE" --name argocd-postgres
```

Use a new image tag for every code release. `IfNotPresent` can reuse a previously
loaded image with the same tag. Existing Compose databases and Kubernetes storage
are independent; this setup does not copy existing records.

## Verify the deployment

After the shared [bootstrap procedure](../../docs/setup.md#4-validate-publish-and-register-staging),
wait for this app to be **Synced / Healthy** and verify it:

```sh
kubectl --context kind-argocd-postgres -n myfastapiapp \
  rollout status deployment/myfastapiapp-deployment --timeout=300s
kubectl --context kind-argocd-postgres -n myfastapiapp get pvc,pods
kubectl --context kind-argocd-postgres get pv myfastapiapp-postgres-pv
curl -fsS http://myfastapiapp.localhost/health
curl -fsS http://myfastapiapp.localhost/ready
```

Open http://myfastapiapp.localhost/api/v1/docs/, register a test account, and log
in. The route is localhost port 80 -> kind node port 30080 -> Traefik -> the app
Service -> FastAPI. Docker Desktop and the cluster must remain running.

For a direct connection while diagnosing ingress:

```sh
kubectl --context kind-argocd-postgres -n myfastapiapp \
  port-forward service/myfastapiapp-service 18000:80
```

Open http://localhost:18000/api/v1/docs/. Inspect Pod events and migration logs
if rollout fails. Routine releases now follow the [release procedure](#release).

## Release

1. Build and publish a new image from the app repository, or build and load it
   into `argocd-postgres` for local use. Keep the app version and lockfile in sync.
2. Update `images[].newTag` in
   `apps/myfastapiapp/kustomization.yaml`. This selects the same
   release for the API and migration Job. This is the only deployment image
   version to edit; the workload manifests contain no release tags.
3. For a database change, follow the backup and controlled sync steps below
   before pushing. For other changes, commit and push, then wait for Argo CD to sync.

Use a new image tag for each code release. Manifest-only edits, such as resource
settings, replicas, and Ingress rules, need only a deployment-repository commit.
FastAPI keeps its app release version; PostgreSQL has its own image version in
`apps/myfastapiapp/postgres/postgres-statefulset.yaml`. Both are deployed
through the same Application.
See [image publishing](#make-the-app-image-available)
if a failed release skipped image publication.

## Back up and release a database change

1. Disable auto-sync in the live Application's Argo CD **App Details** and let
   any active sync finish. Select `staging-myfastapiapp`. The parent
   ApplicationSet preserves this live pause through `ignoreApplicationDifferences`.
2. During a quiet window, run the backup script and continue only if it succeeds:

   ```sh
   ./apps/myfastapiapp/postgres/backup.sh
   ```

   The script explicitly targets context `kind-argocd-postgres`, namespace
   `myfastapiapp`, and database `myfastapiapp`. It uses `pg_dump` and `pg_restore`
   inside the existing Postgres Pod, so local PostgreSQL tools are unnecessary.
   It writes a custom-format archive under
   `$HOME/.local/share/myfastapiapp/backups` with mode `600`, outside Git. It
   removes incomplete files if the dump or archive read check fails. The read
   check renders the full archive to `/dev/null` without connecting to a
   database; it does not test an actual restore. Verify recovery by restoring
   into a disposable database before relying on a backup. Keep writes paused
   through verification if recovery must preserve every write since the backup.
   See [pg_dump](https://www.postgresql.org/docs/17/app-pgdump.html) and
   [pg_restore](https://www.postgresql.org/docs/17/app-pgrestore.html).

   To select another kind cluster or destination:

   ```sh
   ./apps/myfastapiapp/postgres/backup.sh argocd-postgres /absolute/path/outside-the-repo/backups
   ```

3. Validate the app, review the diff, then commit and push the release image
   selection and any manifest changes together:

   ```sh
   ./scripts/validate.sh
   kubectl --context kind-argocd-postgres -n myfastapiapp \
     apply --dry-run=server -k apps/myfastapiapp
   git diff --check
   ```

4. Refresh Argo CD and run a full Application sync, with Force and Replace off.
   Resource-selective sync skips hooks. Sync waves apply storage at `-2`, wait
   for Postgres at `-1`, run the migration Job at `0`, and roll out FastAPI at `1`.
   The Job uses the app's database Secret and the new app image to run
   `python -m alembic upgrade head`. A failed migration blocks the app rollout.
   The latest Job and logs remain until the next sync replaces them. Hooks may
   run again on later syncs; Alembic skips already applied revisions.
   See [Argo CD sync phases and waves](https://argo-cd.readthedocs.io/en/latest/user-guide/sync-waves/).
5. Check the Job logs, revision, rollout, and health:

   ```sh
   kubectl --context kind-argocd-postgres -n myfastapiapp logs job/myfastapiapp-migrate
   kubectl --context kind-argocd-postgres -n myfastapiapp \
     rollout status deployment/myfastapiapp-deployment --timeout=180s
   kubectl --context kind-argocd-postgres -n myfastapiapp \
     exec deployment/myfastapiapp-deployment -- \
     python -m alembic current --check-heads
   curl -fsS http://myfastapiapp.localhost/health
   curl -fsS http://myfastapiapp.localhost/ready
   ```

   `current --check-heads` checks the database against the revisions bundled in
   the running release image and fails if any head is unapplied. Confirm Argo CD
   shows **Synced / Healthy**, test existing login and registration, then
   re-enable auto-sync in the UI.

If migration fails, inspect the Job logs before retrying. If migration succeeds
but the app rollout fails, the database has already changed. Check schema
compatibility before reverting the app image. Git rollback does not undo
migrations. Review each revision's downgrade operations for possible data loss.

The [database reset runbook](postgres/reset.md) records the
historical baseline replacement and its separate reset procedure.

## Recovery after a cluster rebuild

Replacing the Postgres Pod preserves its PVC and laptop data. Deleting the kind
cluster preserves the laptop directory, but removes Kubernetes objects and
Secrets. Recreate the cluster with the same storage mount and node label,
follow the shared [cluster setup](../../docs/setup.md), provision the same Secrets,
and make the selected image available before bootstrapping staging again. To adopt
the shared parent mount, follow the [storage upgrade](../../docs/repository-upgrade.md#shared-storage-at-the-next-rebuild)
so the existing data appears at `/mnt/myfastapiapp-postgres` in the new node.
The node uses label `staging.local/postgres-storage: "true"`, and the PV binds
to the PVC in namespace `myfastapiapp`.

Postgres reuses `pgdata`; `POSTGRES_PASSWORD` only initializes a new database.
Changing that Secret does not rotate an existing database role's password. Keep
the original password with your recovery information, or explicitly change the
role password inside Postgres. Keep the database major version pinned when
reusing its files.

Do not delete the PVC for a rollout. A retained PV can remain `Released` with the
old claim UID after PVC deletion and require deliberate recovery. PV/PVC retention
does not protect against deleting the laptop folder or disk failure. Back up
important data and verify an actual restore. Only one Postgres server may use a
data directory at a time. See [PV retention](https://kubernetes.io/docs/concepts/storage/persistent-volumes/#retain).
