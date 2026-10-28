#!/usr/bin/env bash
set -euo pipefail

usage() {
  printf 'Usage: %s [cluster]\n' "${0##*/}"
  printf 'Default: cluster=argocd-postgres; requires Argo CD and its Git credential.\n'
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

"${kube[@]}" rollout status deployment/argocd-server --timeout=180s
printf 'Registering staging applications from Git\n'
"${kube[@]}" apply -f "$project_root/bootstrap/staging.yaml"
"${kube[@]}" wait --for=jsonpath='{.status.sync.status}'=Synced \
  application/staging-bootstrap --timeout=300s
printf 'Registrations synced. App migrations and rollouts continue through Argo CD.\n'
"${kube[@]}" get applications
