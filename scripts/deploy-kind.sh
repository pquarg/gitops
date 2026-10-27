#!/usr/bin/env bash
set -euo pipefail

usage() {
  printf 'Usage: %s [cluster]\n' "${0##*/}"
  printf 'Default: cluster=argocd-postgres; namespace=default; manifests=apps/myfastapiapp/overlays/staging\n'
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
overlay="$project_root/apps/myfastapiapp/overlays/staging"
kube=(kubectl "--context=$context" --namespace=default)

umask 077
render_dir="$(mktemp -d)"
trap 'rm -rf -- "$render_dir"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# kubectl does not execute Argo hooks or honor sync waves. Split the rendered
# staging resources so bootstrap uses the same database -> migration -> API order.
"${kube[@]}" create --dry-run=client -k "$overlay" -o json > "$render_dir/resources.json"
python3 - "$render_dir" <<'PY'
import json
from pathlib import Path
import sys

directory = Path(sys.argv[1])
# kubectl create can print a stream of JSON objects instead of one List.
content = (directory / "resources.json").read_text()
decoder = json.JSONDecoder()
resources = []
while content.strip():
    content = content.lstrip()
    resource, end = decoder.raw_decode(content)
    content = content[end:]
    resources.extend(resource["items"] if resource.get("kind") == "List" else [resource])
targets = {
    "migration": ("Job", "myfastapiapp-migrate"),
    "app": ("Deployment", "myfastapiapp-deployment"),
}
for filename, identity in targets.items():
    matches = [
        resource for resource in resources
        if (resource["kind"], resource["metadata"]["name"]) == identity
    ]
    if len(matches) != 1:
        raise SystemExit(f"Expected exactly one {identity[0]}/{identity[1]}")
    (directory / f"{filename}.json").write_text(json.dumps(matches[0]))
bootstrap = [
    resource for resource in resources
    if (resource["kind"], resource["metadata"]["name"]) not in targets.values()
]
(directory / "bootstrap.json").write_text(json.dumps({
    "apiVersion": "v1", "kind": "List", "items": bootstrap,
}))
PY

printf 'Bootstrapping staging in context %s, namespace default\n' "$context"
"${kube[@]}" apply -f "$render_dir/bootstrap.json"

printf 'Waiting for Postgres to become ready\n'
"${kube[@]}" rollout status statefulset/myfastapiapp-postgres-statefulset --timeout=180s

printf 'Running database migrations before starting the API\n'
"${kube[@]}" delete job/myfastapiapp-migrate --ignore-not-found --wait=true
"${kube[@]}" create -f "$render_dir/migration.json"
if ! "${kube[@]}" wait --for=condition=complete job/myfastapiapp-migrate --timeout=330s; then
  "${kube[@]}" logs job/myfastapiapp-migrate >&2 || true
  printf 'Error: migration failed; the API Deployment has not been applied.\n' >&2
  exit 1
fi

"${kube[@]}" apply -f "$render_dir/app.json"
printf 'Waiting for myfastapiapp-deployment to become ready\n'
"${kube[@]}" rollout status deployment/myfastapiapp-deployment --timeout=180s

printf 'Deployment ready. With local Ingress set up, open:\n'
printf 'http://myfastapiapp.localhost/api/v1/docs/\n'
printf 'For direct access through port-forward, run:\n'
printf 'kubectl --context=%s --namespace=default port-forward service/myfastapiapp-service 8000:80\n' "$context"
