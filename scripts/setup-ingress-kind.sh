#!/usr/bin/env bash
set -euo pipefail

usage() {
  printf 'Usage: %s [cluster]\n' "${0##*/}"
  printf 'Default: cluster=argocd-postgres; requires Argo CD in namespace argocd\n'
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
nodes="$(kind get nodes --name "$cluster")"
node="${nodes%%$'\n'*}"

if [[ -z "$node" ]]; then
  printf 'Error: kind cluster %s has no nodes.\n' "$cluster" >&2
  exit 1
fi

printf 'Installing the shared Traefik controller through Argo CD\n'
kubectl --context="$context" apply -f "$project_root/argocd/traefik.yaml"
kubectl --context="$context" --namespace=argocd wait \
  --for=jsonpath='{.status.sync.status}'=Synced application/traefik --timeout=180s
kubectl --context="$context" --namespace=traefik wait \
  --for=jsonpath='{.spec.type}'=NodePort service/traefik --timeout=180s
kubectl --context="$context" --namespace=traefik \
  rollout status deployment/traefik --timeout=180s

printf 'Exposing the shared HTTP entry point on 127.0.0.1:80\n'
KIND_NODE="$node" docker compose --project-name "kind-ingress-${cluster}" \
  -f "$project_root/kind/compose.yaml" up -d

printf 'Applying the app Ingress for the initial local setup\n'
kubectl --context="$context" --namespace=default apply -f "$project_root/myfastapiapp/ingress.yaml"
kubectl --context="$context" --namespace=default wait \
  --for=jsonpath='{.status.loadBalancer.ingress[0].ip}'=127.0.0.1 \
  ingress/myfastapiapp-ingress --timeout=60s

printf 'Open http://myfastapiapp.localhost/api/v1/docs/\n'
printf 'Commit and push this deploy repository so Argo CD manages the app route.\n'
