"""Credential handling and retry checks; all AWS/kubectl calls are simulated."""

import base64
import contextlib
import io
import json
from pathlib import Path
import runpy
import subprocess
import sys
import types
import unittest
from unittest.mock import patch


bootstrap = types.SimpleNamespace(**runpy.run_path(
    str(Path(__file__).resolve().parents[1] / "bootstrap-demo-api-rds.py")
))
HOST = "test.eu-north-1.rds.amazonaws.com"
ENDPOINT = "https://test.eks.amazonaws.com"
ADMIN_PASSWORD = "synthetic-admin-password"


class FakeCommands:
    def __init__(self, *, existing=None, fail_admin=False, wrong_context=False, previous_secret=False):
        self.existing = existing
        self.fail_admin = fail_admin
        self.wrong_context = wrong_context
        self.previous_secret = previous_secret
        self.calls = []
        self.created = []

    def run(self, argv, **kwargs):
        self.calls.append((argv, kwargs.get("input")))
        output = ""
        if argv[0] == "aws":
            if "get-caller-identity" in argv:
                output = json.dumps({"Account": bootstrap.AWS_ACCOUNT_ID})
            elif "describe-cluster" in argv:
                output = json.dumps({"cluster": {"endpoint": ENDPOINT}})
            elif "describe-db-instances" in argv:
                output = json.dumps({"DBInstances": [{
                    "DBInstanceStatus": "available", "PubliclyAccessible": False,
                    "DBName": "myfastapiapp", "Endpoint": {"Address": HOST, "Port": 5432},
                    "MasterUsername": "dbadmin", "MasterUserSecret": {"SecretArn": "test-secret"},
                }]})
            elif "get-secret-value" in argv:
                output = json.dumps({"SecretString": json.dumps({
                    "username": "dbadmin", "password": ADMIN_PASSWORD,
                })})
            else:
                raise AssertionError("Unexpected AWS command")
        elif argv[0] == "kubectl":
            if "config" in argv:
                output = json.dumps({"clusters": [{"cluster": {
                    "server": "https://wrong.example" if self.wrong_context else ENDPOINT,
                }}]})
            elif "get" in argv and "secret" in argv:
                if "myfastapiapp-secrets" in argv:
                    output = "secret/myfastapiapp-secrets" if self.previous_secret else ""
                else:
                    output = json.dumps(self.existing) if self.existing else ""
            elif "create" in argv:
                self.created.append(json.loads(kwargs["input"]))
            elif "exec" in argv:
                if argv[-1] == "dbadmin" and self.fail_admin:
                    return subprocess.CompletedProcess(argv, 1, "", ADMIN_PASSWORD)
                if argv[-1] == "myfastapiapp":
                    output = "BOOTSTRAP_OK login=myfastapiapp database=myfastapiapp tls=TLSv1.3\n"
            elif not any(word in argv for word in ("get", "wait", "delete")):
                raise AssertionError("Unexpected kubectl command")
        else:
            raise AssertionError("Unexpected executable")
        return subprocess.CompletedProcess(argv, 0, output, "")


class BootstrapTests(unittest.TestCase):
    def invoke(self, fake):
        output = io.StringIO()
        with patch.object(sys, "argv", ["bootstrap-demo-api-rds.py", "aws-deployment-project"]), \
                patch("shutil.which", return_value="test-executable"), \
                patch("subprocess.run", side_effect=fake.run), \
                contextlib.redirect_stdout(output), contextlib.redirect_stderr(output):
            status = bootstrap.main()
        return status, output.getvalue()

    def test_success_keeps_credentials_off_arguments_and_output(self):
        fake = FakeCommands()
        status, output = self.invoke(fake)
        self.assertEqual(status, 0, output)
        self.assertIn("BOOTSTRAP_OK", output)
        app_secret = next(r for r in fake.created if r["kind"] == "Secret")
        url = app_secret["stringData"]["AUTH_DATABASE_URL"]
        _, app_password = bootstrap.app_credentials({"data": {
            "AUTH_DATABASE_URL": base64.b64encode(url.encode()).decode(),
        }}, HOST)
        self.assertNotIn(ADMIN_PASSWORD, output)
        self.assertNotIn(app_password, output)
        for argv, _ in fake.calls:
            self.assertNotIn(ADMIN_PASSWORD, " ".join(argv))
            self.assertNotIn(app_password, " ".join(argv))
        self.assertEqual([r["kind"] for r in fake.created].count("Secret"), 1)
        pod = next(r for r in fake.created if r["kind"] == "Pod")
        self.assertEqual(pod["metadata"]["namespace"], "demo-api")
        settings = {entry["name"]: entry["value"] for entry in pod["spec"]["containers"][0]["env"]}
        self.assertEqual(settings["PGDATABASE"], "myfastapiapp")
        self.assertNotIn(ADMIN_PASSWORD, json.dumps(pod))
        self.assertNotIn(app_password, json.dumps(pod))
        self.assertFalse(pod["spec"]["automountServiceAccountToken"])
        self.assertEqual(len([a for a, _ in fake.calls if "delete" in a]), 2)

    def test_conflicting_secret_requires_existing_password_before_database_login_changes(self):
        fake = FakeCommands(previous_secret=True)
        status, output = self.invoke(fake)
        self.assertEqual(status, 1)
        self.assertIn("docs/registration-conflicts.md#resolve-a-database-credential-conflict", output)
        self.assertFalse(any(r["kind"] == "Secret" for r in fake.created))
        self.assertFalse(any("get-secret-value" in argv or "exec" in argv for argv, _ in fake.calls))

    def test_retry_reuses_existing_password_without_replacing_secret(self):
        url = f"postgresql://myfastapiapp:existing%2Bpassword@{HOST}:5432/myfastapiapp?sslmode=verify-full"
        existing = {"data": {"AUTH_DATABASE_URL": base64.b64encode(url.encode()).decode()}}
        fake = FakeCommands(existing=existing)
        status, output = self.invoke(fake)
        self.assertEqual(status, 0, output)
        self.assertFalse(any(r["kind"] == "Secret" for r in fake.created))
        admin_stdin = next(data for argv, data in fake.calls if "exec" in argv and argv[-1] == "dbadmin")
        self.assertTrue(admin_stdin.startswith(ADMIN_PASSWORD + "\nexisting+password\n"))
        self.assertNotIn("existing+password", output)

    def test_wrong_cluster_stops_before_secrets_or_mutations(self):
        fake = FakeCommands(wrong_context=True)
        status, output = self.invoke(fake)
        self.assertEqual(status, 1)
        self.assertIn("does not target", output)
        self.assertFalse(fake.created)
        self.assertFalse(any("get-secret-value" in argv for argv, _ in fake.calls))

    def test_sql_failure_cleans_up_client_and_retains_app_secret(self):
        fake = FakeCommands(fail_admin=True)
        status, output = self.invoke(fake)
        self.assertEqual(status, 1)
        self.assertNotIn(ADMIN_PASSWORD, output)
        self.assertIn("Sensitive command failed", output)
        deletes = [argv for argv, _ in fake.calls if "delete" in argv]
        self.assertEqual(len(deletes), 2)
        self.assertFalse(any("secret" in argv for argv in deletes))

    def test_existing_secret_for_other_database_is_refused(self):
        url = "postgresql://myfastapiapp:old@other.example:5432/myfastapiapp?sslmode=verify-full"
        fake = FakeCommands(existing={"data": {"AUTH_DATABASE_URL": base64.b64encode(url.encode()).decode()}})
        status, output = self.invoke(fake)
        self.assertEqual(status, 1)
        self.assertIn("does not match", output)
        self.assertNotIn(url, output)
        self.assertFalse(any(r["kind"] == "Secret" for r in fake.created))
        self.assertFalse(any("exec" in argv for argv, _ in fake.calls))


if __name__ == "__main__":
    unittest.main()
