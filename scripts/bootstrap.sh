#!/usr/bin/env bash
set -euo pipefail
usage() {
  printf 'Usage: %s --context CONTEXT [--kubeconfig PATH]\n' "${0##*/}"
  printf 'Validate and register applications on an existing platform; app readiness is separate.\n'
}
context=""
kubeconfig="${KUBECONFIG:-$HOME/.kube/config}"
while (( $# )); do
  case "$1" in
    --context|--kubeconfig)
      if (( $# < 2 )) || [[ -z "$2" || "$2" == --* ]]; then usage >&2; exit 1; fi
      case "$1" in --context) context="$2" ;; --kubeconfig) kubeconfig="$2" ;; esac
      shift 2 ;;
    --help|-h) usage; exit 0 ;;
    *) usage >&2; exit 1 ;;
  esac
done
if [[ -z "$context" ]]; then usage >&2; exit 1; fi
# One file, not an ambient list that the caller may interpret differently.
if [[ "$kubeconfig" == *:* ]]; then
  printf 'Error: select one kubeconfig file with --kubeconfig PATH.\n' >&2; exit 1
fi
project_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
"$project_root/scripts/validate.sh"
kube=(kubectl "--kubeconfig=$kubeconfig" "--context=$context")
"${kube[@]}" get nodes > /dev/null
"${kube[@]}" -n argocd wait --for=condition=Established \
  crd/applications.argoproj.io crd/applicationsets.argoproj.io --timeout=120s
# Prevent discovery from starting a second Postgres against the retained data.
legacy_application="$("${kube[@]}" -n argocd get application myfastapiapp-postgres-application --ignore-not-found -o name)"
legacy_claim="$("${kube[@]}" --namespace=default \
  get pvc myfastapiapp-postgres-pvc --ignore-not-found -o name)"
if [[ -n "$legacy_application" || -n "$legacy_claim" ]]; then
  printf 'Error: migrate myfastapiapp out of default before bootstrapping.\n' >&2
  printf 'Follow docs/repository-upgrade.md#move-myfastapiapp-out-of-default.\n' >&2
  exit 1
fi

legacy_root="$("${kube[@]}" -n argocd get application staging-bootstrap --ignore-not-found -o name)"
if [[ -n "$legacy_root" ]]; then
  printf 'Error: rename staging-bootstrap before registering staging-root.\n' >&2
  printf 'Follow docs/repository-upgrade.md#rename-the-root-application.\n' >&2
  exit 1
fi


for deployment in argocd-server argocd-repo-server argocd-applicationset-controller; do
  "${kube[@]}" -n argocd rollout status "deployment/$deployment" --timeout=300s
done
"${kube[@]}" -n argocd rollout status statefulset/argocd-application-controller --timeout=300s
"${kube[@]}" -n traefik rollout status deployment/traefik --timeout=300s
controller="$("${kube[@]}" get ingressclass traefik -o jsonpath='{.spec.controller}')"
if [[ "$controller" != traefik.io/ingress-controller ]]; then
  printf 'Error: infra-local must provision IngressClass traefik.\n' >&2; exit 1
fi
printf 'Registering applications from deploy-local/main\n'
"${kube[@]}" -n argocd apply -f "$project_root/root/staging.yaml"
"${kube[@]}" -n argocd wait --for=jsonpath='{.status.sync.status}'=Synced \
  application/staging-root --timeout=300s
printf 'Registrations synced. Automatic app syncs, migrations and rollouts continue through Argo CD.\n'
"${kube[@]}" -n argocd get applications
