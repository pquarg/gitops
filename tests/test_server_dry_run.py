"""Verify server preflight selection and that hooks are only dry-run creations."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class ServerDryRunTests(unittest.TestCase):
    def test_each_environment_renders_only_its_resources_and_preserves_hooks(self):
        for environment, context in [('local', 'kind-selected'), ('aws', 'aws-selected')]:
            with self.subTest(environment=environment), tempfile.TemporaryDirectory() as directory:
                directory = Path(directory)
                log = directory / 'calls.jsonl'
                executable = directory / 'kubectl'
                executable.write_text('''#!/usr/bin/env python3
import json, os, subprocess, sys
args = sys.argv[1:]
if args[:2] == ['patch', '--local']:
    raise SystemExit(subprocess.run([os.environ['REAL_KUBECTL']] + args).returncode)
if '--dry-run=server' not in args:
    raise SystemExit('Unexpected live Kubernetes call')
with open(os.environ['CALL_LOG'], 'a') as output:
    print(json.dumps({'args': args, 'resource': json.load(sys.stdin)}), file=output)
''')
                executable.chmod(0o755)
                env = dict(os.environ, REAL_KUBECTL=shutil.which('kubectl'),
                           CALL_LOG=str(log), PATH=str(directory) + os.pathsep + os.environ['PATH'])
                subprocess.run([
                    str(ROOT / 'scripts/validate-server.sh'), 'myfastapiapp',
                    '--environment', environment, '--context', context,
                    '--kubeconfig', '/tmp/selected config',
                ], env=env, check=True, capture_output=True, text=True)
                calls = [json.loads(line) for line in log.read_text().splitlines()]
                self.assertEqual(len(calls), 2)
                self.assertIn('apply', calls[0]['args'])
                self.assertIn('create', calls[1]['args'])
                for call in calls:
                    self.assertIn('--context=' + context, call['args'])
                    self.assertIn('--kubeconfig=/tmp/selected config', call['args'])
                    self.assertIn('--namespace=myfastapiapp', call['args'])
                    self.assertIn('--dry-run=server', call['args'])
                regular = calls[0]['resource']['items']
                self.assertFalse(any('argocd.argoproj.io/hook' in item['metadata'].get('annotations', {}) for item in regular))
                self.assertFalse(any(item['kind'] in ('StatefulSet', 'PersistentVolume', 'PersistentVolumeClaim') for item in regular))
                hooks = calls[1]['resource']['items']
                self.assertEqual(len(hooks), 1)
                self.assertEqual(hooks[0]['kind'], 'Job')
                self.assertNotIn('name', hooks[0]['metadata'])
                self.assertEqual(hooks[0]['metadata']['generateName'], 'myfastapiapp-migrate-preflight-')

    def test_rejects_environment_context_mismatch_before_kubernetes_calls(self):
        for environment, context in [('local', 'aws-selected'), ('aws', 'kind-selected')]:
            result = subprocess.run([
                str(ROOT / 'scripts/validate-server.sh'), 'myfastapiapp',
                '--environment', environment, '--context', context,
            ], capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('environment and context disagree', result.stderr)


if __name__ == '__main__':
    unittest.main()
