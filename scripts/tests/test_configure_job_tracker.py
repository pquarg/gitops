import base64
import importlib.util
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('configure_tracker',
    Path(__file__).resolve().parents[1] / 'configure-job-tracker.py')
helper = importlib.util.module_from_spec(spec)
spec.loader.exec_module(helper)
DATABASE = 'postgresql+psycopg://job_tracker:synthetic@host.docker.internal:5433/job_tracker'


class ConfigureTrackerTests(unittest.TestCase):
    def test_plan_settings_require_stable_private_key_host_and_loopback(self):
        content = (f'JT_DATABASE_URL={DATABASE}\nJT_AI_AUTH=chatgpt_plan\n'
                   'JT_CHATGPT_ENCRYPTION_KEY=' + base64.urlsafe_b64encode(b'x' * 32).decode() + '\n'
                   'JT_CHATGPT_HOST_ID=urn:uuid:11111111-1111-4111-8111-111111111111\n'
                   'JT_CHATGPT_CALLBACK_URI=http://127.0.0.1:1456/auth/callback\n')
        for replacement, valid in [('', True), ('bad-key', False), ('bad-host', False), ('bad-callback', False)]:
            with self.subTest(replacement=replacement), tempfile.TemporaryDirectory() as directory:
                path = Path(directory) / 'deployment.env'
                value = content
                if replacement == 'bad-key':
                    value = value.replace(base64.urlsafe_b64encode(b'x' * 32).decode(), 'invalid')
                if replacement == 'bad-host':
                    value = value.replace('urn:uuid:11111111-1111-4111-8111-111111111111', 'email@example.test')
                if replacement == 'bad-callback':
                    value = value.replace('127.0.0.1:1456', 'external.example.test:1456')
                path.write_text(value)
                path.chmod(0o600)
                with patch.object(helper.subprocess, 'run') as run:
                    run.return_value.returncode = 1
                    if valid:
                        self.assertEqual(helper.read_settings(path)['JT_AI_AUTH'], 'chatgpt_plan')
                    else:
                        with self.assertRaises(ValueError):
                            helper.read_settings(path)

    def test_private_env_is_parsed_without_executing_shell(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'deployment.env'
            path.write_text(f"JT_DATABASE_URL={DATABASE}\nOPENAI_API_KEY='literal-$(touch /tmp/never)'\n")
            path.chmod(0o600)
            with patch.object(helper.subprocess, 'run') as run:
                run.return_value.returncode = 1
                values = helper.read_settings(path)
            self.assertEqual(values['OPENAI_API_KEY'], 'literal-$(touch /tmp/never)')
            path.chmod(0o644)
            with self.assertRaises(ValueError):
                helper.read_settings(path)

    def test_retired_or_duplicate_settings_fail_before_secret_mutation(self):
        for content in ['JT_SEARCH_KEY=old', 'OPENAI_API_KEY=a\nOPENAI_API_KEY=b']:
            with self.subTest(content=content), tempfile.TemporaryDirectory() as directory:
                path = Path(directory) / 'deployment.env'
                path.write_text(content)
                path.chmod(0o600)
                with patch.object(helper.subprocess, 'run') as run:
                    run.return_value.returncode = 1
                    with self.assertRaises(ValueError):
                        helper.read_settings(path)

    def test_secret_update_removes_old_provider_fields_and_preserves_other_entries(self):
        old = {'metadata': {'resourceVersion': '123', 'annotations': {
            'kubectl.kubernetes.io/last-applied-configuration': 'old-private-settings'}},
            'data': {'JT_AI_MODEL': '', 'JT_AI_KEY': 'old', 'JT_SEARCH_KEY': 'old',
                     'OTHER_SETTING': 'preserved'}}
        result = helper.updated_secret(old, {'JT_DATABASE_URL': DATABASE,
                                             'OPENAI_API_KEY': 'synthetic-new-key'})
        self.assertEqual(result['metadata']['resourceVersion'], '123')
        self.assertNotIn('JT_AI_KEY', result['data'])
        self.assertNotIn('JT_SEARCH_KEY', result['data'])
        self.assertNotIn('JT_AI_MODEL', result['data'])
        self.assertEqual(result['data']['OTHER_SETTING'], 'preserved')
        self.assertEqual(base64.b64decode(result['data']['OPENAI_API_KEY']), b'synthetic-new-key')
        self.assertEqual(result['metadata']['annotations'], {})
