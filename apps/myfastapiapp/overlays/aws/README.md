# myfastapiapp on AWS

Run commands from the deployment repository root with an explicit `EKS_CONTEXT`.
Application code, Dockerfile and Alembic revisions live in the separate
`myfastapiapp` repository.

| Setting | Value |
| --- | --- |
| Namespace | `myfastapiapp` |
| Argo CD Application | `aws-myfastapiapp` |
| Initial image | `ghcr.io/pquarg/myfastapiapp:0.1.12` |
| Database | Private RDS PostgreSQL, provisioned through `infra-aws` |
| Public URL | Read `myfastapiapp_https` from `infra-aws/terraform/edge` after edge provisioning |
| Origin | Internal ALB `deployment-project-dev-app`, HTTP port 80 |

The app has one replica initially. This is a starting deployment, not a configured
high-availability service. Increase capacity and test disruption behavior when
availability requirements are known.

## Provision credentials

For this project's existing Terraform-managed RDS instance, initialize the fresh
database from the deployment repository root:

```sh
python3 scripts/bootstrap-database.py aws-deployment-project --profile aws-project
```

The helper verifies the AWS project and Kubernetes context, creates this namespace
and `myfastapiapp-secrets`, and runs a temporary PostgreSQL 17 client inside EKS.
It reads the administrator password locally through AWS CLI and sends it over
the Kubernetes exec input stream. It never saves the administrator password to
a local file, command argument, or Kubernetes Secret. The app password is generated
locally and stored only in the application's Kubernetes connection Secret.

The helper creates the `myfastapiapp` database login, grants database `CONNECT`
and `USAGE, CREATE` on the `public` schema for Alembic, and verifies that the login
has no elevated role attributes or inherited role memberships. It connects with
`sslmode=verify-full` and the committed RDS CA bundle. Its create/alter/index/insert/
drop probe runs inside a transaction that is rolled back; actual Alembic migrations
remain part of the first Argo CD sync.

The temporary Pod and public CA ConfigMap are removed on exit. The app Secret is
retained on failure so retries reuse its password. Do not delete that Secret to
retry, and do not use this helper as a password rotation procedure. It refuses an
existing connection Secret for a different endpoint or without verified TLS.
The helper requires AWS CLI, kubectl, Python 3 and a current AWS login. No local
PostgreSQL client or Python packages are needed. A successful run prints
`BOOTSTRAP_OK` with the application login, database and negotiated TLS version.

After using the helper, skip the manual connection-Secret steps below and continue
with the [GHCR pull Secret](../../../../docs/aws/credentials.md).

If the app login has instead been provisioned separately, use these manual steps.
Create the namespace, then prepare the ignored Secret file:

```sh
kubectl --context "$EKS_CONTEXT" create namespace myfastapiapp \
  --dry-run=client -o yaml | kubectl --context "$EKS_CONTEXT" apply -f -
cp -n apps/myfastapiapp/overlays/aws/app-secrets.example.yaml apps/myfastapiapp/overlays/aws/app-secrets.yaml
chmod 600 apps/myfastapiapp/overlays/aws/app-secrets.yaml
git check-ignore apps/myfastapiapp/overlays/aws/app-secrets.yaml
```

Set `AUTH_DATABASE_URL` in that local file using the app login provided for RDS:

```text
postgresql://myfastapiapp:ENCODED_PASSWORD@RDS_ENDPOINT:5432/myfastapiapp?sslmode=verify-full
```

Replace the endpoint, password, database and role as needed. URL-encode special
characters in the password. Do not paste credentials into Git, shell history or
issue comments. The API and migration Job both use this same Kubernetes Secret.

Both workloads set `PGSSLMODE=verify-full` and
`PGSSLROOTCERT=/etc/rds-ca/global-bundle.pem`. Kustomize generates their public CA
ConfigMap from `certs/global-bundle.pem`. Keep certificate verification enabled;
check the RDS endpoint and CA bundle if verification fails.

```sh
kubectl --context "$EKS_CONTEXT" -n myfastapiapp apply \
  -f apps/myfastapiapp/overlays/aws/app-secrets.yaml
```

Provision `registry-credentials` in the same namespace using the
[GHCR instructions](../../../../docs/aws/credentials.md). The existing image remains in
GHCR. ECR can be introduced later along with image publishing and EKS pull access;
changing the image name alone does not migrate the image.

## First deployment

Complete [cluster setup](../../../../docs/aws/setup.md) and ensure the RDS database and app
role already exist. This learning deployment starts with a fresh database;
these manifests do not copy local data.

Verify the frontend group configured in `ingress.yaml` matches
`terraform -chdir=../infra-aws/terraform/foundation output myfastapiapp_alb_security_group`. The manifest
uses internal ALB `deployment-project-dev-app`, HTTP port 80, IP targets and
controller-managed backend rules. The host-independent rule accepts the eventual
CloudFront viewer hostname. HTTPS will terminate at CloudFront; there is no
public ALB listener, custom domain or ACM requirement for this initial setup.

```sh
./scripts/validate.sh --environment aws --ready
./scripts/validate-server.sh myfastapiapp --environment aws --context "$EKS_CONTEXT"
```

Publish the checked configuration to `main` and bootstrap the root Application.
In Argo CD, review and sync the **entire** `aws-myfastapiapp` Application. A selective
resource sync skips hooks and must not be used for an app release.

Sync order is:

1. ConfigMaps and Service are applied in wave `0`; the wave `0` migration hook
   runs `python -m alembic upgrade head` against RDS.
2. The API Deployment rolls out in wave `1` after migration success.
3. The ALB Ingress is applied in wave `2` after the Deployment is healthy.

A failed migration blocks the rollout. Inspect its logs and resolve the cause
before retrying a sync. Do not bypass the hook to force a Deployment rollout.
Migrations on later releases run while old Pods may still serve traffic, so schema
changes must remain compatible with the running app or use a planned maintenance window.

## Verify

```sh
kubectl --context "$EKS_CONTEXT" -n argocd get application aws-myfastapiapp
kubectl --context "$EKS_CONTEXT" -n myfastapiapp \
  rollout status deployment/myfastapiapp-deployment --timeout=300s
kubectl --context "$EKS_CONTEXT" -n myfastapiapp get pods,jobs,ingress
kubectl --context "$EKS_CONTEXT" -n myfastapiapp \
  logs job/myfastapiapp-migrate
kubectl --context "$EKS_CONTEXT" -n myfastapiapp get ingress myfastapiapp-ingress \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'
```

The returned hostname is private. Use it and the deterministic ALB name for the
later CloudFront VPC-origin lookup through `infra-aws`; do not use it as a public
app URL. First verify the migration succeeded and the ALB targets are healthy.

For a local check before CloudFront is provisioned, run this in another terminal:

```sh
kubectl --context "$EKS_CONTEXT" -n myfastapiapp \
  port-forward service/myfastapiapp-service 8000:80
```

Then check `http://localhost:8000/health` and `http://localhost:8000/ready`.
This checks the app through a local port forward; it does not test ALB routing.

Follow the [public access sequence](../../../../docs/aws/public-access.md) to create
CloudFront after the internal ALB is Active with healthy targets. Then set the
assigned CloudFront hostname and test:

```sh
APP_URL="$(terraform -chdir=../infra-aws/terraform/edge output -json myfastapiapp_https |
  python3 -c 'import json, sys; print(json.load(sys.stdin)["url"])')"
curl -fsS "$APP_URL/health"
curl -fsS "$APP_URL/ready"
```

Open `$APP_URL/api/v1/docs/` in a browser, register a test account and log in.
A rebuild may assign a different address. Confirm authorization, logout, generated links and
canonical/slash redirects remain correct over HTTPS. Verify the distribution's HTTPS-only viewer
policy rejects public HTTP. The origin ALB sees HTTP; proxy-scheme handling must
be checked before making the public endpoint available to others.

The repeatable public check uses Python 3 only:

```sh
python3 scripts/check-public-endpoint.py "$APP_URL"
```

Add `--auth` to create one synthetic account and test registration/login/logout
and revoked-token rejection. The test session is revoked; the account remains,
and its generated password is discarded. Passwords and tokens are not printed.
Check Argo CD reports **Synced / Healthy** for the app. `/health` checks the API;
`/ready` checks database connectivity and is also used by the ALB.

## Releases

Publish a new immutable image tag from the app repository, then edit only
`images[].newTag` in `kustomization.yaml`. Kustomize applies it to both the API
and migration Job. Run validation, review, commit and push, then review and manually
sync the entire Application. Verify the rollout, HTTPS and authentication again.

Before a database change, take an RDS snapshot or follow the chosen backup policy
and confirm the restore procedure is understood. Use maintenance windows for
incompatible migrations. Git rollback does not undo a database migration; app
rollback is safe only when the previous image supports the current schema.

Do not enable app auto-sync until the database release and recovery process is
ready. The ApplicationSet preserves live changes to `spec.syncPolicy.automated`
so an operator can enable or pause it deliberately.

## Credential and CA changes

Rotate the actual RDS role password and Kubernetes Secret together. Changing the
Secret does not change the database role's password. Secret environment variables
do not update in running Pods; after applying the updated Secret, restart the API:

```sh
kubectl --context "$EKS_CONTEXT" -n myfastapiapp \
  rollout restart deployment/myfastapiapp-deployment
kubectl --context "$EKS_CONTEXT" -n myfastapiapp \
  rollout status deployment/myfastapiapp-deployment --timeout=300s
```

The next migration Job uses the new Secret. Keep image-pull credentials current
as described in the shared credential runbook.

For an AWS CA update, follow [certificate bundle maintenance](certs/README.md).
The generated ConfigMap's content hash updates both workload references and
causes the Deployment to roll out on the next full sync.

## Recovery

Keep app auto-sync paused during recovery if it was enabled. Restore an RDS
snapshot to a separate instance through `infra-aws`/the chosen recovery process,
verify recovered data and schema compatibility, then update the app's Secret to
the restored private endpoint. Restart or sync the app deliberately and verify it
before retiring the previous database. Restores and local-to-AWS data transfers
need a write cutover plan if every record must be preserved.

After an EKS rebuild, recreate Git access and the app's namespace and Secrets,
bootstrap Argo CD, and sync the app against the retained RDS database. Do not run
local database reset scripts against AWS. Test recovery into a disposable
environment before relying on a backup.
