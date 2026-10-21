#!/usr/bin/env bash
set -euo pipefail

usage() {
  printf 'Usage: %s [cluster]\n' "${0##*/}"
  printf 'Default: cluster=argocd-demo; namespace=default\n'
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

cluster="${1:-argocd-demo}"
context="kind-${cluster}"
project_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

printf 'Deploying to context %s, namespace default\n' "$context"
kubectl --context="$context" --namespace=default apply -k "$project_root/myfastapiapp"

printf 'Waiting for myfastapiapp-deployment to become ready\n'
kubectl --context="$context" --namespace=default \
  rollout status deployment/myfastapiapp-deployment --timeout=120s

printf 'Deployment ready. With local Ingress set up, open:\n'
printf 'http://myfastapiapp.localhost/api/v1/docs/\n'
printf 'For direct access through port-forward, run:\n'
printf 'kubectl --context=%s --namespace=default port-forward service/myfastapiapp-service 8000:80\n' "$context"
