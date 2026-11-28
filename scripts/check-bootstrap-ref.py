#!/usr/bin/env python3
"""Verify the bootstrap checkout matches the published revision before registering."""
import json
from pathlib import Path
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
environment, = sys.argv[1:]


def kubectl_json(*args):
    stream = subprocess.check_output(
        ["kubectl", "patch", "--local", *args, "--type=merge", "-p", "{}", "-o", "json"],
        text=True,
    ).lstrip()
    decoder = json.JSONDecoder()
    while stream:
        obj, end = decoder.raw_decode(stream)
        yield from obj["items"] if obj["kind"] == "List" else [obj]
        stream = stream[end:].lstrip()


source = next(kubectl_json("-f", str(ROOT / "bootstrap" / f"{environment}.yaml")))["spec"]["source"]
branch = source["targetRevision"]
if environment == "prod":
    items = kubectl_json("-k", str(ROOT / "apps/demo-api/overlays/prod"))
    deployment = next(item for item in items if item["kind"] == "Deployment")
    image = deployment["spec"]["template"]["spec"]["containers"][0]["image"]
    if (not re.fullmatch(r"ghcr\.io/pquarg/demo-api@sha256:[0-9a-f]{64}", image)
            or image.endswith(":" + "0" * 64)):
        sys.exit("Production registration requires the Demo API digest verified in staging.")

head = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip()
if subprocess.run(["git", "diff", "--quiet", "HEAD"], cwd=ROOT).returncode:
    sys.exit("Check out a clean published GitOps revision before registering.")
ref = f"refs/heads/{branch}"
published = subprocess.check_output(
    ["git", "ls-remote", "--exit-code", source["repoURL"], ref], cwd=ROOT, text=True,
).strip()
if published != f"{head}\t{ref}":
    sys.exit(f"Check out the published tip of {branch} before registering {environment}.")
print(branch, head)
