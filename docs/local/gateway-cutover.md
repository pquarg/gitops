# Local Gateway API cutover

The local platform owns Standard Gateway API v1.6.2 CRDs, GatewayClass `traefik`
and Gateway `traefik/traefik-gateway`. Traefik retains NodePort 30080 and the kind
mapping `127.0.0.1:80`. HTTPRoutes belong to the app overlays in this repository.
Only namespaces `demo-api` and `job-tracker` may attach; new apps require a
reviewed infrastructure namespace-selector update. Same-namespace backends need
no ReferenceGrant. AWS routing is unchanged by these local cutover commits.

A distinct-host smoke route was published and verified first. Demo-api and
Mailpit were converted and verified before job-tracker. The smoke route was
removed through GitOps and explicitly pruned. Original app images, Service ports,
Secrets, database identities and migration definitions are retained. Full syncs
run hooks and require the databases to be ready. Demo-api's live auto-sync pause
is preserved; use a one-time full hook-enabled sync for its updates.

| Host | Path | Backend |
| --- | --- | --- |
| demo-api.localhost | `/` | demo-api:80 |
| mailpit.localhost | `/` | demo-api-mailpit:8025 |
| job-tracker.localhost | `/api/` | job-tracker-api:80 |
| job-tracker.localhost | `/` | job-tracker-frontend:80 |

HTTPRoutes name parent namespace `traefik` and listener `web`. Requests retain
their full path. The API prefix matches `/api`, `/api/` and nested API paths;
`/apix` selects the frontend. Local bootstrap checks Gateway readiness rather
than depending on an IngressClass. AWS bootstrap retains its existing checks
until the separate AWS configuration conversion is published.

## Verify after publishing and syncing

Run from `gitops`; select the same kubeconfig and context throughout:

```sh
./scripts/validate.sh --no-placeholders
./scripts/validate-server.sh demo-api --environment local --context kind-deployment
./scripts/validate-server.sh job-tracker --environment local --context kind-deployment
python3 scripts/check-gateway.py --environment local --context kind-deployment --kubeconfig "$HOME/.kube/config"
python3 scripts/check-gateway.py --environment local --context kind-deployment --kubeconfig "$HOME/.kube/config" --namespace demo-api --route demo-api
python3 scripts/check-gateway.py --environment local --context kind-deployment --kubeconfig "$HOME/.kube/config" --namespace demo-api --route demo-api-mailpit
python3 scripts/check-gateway.py --environment local --context kind-deployment --kubeconfig "$HOME/.kube/config" --namespace job-tracker --route job-tracker
kubectl --context kind-deployment get ingress,httproute -A
```

Require Accepted/ResolvedRefs for the current route generation and the expected
parent, namespace, listener and controller. A successful HTTP response while an
old Ingress still exists does not prove the HTTPRoute carries traffic. After a
full hook-enabled app sync, review Argo CD's obsolete-resource inventory and prune
only the old app Ingresses. Retained migration Jobs are hooks, not obsolete app
resources. Do not prune arbitrary resources or change automatic-prune policy.

Exercise health/readiness and existing login/session/data paths after pruning.
Demo-api checks include account continuity, logout and Mailpit password reset.
Tracker checks include cookie/CSRF login, saved uploads/downloads, sandboxed
parsing, search profiles, provider configuration and cross-account isolation.
Compare `/api`, `/api/`, nested API paths and frontend deep links before/after.
An unrelated hostname must not serve an app. A temporary HTTPRoute in an
unpermitted namespace must be rejected with NotAllowedByListeners; remove only
that test namespace/resources afterward. Provider configuration readiness does
not prove paid discovery behavior; do not run paid research solely to test routing.

## Rollback and final platform cleanup

Keep the Ingress provider enabled during cutover. To roll an app back, publish a
revert restoring its old Ingress, full-sync it, explicitly prune the HTTPRoute
and verify login/data. A route revert does not reverse schema migrations.

Only after both apps and all routes pass, and no Ingresses remain, disable the
Ingress provider/IngressClass through a separately reviewed full infrastructure
platform plan. Preserve Traefik's Helm address, Gateway CRDs, ports, Secrets and
databases. After that cleanup, restore Ingress support through Terraform before
rolling an app back to Ingress. Never delete Gateway CRDs as rollback or rebuild
the cluster to fix ownership. See infra's shared Gateway lifecycle/state runbooks.
