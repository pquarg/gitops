# Gateway API routing and cutover

Argo CD owns HTTPRoutes in each app overlay. Infrastructure owns Standard Gateway
API v1.6.2 CRDs, controller releases and GatewayClasses. Local apps attach to
`traefik/traefik-gateway`, listener `web` on Traefik's internal port 8000. The kind
contract remains `127.0.0.1:80 → NodePort 30080 → Traefik`. Only namespaces
`demo-api` and `job-tracker` may attach, using their built-in namespace name label.
Adding another local app also requires a reviewed infra namespace selector change.
Same-namespace backend Services require no ReferenceGrant.

| Host | Match | Service port |
| --- | --- | --- |
| demo-api.localhost | `/` PathPrefix | demo-api:80 |
| mailpit.localhost | `/` PathPrefix | demo-api-mailpit:8025 |
| job-tracker.localhost | `/api/` PathPrefix | job-tracker-api:80 |
| job-tracker.localhost | `/` PathPrefix | job-tracker-frontend:80 |

Gateway prefix matches use path segments: `/api`, `/api/` and nested API paths
select the API; `/apix` selects the frontend. Paths are preserved without a rewrite
filter. More specific API matches take precedence over `/`.

## Reviewed local transition

This checkout prepares the final routes; publishing them before the platform
apply would leave them without their parent Gateway. Keep separate repository
commits, with platform support delivered first. Independent app source repositories,
images, credentials, migration definitions and database data are unchanged.

1. Validate infra, review the full local platform plan, and apply separately.
   Run infra's `check-ingress-kind.sh`. Existing Ingress routes must still work.
2. Confirm Compose database health through infra's database status command. Run
   the existing app database probe and review its migration hook before publication.
   Full auto-sync reruns hooks even for routing changes. Keep existing data/backups.
3. Before publishing the final conversion, temporarily retain demo-api's old
   Ingress and publish a **separate HTTPRoute** with name `demo-api-gateway-smoke`
   and hostname `gateway-smoke.localhost`, routing to `demo-api:80` with the same
   parentRefs as the final route. Add it to that overlay's Kustomization. This is
   an Argo-owned smoke test; do not manually apply it alongside a different Git
   desired state. Test `/health` and `/ready` on the smoke host and check status.
   Remove it through GitOps and explicit pruning after verification.
4. Publish demo-api's final conversion, including Mailpit. Server dry-run first
   using the commands below. Check app sync and route status, then explicitly
   prune **only** the old `demo-api` and `demo-api-mailpit` Ingresses in Argo CD.
   Auto-sync currently has no prune policy, so removing YAML alone leaves them
   live. Review the full app resource diff before pruning. Verify all demo-api,
   login/session, email verification and Mailpit journeys before proceeding.
5. Publish job-tracker's conversion separately; check status, explicitly prune
   its old Ingress and verify its saved jobs/login/provider journeys. Preserve
   existing registration names, Secrets and database records.
6. Inspect all namespaces for remaining Ingresses. Only after every route passes,
   review a separate platform change disabling the Ingress provider/IngressClass.
   This checkout deliberately retains that provider for the verification window.

Switching resource kinds is not atomic and does not promise zero downtime.
Selective sync skips hooks; use the app's existing full-sync/recovery procedure.
Do not combine unpublished local changes with claims about Argo CD's deployed Git.

Run from `gitops`, after platform installation and before publication:

```sh
./scripts/validate.sh --no-placeholders
./scripts/validate-server.sh demo-api --environment local --context kind-deployment
./scripts/validate-server.sh job-tracker --environment local --context kind-deployment
```

Run status checks after the corresponding app sync:

```sh
python3 scripts/check-gateway.py --environment local --context kind-deployment \
  --kubeconfig "$HOME/.kube/config"
python3 scripts/check-gateway.py --environment local --context kind-deployment \
  --kubeconfig "$HOME/.kube/config" --namespace demo-api --route demo-api
python3 scripts/check-gateway.py --environment local --context kind-deployment \
  --kubeconfig "$HOME/.kube/config" --namespace demo-api --route demo-api-mailpit
python3 scripts/check-gateway.py --environment local --context kind-deployment \
  --kubeconfig "$HOME/.kube/config" --namespace job-tracker --route job-tracker
```

The checker requires parent `Accepted=True` and `ResolvedRefs=True` for the current
route generation, the expected controller, namespace and listener. Platform checks
also require class acceptance and local Gateway/listener readiness. HTTP success
alone does not prove traffic uses the HTTPRoute while an old Ingress still exists.

Exercise `/health`, `/ready`, account login/session, existing records and the app
runbooks. For job-tracker check `/api`, `/api/`, a real nested API endpoint, `/`,
a frontend deep link and `/apix`. Compare expected backend responses, including
redirects/errors, rather than requiring every path to return 200. An unrelated
hostname must not serve either app; unknown paths must retain each app's expected
404 or frontend behavior. In a temporary unpermitted namespace, a route naming
this Gateway must not get `Accepted=True`; remove the test resources afterwards.
No backend or Secret needs to be copied for that attachment-denial test.

## AWS first deployment

The AWS overlay owns Gateway `demo-api`, HTTPRoute `demo-api`,
LoadBalancerConfiguration and Service-associated TargetGroupConfiguration.
GatewayClass `alb` uses controller `gateway.k8s.aws/alb`; the app Gateway permits
same-namespace HTTPRoutes only. Its HTTP port 80 listener accepts CloudFront's
forwarded viewer host; the route intentionally has no `hostnames` restriction.

**Before manual sync**, replace `spec.securityGroups` in
`apps/demo-api/overlays/aws/load-balancer-configuration.yaml` with the new
foundation `myfastapiapp_alb_security_group` output. The historical checked-in
value is not evidence that such a group currently exists. Preserve internal
scheme, IPv4, `dev-demo-api`, managed backend rules, Pod IP targets and `/ready`
HTTP 200 health checks. No AWS job-tracker overlay is added.

Migration/Service remain wave 0, healthy workload wave 1, and both configurations,
Gateway and HTTPRoute wave 2. Keeping routing in one wave avoids waiting for a
healthy Gateway before applying its route. Argo CD v3.5.6 supplies built-in health
checks; no override is added. Bootstrap checks CRDs and class, without requiring
an app-owned Gateway before manual app sync.

After sync, run `check-gateway.py` with `--environment aws`, the explicit EKS
context and `--namespace demo-api --route demo-api`. Edge planning also requires
Gateway/route acceptance, an Active ALB and healthy target groups. Continue with
[deploy from scratch](aws/deploy-from-scratch.md), then public HTTPS/session tests.
Configuration validation does not provision AWS or demonstrate ALB reconciliation.

## Rollback and cleanup

While Ingress support is enabled, publish a revert restoring the affected old
Ingress and prune its replaced HTTPRoute deliberately. Verify service/login/data.
After provider cleanup, restore Ingress support through a reviewed Terraform
apply first. Do not leave competing route definitions for the same hostname.
Routing reverts do not undo schema migrations. Keep CRDs installed throughout.

For AWS removal, [teardown](aws/teardown.md) removes edge before app Gateways while
the controller runs, waits for finalizers and ALBs/targets, then removes platform
and foundation. Legacy Ingress/LoadBalancer Service cleanup remains supported.
Do not strip finalizers or execute teardown as part of this conversion.

Pinned schemas under `schemas/` derive from infra's vendored Standard v1.6.2 and
AWS controller chart 3.6.2 CRDs via `infra/scripts/update-gateway-schemas.py`.
Unknown kinds still fail validation. The two repositories carry the same
read-only `check-gateway.py`; update and test both copies together.
