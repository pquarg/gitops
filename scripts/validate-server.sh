#!/usr/bin/env bash
set -euo pipefail

usage() {
  printf 'Usage: %s <app> [cluster]\n' "${0##*/}"
  printf 'Default: cluster=argocd-postgres; requires kubectl, Python 3 and the app namespace.\n'
  printf 'Validates updates and new Argo CD hooks using server dry-run; no resources are persisted.\n'
}

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  usage
  exit 0
fi
if (( $# < 1 || $# > 2 )); then
  usage >&2
  exit 1
fi

app="$1"
context="kind-${2:-argocd-postgres}"
project_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
if (( ${#app} > 63 )) || [[ ! "$app" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]] || \
  [[ ! -f "$project_root/apps/$app/kustomization.yaml" ]]; then
  printf 'Error: %s must name an app with a root kustomization.yaml under apps/.\n' "$app" >&2
  exit 1
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
kubectl patch --local -k "$project_root/apps/$app" --type=merge -p '{}' -o json |
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

kube = ["kubectl", "--context=" + sys.argv[1], "--namespace=" + sys.argv[2]]
try:
    for verb, items in (("apply", workloads), ("create", hooks)):
        if items:
            manifest = {"apiVersion": "v1", "kind": "List", "items": items}
            subprocess.run(kube + [verb, "--dry-run=server", "-f", "-"],
                           input=json.dumps(manifest), text=True, check=True)
except subprocess.CalledProcessError as error:
    raise SystemExit(error.returncode)
' "$context" "$app"

printf 'Server dry-run checks passed.\n'
