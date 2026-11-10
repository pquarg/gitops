#!/usr/bin/env bash
set -euo pipefail
usage() {
  printf 'Usage: %s --environment local|aws --context CONTEXT [--kubeconfig PATH]\n' "${0##*/}"
  printf 'Validate and register one environment on an existing platform; app readiness is separate.\n'
}
environment=""
context=""
kubeconfig="${KUBECONFIG:-$HOME/.kube/config}"
while (( $# )); do
  case "$1" in
    --environment|--context|--kubeconfig)
      if (( $# < 2 )) || [[ -z "$2" || "$2" == --* ]]; then usage >&2; exit 1; fi
      case "$1" in
        --environment) environment="$2" ;;
        --context) context="$2" ;;
        --kubeconfig) kubeconfig="$2" ;;
      esac
      shift 2 ;;
    --help|-h) usage; exit 0 ;;
    *) usage >&2; exit 1 ;;
  esac
done
if [[ -z "$context" ]]; then usage >&2; exit 1; fi
bootstrap_name=bootstrap
case "$environment" in
  local)
    if [[ "$context" != kind-* ]]; then
      printf 'Error: local registration requires an explicit kind-* context.\n' >&2; exit 1
    fi
    bootstrap_file=local.yaml ;;
  aws)
    if [[ "$context" == kind-* ]]; then
      printf 'Error: AWS registration cannot target a kind context.\n' >&2; exit 1
    fi
    bootstrap_file=aws.yaml ;;
  *) usage >&2; exit 1 ;;
esac
# Select one file consistently instead of an ambient kubeconfig list.
if [[ "$kubeconfig" == *:* ]]; then
  printf 'Error: select one kubeconfig file with --kubeconfig PATH.\n' >&2; exit 1
fi
project_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
validation_args=(--environment "$environment")
if [[ "$environment" == aws ]]; then validation_args+=(--no-placeholders); fi
"$project_root/scripts/validate.sh" "${validation_args[@]}"
kube=(kubectl "--kubeconfig=$kubeconfig" "--context=$context")
"${kube[@]}" get nodes > /dev/null
"${kube[@]}" -n argocd wait --for=condition=Established \
  crd/applications.argoproj.io crd/applicationsets.argoproj.io --timeout=120s
# Conflicting registrations can leave two reconcilers owning one workload.
# Require an ownership review before creating the registration chain.
for legacy in application/root applicationset/staging-apps applicationset/aws-apps; do
  legacy_registration="$("${kube[@]}" -n argocd get "$legacy" --ignore-not-found -o name)"
  if [[ -n "$legacy_registration" ]]; then
    printf 'Error: conflicting registration %s exists; follow docs/registration-conflicts.md first.\n' "$legacy" >&2
    exit 1
  fi
done
registrations="$("${kube[@]}" -n argocd get applications -o jsonpath='{range .items[*]}{.metadata.name}{":"}{.spec.source.path}{"\n"}{end}')"
while IFS=: read -r name path; do
  if [[ "$name" == myfastapiapp || "$path" == apps/myfastapiapp/overlays/* ]]; then
    printf 'Error: conflicting app registration %s exists; follow docs/registration-conflicts.md first.\n' "$name" >&2
    exit 1
  fi
  for prefix in staging aws; do
    if [[ "$name" == "$prefix-"* && "$path" == "apps/${name#"$prefix-"}/overlays/"* ]]; then
      printf 'Error: conflicting Application %s exists; follow docs/registration-conflicts.md first.\n' "$name" >&2
      exit 1
    fi
  done
done <<< "$registrations"
registered_bootstrap="$("${kube[@]}" -n argocd get application "$bootstrap_name" --ignore-not-found -o jsonpath='{.metadata.name}:{.spec.source.path}')"
if [[ -n "$registered_bootstrap" && "$registered_bootstrap" != "$bootstrap_name:argocd/$environment" ]]; then
  printf 'Error: existing bootstrap does not use argocd/%s; inspect it before registration.\n' "$environment" >&2
  exit 1
fi
for deployment in argocd-server argocd-repo-server argocd-applicationset-controller; do
  "${kube[@]}" -n argocd rollout status "deployment/$deployment" --timeout=300s
done
"${kube[@]}" -n argocd rollout status statefulset/argocd-application-controller --timeout=300s
if [[ "$environment" == local ]]; then
  "${kube[@]}" -n traefik rollout status deployment/traefik --timeout=300s
  controller="$("${kube[@]}" get ingressclass traefik -o jsonpath='{.spec.controller}')"
  expected_controller=traefik.io/ingress-controller
else
  "${kube[@]}" -n kube-system rollout status deployment/aws-load-balancer-controller --timeout=300s
  controller="$("${kube[@]}" get ingressclass alb -o jsonpath='{.spec.controller}')"
  expected_controller=ingress.k8s.aws/alb
fi
if [[ "$controller" != "$expected_controller" ]]; then
  infrastructure_target=local
  if [[ "$environment" == aws ]]; then infrastructure_target=aws/dev; fi
  printf 'Error: provision the expected %s ingress controller through infra/environments/%s first.\n' "$environment" "$infrastructure_target" >&2
  exit 1
fi
printf 'Registering %s applications from gitops/main\n' "$environment"
"${kube[@]}" -n argocd apply -f "$project_root/bootstrap/$bootstrap_file"
"${kube[@]}" -n argocd wait --for=jsonpath='{.status.sync.status}'=Synced \
  "application/$bootstrap_name" --timeout=300s
if [[ "$environment" == local ]]; then
  printf 'Registrations synced. Automatic app syncs, migrations and rollouts continue through Argo CD.\n'
else
  printf 'Registrations synced. Review AWS apps and sync them manually in Argo CD.\n'
fi
"${kube[@]}" -n argocd get applications
