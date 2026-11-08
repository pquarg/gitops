# AWS-provided HTTPS address

The live request path is CloudFront HTTPS → private VPC origin → internal ALB →
FastAPI → RDS. The default `*.cloudfront.net` hostname supplies the public
certificate. Keep the ALB internal; private origin HTTP is unchanged.
These instructions describe desired configuration and checks, not current health.

## 1. Prepare restricted ALB access

Foundation owns the frontend SG and rules in
`../infra/environments/aws/dev/foundation/app-ingress.tf`: HTTP from the CloudFront
origin-facing prefix list, app/check traffic to worker port 8000. Read:

```sh
terraform -chdir=../infra/environments/aws/dev/foundation output myfastapiapp_alb_security_group
```

Keep that identity in the app Ingress. The controller owns its backend group,
ALB and targets. Terraform must never import those resources.

## 2. Prepare and publish the internal Ingress

Keep deterministic name `deployment-project-dev-app`, internal IPv4 scheme,
HTTP port 80, IP targets, `/ready` health check, controller backend-rule management
and no host-specific rule. Preserve the application name, namespace and image.
Follow [setup](setup.md) to validate/publish and register `root`, then manually
sync the full app including its migration hook.

## 3. Verify the origin

```sh
../infra/environments/aws/dev/scripts/check-stage.sh edge --context aws-deployment-project
```

Supply `--kubeconfig /absolute/file` when needed. This verifies the selected EKS
endpoint, platform controllers, Active ALB and healthy targets. Investigate
migration logs, app `/ready`, networking and database access before creating edge
if target health fails. Private ALB DNS is not a public app URL.

## 4. Provision CloudFront through Terraform

```sh
../infra/scripts/plan.sh --environment aws/dev --stage edge --context aws-deployment-project
terraform -chdir=../infra/environments/aws/dev/edge apply stage.tfplan
terraform -chdir=../infra/environments/aws/dev/edge output myfastapiapp_https
```

Review the full saved edge plan first. It owns the VPC origin, distribution,
functions, response policy, log bucket and delivery. No `-target` sequence or root
plan is required. The bucket is private, encrypted and expires access logs after
14 days; selected fields omit query strings, cookies, authorization, referer and
viewer IPs. Log delivery stays `us-east-1`, bucket/VPC resources `eu-north-1`.

The viewer-request function permits only exact IPv4 `/32` addresses supplied by
`../infra/environments/aws/dev/config/operator.tfvars`, shared with foundation's API allowlist.
It uses connection-derived viewer IP and rejects other addresses before origin
access. IPv6 remains disabled. A shared public IP permits all devices using that
IP; app authentication is still required.

## Verify HTTPS, authentication, restrictions and logging

Read the URL from the current edge output after the distribution reaches
Deployed. Run from `gitops`:

```sh
APP_URL="$(terraform -chdir=../infra/environments/aws/dev/edge output -json myfastapiapp_https |
  python3 -c 'import json, sys; print(json.load(sys.stdin)["url"])')"
python3 scripts/check-public-endpoint.py "$APP_URL"
# Separately authorized test-user creation/login/logout check:
python3 scripts/check-public-endpoint.py "$APP_URL" --auth
```

The basic check covers health/readiness, docs/OpenAPI, redirects and response
headers. Test existing login/data as well. From an allowed connection expect
success; from a different public IPv4 (for example a phone with Wi-Fi off) expect
403 on both `/health` and `/api/v1/docs/`. A device on the same home Wi-Fi is
allowed. Confirm actual log delivery and encryption in the bucket named by
`myfastapiapp_https`, allowing for delivery delay. Do not publish raw logs.
Finish with full stage plans and record live results without credentials.

If the ISP/VPN changes the outbound IPv4, update the single ignored allowlist,
review and apply fresh **foundation and edge** plans. Applying one stage alone
does not update both restrictions. Keep AWS CLI access for recovery. Do not
reuse consumed plans. Check the deployed outputs and endpoints directly.
