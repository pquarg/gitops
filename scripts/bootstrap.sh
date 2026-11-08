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
root_name=root
case "$environment" in
  local)
    if [[ "$context" != kind-* ]]; then
      printf 'Error: local registration requires an explicit kind-* context.\n' >&2; exit 1
    fi
    root_file=staging.yaml ;;
  aws)
    if [[ "$context" == kind-* ]]; then
      printf 'Error: AWS registration cannot target a kind context.\n' >&2; exit 1
    fi
    root_file=aws.yaml ;;
  *) usage >&2; exit 1 ;;
esac
# Select one file consistently instead of an ambient kubeconfig list.
if [[ "$kubeconfig" == *:* ]]; then
  printf 'Error: select one kubeconfig file with --kubeconfig PATH.\n' >&2; exit 1
fi
project_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
validation_args=(--environment "$environment")
if [[ "$environment" == aws ]]; then validation_args+=(--ready); fi
"$project_root/scripts/validate.sh" "${validation_args[@]}"
kube=(kubectl "--kubeconfig=$kubeconfig" "--context=$context")
"${kube[@]}" get nodes > /dev/null
"${kube[@]}" -n argocd wait --for=condition=Established \
  crd/applications.argoproj.io crd/applicationsets.argoproj.io --timeout=120s
registered_root="$("${kube[@]}" -n argocd get application "$root_name" --ignore-not-found -o jsonpath='{.metadata.name}:{.spec.source.path}')"
if [[ -n "$registered_root" && "$registered_root" != "$root_name:argocd/$environment" ]]; then
  printf 'Error: existing root does not use argocd/%s; inspect it before registration.\n' "$environment" >&2
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
"${kube[@]}" -n argocd apply -f "$project_root/root/$root_file"
"${kube[@]}" -n argocd wait --for=jsonpath='{.status.sync.status}'=Synced \
  "application/$root_name" --timeout=300s
if [[ "$environment" == local ]]; then
  printf 'Registrations synced. Automatic app syncs, migrations and rollouts continue through Argo CD.\n'
else
  printf 'Registrations synced. Review AWS apps and sync them manually in Argo CD.\n'
fi
"${kube[@]}" -n argocd get applications
