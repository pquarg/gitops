#!/usr/bin/env bash
set -euo pipefail
usage() {
  printf 'Usage: %s --environment local|aws|prod --context CONTEXT [--kubeconfig PATH]\n' "${0##*/}"
  printf 'Validate and register one environment on an existing platform; app readiness is separate.\n'
}
environment=""
context=""
kubeconfig="${KUBECONFIG:-$HOME/.kube/config}"
while (( $# )); do
  case "$1" in
    --environment|--context|--kubeconfig)
      if (( $# < 2 )) || [[ -z "$2" || "$2" == --* ]]; then usage >&2; exit 1; fi
      case "$1" in
        --environment) environment="$2" ;;
        --context) context="$2" ;;
        --kubeconfig) kubeconfig="$2" ;;
      esac
      shift 2 ;;
    --help|-h) usage; exit 0 ;;
    *) usage >&2; exit 1 ;;
  esac
done
if [[ -z "$context" ]]; then usage >&2; exit 1; fi
bootstrap_name=bootstrap
case "$environment" in
  local)
    if [[ "$context" != kind-deployment ]]; then
      printf 'Error: local registration requires the kind-deployment context.\n' >&2; exit 1
    fi
    bootstrap_file=local.yaml ;;
  aws|prod)
    if [[ "$context" == kind-* ]]; then
      printf 'Error: AWS registration cannot target a kind context.\n' >&2; exit 1
    fi
    bootstrap_file="$environment.yaml" ;;
  *) usage >&2; exit 1 ;;
esac
# Select one file consistently instead of an ambient kubeconfig list.
if [[ "$kubeconfig" == *:* ]]; then
  printf 'Error: select one kubeconfig file with --kubeconfig PATH.\n' >&2; exit 1
fi
project_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
validation_args=(--environment "$environment")
if [[ "$environment" != local ]]; then validation_args+=(--no-placeholders); fi
"$project_root/scripts/validate.sh" "${validation_args[@]}"
published="$(python3 "$project_root/scripts/check-bootstrap-ref.py" "$environment")"
read -r branch revision <<< "$published"
kube=(kubectl "--kubeconfig=$kubeconfig" "--context=$context")
if [[ "$environment" != local ]]; then
  profile=aws-project
  cluster=deployment-project-dev
  if [[ "$environment" == prod ]]; then
    profile=aws-project-prod
    cluster=deployment-project-prod
  fi
  endpoint="$(aws --profile "$profile" --region eu-north-1 eks describe-cluster \
    --name "$cluster" --query cluster.endpoint --output text)"
  selected="$("${kube[@]}" config view --minify -o jsonpath='{.clusters[0].cluster.server}')"
  if [[ -z "$endpoint" || "$selected" != "$endpoint" ]]; then
    printf 'Error: context does not select %s.\n' "$cluster" >&2
    exit 1
  fi
fi
"${kube[@]}" get nodes > /dev/null
"${kube[@]}" -n argocd wait --for=condition=Established \
  crd/applications.argoproj.io crd/applicationsets.argoproj.io --timeout=120s
# Conflicting registrations can leave two reconcilers owning one workload.
# Require an ownership review before creating the registration chain.
for legacy in application/root applicationset/staging-apps applicationset/aws-apps; do
  legacy_registration="$("${kube[@]}" -n argocd get "$legacy" --ignore-not-found -o name)"
  if [[ -n "$legacy_registration" ]]; then
    printf 'Error: conflicting registration %s exists; follow docs/registration-conflicts.md first.\n' "$legacy" >&2
    exit 1
  fi
done
registrations="$("${kube[@]}" -n argocd get applications -o jsonpath='{range .items[*]}{.metadata.name}{":"}{.spec.source.path}{"\n"}{end}')"
while IFS=: read -r name path; do
  if [[ "$name" == myfastapiapp || "$path" == apps/myfastapiapp/overlays/* ]]; then
    printf 'Error: conflicting app registration %s exists; follow docs/registration-conflicts.md first.\n' "$name" >&2
    exit 1
  fi
  for prefix in staging aws; do
    if [[ "$name" == "$prefix-"* && "$path" == "apps/${name#"$prefix-"}/overlays/"* ]]; then
      printf 'Error: conflicting Application %s exists; follow docs/registration-conflicts.md first.\n' "$name" >&2
      exit 1
    fi
  done
done <<< "$registrations"
registered_bootstrap="$("${kube[@]}" -n argocd get application "$bootstrap_name" --ignore-not-found -o jsonpath='{.metadata.name}:{.spec.source.path}')"
if [[ -n "$registered_bootstrap" && "$registered_bootstrap" != "$bootstrap_name:argocd/$environment" ]]; then
  printf 'Error: existing bootstrap does not use argocd/%s; inspect it before registration.\n' "$environment" >&2
  exit 1
fi
for deployment in argocd-server argocd-repo-server argocd-applicationset-controller; do
  "${kube[@]}" -n argocd rollout status "deployment/$deployment" --timeout=300s
done
"${kube[@]}" -n argocd rollout status statefulset/argocd-application-controller --timeout=300s
if [[ "$environment" == local ]]; then
  "${kube[@]}" -n traefik rollout status deployment/traefik --timeout=300s
  python3 "$project_root/scripts/check-gateway.py" --environment local --context "$context" --kubeconfig "$kubeconfig"
else
  "${kube[@]}" -n kube-system rollout status deployment/aws-load-balancer-controller --timeout=300s
  python3 "$project_root/scripts/check-gateway.py" --environment aws --context "$context" --kubeconfig "$kubeconfig"
fi
printf 'Registering %s applications from %s (%s)\n' "$environment" "$branch" "$revision"
"${kube[@]}" -n argocd apply -f "$project_root/bootstrap/$bootstrap_file"
"${kube[@]}" -n argocd wait --for="jsonpath={.status.sync.revision}=$revision" \
  "application/$bootstrap_name" --timeout=300s
"${kube[@]}" -n argocd wait --for=jsonpath='{.status.sync.status}'=Synced \
  "application/$bootstrap_name" --timeout=300s
for selector in '.spec.generators[0].git.revision' '.spec.template.spec.source.targetRevision'; do
  "${kube[@]}" -n argocd wait --for="jsonpath={$selector}=$branch" \
    applicationset/apps --timeout=300s
done
for overlay in "$project_root"/apps/*/overlays/"$environment"/kustomization.yaml; do
  app_path="${overlay%/overlays/*}"
  app="${app_path##*/}"
  "${kube[@]}" -n argocd wait --for=create "application/$app" --timeout=300s
  "${kube[@]}" -n argocd wait --for="jsonpath={.spec.source.targetRevision}=$branch" \
    "application/$app" --timeout=300s
done
if [[ "$environment" == local ]]; then
  printf 'Registrations synced. Automatic app syncs, migrations and rollouts continue through Argo CD.\n'
else
  printf 'Registrations synced. Review AWS apps and sync them manually in Argo CD.\n'
fi
"${kube[@]}" -n argocd get applications
