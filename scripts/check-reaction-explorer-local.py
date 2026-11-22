#!/usr/bin/env python3
"""Probe the external local DB from a Pod with the selected app image and Secret."""
import argparse
import copy
import json
import os
from pathlib import Path
import subprocess
import uuid

ROOT = Path(__file__).resolve().parents[1]
PROBE = r"""
from backend import dashboard_data as data
try:
    with data.connect() as conn:
        assert (conn.info.user, conn.info.dbname) == ('dashboard', 'reaction_warehouse')
        assert conn.execute("SELECT rolsuper OR rolcreatedb OR rolcreaterole OR rolreplication OR rolbypassrls FROM pg_roles WHERE rolname=current_user").fetchone()['?column?'] is False
        assert not conn.execute("SELECT 1 FROM pg_auth_members WHERE member=(SELECT oid FROM pg_roles WHERE rolname=current_user)").fetchone()
        assert data.snapshots(conn), 'No modeled snapshot'
        assert conn.execute('SELECT count(*) AS n FROM analytics.solvent_comparisons').fetchone()['n'] == 8640
        assert conn.execute("SELECT has_schema_privilege(current_user, 'public', 'CREATE') OR has_schema_privilege(current_user, 'analytics', 'CREATE') AS writable").fetchone()['writable'] is False
        assert not conn.execute("SELECT 1 FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname IN ('public','analytics') AND c.relkind IN ('r','p','v','m','f') AND has_table_privilege(current_user,c.oid,'INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER')").fetchone()
except Exception:
    raise SystemExit('Dashboard Pod probe failed; check deployment login, permissions and data preparation.') from None
print('Dashboard Pod connectivity, read-only privileges and 8,640 modeled pairs passed.')
"""


def make_job(pod_spec, name):
    spec = copy.deepcopy(pod_spec)
    spec['restartPolicy'] = 'Never'
    container = spec['containers'][0]
    container['name'] = 'check'
    container['command'] = ['/app/.venv/bin/python', '-c', PROBE]
    # Only the connection Secret is needed; no ConfigMap or deployed API required.
    for key in ('args', 'ports', 'readinessProbe', 'livenessProbe', 'startupProbe'):
        container.pop(key, None)
    return {
        'apiVersion': 'batch/v1', 'kind': 'Job',
        'metadata': {'name': name, 'namespace': 'reaction-explorer'},
        'spec': {'backoffLimit': 0, 'activeDeadlineSeconds': 90,
                 'template': {'spec': spec}},
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--environment', required=True, choices=['local'])
    parser.add_argument('--context', required=True)
    parser.add_argument('--kubeconfig', default=os.environ.get('KUBECONFIG', str(Path.home() / '.kube/config')))
    args = parser.parse_args()
    if not args.context.startswith('kind-'):
        parser.error('Local database checks require an explicit kind-* context')
    if ':' in args.kubeconfig:
        parser.error('Select one kubeconfig file with --kubeconfig')
    # Local rendering never contacts the API server or reads filled Secret files.
    rendered = subprocess.check_output([
        'kubectl', 'patch', '--local', '-k',
        str(ROOT / 'apps/reaction-explorer/overlays/local'),
        '--type=merge', '-p', '{}', '-o', 'json'], text=True)
    decoder = json.JSONDecoder()
    resources = []
    rendered = rendered.lstrip()
    while rendered:
        resource, end = decoder.raw_decode(rendered)
        resources.extend(resource['items'] if resource['kind'] == 'List' else [resource])
        rendered = rendered[end:].lstrip()
    deployment = next(r for r in resources if r['kind'] == 'Deployment' and r['metadata']['name'] == 'reaction-explorer')
    name = 'local-db-check-' + uuid.uuid4().hex[:12]
    job = make_job(deployment['spec']['template']['spec'], name)
    kube = ['kubectl', '--kubeconfig', args.kubeconfig, '--context', args.context,
            '--namespace', 'reaction-explorer', '--request-timeout=30s']
    subprocess.run(kube + ['create', '-f', '-'], input=json.dumps(job), text=True, check=True)
    try:
        result = subprocess.run(kube + ['wait', '--for=condition=complete', 'job/' + name, '--timeout=120s'])
        subprocess.run(kube + ['logs', 'job/' + name], check=True)
        result.check_returncode()
    finally:
        subprocess.run(kube + ['delete', 'job', name, '--wait=false'], check=True)


if __name__ == '__main__':
    main()
