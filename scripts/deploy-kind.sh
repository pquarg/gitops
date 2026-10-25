#!/usr/bin/env bash
set -euo pipefail

usage() {
  printf 'Usage: %s [cluster]\n' "${0##*/}"
  printf 'Default: cluster=argocd-postgres; namespace=default; manifests=overlays/kind-postgres\n'
}

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  usage
  exit 0
fi

if (( $# > 1 )); then
  printf 'Error: expected at most 1 argument (cluster), received %s.\n' "$#" >&2
  usage >&2
  exit 1
fi

cluster="${1:-argocd-postgres}"
context="kind-${cluster}"
project_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

printf 'Deploying to context %s, namespace default\n' "$context"
kubectl --context="$context" --namespace=default apply -k "$project_root/overlays/kind-postgres"

printf 'Waiting for Postgres to become ready\n'
kubectl --context="$context" --namespace=default \
  rollout status statefulset/myfastapiapp-postgres-statefulset --timeout=180s

printf 'Waiting for myfastapiapp-deployment to become ready\n'
kubectl --context="$context" --namespace=default \
  rollout status deployment/myfastapiapp-deployment --timeout=180s

printf 'Deployment ready. With local Ingress set up, open:\n'
printf 'http://myfastapiapp.localhost/api/v1/docs/\n'
printf 'For direct access through port-forward, run:\n'
printf 'kubectl --context=%s --namespace=default port-forward service/myfastapiapp-service 8000:80\n' "$context"
