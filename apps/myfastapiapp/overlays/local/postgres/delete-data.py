#!/usr/bin/env python3
"""Remove only this app's pgdata after its local kind cluster is gone."""

import argparse
import json
from pathlib import Path
import re
import shutil
import subprocess
import sys


def command(*args):
    result = subprocess.run(args, capture_output=True, text=True)
    if result.returncode:
        raise ValueError(f"{args[0]} {args[1]} failed; database files were not removed")
    return result.stdout


def host_path(value):
    # Docker Desktop reports bind sources inside its Linux VM using this alias.
    if sys.platform == "darwin" and value.startswith("/host_mnt/"):
        value = value.removeprefix("/host_mnt")
    return Path(value)


def data_path(value):
    path = host_path(value)
    if (
        not path.is_absolute()
        or ".." in path.parts
        or any(character in value for character in "\n\r\t")
        or path.name != "pgdata"
        or path.parent.name != "myfastapiapp-postgres"
    ):
        raise ValueError("expected an absolute <storage-parent>/myfastapiapp-postgres/pgdata path")
    if path.is_symlink() or path.parent.is_symlink():
        raise ValueError("pgdata and myfastapiapp-postgres must not be symbolic links")
    path = path.resolve()
    workspace = Path(__file__).resolve().parents[6]
    if path.is_relative_to(workspace) or path.parent.parent == Path("/"):
        raise ValueError("database storage must be outside the workspace and filesystem root")
    if not path.parent.is_dir():
        raise ValueError("the existing myfastapiapp-postgres directory is required")
    if path.exists():
        if not path.is_dir():
            raise ValueError("pgdata must be a directory")
        version = path / "PG_VERSION"
        if version.is_symlink():
            raise ValueError("PG_VERSION must not be a symbolic link")
        if any(path.iterdir()) and (
            not version.is_file()
            or not re.fullmatch(r"\d+(?:\.\d+)?", version.read_text().strip())
        ):
            raise ValueError("refusing a nonempty directory without a valid PostgreSQL PG_VERSION")
    return path


def check_containers(path, cluster, preview):
    for container_id in command("docker", "ps", "-q").split():
        container = json.loads(command("docker", "inspect", container_id))[0]
        labels = container.get("Config", {}).get("Labels") or {}
        if preview and labels.get("io.x-k8s.kind.cluster") == cluster:
            continue
        for mount in container.get("Mounts", []):
            if mount.get("Type") != "bind":
                continue
            source = host_path(mount["Source"]).resolve()
            if path.is_relative_to(source) or source.is_relative_to(path):
                raise ValueError(
                    f"running container {container['Name'].lstrip('/')} mounts database storage; stop it first"
                )


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cluster", required=True)
    parser.add_argument("--data-directory", required=True)
    action = parser.add_mutually_exclusive_group(required=True)
    action.add_argument("--dry-run", action="store_true")
    action.add_argument("--delete", action="store_true")
    args = parser.parse_args()
    if not re.fullmatch(r"[a-z0-9][a-z0-9-]*", args.cluster):
        parser.error("invalid kind cluster name")
    try:
        path = data_path(args.data_directory)
        clusters = command("kind", "get", "clusters").splitlines()
        if args.delete and args.cluster in clusters:
            raise ValueError("delete the selected kind cluster before removing database files")
        check_containers(path, args.cluster, args.dry_run)
        print(f"PostgreSQL data directory: {path}")
        if args.dry_run:
            print("Would remove only pgdata; app directory, other apps and backups are kept.")
        elif path.exists():
            shutil.rmtree(path)
            print("myfastapiapp database files removed; accounts, sessions and records are discarded.")
        else:
            print("Database directory is already absent; nothing to remove.")
    except (OSError, ValueError, KeyError, IndexError) as error:
        print(f"Error: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
