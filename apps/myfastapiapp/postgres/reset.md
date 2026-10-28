# Reset the myfastapiapp staging database

This procedure deletes application data in the staging cluster. For ordinary
schema changes, use the [backup and release workflow](../README.md#back-up-and-release-a-database-change)
and add new Alembic revisions.

## Historical baseline reset

App release `0.1.10` replaced the development migration history with a new
`001_initial` revision. Databases created under the earlier history require a
reset before using the replacement history, including databases previously
marked `001_initial`. Matching that revision name does not establish schema
compatibility. This records a historical change, not the current release or head.

The reset removes accounts, login sessions, and revision tracking. It is needed
only when deliberately recreating disposable development data, including the
older incompatible baseline. Later schema changes normally use new revisions.

For the local Compose database, stop the local API and run these commands from
the app repository, with `AUTH_DATABASE_URL` targeting the Compose database:

```sh
docker compose down --volumes
docker compose up -d --wait postgres
uv run --locked alembic upgrade head
uv run --locked alembic current --check-heads
```

This deletes the Compose database volume. Kubernetes storage is independent;
the remaining steps apply to the Kubernetes database.

## Reset the Kubernetes database

Run deployment commands from this deployment repository. The target is context
`kind-argocd-postgres`, namespace `default`, database `myfastapiapp`, and Argo CD
Application `myfastapiapp-postgres-application`.

PostgreSQL has a retained PV/PVC backed by a laptop directory. Recreating its
Pod, PVC, or kind cluster does not clear that directory. The reset below replaces
the app's `public` schema while preserving PostgreSQL storage, its role, and
Secrets.

1. Make the intended app image available using the
   [image preparation instructions](../README.md#make-the-app-image-available).
   Use the release selected in `apps/myfastapiapp/kustomization.yaml`; its image
   tag applies to both the API Deployment and migration Job. No historical
   release tag needs to be copied from this runbook.

2. Disable auto-sync on the live Application and let any active sync finish:

   ```sh
   kubectl --context kind-argocd-postgres -n argocd patch application \
     myfastapiapp-postgres-application --type merge \
     -p '{"spec":{"syncPolicy":{"automated":{"enabled":false}}}}'
   ```

   The root registration controller preserves the live pause. Applying
   `argocd/myfastapiapp.yaml` directly enables auto-sync again. Commit and push
   any release-image selection change while auto-sync remains disabled.

3. Stop the API and wait for its Pods to disappear:

   ```sh
   kubectl --context kind-argocd-postgres -n default scale \
     deployment/myfastapiapp-deployment --replicas=0
   kubectl --context kind-argocd-postgres -n default wait \
     --for=delete pod -l app=myfastapiapp-pod --timeout=120s
   ```

4. Recreate the app's `public` schema. This deletes all objects and data in that
   schema, including accounts, sessions, and migration version tables:

   ```sh
   kubectl --context kind-argocd-postgres -n default exec \
     myfastapiapp-postgres-statefulset-0 -c postgres -- \
     psql -X -v ON_ERROR_STOP=1 --single-transaction \
     -U myfastapiapp -d myfastapiapp \
     -c 'DROP SCHEMA public CASCADE; CREATE SCHEMA public AUTHORIZATION myfastapiapp;'
   ```

5. Refresh Argo CD and run a full Application sync of the deployment commit,
   with Force and Replace off. Resource-selective sync skips hooks. The existing
   migration Job applies the selected image's revisions to the empty schema;
   its completion allows the API to return to the replica count declared in Git.

6. Verify migration completion, rollout, and database revision:

   ```sh
   kubectl --context kind-argocd-postgres -n default logs job/myfastapiapp-migrate
   kubectl --context kind-argocd-postgres -n default rollout status \
     deployment/myfastapiapp-deployment --timeout=180s
   kubectl --context kind-argocd-postgres -n default exec \
     deployment/myfastapiapp-deployment -- \
     python -m alembic current --check-heads
   curl -fsS http://myfastapiapp.localhost/health
   curl -fsS http://myfastapiapp.localhost/ready
   ```

   The revision check uses the running image's migration heads. Confirm Argo CD
   shows **Synced / Healthy** and register a new account; old accounts and tokens
   were deleted by the reset.

7. Re-enable automatic sync after verification:

   ```sh
   kubectl --context kind-argocd-postgres -n argocd patch application \
     myfastapiapp-postgres-application --type merge \
     -p '{"spec":{"syncPolicy":{"automated":{"enabled":true}}}}'
   ```

Keep reset SQL out of migration Jobs and revision scripts so later syncs preserve
data. Use the app image's Alembic commands to discover revisions; update this
runbook when the deployment or reset procedure changes.
