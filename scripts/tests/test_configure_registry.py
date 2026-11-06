"""Check that registry credentials stay off arguments and terminal output."""

import base64
import contextlib
import getpass
import io
import json
from pathlib import Path
import runpy
import subprocess
import sys
import unittest
from unittest.mock import patch


main = runpy.run_path(str(Path(__file__).resolve().parents[1] / "configure-registry.py"))["main"]


class RegistryTests(unittest.TestCase):
    def invoke(self, result, *, password="synthetic-token", prompt_error=None):
        output = io.StringIO()
        with patch.object(sys, "argv", ["configure-registry.py", "aws-deployment-project", "pquarg"]), \
                patch("getpass.getpass", return_value=password, side_effect=prompt_error), \
                patch("subprocess.run", return_value=result) as run, \
                contextlib.redirect_stdout(output), contextlib.redirect_stderr(output):
            status = main()
        return status, output.getvalue(), run

    def test_secret_goes_through_stdin_and_is_correctly_encoded(self):
        status, output, run = self.invoke(subprocess.CompletedProcess([], 0, "", ""))
        self.assertEqual(status, 0)
        argv = run.call_args.args[0]
        self.assertNotIn("synthetic-token", " ".join(argv))
        self.assertNotIn("synthetic-token", output)
        secret = json.loads(run.call_args.kwargs["input"])
        config = json.loads(base64.b64decode(secret["data"][".dockerconfigjson"]))
        self.assertEqual(base64.b64decode(config["auths"]["ghcr.io"]["auth"]).decode(),
                         "pquarg:synthetic-token")
        self.assertIn("--server-side", argv)

    def test_api_errors_cannot_echo_secret_input(self):
        status, output, _ = self.invoke(subprocess.CompletedProcess([], 1, "synthetic-token", "synthetic-token"))
        self.assertEqual(status, 1)
        self.assertNotIn("synthetic-token", output)

    def test_refuses_prompt_that_cannot_hide_input(self):
        status, output, run = self.invoke(None, prompt_error=getpass.GetPassWarning())
        self.assertEqual(status, 1)
        self.assertIn("hidden password prompt", output)
        run.assert_not_called()


if __name__ == "__main__":
    unittest.main()
