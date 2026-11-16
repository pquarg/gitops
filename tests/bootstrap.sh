#!/usr/bin/env bash
set -euo pipefail
root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/repo/scripts"
cp "$root/scripts/bootstrap.sh" "$root/scripts/check-gateway.py" "$tmp/repo/scripts/"
export GATEWAY_FIXTURE="$root/tests/gateway-status.py"
cat > "$tmp/repo/scripts/validate.sh" <<'FAKE'
#!/usr/bin/env bash
printf 'validate %s\n' "$*" >> "$LOG"
[[ "$CASE" != validation ]]
FAKE
cat > "$tmp/bin/kubectl" <<'FAKE'
#!/usr/bin/env bash
printf 'kubectl' >> "$LOG"
printf ' <%s>' "$@" >> "$LOG"
printf '\n' >> "$LOG"
if [[ "$*" == *'rollout status'* && "$CASE" == controller ]]; then exit 42; fi
if [[ "$*" == *'get ingressclass traefik'* && "$CASE" != class ]]; then echo traefik.io/ingress-controller; fi
if [[ "$*" == *'get ingressclass alb'* && "$CASE" != class ]]; then echo ingress.k8s.aws/alb; fi
if [[ "$*" == *'get application bootstrap '* ]]; then
  if [[ "$CASE" == wrong-bootstrap ]]; then echo bootstrap:argocd/other; fi
  if [[ "$CASE" == bootstrap-without-path ]]; then echo bootstrap:; fi
  if [[ "$CASE" == existing-bootstrap ]]; then
    if [[ "$*" == *'--context=kind-selected'* ]]; then echo bootstrap:argocd/local
    else echo bootstrap:argocd/aws; fi
  fi
fi
case "$*" in
  *'get application/root '*)
    if [[ "$CASE" == legacy-query-error ]]; then exit 43; fi
    if [[ "$CASE" == legacy-root ]]; then echo application.argoproj.io/root; fi ;;
  *'get applicationset/staging-apps '*)
    if [[ "$CASE" == legacy-local-set ]]; then echo applicationset.argoproj.io/staging-apps; fi ;;
  *'get applicationset/aws-apps '*)
    if [[ "$CASE" == legacy-aws-set ]]; then echo applicationset.argoproj.io/aws-apps; fi ;;
  *'get applications -o jsonpath='*)
    if [[ "$CASE" == legacy-local-app ]]; then echo staging-demo-api:apps/demo-api/overlays/local; fi
    if [[ "$CASE" == legacy-aws-app ]]; then echo aws-demo-api:apps/demo-api/overlays/aws; fi
    if [[ "$CASE" == previous-app ]]; then echo myfastapiapp:apps/myfastapiapp/overlays/local; fi
    if [[ "$CASE" == unprefixed-app ]]; then echo aws-billing:apps/aws-billing/overlays/aws; fi ;;
esac
if [[ "$*" == *'get gatewayclass '* || "$*" == *'get gateway '* ]]; then
  python3 "$GATEWAY_FIXTURE" "$@"
fi
# Fake read commands succeed even when no resource is found.
exit 0
FAKE
chmod +x "$tmp/repo/scripts/validate.sh" "$tmp/bin/kubectl"
fail() { cat "$tmp/out" >&2; printf 'FAIL: %s\n' "$*" >&2; exit 1; }
run() {
  : > "$tmp/log"; result=0
  CASE="$1" PATH="$tmp/bin:$PATH" LOG="$tmp/log" KUBECONFIG=/ambient \
    bash "$tmp/repo/scripts/bootstrap.sh" "${@:2}" > "$tmp/out" 2>&1 || result=$?
}
for env in local aws; do
  context=selected; bootstrap_file=aws.yaml; platform=aws-load-balancer-controller
  if [[ "$env" == local ]]; then context=kind-selected; bootstrap_file=local.yaml; platform=traefik; fi
  for scenario in success existing-bootstrap unprefixed-app validation controller class unaccepted unresolved stale wrong-bootstrap bootstrap-without-path legacy-root legacy-local-set legacy-aws-set legacy-local-app legacy-aws-app legacy-query-error previous-app; do
    if [[ "$env" == aws && ( "$scenario" == unaccepted || "$scenario" == unresolved || "$scenario" == stale ) ]]; then continue; fi
    run "$scenario" --environment "$env" --context "$context" --kubeconfig '/tmp/selected config'
    if [[ "$scenario" == success || "$scenario" == existing-bootstrap || "$scenario" == unprefixed-app ]]; then
      [[ "$result" == 0 ]] || fail "$env success"
      awk 'NR==1 && !/^validate/ {exit 1} /<apply>/ {if (!controller) exit 1; applies++} /rollout/ {controller=1} END {if (applies!=1) exit 1}' "$tmp/log" || fail ordering
      grep -q "bootstrap/$bootstrap_file>" "$tmp/log" || fail 'wrong environment bootstrap'
      grep -q '<application/bootstrap>' "$tmp/log" || fail 'must wait for the bootstrap Application'
      grep -q "rollout.*deployment/$platform" "$tmp/log" || fail 'platform readiness missing'
      grep -q "validate --environment $env" "$tmp/log" || fail 'validation environment missing'
      if [[ "$env" == aws ]]; then
        grep -q -- '--no-placeholders' "$tmp/log" || fail 'AWS placeholder check missing'
        if grep -q 'traefik\|get pvc' "$tmp/log"; then fail 'AWS must not inspect local storage'; fi
      elif grep -q 'aws-load-balancer-controller' "$tmp/log"; then fail 'local must not inspect AWS'; fi
      while IFS= read -r line; do
        [[ "$line" == *"<--context=$context>"* && "$line" == *'<--kubeconfig=/tmp/selected config>'* ]] || fail forwarding
      done < <(grep '^kubectl' "$tmp/log")
    else
      [[ "$result" != 0 ]] || fail "$env $scenario must fail"
      if grep -q '<apply>' "$tmp/log"; then fail 'failure must stop registration'; fi
      if [[ "$scenario" == legacy-* && "$scenario" != legacy-query-error ]]; then
        grep -q 'docs/registration-conflicts.md' "$tmp/out" || fail 'registration conflict guidance missing'
      fi
      if [[ "$scenario" == previous-app ]]; then
        grep -q 'docs/registration-conflicts.md' "$tmp/out" || fail 'registration conflict guidance missing'
      fi
      if [[ "$scenario" == class ]]; then
        infrastructure_target=local
        if [[ "$env" == aws ]]; then infrastructure_target=aws/dev; fi
        grep -q "infra/environments/$infrastructure_target first" "$tmp/out" || fail 'current infrastructure prerequisite path'
      fi
    fi
  done
done
for arguments in '' '--context selected' '--environment local' '--environment local --context selected' '--environment aws --context kind-selected' '--environment unknown --context selected' '--environment aws --context' '--environment aws --context selected --kubeconfig /one:/two'; do
  # Intentional word splitting: each test case above is a fixed option sequence.
  run missing $arguments
  [[ "$result" != 0 && ! -s "$tmp/log" ]] || fail "reject before validation: $arguments"
done
printf 'GitOps environment selection, bootstrap safety and forwarding tests passed.\n'
