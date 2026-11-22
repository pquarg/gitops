# Local Reaction Explorer release

Run from `gitops`, targeting `kind-deployment`. The React UI and read-only API
share http://reaction-explorer.localhost. This release is local only and uses a
locally built/loaded image. The existing ApplicationSet discovers it from published
`main` and syncs automatically. Complete preparation before publishing this overlay.

## Prepare

1. Follow [local platform setup](../../../../docs/local/setup.md). Provision the
   dedicated deployment warehouse and apply the reviewed Gateway namespace change
   using the infra [Reaction Explorer runbook](https://github.com/pquarg/infra/blob/main/environments/local/docs/reaction-explorer.md).
   Retain the existing cluster, development warehouse and other apps.
2. Set `REACTION_PRIVATE` to the absolute private directory containing the two
   deployment password files. Prepare schema/data from the app checkout with uv,
   Python 3.12 and the app's documented download prerequisites:

   ```sh
   python3 scripts/prepare-reaction-explorer-local.py --environment local --app-dir ../apps/reaction-explorer --password-file "$REACTION_PRIVATE/warehouse-password" --dashboard-password-file "$REACTION_PRIVATE/dashboard-password"
   ```

   This explicitly targets the deployment warehouse on localhost:5433, initializes
   missing source tables, verifies/downloads the pinned workbook, loads it, builds
   and tests dbt models, and checks 8,640 comparisons and original workbook rows.
   It never reads the development `.env`. Run only against this app's provisioned
   deployment database. Failed dbt builds can leave old models; stop on failure.
   For existing data, take a verified backup before schema/data changes. There
   is no automatic downgrade or schema reset. Review schema changes as releases.
3. Build the matched React/API image from app source, then load the exact tag:

   ```sh
   docker build --provenance=false -f ../apps/reaction-explorer/Dockerfile.web -t ghcr.io/pquarg/reaction-explorer-web:0.1.0-local.1 ../apps/reaction-explorer
   kind load docker-image ghcr.io/pquarg/reaction-explorer-web:0.1.0-local.1 --name deployment
   ```

   Build contexts exclude private credentials and downloaded data. This is a local
   loaded release, not a published GHCR package. Use a new tag for changed code.
   Replacement clusters need the image loaded again. Registry-based deployment
   requires image publication and a namespace-local imagePullSecrets reference.
4. Create the namespace and copy [app-secrets.example.yaml](app-secrets.example.yaml)
   to ignored `app-secrets.yaml`. Fill only `DASHBOARD_PASSWORD` using the existing
   deployment dashboard password. Never use the warehouse writer password.

   ```sh
   kubectl --context kind-deployment apply -f apps/reaction-explorer/base/namespace.yaml
   kubectl --context kind-deployment apply -f apps/reaction-explorer/overlays/local/app-secrets.yaml
   ```

   The temporary Job uses the selected image, ConfigMap and Secret to check the
   actual Pod database path, restricted login and modeled data. It removes only
   its probe Job. Apply the rendered ConfigMap before the probe (it is public):

   ```sh
   kubectl --context kind-deployment -n reaction-explorer apply -f apps/reaction-explorer/overlays/local/configmap.yaml
   python3 scripts/check-reaction-explorer-local.py --environment local --context kind-deployment
   ```

5. Validate and publish only once prerequisites pass:

   ```sh
   ./scripts/validate.sh --no-placeholders
   ./scripts/validate-server.sh reaction-explorer --environment local --context kind-deployment
   git diff --check
   ```

   Review, commit and push GitOps changes. If bootstrap is not registered yet,
   follow local setup. On an existing installation, discovery requires no new
   registration command. Filled Secrets stay outside Kustomize and Git.

## Verify

```sh
kubectl --context kind-deployment -n argocd get application reaction-explorer
kubectl --context kind-deployment -n reaction-explorer rollout status deployment/reaction-explorer --timeout=180s
python3 scripts/check-gateway.py --environment local --context kind-deployment --kubeconfig "$HOME/.kube/config" --namespace reaction-explorer --route reaction-explorer
curl -fsS http://reaction-explorer.localhost/api/health
curl -fsS http://reaction-explorer.localhost/api/snapshots
curl -fsS http://reaction-explorer.localhost/ > /dev/null
```

Confirm Application **Synced / Healthy** at the intended Git revision. Liveness
checks the process; readiness queries modeled snapshots with the read-only login.
An empty snapshot list is HTTP 200, so also require the successful data/Pod checks.
Open the browser, select MeCN then THF, check 1,344 comparisons and trace reactions
1 → 97 (worksheet rows 2 → 98, +29.024313 pp). Reverse the selection and confirm
negated differences and swapped source records. Refresh a shared URL and verify
UI assets load. Check demo-api and job-tracker routes after the platform apply.
Schema validation alone does not establish deployment health.

## Releases and recovery

Back up before schema/model changes, pause this app's auto-sync/traffic, and stop
any deployment pipeline writers. Re-run explicit preparation and acceptance checks
before publishing a compatible web tag. The web image needs no migrations during
sync and has only the read-only password. A web rollback changes the image tag;
it does not reverse source/model changes. Keep schema and image compatibility.

Use infra's independent backup/restore procedure. After kind replacement preserve
the existing external PostgreSQL volume, reload the image, recreate namespace,
ConfigMap and private Secret, run the Pod probe, then resume GitOps. After changing
the Secret, restart `deployment/reaction-explorer` explicitly and repeat checks.
A Secret edit alone does not rotate a PostgreSQL password. Keep both deployment
password files and backups private; Git contains source configuration only.
