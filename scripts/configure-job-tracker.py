#!/usr/bin/env python3
"""Load private tracker env settings into the local Secret without printing values."""
import argparse
import base64
import json
from pathlib import Path
import re
import shlex
import subprocess

ALLOWED = {'JT_DATABASE_URL', 'JT_ORIGIN', 'JT_COOKIE_SECURE', 'JT_AI_PROVIDER',
           'JT_AI_MODEL', 'JT_AI_RETENTION', 'OPENAI_API_KEY'}
RETIRED = {'JT_AI_URL', 'JT_AI_EXTERNAL', 'JT_AI_KEY', 'JT_SEARCH_KEY', 'JT_SEARCH_RETENTION'}


def read_settings(path):
    path = Path(path)
    if not path.is_absolute() or not path.is_file() or path.stat().st_mode & 0o077:
        raise ValueError('Use an absolute private env file with permissions 600')
    if subprocess.run(['git', '-C', str(path.resolve().parent), 'rev-parse',
                       '--is-inside-work-tree'], capture_output=True).returncode == 0:
        raise ValueError('Private env files must be outside Git working trees')
    values = {}
    for line in path.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith('#'):
            continue
        key, sep, raw = line.partition('=')
        if not sep or key not in ALLOWED or key in values:
            raise ValueError('Unknown, retired or duplicate setting in private env file')
        parts = shlex.split(raw, comments=True)
        if len(parts) > 1:
            raise ValueError('Quote values containing spaces')
        values[key] = parts[0] if parts else ''
        if '\n' in values[key] or '\r' in values[key]:
            raise ValueError('Settings must be single-line values')
    if values.get('JT_AI_PROVIDER', 'openai') != 'openai':
        raise ValueError('Only the OpenAI provider is supported')
    database = values.get('JT_DATABASE_URL', '')
    if not re.fullmatch(r'postgresql\+psycopg://job_tracker:[^@\s]+@host\.docker\.internal:5433/job_tracker', database):
        raise ValueError('Expected the dedicated local tracker database/login and host route')
    if values.get('JT_ORIGIN', 'http://job-tracker.localhost') != 'http://job-tracker.localhost':
        raise ValueError('Expected the local tracker origin')
    if values.get('JT_COOKIE_SECURE', 'false').lower() != 'false':
        raise ValueError('Local HTTP requires non-Secure cookies')
    return values


def updated_secret(existing, values):
    secret = existing or {'apiVersion': 'v1', 'kind': 'Secret', 'type': 'Opaque',
                          'metadata': {'name': 'job-tracker-secrets', 'namespace': 'job-tracker'}}
    data = secret.setdefault('data', {})
    # Replace/remove only this app's known provider settings; preserve unrelated entries.
    for key in RETIRED | ALLOWED:
        data.pop(key, None)
    for key, value in values.items():
        data[key] = base64.b64encode(value.encode()).decode()
    data.setdefault('OPENAI_API_KEY', '')
    annotations = secret['metadata'].get('annotations', {})
    annotations.pop('kubectl.kubernetes.io/last-applied-configuration', None)
    return secret


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--environment', required=True, choices=['local'])
    parser.add_argument('--context', required=True, choices=['kind-deployment'])
    parser.add_argument('--env-file', required=True)
    parser.add_argument('--kubeconfig')
    args = parser.parse_args()
    values = read_settings(args.env_file)
    kube = ['kubectl', '--context', args.context, '-n', 'job-tracker']
    if args.kubeconfig:
        if ':' in args.kubeconfig:
            parser.error('Select one kubeconfig file')
        kube += ['--kubeconfig', args.kubeconfig]
    result = subprocess.run(kube + ['get', 'secret', 'job-tracker-secrets',
                                   '--ignore-not-found', '-o', 'json'], capture_output=True, text=True)
    if result.returncode:
        raise RuntimeError('Cannot read the tracker Secret; check explicit context/namespace access')
    existing = json.loads(result.stdout) if result.stdout.strip() else None
    secret = updated_secret(existing, values)
    result = subprocess.run(kube + ['replace' if existing else 'create', '-f', '-'],
                            input=json.dumps(secret), capture_output=True, text=True)
    if result.returncode:
        raise RuntimeError('Cannot update the tracker Secret; private values were not logged')
    print('Tracker Secret updated. Restart API and worker to load settings; review new disclosure.')


if __name__ == '__main__':
    main()
