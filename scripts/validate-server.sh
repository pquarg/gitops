#!/usr/bin/env bash
set -euo pipefail
usage() {
  printf 'Usage: %s APP --environment local|aws|prod --context CONTEXT [--kubeconfig PATH]\n' "${0##*/}"
  printf 'Server dry-run only; requires the app namespace and cluster CRDs.\n'
}
if [[ "${1:-}" == --help || "${1:-}" == -h ]]; then usage; exit 0; fi
if (( $# < 1 )); then usage >&2; exit 1; fi
app="$1"; shift
environment=""; context=""; kubeconfig="${KUBECONFIG:-$HOME/.kube/config}"
while (( $# )); do
  case "$1" in
    --environment|--context|--kubeconfig)
      if (( $# < 2 )) || [[ -z "$2" || "$2" == --* ]]; then usage >&2; exit 1; fi
      case "$1" in --environment) environment="$2" ;; --context) context="$2" ;; --kubeconfig) kubeconfig="$2" ;; esac
      shift 2 ;;
    *) usage >&2; exit 1 ;;
  esac
done
case "$environment" in local|aws|prod) ;; *) usage >&2; exit 1 ;; esac
if [[ -z "$context" || "$kubeconfig" == *:* ]]; then usage >&2; exit 1; fi
if [[ "$environment" == local && "$context" != kind-* ]] || [[ "$environment" != local && "$context" == kind-* ]]; then
  printf 'Error: environment and context disagree.\n' >&2; exit 1
fi
project_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
overlay="$project_root/apps/$app/overlays/$environment"
if (( ${#app} > 63 )) || [[ ! "$app" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]] || [[ ! -f "$overlay/kustomization.yaml" ]]; then
  printf 'Error: select an app with an overlay for this environment.\n' >&2; exit 1
fi
for required_command in kubectl python3; do
  if ! command -v "$required_command" > /dev/null; then
    printf 'Error: %s is required.\n' "$required_command" >&2
    exit 1
  fi
done

printf 'Validating app %s in context %s, namespace %s\n' "$app" "$context" "$app"
# An empty local patch converts the complete Kustomize output to JSON without
# querying or changing cluster resources. kubectl prints one JSON object per resource.
kubectl patch --local -k "$overlay" --type=merge -p '{}' -o json |
  python3 -c '
import json
import subprocess
import sys

remaining = sys.stdin.read().lstrip()
decoder = json.JSONDecoder()
resources = []
while remaining:
    resource, offset = decoder.raw_decode(remaining)
    resources.extend(resource["items"] if resource.get("kind") == "List" else [resource])
    remaining = remaining[offset:].lstrip()

workloads = []
hooks = []
for resource in resources:
    metadata = resource["metadata"]
    if "argocd.argoproj.io/hook" in (metadata.get("annotations") or {}):
        # Argo CD recreates named hooks on sync. Validate creation under a fresh
        # generated name so the retained Job template is never patched.
        name = metadata.pop("name", None)
        if name:
            metadata["generateName"] = name + "-preflight-"
        hooks.append(resource)
    else:
        workloads.append(resource)

kube = ["kubectl", "--kubeconfig=" + sys.argv[3], "--context=" + sys.argv[1], "--namespace=" + sys.argv[2]]
try:
    for verb, items in (("apply", workloads), ("create", hooks)):
        if items:
            manifest = {"apiVersion": "v1", "kind": "List", "items": items}
            subprocess.run(kube + [verb, "--dry-run=server", "-f", "-"],
                           input=json.dumps(manifest), text=True, check=True)
except subprocess.CalledProcessError as error:
    raise SystemExit(error.returncode)
' "$context" "$app" "$kubeconfig"

printf 'Server dry-run checks passed.\n'
