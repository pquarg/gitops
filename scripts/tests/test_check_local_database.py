"""The connectivity probe must use the promoted image and connection Secret."""
import importlib.util
from pathlib import Path
import subprocess
import sys
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / 'check-local-database.py'
spec = importlib.util.spec_from_file_location('check_local_database', SCRIPT)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class LocalDatabaseCheckTests(unittest.TestCase):
    def test_probe_uses_selected_image_and_secret_without_api_readiness_probe(self):
        pod = {'restartPolicy': 'Always', 'imagePullSecrets': [{'name': 'registry-credentials'}],
               'containers': [{'name': 'api', 'image': 'test/app:release',
                               'readinessProbe': {'httpGet': {'path': '/ready'}},
                               'env': [{'name': 'AUTH_DATABASE_URL', 'valueFrom': {'secretKeyRef': {'name': 'myfastapiapp-secrets', 'key': 'AUTH_DATABASE_URL'}}},
                                       {'name': 'APP_MESSAGE', 'valueFrom': {'configMapKeyRef': {'name': 'unused'}}}]}]}
        job = module.make_job(pod, 'check-example')
        result = job['spec']['template']['spec']
        self.assertEqual(result['containers'][0]['image'], 'test/app:release')
        self.assertEqual(result['containers'][0]['env'], pod['containers'][0]['env'][:1])
        self.assertEqual(result['imagePullSecrets'], pod['imagePullSecrets'])
        self.assertNotIn('readinessProbe', result['containers'][0])
        self.assertEqual(result['restartPolicy'], 'Never')
        self.assertIn('readinessProbe', pod['containers'][0])

    def test_aws_context_and_ambient_environment_are_rejected_before_kubectl(self):
        for args in (['--environment', 'local', '--context', 'aws-deployment-project'],
                     ['--context', 'kind-test'],
                     ['--environment', 'aws', '--context', 'kind-test'],
                     ['--environment', 'local', '--context', 'kind-test', '--kubeconfig', '/a:/b']):
            result = subprocess.run([sys.executable, str(SCRIPT), *args], capture_output=True)
            self.assertEqual(result.returncode, 2)
