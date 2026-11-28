#!/usr/bin/env python3
"""Prepare the three Argo CD revision selectors on a local deployment branch."""
import argparse
from pathlib import Path
import re
import subprocess

ROOT = Path(__file__).resolve().parents[1]

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("branch", help="checked-out feat/* branch, or dev")
args = parser.parse_args()
branch = args.branch
current = subprocess.check_output(
    ["git", "branch", "--show-current"], cwd=ROOT, text=True
).strip()
if (
    branch != current
    or not (branch == "dev" or re.fullmatch(r"feat/[A-Za-z0-9._/-]+", branch))
    or subprocess.run(["git", "check-ref-format", f"refs/heads/{branch}"]).returncode
):
    parser.error("check out dev or the feat/* branch you want to prepare")

revisions = {
    "bootstrap/local.yaml": 1,
    "argocd/local/apps.yaml": 2,
}
updates = {}
for name, expected in revisions.items():
    path = ROOT / name
    content, count = re.subn(
        r"^( +(?:targetRevision|revision): )[^\s]+$", lambda match: match[1] + branch,
        path.read_text(), flags=re.MULTILINE,
    )
    if count != expected:
        parser.error(f"expected {expected} revision selectors in {name}")
    updates[path] = content
for path, content in updates.items():
    path.write_text(content)
print(f"Prepared {branch}. Commit and publish these local registration changes before bootstrap.")
