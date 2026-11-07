#!/usr/bin/env bash
set -euo pipefail

usage() {
  printf 'Usage: %s [cluster] [backup-directory]\n' "${0##*/}"
  printf 'Defaults: cluster=deployment; backup-directory=$HOME/.local/share/myfastapiapp/backups\n'
  printf 'Namespace defaults to myfastapiapp; override with NAMESPACE. Uses the Postgres Pod tools.\n'
}

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  usage
  exit 0
fi

if (( $# > 2 )); then
  printf 'Error: expected at most 2 arguments (cluster and backup-directory).\n' >&2
  usage >&2
  exit 1
fi

if ! command -v kubectl > /dev/null; then
  printf 'Error: kubectl is required.\n' >&2
  exit 1
fi

cluster="${1:-deployment}"
context="kind-${cluster}"
backup_dir="${2:-$HOME/.local/share/myfastapiapp/backups}"
namespace="${NAMESPACE:-myfastapiapp}"
postgres_pod="myfastapiapp-postgres-statefulset-0"
kube=(kubectl "--context=$context" "--namespace=$namespace")

printf 'Backing up staging in context %s, namespace %s, database myfastapiapp\n' "$context" "$namespace"
"${kube[@]}" wait --for=condition=Ready "pod/$postgres_pod" --timeout=30s

umask 077
mkdir -p -- "$backup_dir"
temporary_file="$(mktemp "$backup_dir/myfastapiapp-$(date -u +%Y%m%dT%H%M%SZ).XXXXXX")"

cleanup() {
  rm -f -- "$temporary_file"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

if ! "${kube[@]}" exec "$postgres_pod" -c postgres -- \
  pg_dump --username=myfastapiapp --dbname=myfastapiapp --no-password --format=custom \
  > "$temporary_file"; then
  printf 'Error: pg_dump failed; removing the incomplete backup.\n' >&2
  exit 1
fi

if [[ ! -s "$temporary_file" ]]; then
  printf 'Error: pg_dump produced an empty backup.\n' >&2
  exit 1
fi

printf 'Checking that pg_restore can read the full archive\n'
# Without --dbname, pg_restore renders SQL rather than connecting to a database.
if ! "${kube[@]}" exec -i "$postgres_pod" -c postgres -- \
  pg_restore --file=/dev/null < "$temporary_file"; then
  printf 'Error: archive read check failed; removing the incomplete backup.\n' >&2
  exit 1
fi

backup_file="${temporary_file}.dump"
mv -- "$temporary_file" "$backup_file"
printf 'Backup saved: %s\n' "$backup_file"
printf 'Archive read check passed. A restore into a disposable database is still needed to verify recovery.\n'
