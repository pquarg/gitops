#!/usr/bin/env bash
set -euo pipefail
root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/repo/scripts"
cp "$root/scripts/bootstrap.sh" "$tmp/repo/scripts/"
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
if [[ "$*" == *'get application root '* ]]; then
  if [[ "$CASE" == wrong-root ]]; then echo root:argocd/other; fi
  if [[ "$CASE" == root-without-path ]]; then echo root:; fi
  if [[ "$CASE" == existing-root ]]; then
    if [[ "$*" == *'--context=kind-selected'* ]]; then echo root:argocd/local
    else echo root:argocd/aws; fi
  fi
fi
FAKE
chmod +x "$tmp/repo/scripts/validate.sh" "$tmp/bin/kubectl"
fail() { cat "$tmp/out" >&2; printf 'FAIL: %s\n' "$*" >&2; exit 1; }
run() {
  : > "$tmp/log"; result=0
  CASE="$1" PATH="$tmp/bin:$PATH" LOG="$tmp/log" KUBECONFIG=/ambient \
    bash "$tmp/repo/scripts/bootstrap.sh" "${@:2}" > "$tmp/out" 2>&1 || result=$?
}
for env in local aws; do
  context=selected; root_file=aws.yaml; platform=aws-load-balancer-controller
  if [[ "$env" == local ]]; then context=kind-selected; root_file=staging.yaml; platform=traefik; fi
  for scenario in success existing-root validation controller class wrong-root root-without-path; do
    run "$scenario" --environment "$env" --context "$context" --kubeconfig '/tmp/selected config'
    if [[ "$scenario" == success || "$scenario" == existing-root ]]; then
      [[ "$result" == 0 ]] || fail "$env success"
      awk 'NR==1 && !/^validate/ {exit 1} /<apply>/ {if (!controller) exit 1; applies++} /rollout/ {controller=1} END {if (applies!=1) exit 1}' "$tmp/log" || fail ordering
      grep -q "root/$root_file>" "$tmp/log" || fail 'wrong environment root'
      grep -q '<application/root>' "$tmp/log" || fail 'must wait for the root Application'
      grep -q "rollout.*deployment/$platform" "$tmp/log" || fail 'platform readiness missing'
      grep -q "validate --environment $env" "$tmp/log" || fail 'validation environment missing'
      if [[ "$env" == aws ]]; then
        grep -q -- '--ready' "$tmp/log" || fail 'AWS placeholder check missing'
        if grep -q 'traefik\|get pvc' "$tmp/log"; then fail 'AWS must not inspect local storage'; fi
      elif grep -q 'aws-load-balancer-controller' "$tmp/log"; then fail 'local must not inspect AWS'; fi
      while IFS= read -r line; do
        [[ "$line" == *"<--context=$context>"* && "$line" == *'<--kubeconfig=/tmp/selected config>'* ]] || fail forwarding
      done < <(grep '^kubectl' "$tmp/log")
    else
      [[ "$result" != 0 ]] || fail "$env $scenario must fail"
      if grep -q '<apply>' "$tmp/log"; then fail 'failure must stop registration'; fi
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
