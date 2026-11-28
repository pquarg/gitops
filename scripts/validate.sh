#!/usr/bin/env bash
set -euo pipefail
usage() {
  printf 'Usage: %s [--environment local|aws|prod] [--no-placeholders]\n' "${0##*/}"
  printf 'Validate all environments by default; --no-placeholders also rejects deployment placeholders.\n'
  printf 'Legacy --ready is an alias for --no-placeholders; neither checks runtime readiness.\n'
}
environment=""
no_placeholders=false
while (( $# )); do
  case "$1" in
    --environment)
      if (( $# < 2 )); then usage >&2; exit 1; fi
      case "$2" in local|aws|prod) environment="$2" ;; *) usage >&2; exit 1 ;; esac
      shift 2 ;;
    --no-placeholders|--ready) no_placeholders=true; shift ;;
    --help|-h) usage; exit 0 ;;
    *) usage >&2; exit 1 ;;
  esac
done
project_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$project_root"
for required_command in kubectl kubeconform python3; do
  if ! command -v "$required_command" > /dev/null; then
    printf 'Error: %s is required; see docs/validation.md.\n' "$required_command" >&2; exit 1
  fi
done
bash tests/bootstrap.sh
python3 -m unittest discover -s scripts/tests
python3 -m unittest discover -s tests
while IFS= read -r -d '' script; do bash -n "$script"; done < <(find scripts apps tests -type f -name '*.sh' -print0)
render_dir="$(mktemp -d)"
trap 'rm -rf -- "$render_dir"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
shopt -s nullglob
app_directories=(apps/*/)
if (( ${#app_directories[@]} == 0 )); then printf 'Error: no apps under apps/.\n' >&2; exit 1; fi
# Validate shared app names before deriving namespace and Application names.
for app_directory in "${app_directories[@]}"; do
  app_name="${app_directory#apps/}"; app_name="${app_name%/}"
  if (( ${#app_name} > 63 )) || [[ ! "$app_name" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]]; then
    printf 'Error: app name %s must be a DNS label of at most 63 characters.\n' "$app_name" >&2; exit 1
  fi
  case "$app_name" in
    argocd|traefik|default|apps|bootstrap|root|kube-*) printf 'Error: reserved app name %s.\n' "$app_name" >&2; exit 1 ;;
  esac
  if [[ ! -f "$app_directory/base/kustomization.yaml" ]]; then
    printf 'Error: %s needs base/kustomization.yaml.\n' "$app_directory" >&2; exit 1
  fi
  overlays=("$app_directory"/overlays/*/)
  if (( ${#overlays[@]} == 0 )); then printf 'Error: %s has no environment overlays.\n' "$app_directory" >&2; exit 1; fi
  for overlay in "${overlays[@]}"; do
    overlay_name="${overlay%/}"; overlay_name="${overlay_name##*/}"
    case "$overlay_name" in local|aws|prod) ;; *) printf 'Error: unknown overlay %s.\n' "$overlay" >&2; exit 1 ;; esac
    if [[ ! -f "$overlay/kustomization.yaml" ]]; then printf 'Error: %s needs kustomization.yaml.\n' "$overlay" >&2; exit 1; fi
  done
done
environments=(local aws prod)
if [[ -n "$environment" ]]; then environments=("$environment"); fi
for selected in "${environments[@]}"; do
  entries=(apps/*/overlays/"$selected"/kustomization.yaml)
  if (( ${#entries[@]} == 0 )); then printf 'Error: no %s overlays found.\n' "$selected" >&2; exit 1; fi
  for entry in "${entries[@]}"; do
    overlay="${entry%/kustomization.yaml}"
    app_name="${overlay#apps/}"; app_name="${app_name%%/*}"
    printf 'Rendering %s\n' "$overlay"
    kubectl kustomize "$overlay" > "$render_dir/$selected-$app_name.yaml"
  done
  kubectl kustomize "argocd/$selected" > "$render_dir/$selected-registrations.yaml"
  cp "bootstrap/$selected.yaml" "$render_dir/$selected-bootstrap.yaml"
done
if [[ "$no_placeholders" == true ]]; then
  python3 - "$render_dir" <<'PY'
from pathlib import Path
import re, sys
unresolved=[]
for manifest in sorted(Path(sys.argv[1]).glob('*.yaml')):
    for number,line in enumerate(manifest.read_text().splitlines(),1):
        if re.search(r'REPLACE_[A-Z_]+|(?:^|[.\s])example\.(?:com|net|org)\b',line):
            unresolved.append(f'{manifest.name}:{number}: {line.strip()}')
if unresolved:
    raise SystemExit('Replace deployment placeholders before bootstrap or sync:\n'+'\n'.join(unresolved))
PY
fi
python3 tests/manifests.py
kubeconform -strict -summary \
  -kubernetes-version "${KUBERNETES_VERSION:-1.36.0}" \
  -schema-location default \
  -schema-location "$project_root/schemas/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json" \
  -schema-location 'https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json' \
  "$render_dir"/*.yaml
printf 'GitOps configuration checks passed; deployment health is separate.\n'
