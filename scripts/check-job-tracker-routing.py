#!/usr/bin/env python3
"""Verify the local tracker HTTPRoute preserves API and frontend path behavior."""
import argparse
import http.client
import json
from pathlib import Path
import subprocess
import sys


def check_paths():
    def get(host, path):
        connection = http.client.HTTPConnection('127.0.0.1', 80, timeout=15)
        connection.request('GET', path, headers={'Host': host})
        response = connection.getresponse()
        result = response.status, response.getheader('Content-Type', ''), response.read()
        connection.close()
        return result

    host = 'job-tracker.localhost'
    root_status, root_type, root_body = get(host, '/')
    assert root_status == 200 and 'text/html' in root_type, 'Frontend root is not healthy'
    for path in ('/api', '/apix', '/profile'):
        status, media, body = get(host, path)
        assert status == 200 and 'text/html' in media and body == root_body, f'{path}: expected the unchanged frontend fallback; got {status} {media}'
        print(f'{path}: frontend fallback preserved')
    for path in ('/api/health', '/api/ready'):
        status, media, body = get(host, path)
        assert status == 200 and 'json' in media and json.loads(body) == {'status': 'ok'}, f'{path}: API health/readiness failed'
        print(f'{path}: API ready')
    for path, expected in (('/api/', 404), ('/api/auth/me', 401), ('/api/documents', 401)):
        status, media, _ = get(host, path)
        assert status == expected and 'json' in media, f'{path}: wrong backend or response: {status} {media}'
        print(f'{path}: API response {status} preserved')
    assert get('unmatched-gateway-check.localhost', '/')[0] == 404, 'Unexpected catch-all route'


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--environment', required=True, choices=['local'])
    parser.add_argument('--context', required=True, choices=['kind-deployment'])
    parser.add_argument('--kubeconfig', required=True)
    args = parser.parse_args()
    subprocess.run([sys.executable, str(Path(__file__).with_name('check-gateway.py')),
                    '--environment', args.environment, '--context', args.context,
                    '--kubeconfig', args.kubeconfig, '--namespace', 'job-tracker',
                    '--route', 'job-tracker'], check=True)
    check_paths()
    print('Tracker routing contract passed.')


if __name__ == '__main__':
    main()
