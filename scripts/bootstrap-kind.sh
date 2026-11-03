#!/usr/bin/env bash
set -euo pipefail

usage() {
  printf 'Usage: %s [cluster]\n' "${0##*/}"
  printf 'Default: cluster=argocd-postgres; requires infra-local platform and deployment Git credential.\n'
}

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  usage
  exit 0
fi
if (( $# > 1 )); then
  usage >&2
  exit 1
fi

cluster="${1:-argocd-postgres}"
project_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
kube=(kubectl "--context=kind-${cluster}" --namespace=argocd)

# Prevent discovery from starting a second Postgres against the retained data.
legacy_application="$("${kube[@]}" get application myfastapiapp-postgres-application --ignore-not-found -o name)"
legacy_claim="$(kubectl "--context=kind-${cluster}" --namespace=default \
  get pvc myfastapiapp-postgres-pvc --ignore-not-found -o name)"
if [[ -n "$legacy_application" || -n "$legacy_claim" ]]; then
  printf 'Error: migrate myfastapiapp out of default before bootstrapping.\n' >&2
  printf 'Follow docs/repository-upgrade.md#move-myfastapiapp-out-of-default.\n' >&2
  exit 1
fi

legacy_root="$("${kube[@]}" get application staging-bootstrap --ignore-not-found -o name)"
if [[ -n "$legacy_root" ]]; then
  printf 'Error: rename staging-bootstrap before registering staging-root.\n' >&2
  printf 'Follow docs/repository-upgrade.md#rename-the-root-application.\n' >&2
  exit 1
fi

"${kube[@]}" rollout status deployment/argocd-server --timeout=180s
"${kube[@]}" rollout status deployment/argocd-applicationset-controller --timeout=180s
kubectl "--context=kind-${cluster}" get ingressclass traefik > /dev/null
kubectl "--context=kind-${cluster}" --namespace=traefik \
  rollout status deployment/traefik --timeout=180s
printf 'Registering staging applications from Git\n'
"${kube[@]}" apply -f "$project_root/root/staging.yaml"
"${kube[@]}" wait --for=jsonpath='{.status.sync.status}'=Synced \
  application/staging-root --timeout=300s
printf 'Registrations synced. App discovery, migrations and rollouts continue through Argo CD.\n'
"${kube[@]}" get applications
