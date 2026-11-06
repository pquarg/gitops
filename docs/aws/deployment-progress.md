# AWS deployment progress and session handoff

> Historical deployment evidence: repository names, source paths and commands below
> describe their recorded dates. Use [GitOps](../../README.md), [current setup](setup.md)
> and [repository cutover](../repository-migration.md) for the current layout.

Historical record of earlier deployments and the monolithic Terraform layout.
Do not execute historical plan/target/state commands below. The configuration
was split on 2026-11-06; this record does not prove the staged live migration has
happened. Use [current setup](setup.md), [deployment](deploy-from-scratch.md) and
[state migration](../../../infra-aws/docs/state-migration.md) for current commands.

Last updated: **2026-11-01**. The current task is to rebuild the deleted learning
environment and continue deployment. The latest verified state and next actions
are below; October 31 provisioning details are historical. Recheck live state
before applying a saved plan; this document is a snapshot, not a replacement for
Terraform state.

## Latest user instructions

- **Operator-IP access requested, 2026-11-01.** Restrict all public app endpoints
  to the same IPv4 allowlist already used for EKS administration. The new
  CloudFront viewer-request function and IPv6 disablement are prepared and
  validated; the fresh saved plan is `infra-aws/app-ip-allowlist.tfplan`, with
  **1 addition, 1 in-place change, 0 deletions**. All 12 function tests pass.
  The user-run apply and allowed/denied network checks are pending. The live
  app remains public until deployment completes. See
  [the IP-access batch](public-access.md#verify-https-authentication-restrictions-and-logging).
- **Rebuild requested, 2026-11-01.** The user asked to spin the environment back
  up and continue deployment. This supersedes the previous instruction to leave
  infrastructure deleted. The prior teardown destroyed **67 resources** without
  database backups; rebuild with a fresh database.
- Work in **medium-guidance batches**: explain a group of steps, give commands,
  let the user execute them, and wait for their results before the next batch.
  Read-only verification and preparing/validating files have been done by the agent.
- Use Terraform for reproducibility. The user prefers explicit AWS profile/Region
  flags and provider configuration rather than shell environment variables.
- Use a **fresh database**. Existing local records do not need transferring.
- The user **does not own a domain** and wants an AWS-provided address initially,
  with the option of adding a custom domain later.
- Infrastructure, app sync, public HTTPS, authentication and log verification
  have succeeded. The final step is saving the remaining Terraform, helper and
  runbook changes in both repositories' Git history/remotes.

## Resume here

### Current checkpoint, 2026-11-01

The user has successfully run the database bootstrap against the rebuilt EKS/RDS
environment and verified a GHCR image pull. Reported output confirms:

- Correct AWS project, EKS context and an available private RDS instance.
- Application connection Secret ready; restricted database login and schema grants
  initialized. `BOOTSTRAP_OK login=myfastapiapp database=myfastapiapp tls=TLSv1.3`.
- Schema create/alter/index/insert/drop probe passed and was rolled back.
- `registry-credentials` configured in namespace `myfastapiapp`.
- The image-pull check Pod succeeded with `GHCR image pull OK`, then was deleted.
- A dedicated deploy key was added to GitHub. The user connected
  `git@github.com:pquarg/deploy-aws.git` in Argo CD and reported **Successful**.
  The local private key is `~/.ssh/argocd-deploy-aws`; no key value or PAT was
  provided to the agent.
- Manifests and credential helpers were committed/published as
  `091b797952eaab5e1b9623867548de072c9a1b76`. Bootstrap passed readiness checks
  and registered `aws-root` and generated `aws-myfastapiapp`.
- The user completed the first full app sync. Both `aws-root` and
  `aws-myfastapiapp` are now **Synced/Healthy**, with app auto-sync still off.
- Alembic revision `001_initial` ran successfully. The migration Job is Complete
  (1/1); the API Pod is 1/1 Ready, Running, with zero restarts.
- The controller-created internal ALB is **Active**, with a **Healthy** target
  at pod port 8000 and health check `/ready`. Public HTTPS is now deployed.

Read-only verification now confirms both workers `Ready`, all kube-system Pods
running, all six Argo CD Deployments available, the load balancer controller
2/2 Ready, and IngressClass `alb` using `ingress.k8s.aws/alb`. Argo CD now has
the root and generated app Applications. RDS is `available`, private and encrypted, with deletion
protection enabled, one-day backups and its parameter group `in-sync`.

A full Terraform check reported **No changes** before the next configuration
was added. The foundation and six-resource platform plans are consumed/stale.

**ALB security-group batch applied:** the user shared output
`sg-0e84da2f851551dff`, name `deployment-project-dev-myfastapiapp-alb`. AWS confirms
the group exists in `vpc-006a5246db7b228cf`, with TCP 80 inbound only from the
CloudFront managed prefix list and TCP 8000 outbound to worker group
`sg-0835b138e908bfb3c`. Its three-resource saved plan is now consumed/stale.

**Internal Ingress deployed:** `apps/myfastapiapp/ingress.yaml` uses that
frontend group, controller-managed backend rules, internal IPv4 ALB
`deployment-project-dev-app`, HTTP port 80, IP targets and `/ready` checks. The
custom-hostname and ACM placeholders are removed. Supporting runbooks have been
updated. Validation passed: **8 resources valid, zero invalid/errors/skipped**
with kubeconform v0.8.0, and the server dry-run accepted all app resources and
the generated migration hook without persisting resources or running migrations.
Publishing, bootstrap and first full app sync are complete. The ALB ARN is
`arn:aws:elasticloadbalancing:eu-north-1:245361883993:loadbalancer/app/deployment-project-dev-app/9cefc8117d894848`;
its private hostname is
`internal-deployment-project-dev-app-89376549.eu-north-1.elb.amazonaws.com`.
It uses the expected private subnets, frontend group `sg-0e84da2f851551dff` and
controller backend group `sg-049751e585bbba67a`.

**VPC origin applied and verified:** the user shared ID
`vo_3SwvkrNaK1HC94CRt9XyJ9`; AWS `GetVpcOrigin` confirms **Deployed** and the
expected ALB ARN, private HTTP port 80 and HTTP-only origin protocol. The
one-resource origin plan is consumed/stale.

**Distribution/logging batch applied:** `infra-aws/terraform/edge/cloudfront.tf`,
`infra-aws/terraform/edge/cloudfront-logs.tf`, `infra-aws/functions/https-redirects.js` and its five
Node tests define the public distribution, security/no-store headers,
same-host HTTPS redirects and private encrypted S3 standard logging v2. Terraform
validation and all five tests passed. The full saved plan at
`/tmp/deployment-project-cloudfront-distribution-20261101.tfplan` was reviewed:
**12 additions, zero changes, zero deletions**. The user applied it and shared:

- Distribution **`E318GC97RVXQ86`**, confirmed **Deployed** by AWS.
- Base URL: **https://d1dgp19b9ypb8r.cloudfront.net**.
- Swagger: **https://d1dgp19b9ypb8r.cloudfront.net/api/v1/docs/**.
- Log bucket: `deployment-project-cf-logs-245361883993-eu-north-1`.
- V2 delivery: `HYzdS5Fk2Zs6wohw`, via `us-east-1` Logs APIs to Stockholm S3.

The full post-apply Terraform plan reports **No changes**. All earlier saved
plans, including the 12-resource distribution plan, are consumed/stale.

The distribution uses the default AWS hostname/certificate, HTTPS-only viewers,
managed CachingDisabled/AllViewer policies, all API methods, and zero supported
error-cache TTLs. Logs use a separate private AES256 S3 bucket in Stockholm with
14-day retention; query strings, cookies, authentication data and viewer IPs
are excluded. CloudWatch delivery configuration uses `us-east-1` as required for
global CloudFront logging. No WAF subscription/rules or paid CDN pricing plan
is added by this learning batch.

**Read-only public verification passed**, using
`python3 scripts/check-public-endpoint.py https://d1dgp19b9ypb8r.cloudfront.net`:
health/readiness return OK, Swagger HTML/OpenAPI load, the slash redirect
preserves HTTPS/host/query, public HTTP is rejected with 403, expected CSP/HSTS/
nosniff/frame/referrer headers are present, and responses have `no-store` with
no cache hits. Unauthenticated `/api/v1/auth/me` returns 401.

**User-run authentication check passed:**

```sh
python3 scripts/check-public-endpoint.py https://d1dgp19b9ypb8r.cloudfront.net --auth
```

This explicitly creates one synthetic test account, checks registration,
login, authenticated/unauthenticated identity, logout and revoked-token
rejection, and revokes the test session. Password/token stay in memory and
are not printed. The user reported `PUBLIC_OK` and
`AUTH_OK account=deploy_check_77ad069738`, confirming registration, login,
identity, logout, revoked-token rejection and no-store behavior. The synthetic
account remains; its test session was revoked and password discarded.

**Access-log receipt verified:** a nonempty gzip log object for distribution
`E318GC97RVXQ86` arrived at 08:48:15 UTC. Inspection found **11 JSON request
records**, exactly the 12 configured field names, no query/cookie/authorization/
referer/viewer-IP fields, and AES256 object encryption. Only field names/counts
were printed; request-record values were not displayed. The short-lived download
URL was handled through a protected temporary file and removed after inspection.

Before this first sync, the AWS Price List API was checked for Stockholm
(`AWSELB`, `Load Balancer-Application`): **USD 0.02394 per ALB-hour**, plus
**USD 0.0076 per used LCU-hour**. Scripted conversion puts the ALB-only baseline
at **USD 0.57456/day** or **USD 17.4762 per 730-hour month**, before credits,
taxes, capacity usage and other services. No capacity reservation or trust store
is planned. This cost begins when the controller creates the ALB.

Follow [AWS-provided HTTPS access](public-access.md) for the staged sequence:
security group, adapted internal Ingress and first full app sync, then CloudFront.
Keep app sync manual. **Deployment and all planned functional checks are
complete**, including authentication and real log receipt. The infra README
and cleanup plan now describe the running deployment, rebuild dependencies and
future cleanup order. **Only the final Git commits/pushes remain** in `infra-aws`
and `deploy-aws`; the user runs these under the recorded guidance preference.
Do not rerun applies or app syncs merely to commit documentation/helper files.

### Rebuild preparation (earlier November 1 checks)

Before rebuilding, read-only checks confirmed:

- The `aws-project` login targets project `245361883993`; selected Region remains
  `eu-north-1`. Free plan is `ACTIVE`, with **USD 199.40** remaining credits.
- Root Terraform state is empty; EKS, RDS and the project-tagged VPC are absent.
  The retained state bucket is available in Stockholm.
- Current public IPv4 matches `infra-aws/config/operator.tfvars`; the EKS API remains
  restricted to that `/32` address.
- Terraform validation passes. EKS 1.36 is in standard support, and PostgreSQL
  17.11 / db.t4g.micro / 20 GiB gp3 is available in the selected Region.

A fresh first-batch plan was generated and reviewed at
`/tmp/deployment-project-rebuild-foundation-20261101.tfplan`:
**61 additions, zero changes, zero deletions**. It targets `module.vpc`,
`module.eks` and `aws_db_instance.postgres` to rebuild the network, cluster,
two workers and private database before configuring Helm against the new cluster.
Database deletion safeguards and one-day backups were configured in the plan.
The successful later bootstrap and image pull demonstrate that EKS and RDS have
been recreated; the foundation apply summary was not shared. This saved plan
describes the earlier empty state and must not be reapplied. Do not reuse any
October 31 plans either.

Complete any unreported infrastructure/platform health checks below. Temporary
plans can disappear and become stale after configuration/state changes; generate
and review a fresh plan whenever further infrastructure work requires one.

See the [deployment batches](#remaining-deployment-work) for the full sequence.

### Completed teardown, 2026-10-31 (historical)

**Completed: teardown without database backups, 2026-10-31.** The user reported
`Destroy complete! Resources: 67 destroyed.` The agent verified AWS afterward;
`terraform -chdir=../infra-aws/terraform/foundation state list` is empty.

Verified project `245361883993`, selected Region `eu-north-1`:

- EKS cluster absent; both workers terminated and both root EBS disks absent.
- RDS instance absent, no snapshots, and its automated backup set not found.
- RDS-managed administrator Secret not found; no database password was read.
- VPC and network interfaces absent; NAT gateway reports `deleted`; no allocated
  Elastic IP remains.
- No ALBs, target groups or CloudFront distributions.
- EKS cluster CloudWatch log group absent.
- Separate state bucket `deployment-project-tfstate-245361883993-eu-north-1`
  still exists in Stockholm, as intended. Its versioned states and all local
  repositories/deploy-local are retained.

The Helm warning about retained Argo CD CRDs during uninstall requires no action:
those definitions disappeared with the deleted EKS cluster. Deleted NAT gateways
and terminated EC2 instances can still appear temporarily as historical entries.

Main infrastructure hourly usage has ended. The retained state bucket still has
small storage/request charges, and earlier usage may appear in billing later.
No RDS snapshot or automated backup was retained.

**Local configuration cleanup is complete:** `infra-aws/terraform/foundation/database.tf` again enables
`deletion_protection` and `prevent_destroy`, requires a final snapshot and retains
backups for a future rebuild; the temporary `apply_immediately = true` was removed.
These are file-only defaults and did not recreate resources or retain a backup of
this destroyed database. All saved Terraform plans from October 31 are stale.
Do not apply them. The root state is empty; a normal future plan would propose
creation, not a running deployment check.

`infra-aws/CLEANUP_PLAN.md` records the completed removal and verification. The earlier
deployment details below are historical rebuild context, **not current live state**.

### Deployment checkpoint before teardown

Continuation update, **2026-10-31**: **RDS creation is complete**. The first apply
created its four supporting resources, then AWS rejected seven-day backup
retention with `FreeTierRestrictionError`. Changing `infra-aws/terraform/foundation/database.tf` to
**one-day** retention and applying a refreshed one-resource plan succeeded.
`terraform output database` now exists. AWS reports the instance `available`,
private and encrypted, with deletion protection enabled, one-day backup retention,
an active administrator Secret and the parameter group `in-sync`.
All saved database creation plans are now consumed or stale; do not reapply them.

**The user successfully ran the database bootstrap helper.** Its output confirms
`BOOTSTRAP_OK login=myfastapiapp database=myfastapiapp tls=TLSv1.3` and a successful
rolled-back schema create/alter/index/insert/drop probe. Namespace `myfastapiapp`,
the app connection Secret and restricted database login now exist. Temporary
client resources were cleaned up. Alembic migrations have **not** been run.
The administrator password was never persisted by the helper.

**Deployment paused before GHCR access was configured.**
Anonymous access to `ghcr.io/pquarg/myfastapiapp:0.1.12` returned HTTP `401`.
From `deploy-aws/`, run
`python3 scripts/configure-registry.py aws-deployment-project pquarg`, entering
a GitHub classic PAT with `read:packages` at its hidden local prompt. Use the
token owner's username if different. The helper is prepared but has not been
run; no PAT has been provided to the agent. It creates/updates the
`registry-credentials` Secret without local credential files. Then follow the
temporary pull check in `docs/credentials.md`, using
`scripts/image-pull-check.yaml`. The check Pod passed a server dry-run in the
app namespace; it has not been created. Eight local helper tests pass.

Stockholm Price List API checks put the additional database baseline at
**USD 14.48 per 730-hour month**: USD 11.68 for the instance, USD 2.40 for
20 GiB gp3 storage and USD 0.40 for one administrator Secret. This excludes
credits, taxes, API calls, surplus CPU credits, excess backup storage and transfer.
The Free Tier API still reports `FREE` / `ACTIVE` and USD 199.78 remaining credits.

After the image pull succeeds, prepare Argo CD Git credentials, adapt the ingress for
an AWS-provided HTTPS URL, configure Git/registry access, publish the manifests,
and perform the first full Argo CD app sync. Details are below.

That cluster and network were subsequently deleted. Rebuild them before resuming
the credential steps; the former namespace, database login and Secrets are gone.

## Repositories and ownership

All paths below are under `/Users/admin/Developer/learning/deployment-project`.

| Directory | Responsibility |
| --- | --- |
| `infra-aws/` | Terraform: AWS infrastructure and Helm installation of platform components |
| `deploy-aws/` | This repository: Kubernetes app manifests, Kustomize and Argo CD registrations |
| `deploy-local/` | Existing kind/Traefik/local PostgreSQL environment; kept separate and unchanged |
| `apps/myfastapiapp/` | FastAPI code, Dockerfile, Alembic migrations and image publishing workflow |

Terraform installs Argo CD and the AWS Load Balancer Controller. Argo CD will
manage the app resources. The controller will create the ALB and target groups
from the app Ingress; Terraform must reference those resources without also
managing their lifecycle.

At this snapshot, `deploy-aws` was clean at commit `cd57b49` before adding this
handoff and its README link. The newly created files in `infra-aws` remain untracked
and uncommitted, including its Terraform configuration and provider lock files.
Review and save them in Git as part of continuing the project. Keep state,
binary plans, filled Secrets and local `.tfvars` out of Git.

## AWS access and tools

| Setting | Value |
| --- | --- |
| AWS project/account ID | `245361883993` |
| AWS profile | `aws-project` |
| Confirmed selected Region | Europe (Stockholm), `eu-north-1` |
| Plan | `FREE`, last observed `ACTIVE` |
| EKS cluster | `deployment-project-dev` |
| Explicit kubectl context | `aws-deployment-project` |
| Existing human role used for cluster administration | `arn:aws:iam::245361883993:role/managed/AccountFullAccessRole` |

The `/managed/` path in that IAM role ARN matters. The Terraform module resolved
the stable role behind the assumed-role login and created an EKS cluster-admin
access entry for it.

Installed tools observed: AWS CLI 2.39.0, Terraform 1.17.1, kubectl 1.36.1 with
built-in Kustomize, and Python 3 on macOS ARM64. `kubeconform` is not installed
globally; the checksum-verified v0.8.0 binary under
`/tmp/deployment-project-validation-20261101` passed local readiness validation.
Add that directory to `PATH` for this session's bootstrap or install kubeconform
for ongoing use. Helm CLI is not needed for the Terraform Helm installations.

If the temporary AWS login expires, the user can renew it and verify access:

```sh
aws login --profile aws-project --region eu-north-1
aws sts get-caller-identity --profile aws-project --region eu-north-1 --no-cli-pager
```

An earlier Terraform error, `No valid credential sources found ... login session
has expired`, was resolved this way. It did not require configuration changes or
another state migration.

## Provisioning history (resources now deleted except state bootstrap)

### Terraform state bootstrap

- `infra-aws/bootstrap/` manages six resources configuring the state bucket.
- Bucket: `deployment-project-tfstate-245361883993-eu-north-1`.
- Versioning enabled, SSE-S3/AES256 encryption, public access blocked, ACLs disabled,
  HTTPS enforced, and bucket deletion guarded.
- Both Terraform directories now use the bucket with native S3 locking:

| Terraform directory | State key |
| --- | --- |
| `infra-aws/bootstrap/` | `bootstrap/terraform.tfstate` |
| `infra-aws/` root | `dev/terraform.tfstate` |

Both backends explicitly select `aws-project`, `eu-north-1`, the allowed project
ID, encryption and `use_lockfile = true`. DynamoDB locking was not introduced.
State was migrated from local storage after creating the bucket.

### Network

`infra-aws/terraform/foundation/network.tf` uses VPC module version **6.7.3**. Applied successfully:
**24 additions**. Live VPC, subnet states, DNS settings, route associations, NAT
availability, Elastic IP attachment and load-balancer discovery tags were verified.

| Resource | ID / address range |
| --- | --- |
| VPC | `vpc-09d25da0b882dacbe`, `10.42.0.0/16` |
| Public subnet, `eu-north-1a` | `subnet-0f242140cfd7551f0`, `10.42.0.0/24` |
| Public subnet, `eu-north-1b` | `subnet-01224a14649a0ec1f`, `10.42.1.0/24` |
| Private worker subnet, `eu-north-1a` | `subnet-06f41d2788d7209b6`, `10.42.16.0/20` |
| Private worker subnet, `eu-north-1b` | `subnet-0148b0ed690e671be`, `10.42.32.0/20` |
| Database subnet, `eu-north-1a` | `subnet-00ed042d362001814`, `10.42.48.0/24` |
| Database subnet, `eu-north-1b` | `subnet-0ae43b0cdf68c356d`, `10.42.49.0/24` |
| NAT gateway | `nat-047f44dbb729b0b7e` |
| NAT Elastic IP allocation | `eipalloc-04d69aa7e867e1976` |
| Internet gateway | `igw-01f44badba1595f22` |

Public subnets route through the internet gateway. Private worker subnets share
one NAT gateway in the first public subnet. Database subnets have no default
internet route. The shared NAT is a development choice and makes outbound
internet access dependent on its Availability Zone.

### EKS and workers

`infra-aws/terraform/foundation/eks.tf` uses EKS module **21.26.0**. Applied successfully:
**32 additions**. AWS reported cluster `ACTIVE`; both workers were `Ready` and
all eight kube-system Pods were running with zero restarts at initial verification.
The cluster and workers were checked again when writing this handoff.

- Kubernetes **1.36**, confirmed in standard support in Stockholm.
- Two private, On-Demand **t3.small** workers: 2 vCPU / 2 GiB RAM each.
- Amazon Linux 2023 x86_64 image release pinned to **1.36.5-20261031**.
- Each worker has an encrypted **20 GiB gp3** root disk, deleted on termination.
- Node-group minimum, desired and maximum sizes are all **2**; no node autoscaler
  has been installed.
- T3 CPU credits use **standard** mode: CPU can throttle when credits run out
  instead of incurring surplus-credit charges.
- IMDSv2 required, metadata hop limit 1, no SSH key configured.
- Private API endpoint enabled; public endpoint restricted to the user's `/32`
  address in ignored `infra-aws/config/operator.tfvars`. Update that value if their IP changes.
- API authentication uses EKS access entries; initial operator has cluster-admin.
- IRSA disabled; EKS Pod Identity is used for controller AWS access.
- AWS-owned default encryption for Kubernetes API data; no customer KMS key added.
- API/audit/authenticator logs enabled with seven-day CloudWatch retention.
- Worker security group: **`sg-05333446d51a79145`**.

Pinned add-ons:

| Add-on | Version |
| --- | --- |
| VPC CNI | `v1.22.4-eksbuild.10` |
| Pod Identity agent | `v1.4.1-eksbuild.3` |
| kube-proxy | `v1.36.0-eksbuild.58` |
| CoreDNS | `v1.14.7-eksbuild.22` |

The worker role carries the CNI bootstrap permissions. Separate application
Pod IAM roles have not been needed or created.

### Argo CD

`infra-aws/terraform/platform/argocd.tf` manages `helm_release.argocd`, using chart **10.11.6** and Helm
provider **3.3.0**. Applied successfully: **1 addition**.

- Namespace `argocd`, private `ClusterIP` server Service, no public ingress.
- User successfully signed into the UI. An empty Applications page is expected:
  **there are currently no registered Argo CD Applications**.
- Initial password retrieval was kept local via clipboard; no credentials belong
  in this handoff. Changing the initial password was instructed but not confirmed.
- Access the UI with this long-running command in a separate terminal:

```sh
kubectl --context aws-deployment-project -n argocd \
  port-forward service/argocd-server 8081:443
```

Then open `https://localhost:8081`. Argo CD's default certificate is self-signed.

### AWS Load Balancer Controller

`infra-aws/terraform/platform/load-balancer-controller.tf` was applied successfully: **5 additions**.

- Chart/controller version **3.6.2**, two replicas in `kube-system`.
- Dedicated IAM role and official, versioned permissions policy, plus attachment
  and EKS Pod Identity association.
- Role trust is restricted to this cluster ARN, namespace `kube-system` and
  service account `aws-load-balancer-controller` through Pod Identity request tags.
- Public policy is committed-source material under `infra-aws/policies/`, not a Secret.
- Region and VPC ID are passed explicitly, preserving worker metadata hop limit 1.
- Optional Shield/WAF integrations disabled for this setup. Shield is unsupported
  in this project's managed AWS experience.
- Live deployment checked **2/2 Ready**, and IngressClass `alb` uses
  **`ingress.k8s.aws/alb`**.

Installing the controller did not create an ALB. No app Ingress has been deployed.

## Historical RDS provisioning (instance subsequently deleted)

All five resources below were applied on October 31. The first attempt completed
resources 1–4; the one-day retention retry successfully created resource 5:

1. DB subnet group using the isolated database subnets.
2. Database security group.
3. TCP 5432 ingress from the worker security group only.
4. PostgreSQL 17 parameter group with `rds.force_ssl = 1`.
5. RDS PostgreSQL instance `deployment-project-dev-postgres`.

Configuration: PostgreSQL **17.11**, **db.t4g.micro**, Single-AZ, encrypted gp3
storage starting at **20 GiB** with autoscaling capped at **40 GiB**. Regional
availability and minimum storage were checked with the RDS API. Database name
`myfastapiapp`; administrator username `dbadmin`; master password generated,
stored and rotated by RDS/Secrets Manager. No password value is placed in Terraform.

Backup retention was **one day**, following the rejected seven-day attempt.
The user then explicitly chose deletion without backups. Deletion guards were
disabled, the no-backup settings were applied, and the instance was destroyed.
The preserved configuration and November 1 rebuild plan restore deletion
protection, `prevent_destroy`, a required final snapshot, retained automated
backups and one-day backup retention. These settings do not recover the deleted
database or its data.
Minor upgrades are pinned/manual in this draft and need an ongoing update process.

Former private endpoint (do not use for the rebuilt database):
`deployment-project-dev-postgres.ct2486204t4q.eu-north-1.rds.amazonaws.com:5432`.
Database security group: `sg-0eb0f555b5e23ea74`. Its worker ingress rule is
`sgr-00c9587f3ba6a6a40`. These resources were removed from Terraform state by
the completed destroy. After rebuilding, use `terraform output database` for
the new endpoint and administrator Secret ARN, without printing its password.

The former `myfastapiapp` application login was provisioned with database `CONNECT`
and schema `USAGE, CREATE` permissions for Alembic. The helper checked that it has
no elevated role attributes or inherited role memberships. The API and migration
Job used its `myfastapiapp-secrets` connection Secret, not `dbadmin`. TLS and
DDL permissions were verified. Recreate that login and Secret after the rebuild;
actual migrations remain part of the Argo CD sync.

## Remaining deployment work

Follow these batches in order, with the user running apply and credential setup
commands. Record each result before moving to the next batch. Database bootstrap
and image-pull verification have succeeded; no app sync has been reported.

### 1. Rebuild network, EKS and the fresh database — verified

- [x] Verify the AWS identity, selected Region, Free-plan status, retained state
  bucket, empty root state and current EKS operator IP allowlist.
- [x] Validate Terraform and review the fresh foundation plan: **61 additions,
  zero changes, zero deletions**.
- [x] Recreate EKS and RDS: demonstrated by the successful database bootstrap and
  image-pull check. The foundation apply summary has not been shared; do not
  reapply the old foundation plan.

- [x] Refresh the explicit Kubernetes context (verified by the bootstrap helper
  and subsequent successful kubectl checks):

  ```sh
  aws eks update-kubeconfig --name deployment-project-dev \
    --region eu-north-1 --profile aws-project --alias aws-deployment-project
  kubectl --context aws-deployment-project get nodes
  ```

- [x] Verify cluster access, both workers are `Ready`, add-ons are
  healthy, and RDS is `available`, private, encrypted and protected with one-day
  backups. Read the new database output; do not reuse the historical endpoint.

The foundation plan deliberately targeted infrastructure before Helm setup.
Subsequent plans must be untargeted. The rebuilt resources incur AWS usage;
closing terminals does not stop it.

### 2. Restore Argo CD and the load balancer controller — verified

- [x] Generate and review a full **untargeted** Terraform plan:
  `infra-aws/rebuild-platform.tfplan`, **6 additions, zero changes, zero deletions**.
  It includes the two Helm releases and controller IAM/Pod Identity resources.
- [x] Apply that reviewed plan. Check Argo CD and ApplicationSet controller
  rollouts, the controller's two replicas, its Pod Identity association and the
  `alb` IngressClass. Do not bootstrap app registrations yet.
- [x] Confirm a subsequent full Terraform plan reports no outstanding changes
  (before adding the next ingress security-group configuration).

### 3. Recreate database and app credentials — complete

- [x] From `deploy-aws/`, run the prepared database bootstrap helper:

  ```sh
  python3 scripts/bootstrap-database.py aws-deployment-project --profile aws-project
  ```

  Require `BOOTSTRAP_OK`, verified TLS and a successful migration-permission
  probe. The helper recreates the namespace, restricted app login and connection
  Secret. Actual Alembic migrations run during the later full Argo CD sync.
- [x] Run `python3 scripts/configure-registry.py aws-deployment-project pquarg`,
  using the token owner's username if different. Enter the `read:packages` PAT
  only at the helper's hidden local prompt.
- [x] Follow the [temporary image-pull check](credentials.md#registry-authentication)
  and require `GHCR image pull OK`. Remove the successful check Pod.
- [x] Configure Argo CD read access to `git@github.com:pquarg/deploy-aws.git` with
  SSH host verification enabled. Git access and GHCR access are separate credentials;
  the old cluster's Secrets were deleted.

  The user reported repository connection status **Successful**.

### 4. Adapt public access for an AWS-provided HTTPS address — pending

The security group and internal Ingress are deployed; the app is healthy.
The VPC origin and distribution are Deployed. Public HTTPS, authentication and
actual log-record delivery passed. The detailed creation order,
validation requirements and pricing distinction are recorded in
[AWS-provided HTTPS access](public-access.md).

The user has no custom domain. The published Ingress/runbooks now use a private
ALB and no ACM/hostname requirement; CloudFront's default HTTPS address is next
after the first app sync and ALB verification.

The public endpoint is **CloudFront's default HTTPS hostname in front of
the internal ALB through a VPC origin**. CloudFront is provisioned. It
provides the certificate for its own `*.cloudfront.net` address; VPC origins
support Stockholm. A custom domain can be added later.

- Prepare Terraform for CloudFront/VPC-origin access and the necessary security
  groups; keep all Regional resources in Stockholm. CloudFront itself is global.
- The published Ingress requests an internal ALB with restricted frontend access,
  HTTP port 80 and no hostname/ACM requirement.
- Resolve resource ordering: the controller must create an active ALB before
  CloudFront can reference it. Terraform may look up the ALB but should not also
  own the controller-managed ALB/target groups. A deterministic ALB name can help.
- Configure API behaviour deliberately: disable response caching for this API,
  forward required methods/headers/cookies/query parameters, and verify login,
  generated links and redirects through the final HTTPS URL.
- Recheck current docs, project support and costs before implementation. Avoid
  exposing registration/login over a public plaintext HTTP endpoint.

References:

- [CloudFront default-domain HTTPS](https://docs.aws.amazon.com/AmazonCloudFront/latest/DeveloperGuide/using-https-viewers-to-cloudfront.html)
- [CloudFront VPC origins, including Stockholm support](https://docs.aws.amazon.com/AmazonCloudFront/latest/DeveloperGuide/private-content-vpc-origins.html)

### 5. Publish app configuration and bootstrap Argo CD registrations — complete

- Keep the release image `ghcr.io/pquarg/myfastapiapp:0.1.12` initially. The app's
  CI publishes AMD64 and ARM64 images; the November 1 cluster pull succeeded.
- Deployment readiness validation and server dry-run passed. The example
  hostname/certificate values have been removed. A checksum-verified kubeconform
  v0.8.0 is temporarily available under `/tmp/deployment-project-validation-20261101`;
  use that directory on `PATH` or install kubeconform for ongoing local use.
- [x] Publish the configured manifests and credential helpers to `deploy-aws/main`,
  commit `091b797`. Review/save the separate infra files too.
- [x] Run `scripts/bootstrap-eks.sh aws-deployment-project`: readiness and rollout
  checks passed, `aws-root` is Synced/Healthy and `aws-myfastapiapp` was generated.
  Read-only inspection confirms the app compares against commit `091b797`, with
  no comparison errors. It is OutOfSync/Missing until the first full manual sync.

### 6. First app sync and verification — complete; final Git save pending

- [x] Manually sync the entire `aws-myfastapiapp` Application.
- [x] Migration `001_initial` succeeded, API is Ready, internal ALB is Active and
  its target is Healthy. Argo CD reports Synced/Healthy.
- [x] Apply the VPC-origin plan and verify Deployed.
- [x] Apply the reviewed 12-resource distribution/logging plan; distribution Deployed
  and a full post-apply plan reports No changes.
- [x] Verify public health/readiness, Swagger/OpenAPI, HTTPS redirect, HTTP rejection,
  security/no-store headers and unauthenticated rejection.
- [x] User runs the prepared `--auth` check and reports `AUTH_OK`;
  synthetic account `deploy_check_77ad069738`, test session revoked.
- [x] Confirm real access-log objects arrive and inspect selected field names
  without displaying request-record values; AES256 object encryption confirmed.
- [ ] Save the remaining infra and deployment documentation/helper changes in Git.
- Keep app auto-sync off initially.

The application still has **one replica**. This learning deployment is not yet a
configured highly available production service. Reassess replicas, capacity,
failure recovery, updates, backups/restore tests and availability requirements
before calling it production-ready.

## Historical running costs before teardown

Pre-teardown infrastructure baseline with Stockholm RDS pricing; these
resources are now deleted:

| Component | Approximate USD/hour |
| --- | ---: |
| EKS standard-support control plane | 0.1000 |
| Two t3.small workers | 0.0432 |
| One NAT gateway | 0.0460 |
| One public IPv4 address | 0.0050 |
| Two 20 GiB gp3 worker disks, monthly cost converted to hourly | 0.0046 |
| RDS db.t4g.micro | 0.0160 |
| RDS 20 GiB gp3 storage, monthly cost converted to hourly | 0.0033 |
| One administrator Secret, monthly cost converted to hourly | 0.0005 |
| **Total** | **0.2186** |

Approximately **USD 5.25/day** or **USD 159.60 per 730-hour month**, before credits,
allowances and taxes. S3 state, CloudWatch logs, NAT processing and data transfer
add usage-based amounts, as do Secrets Manager API calls, RDS surplus CPU credits
and excess backup storage. Argo CD and the controller run on the existing workers.
An application ALB and CloudFront are not included because neither has been
created by this deployment yet.

October 31 Free Tier API result: `FREE` / `ACTIVE`, **USD 199.78**
remaining credits, plan expiry **2027-04-28**. That balance is a historical API
reading, not a live balance. Free-plan usage consumes credits; check AWS Settings
Billing for the current balance. Closing terminals/port-forwards does not stop AWS
resource usage. The resources listed above are now deleted; only the retained
state bucket and previously incurred usage can produce subsequent charges.

Pricing references: [EKS](https://aws.amazon.com/eks/pricing/),
[EC2](https://aws.amazon.com/ec2/pricing/on-demand/),
[VPC](https://aws.amazon.com/vpc/pricing/),
[EBS](https://aws.amazon.com/ebs/pricing/),
[RDS PostgreSQL](https://aws.amazon.com/rds/postgresql/pricing/),
[Secrets Manager](https://aws.amazon.com/secrets-manager/pricing/).

## Historical teardown result and post-deletion checks

The user applied the unlock and no-backup settings, then destroyed all **67**
root-managed resources. No destroy is pending. The separate six-resource
`infra-aws/bootstrap/` state was deliberately retained.

Read-only checks used after teardown (an empty state is expected only until the
rebuild is applied):

```sh
terraform -chdir=../infra-aws/terraform/foundation state list
aws s3api head-bucket \
  --bucket deployment-project-tfstate-245361883993-eu-north-1 \
  --expected-bucket-owner 245361883993 \
  --profile aws-project --region eu-north-1 --no-cli-pager
```

The first command produced no addresses after teardown. The existing
`aws-deployment-project` kubeconfig entry must be refreshed after the rebuild.
All October 31 `.tfplan` files are stale and must remain outside Git. The
November 1 rebuild is tracked under "Resume here" and the deployment batches
above. No app data can be recovered from this teardown because the user chose
deletion without backups.

## Existing runbooks to use and update

The complete deployment and teardown walkthroughs were added after verification,
at the user's request. Their shell blocks were syntax-checked, and both
temporary teardown Terraform variants were validated in isolated copies. No
teardown or live configuration change was performed to write these guides.

- [Complete deployment/rebuild walkthrough](deploy-from-scratch.md)
- [Complete teardown walkthrough](teardown.md)
- [Infrastructure ownership/requirements](infrastructure.md)
- [Cluster and Argo CD setup](setup.md)
- [Credentials and GHCR authentication](credentials.md)
- [Deployment validation](validation.md)
- [App database, sync and recovery runbook](../../apps/myfastapiapp/overlays/aws/README.md)

The runbooks now describe the internal Ingress and the staged no-custom-domain
deployment. Complete the CloudFront-specific commands/outputs and HTTPS
verification details when the edge resources are implemented.
Prepared files were staged under `/tmp/deployment-project-*-step.*` during the
session, but the working copies are now in `infra-aws/`; future work should use the
repository copies rather than depend on temporary directories surviving.
