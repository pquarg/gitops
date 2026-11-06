#!/usr/bin/env bash
set -euo pipefail
root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/repo/scripts"
cp "$root/scripts/bootstrap"*.sh "$tmp/repo/scripts/"
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
if [[ "$CASE" == legacy && "$*" == *'get pvc '* ]]; then echo pvc/old; fi
FAKE
chmod +x "$tmp/repo/scripts/validate.sh" "$tmp/bin/kubectl"
fail() { cat "$tmp/out" >&2; printf 'FAIL: %s\n' "$*" >&2; exit 1; }
run() {
  : > "$tmp/log"
  result=0
  CASE="$1" PATH="$tmp/bin:$PATH" LOG="$tmp/log" KUBECONFIG=/ambient \
    bash "$tmp/repo/scripts/bootstrap.sh" "${@:2}" > "$tmp/out" 2>&1 || result=$?
}
for scenario in success validation controller class; do
  run "$scenario" --context selected --kubeconfig '/tmp/selected config'
  if [[ "$scenario" == success ]]; then
    [[ "$result" == 0 ]] || fail success
    awk 'NR==1 && !/^validate/ {exit 1} /<apply>/ {if (!controller) exit 1; applies++} /rollout/ {controller=1} END {if (applies!=1) exit 1}' "$tmp/log" || fail ordering
    while IFS= read -r line; do
      [[ "$line" == *'<--context=selected>'* && "$line" == *'<--kubeconfig=/tmp/selected config>'* ]] || fail forwarding
    done < <(grep '^kubectl' "$tmp/log")
  else
    [[ "$result" != 0 ]] || fail "$scenario must fail"
    if grep -q '<apply>' "$tmp/log"; then fail 'failure must stop registration'; fi
  fi
done
run missing
[[ "$result" != 0 && ! -s "$tmp/log" ]] || fail 'context required before validation'
run incomplete --context
[[ "$result" != 0 && ! -s "$tmp/log" ]] || fail 'missing option value'
if [[ "$root" == *deploy-local ]]; then
  run legacy --context selected
  [[ "$result" != 0 ]] || fail 'legacy PVC must prevent registration'
fi
# Old names must forward to the common implementation and preserve selection.
: > "$tmp/log"
if [[ "$root" == *deploy-local ]]; then
  CASE=success PATH="$tmp/bin:$PATH" LOG="$tmp/log" INFRA_LOCAL_KUBECONFIG='/tmp/wrapper config' \
    bash "$tmp/repo/scripts/bootstrap-kind.sh" selected > "$tmp/out" 2>&1 || fail wrapper
  grep -q '<--context=kind-selected>' "$tmp/log" || fail 'kind wrapper context'
else
  CASE=success PATH="$tmp/bin:$PATH" LOG="$tmp/log" KUBECONFIG='/tmp/wrapper config' \
    bash "$tmp/repo/scripts/bootstrap-eks.sh" selected > "$tmp/out" 2>&1 || fail wrapper
  grep -q '<--context=selected>' "$tmp/log" || fail 'EKS wrapper context'
fi
grep -q '<--kubeconfig=/tmp/wrapper config>' "$tmp/log" || fail 'wrapper kubeconfig'
printf 'Deployment bootstrap ordering and forwarding tests passed.\n'
