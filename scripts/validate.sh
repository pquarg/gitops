#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$project_root"
for required_command in kubectl kubeconform; do
  if ! command -v "$required_command" > /dev/null; then
    printf 'Error: %s is required; see docs/validation.md.\n' "$required_command" >&2
    exit 1
  fi
done

while IFS= read -r -d '' script; do
  bash -n "$script"
done < <(find scripts apps -type f -name '*.sh' -print0)

render_dir="$(mktemp -d)"
trap 'rm -rf -- "$render_dir"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
shopt -s nullglob
app_directories=(apps/*/)
if (( ${#app_directories[@]} == 0 )); then
  printf 'Error: no app deployment entry points found under apps/.\n' >&2
  exit 1
fi

for app_directory in "${app_directories[@]}"; do
  app_directory="${app_directory%/}"
  app_name="${app_directory#apps/}"
  # Apps use the directory name for their namespace and Application naming.
  if (( ${#app_name} > 63 )) || [[ ! "$app_name" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]]; then
    printf 'Error: app directory %s must be a DNS label of at most 63 characters.\n' "$app_name" >&2
    exit 1
  fi
  case "$app_name" in
    argocd|traefik|default|bootstrap|root|kube-*)
      printf 'Error: app directory %s conflicts with a reserved namespace or registration.\n' "$app_name" >&2
      exit 1
      ;;
  esac
  if [[ ! -f "$app_directory/kustomization.yaml" ]]; then
    printf 'Error: %s needs a root kustomization.yaml for deployment.\n' "$app_directory" >&2
    exit 1
  fi
  printf 'Rendering %s\n' "$app_directory"
  kubectl kustomize "$app_directory" > "$render_dir/app-${app_name}.yaml"
done
kubectl kustomize argocd > "$render_dir/registrations.yaml"
cp root/staging.yaml "$render_dir/root.yaml"

# Fail on unknown kinds as well as invalid resources. Add a schema source when
# introducing CRDs; never silently skip resources whose schemas are missing.
kubeconform -strict -summary \
  -kubernetes-version "${KUBERNETES_VERSION:-1.36.0}" \
  -schema-location default \
  -schema-location 'https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json' \
  "$render_dir"/*.yaml

printf 'Deployment configuration checks passed.\n'
