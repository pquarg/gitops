"""Use temporary data and simulated Docker/kind; never touch a real database."""

import contextlib
import io
import json
from pathlib import Path
import runpy
import subprocess
import sys
import tempfile
import types
import unittest
from unittest.mock import patch


delete_data = types.SimpleNamespace(**runpy.run_path(str(
    Path(__file__).resolve().parents[2]
    / "apps/myfastapiapp/overlays/local/postgres/delete-data.py"
)))


class DeleteLocalDatabaseTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.storage = Path(self.directory.name).resolve() / "storage with spaces"
        self.data = self.storage / "myfastapiapp-postgres/pgdata"
        self.data.mkdir(parents=True)
        (self.data / "PG_VERSION").write_text("17\n")
        self.other = self.storage / "other-postgres/pgdata"
        self.other.mkdir(parents=True)
        (self.other / "record").write_text("keep")
        self.backup = self.storage / "backup.dump"
        self.backup.write_text("keep backup")
        self.containers = []
        self.clusters = []
        self.fail_docker = False

    def fake_run(self, args, **kwargs):
        if args == ("kind", "get", "clusters"):
            output = "\n".join(self.clusters)
        elif args == ("docker", "ps", "-q"):
            if self.fail_docker:
                return subprocess.CompletedProcess(args, 1, "", "unavailable")
            output = "\n".join(str(index) for index in range(len(self.containers)))
        elif args[:2] == ("docker", "inspect"):
            output = json.dumps([self.containers[int(args[2])]])
        else:
            self.fail(f"Unexpected command: {args}")
        return subprocess.CompletedProcess(args, 0, output, "")

    def invoke(self, action="--delete", path=None):
        output = io.StringIO()
        with patch.object(sys, "argv", [
            "delete-data.py", "--cluster", "example",
            "--data-directory", str(self.data if path is None else path), action,
        ]), patch("subprocess.run", side_effect=self.fake_run), \
                contextlib.redirect_stdout(output), contextlib.redirect_stderr(output):
            status = delete_data.main()
        return status, output.getvalue()

    def mount(self, source, *, cluster="other", name="other-postgres"):
        self.containers.append({
            "Name": f"/{name}",
            "Config": {"Labels": {"io.x-k8s.kind.cluster": cluster}},
            "Mounts": [{"Type": "bind", "Source": str(source)}],
        })

    def test_delete_removes_only_pgdata(self):
        # Symlinks inside pgdata must be unlinked without following their target.
        (self.data / "external-backup").symlink_to(self.backup)
        status, output = self.invoke()
        self.assertEqual(status, 0, output)
        self.assertFalse(self.data.exists())
        self.assertTrue(self.data.parent.is_dir())
        self.assertEqual((self.other / "record").read_text(), "keep")
        self.assertEqual(self.backup.read_text(), "keep backup")

    def test_preview_allows_selected_cluster_but_keeps_files(self):
        self.clusters = ["example"]
        self.mount(self.storage, cluster="example")
        status, output = self.invoke("--dry-run")
        self.assertEqual(status, 0, output)
        self.assertTrue((self.data / "PG_VERSION").exists())

    def test_live_cluster_prevents_deletion(self):
        self.clusters = ["example"]
        status, output = self.invoke()
        self.assertEqual(status, 1)
        self.assertIn("delete the selected kind cluster", output)
        self.assertTrue(self.data.exists())

    def test_running_containers_block_preview_and_deletion(self):
        for source in (self.storage, self.data, self.data / "nested"):
            for action in ("--delete", "--dry-run"):
                with self.subTest(source=source, action=action):
                    self.containers = []
                    self.mount(source)
                    status, output = self.invoke(action)
                    self.assertEqual(status, 1, output)
                    self.assertTrue(self.data.exists())

    def test_surviving_selected_cluster_container_also_blocks_deletion(self):
        self.mount(self.storage, cluster="example")
        status, output = self.invoke()
        self.assertEqual(status, 1, output)
        self.assertTrue(self.data.exists())

    def test_docker_desktop_paths_are_mapped_to_the_mac_host(self):
        with patch.object(sys, "platform", "darwin"):
            status, output = self.invoke("--dry-run", path="/host_mnt" + str(self.data))
            self.assertEqual(status, 0, output)
            self.assertIn(str(self.data), output)
            self.mount("/host_mnt" + str(self.storage))
            status, output = self.invoke()
        self.assertEqual(status, 1, output)
        self.assertTrue(self.data.exists())

    def test_other_apps_mounts_are_allowed(self):
        self.mount(self.other)
        status, output = self.invoke()
        self.assertEqual(status, 0, output)
        self.assertTrue(self.other.exists())

    def test_unsafe_paths_are_rejected(self):
        for path in (
            self.storage, self.data.parent, self.other,
            "relative/myfastapiapp-postgres/pgdata",
            str(self.data.parent / ".." / "myfastapiapp-postgres/pgdata"),
            str(self.data) + "\n",
            "/myfastapiapp-postgres/pgdata",
        ):
            with self.subTest(path=path):
                status, _ = self.invoke(path=path)
                self.assertEqual(status, 1)
                self.assertTrue(self.data.exists())

    def test_symlink_data_and_app_directory_are_rejected(self):
        alternate = self.storage / "alternate"
        self.data.rename(alternate)
        self.data.symlink_to(alternate, target_is_directory=True)
        status, _ = self.invoke()
        self.assertEqual(status, 1)
        self.assertTrue(alternate.exists())
        self.data.unlink()
        alternate.rename(self.data)
        app_alias = self.storage / "alias/myfastapiapp-postgres"
        app_alias.parent.mkdir()
        app_alias.symlink_to(self.data.parent, target_is_directory=True)
        status, _ = self.invoke(path=app_alias / "pgdata")
        self.assertEqual(status, 1)
        self.assertTrue(self.data.exists())

    def test_non_database_directory_is_rejected(self):
        (self.data / "PG_VERSION").unlink()
        (self.data / "unrelated-file").write_text("keep")
        status, output = self.invoke()
        self.assertEqual(status, 1)
        self.assertIn("PG_VERSION", output)
        self.assertTrue(self.data.exists())

    def test_empty_and_already_absent_data_are_safe(self):
        (self.data / "PG_VERSION").unlink()
        status, output = self.invoke()
        self.assertEqual(status, 0, output)
        status, output = self.invoke()
        self.assertEqual(status, 0, output)
        self.assertIn("already absent", output)

    def test_docker_failure_does_not_remove_data(self):
        self.fail_docker = True
        status, _ = self.invoke()
        self.assertEqual(status, 1)
        self.assertTrue(self.data.exists())

    def test_permission_error_is_reported_without_claiming_success(self):
        with patch("shutil.rmtree", side_effect=PermissionError("denied")):
            status, output = self.invoke()
        self.assertEqual(status, 1)
        self.assertNotIn("database files removed", output)
        self.assertTrue(self.data.exists())


if __name__ == "__main__":
    unittest.main()
