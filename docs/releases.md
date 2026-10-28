# Release myfastapiapp

Run these commands from the deployment repository root. This runbook targets the
existing app in namespace `default`; new apps use their own namespaces. See
[adding apps](adding-apps.md) for the registration convention.

1. Build and publish a new image from the app repository, or build and load it
   into `argocd-postgres` for local use. Keep the app version and lockfile in sync.
2. Update `images[].newTag` in
   `apps/myfastapiapp/kustomization.yaml`. This selects the same
   release for the API and migration Job. This is the only deployment image
   version to edit; the base manifests contain no release tags.
3. For a database change, follow the backup and controlled sync steps below
   before pushing. For other changes, commit and push, then wait for Argo CD to sync.

Use a new image tag for each code release. Manifest-only edits, such as resource
settings, replicas, and Ingress rules, need only a deployment-repository commit.
FastAPI keeps its app release version; PostgreSQL has its own image version in
`apps/myfastapiapp/postgres/postgres-statefulset.yaml`. Both are deployed
through the same Application.
See [image publishing](postgres-kind.md#4-make-the-app-image-available)
if a failed release skipped image publication.

## Back up and release a database change

1. Disable auto-sync in the live Application's Argo CD **App Details** and let
   any active sync finish. Select `myfastapiapp-postgres-application`. The parent
   registration controller preserves this live pause. Applying
   `argocd/myfastapiapp.yaml` directly enables auto-sync again; use the root
   bootstrap registration for routine setup.
2. During a quiet window, run the backup script and continue only if it succeeds:

   ```sh
   ./scripts/backup-postgres.sh
   ```

   The script explicitly targets context `kind-argocd-postgres`, namespace
   `default`, and database `myfastapiapp`. It uses `pg_dump` and `pg_restore`
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
   ./scripts/backup-postgres.sh argocd-postgres /absolute/path/outside-the-repo/backups
   ```

3. Validate the overlay, review the diff, then commit and push the release image
   selection and any manifest changes together:

   ```sh
   ./scripts/validate.sh
   kubectl --context kind-argocd-postgres -n default \
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
   kubectl --context kind-argocd-postgres -n default logs job/myfastapiapp-migrate
   kubectl --context kind-argocd-postgres -n default \
     rollout status deployment/myfastapiapp-deployment --timeout=180s
   kubectl --context kind-argocd-postgres -n default \
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

The [development database reset runbook](database-reset.md) records the
historical baseline replacement and its separate reset procedure.
