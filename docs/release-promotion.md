# Promote a Demo API release

| Target | GitOps branch | App sync |
| --- | --- | --- |
| Local kind | `dev` by default, or a selected `feat/*` | Automatic |
| AWS staging | `dev` | Manual |
| AWS production | `main` | Manual |

The image comes from the Demo API repository. GitOps selects its digest and
defines the migration Job and workload. Terraform platform changes use a
reviewed plan from the infrastructure checkout and the explicit target.

## Introduce the branches

1. Publish the implementation to GitOps `dev` first. Use the same published
   source when setting up the initial `main` promotion PR. Enable branch
   protection or rulesets on both GitOps branches. Require PRs and the
   **Validate deployment configuration / validate** check and block direct and
   force pushes. Require approval for `main` where a second reviewer is available.
   Protect Demo API's `dev` and `main` and require its app checks before merge.
2. Publish the application CI change and create the Demo API `dev` branch.
   Image publication is restricted to trusted branches; fork PRs only build.
3. Check out the published tip of GitOps `dev`. For each existing cluster,
   confirm no migrations are running and review its current app revision.
   Reapply the existing bootstrap using the [local](local/setup.md#4-validate-publish-and-register-apps)
   or [staging](aws/setup.md#4-validate-publish-and-bootstrap) guide. This updates
   the existing registration in place. Verify the bootstrap, ApplicationSet,
   and generated applications all select `dev` before syncing an AWS app.

## Test a feature in kind

Use a dedicated local deployment branch such as `feat/my-change-local`. Put
the manifest changes and candidate image on that branch. The branch name can
differ from the application branch. Demo API Actions records the published
digest in its job summary. Set the local Demo API image's `digest` in
`apps/demo-api/overlays/local/kustomization.yaml` and remove its `newTag` when
selecting a digest.

```sh
git switch -c feat/my-change-local dev
python3 scripts/select-local-ref.py feat/my-change-local
./scripts/validate.sh --environment local --no-placeholders
# Commit and push the deployment branch, then register its published tip.
./scripts/bootstrap.sh --environment local --context kind-deployment
```

Check the app's source revision, sync health, migration result and HTTP response.
Use a disposable database or schema for incompatible migrations. Keep the
local registration edits on the deployment branch; merge the application and
portable manifest changes separately through the normal PRs into `dev`.

When finished, check out the current published GitOps `dev` tip and rerun the
local bootstrap. Verify the generated Applications return to `dev` and their
workloads become healthy. Reverting the deployment does not reverse migrations.

## Verify staging and promote

1. Select the candidate digest in the AWS staging kustomization on `dev`.
   Remove `newTag` when changing to `digest`. Review the full Argo CD diff and
   manually sync the app at the reviewed commit. Verify the migration, app
   health, and HTTPS endpoint using the [staging runbook](aws/setup.md#5-sync-and-verify-the-app).
2. Record the staging GitOps commit, app source commit, digest, and verification
   results. Update the production kustomization on `dev` with the same digest.
   Confirm no shared app inputs changed after the staging run. Re-test if the
   candidate's shared manifests, migration image or configuration have changed.
3. Open a PR from the repository's `dev` into `main` and fill in the production
   promotion section. Compare the rendered production manifests against the
   current `main` and review the environment-specific differences. CI requires
   the production image digest to match the staging overlay in the candidate.
   Merge once the staging evidence applies to the release under review.
4. Sync production at the reviewed `main` commit using the
   [production runbook](production/setup.md). Record migration, readiness,
   routing and HTTPS results with the deployed revision.

For rollback, restore the previously approved image digest and manifest changes
through Git. Verify that the current schema supports the prior app before
syncing. For incompatible migrations, follow the reviewed forward-fix or
database recovery procedure and verify restored data before redirecting traffic.
