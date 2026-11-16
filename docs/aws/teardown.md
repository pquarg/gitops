# Remove the AWS deployment deliberately

Choose retention and destructive scope before running commands. This procedure
is for reviewed operator work; it is not a validation test. The
[automated command](https://github.com/pquarg/infra/blob/main/environments/aws/dev/docs/teardown.md) deletes runtime, database
recovery data and access logs, retaining the backend unless `--delete-backend`
is selected. Use the manual sequence here to retain recovery copies or logs.

## 1. Inventory, freeze and choose retention

Freeze applies/state writes, finish app syncs/migrations and stop external writers.
Confirm account `245361883993`, profile `aws-project`, Region `eu-north-1`, explicit
EKS context and all three current state keys. Record Git
revisions, Helm status, Applications/finalizers/sync policies, EKS/RDS/ALB/origin/
distribution IDs, SG rules, log bucket and state VersionIds in a private ledger.
Take mode-600 state/Secret/configuration backups outside Git. Verify actual DB
backup restoration before relying on a recovery copy.

| Data | Default/manual retention choice |
| --- | --- |
| Database | Keep a uniquely named final snapshot and retained automated backups unless deliberate data deletion is chosen |
| Access logs | Keep the encrypted private bucket and its safeguards, or explicitly delete all objects/bucket |
| State backend | Keep the protected/versioned bucket and all stage keys; backend retirement is separate |

The database's current retention/protection defaults remain in source. The log
bucket's existing 14-day lifecycle still expires objects if you retain it;
archive required evidence privately before expiry. Retained copies can incur
charges. State contains secrets and does not replace database backups.

## 2. Prepare isolated stage configurations

Work in a private copy of the infrastructure directory layout, preserving
`environments/aws/dev/{foundation,platform,edge}`, environment controller
values/pins, functions, policies, locks, `shared/argocd/values.yaml` and ignored
`environments/aws/dev/config/operator.tfvars`.
Copy only required configuration, not cached `.terraform`, binary plans or old
state. Set `TEARDOWN_COPY` to that absolute private root. Initialize each copy
against its existing S3 key and save fresh `state pull` snapshots outside Git.
Do not invent new keys or overwrite live state with a backup. A missing key is
an absent stage, not drift to fix automatically.

Use the copied roots below. Keep the original safe source defaults unchanged.
Do not run a normal apply during partial teardown; plan/apply only each reviewed
phase, with locks and the same allowlist inputs.

## 3. Remove edge before the app ALB

If deleting logs, set only `force_destroy=true` in the private edge log bucket
configuration. Review a settings-only plan; reject unrelated changes. Do not
change expiry, encryption or public-access policy as part of teardown.

If retaining logs, privately record identities/import IDs for exactly the six
`aws_s3_bucket*.cloudfront_logs` resources (bucket, public-access block, ownership,
encryption, lifecycle and policy). Review `terraform state rm -dry-run ADDRESS`
against the edge copy, then forget only those six bindings, without deleting
the bucket or safeguards. Keep the configuration present while using `-destroy`;
never run a normal plan/apply in this partially detached root. This is an explicit
retention ownership transfer: record the new owner (private retained-resource
ledger) and re-import each resource before any later normal edge apply.

After choosing logs, review a full edge destroy plan while ALB/foundation/platform
still exist:

```sh
terraform -chdir="$TEARDOWN_COPY/environments/aws/dev/edge" plan -destroy \
  -var-file=../config/operator.tfvars -out=remove-edge.tfplan
terraform -chdir="$TEARDOWN_COPY/environments/aws/dev/edge" show remove-edge.tfplan
terraform -chdir="$TEARDOWN_COPY/environments/aws/dev/edge" apply remove-edge.tfplan
```

Require only intended edge deletions, no creates/replacements/updates and no
foundation/platform/ALB deletion. With retained logs the six forgotten resources
must not appear as deletions. Wait for distribution and VPC origin removal before
app cleanup; do not remove the frontend SG first. Verify using actual recorded IDs.

## 4. Pause GitOps and let the controller remove ALBs

Record/pause bootstrap and app reconciliation. Let active operations complete. Remove
app Gateways through a reviewed Git change and explicit full app sync/prune, or
pause both Argo CD reconcilers and remove their live Gateways deliberately. Do
not let a parent ApplicationSet/bootstrap recreate a removed Gateway. Inspect any
Application finalizers; do not cascade-delete the app/database by accident.

Keep `aws-load-balancer-controller` and its Pod Identity association/role/agent
running. Verify its rollout, delete the Gateway, then wait for Kubernetes
finalizers and AWS ALBs/target groups to disappear. Check target/network interfaces
and controller backend groups. Investigate unrelated references rather than
revoking arbitrary rules. Do not destroy platform while ALB cleanup is pending.

## 5. Remove platform

After confirming there are no controller-owned load balancers/targets left:

```sh
terraform -chdir="$TEARDOWN_COPY/environments/aws/dev/platform" plan -destroy -out=remove-platform.tfplan
terraform -chdir="$TEARDOWN_COPY/environments/aws/dev/platform" show remove-platform.tfplan
terraform -chdir="$TEARDOWN_COPY/environments/aws/dev/platform" apply remove-platform.tfplan
```

Only the controller, CRD and GatewayClass Helm releases should be deleted. The EKS API/workers and controller
AWS prerequisites remain until foundation is removed. Inspect failed Helm uninstalls
before continuing. Kubernetes registrations/Secrets disappear with the cluster;
keep original credentials in the private recovery set.

## 6. Choose database recovery flags, then remove foundation

In the private foundation copy, set `prevent_destroy=false` and
`deletion_protection=false`. To retain recovery, keep `skip_final_snapshot=false`,
choose a **new unique** `final_snapshot_identifier`, and keep
`delete_automated_backups=false`. To delete data deliberately, choose
`skip_final_snapshot=true` and `delete_automated_backups=true`; existing manual
snapshots/retained backups still need separately authorized deletion.

Review/apply a settings plan containing only those intentional DB flags/identifier
changes before destroying. Reject other resource drift, creation or replacement.
Then review the full foundation destroy:

```sh
terraform -chdir="$TEARDOWN_COPY/environments/aws/dev/foundation" plan -destroy \
  -var-file=../config/operator.tfvars -out=remove-foundation.tfplan
terraform -chdir="$TEARDOWN_COPY/environments/aws/dev/foundation" show remove-foundation.tfplan
terraform -chdir="$TEARDOWN_COPY/environments/aws/dev/foundation" apply remove-foundation.tfplan
```

Expect only foundation removals. It must not include CloudFront, Helm releases
or the state bucket. Verify EKS/RDS/VPC/NAT/EIPs/worker disks/log groups are gone,
and verify the chosen snapshots/backups/logs still exist (or were deliberately
removed). Record retained artifact IDs and how to restore them. All three stage
states must now contain no managed runtime resources; retained logs were explicitly
detached and recorded. Do not claim removal merely because Terraform exited zero.

## 7. Backend and recovery

Retain bootstrap/state by default. Only a separately authorized backend retirement
should delete its versions; use the [backend-last procedure](https://github.com/pquarg/infra/blob/main/environments/aws/dev/docs/teardown.md).
Never destroy the bucket while the Terraform executing deletion uses state in it.

Private configs/ledger/states remain until recovery/removal is verified. Restore
using fresh full stage plans in foundation → platform → app/healthy ALB → edge
order. Re-import retained log bindings before normal edge applies, after validating
provider IDs. A DB restore and its original app credentials require a deliberate
recovery procedure; a Git revert or blank new instance cannot restore data.
See [deploy from scratch](deploy-from-scratch.md) and the app runbook.

Follow [Gateway API routing and cutover](../gateway-api.md) for route status checks,
publication order, CRD prerequisites and recovery. Local controller support must
be applied before publishing HTTPRoutes. AWS app sync remains manual.
