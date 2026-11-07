# Move the local database out of Kubernetes

This is an operator-run cutover, not part of an app sync. Keep the existing
kind cluster, mounted data directory, PV/PVC, original Secrets and backups.
The new Compose instance uses a separate empty Docker volume. No storage removal,
database reset or cluster rebuild is needed. Run GitOps commands from `gitops`;
run the explicitly marked Compose commands from `infra-local`.

Fresh installations skip this page and follow [setup](setup.md). Before publishing
this overlay change to a remote used by an existing cluster, pause that app's
automatic sync. Other apps and AWS keep their existing policies and configuration.

Examples use `deployment` / `kind-deployment`. For an older `argocd-postgres`
cluster, use [existing-cluster selection](../../../infra-local/README.md#existing-clusters)
and substitute its actual name/context in every command. This cutover does not
rename or rebuild the cluster.

## 1. Pause and back up

Confirm the target explicitly:

```sh
kubectl --context kind-deployment get nodes
kubectl --context kind-deployment -n argocd patch application staging-myfastapiapp \
  --type merge -p '{"spec":{"syncPolicy":{"automated":{"enabled":false}}}}'
```

The ApplicationSet preserves this live pause. Wait until any active app sync and
migration Job finishes. Stop inbound traffic and every writer, including local
development processes. Then:

```sh
kubectl --context kind-deployment -n myfastapiapp scale deployment/myfastapiapp-deployment --replicas=0
kubectl --context kind-deployment -n myfastapiapp wait --for=delete pod -l app=myfastapiapp-pod --timeout=120s
./apps/myfastapiapp/overlays/local/postgres/backup.sh deployment
```

Record the resulting archive path. Privately preserve the original connection
Secret, database credentials and host data path outside Git. The backup script
checks archive readability; the actual restore test happens next. Keep writers
paused from this final backup until verification and cutover finish.

## 2. Prepare and test the separate database

From `infra-local`, follow [first setup](../../../infra-local/docs/database.md#first-setup),
using new separate admin/app passwords and the new external volume. Do not mount
the Kubernetes data directory into Compose. Then use the archive path from step 1:

```sh
./scripts/local-database.sh verify-backup /absolute/path/to/legacy-backup.dump
./scripts/local-database.sh restore /absolute/path/to/legacy-backup.dump
```

Both commands must succeed. Restore omits old ownership/ACLs, so the restricted
app login owns restored tables, sequences and Alembic history. Do not run
migrations before restoring the archive into the empty database.

## 3. Switch the connection and stop the old server

From `gitops`, update the ignored app Secret's `AUTH_DATABASE_URL` to:

```text
postgresql://myfastapiapp:ENCODED_APP_PASSWORD@host.docker.internal:5433/myfastapiapp?sslmode=disable
```

Use the Compose app password, URL-encoded, and the configured published port.
Apply and probe it with the selected release image:

```sh
kubectl --context kind-deployment -n myfastapiapp apply -f apps/myfastapiapp/overlays/local/app-secrets.yaml
./scripts/check-local-database.py --environment local --context kind-deployment
kubectl --context kind-deployment -n myfastapiapp scale statefulset/myfastapiapp-postgres-statefulset --replicas=0
kubectl --context kind-deployment -n myfastapiapp wait --for=delete pod -l app=myfastapiapp-postgres-pod --timeout=180s
```

The connectivity check performs and rolls back a small DDL/data transaction. It
does not migrate the schema. A failure here means keep auto-sync and traffic
paused and resolve DNS, port, credentials or permissions before proceeding.

## 4. Publish, sync and verify

Validate both environments with `./scripts/validate.sh --ready`, review the diff,
then commit and publish the GitOps changes. Refresh Argo CD and sync the entire
`staging-myfastapiapp` Application, with **Prune, Force and Replace off**. The new
overlay excludes the old PostgreSQL resources. Automated pruning remains disabled;
the stopped legacy StatefulSet, Service and retained PV/PVC stay available for
recovery. Argo CD may report the app OutOfSync because those resources remain;
do not enable pruning to clear that status.

Check migration logs, the current revision, rollout, `/health`, `/ready` and
existing account login using the [app verification](../../apps/myfastapiapp/overlays/local/README.md#verify-the-deployment).
Compare expected records before resuming traffic. Once verified, re-enable app
auto-sync with the same patch as step 1 using `"enabled":true`.

Retirement of the legacy resources/data is a separate, explicitly authorized
cleanup. Until then leave the StatefulSet at zero replicas and keep pruning off.
Never sync the legacy `postgres/` Kustomization back into a migrated app. Do not
reuse the old `--delete-database` teardown option to reset Compose data: it only
targets the old laptop directory.

## Recovery if cutover fails

Keep writers and auto-sync paused. If no new schema or data changes have happened
since the final backup, restore the original connection Secret and select the
previous GitOps revision containing `./postgres` before restarting the old
StatefulSet and syncing the previous app release. Keep Prune/Force/Replace off.
Verify database compatibility, old records and login before traffic and auto-sync.
The original data directory and credentials remain unchanged.

If Compose has received writes or migrations, the old database is stale. Preserve
both copies and take a new backup before choosing recovery; simply switching
endpoints would lose those writes. Git rollback does not reverse migrations.
