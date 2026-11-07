#!/usr/bin/env bash
# Compatibility entry point; prefer bootstrap.sh --environment local --context CONTEXT [--kubeconfig PATH].
set -euo pipefail
project_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ "${1:-}" == --help || "${1:-}" == -h ]]; then
  exec "$project_root/scripts/bootstrap.sh" --help
fi
if (( $# > 1 )); then printf 'Usage: %s [cluster]\n' "${0##*/}" >&2; exit 1; fi
exec "$project_root/scripts/bootstrap.sh" --environment local --context "kind-${1:-deployment}" \
  --kubeconfig "${INFRA_LOCAL_KUBECONFIG:-${KUBECONFIG:-$HOME/.kube/config}}"
