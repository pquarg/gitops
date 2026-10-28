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

printf 'Waiting for the shared Traefik controller managed by Argo CD\n'
kubectl --context="$context" --namespace=argocd wait \
  --for=jsonpath='{.status.sync.status}'=Synced application/traefik --timeout=180s
kubectl --context="$context" --namespace=traefik wait \
  --for=jsonpath='{.spec.type}'=NodePort service/traefik --timeout=180s
kubectl --context="$context" --namespace=traefik \
  rollout status deployment/traefik --timeout=180s

direct_mapping=false
while IFS= read -r candidate_node; do
  port_bindings="$(docker inspect --format '{{range (index .HostConfig.PortBindings "30080/tcp")}}{{.HostIp}}:{{.HostPort}}{{"\n"}}{{end}}' "$candidate_node")"
  if [[ "$port_bindings" == "127.0.0.1:80" ]]; then
    direct_mapping=true
    break
  fi
done <<< "$nodes"

if [[ "$direct_mapping" == true ]]; then
  printf 'kind maps 127.0.0.1:80 directly to Traefik; no gateway container is needed.\n'
else
  printf 'Existing cluster has no direct localhost mapping; starting the legacy gateway.\n'
  KIND_NODE="$node" docker compose --project-name "kind-ingress-${cluster}" \
    -f "$project_root/kind/legacy/compose.yaml" up -d
fi
printf 'Shared ingress is ready. Each app supplies its own hostname and Ingress through Git.\n'
