#!/usr/bin/env python3
"""Prompt locally for a GHCR read:packages PAT and configure its pull Secret."""

import argparse
import base64
import getpass
import json
import subprocess
import sys
import warnings


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("context", help="Explicit Kubernetes context")
    parser.add_argument("username", help="GitHub account that owns the classic PAT")
    parser.add_argument("--namespace", default="myfastapiapp")
    args = parser.parse_args()
    try:
        # Fail rather than fall back to an echoed prompt without a usable TTY.
        with warnings.catch_warnings():
            warnings.simplefilter("error", getpass.GetPassWarning)
            token = getpass.getpass("GitHub PAT (classic, read:packages): ")
        if not token:
            raise ValueError("PAT cannot be empty.")
        auth = base64.b64encode(f"{args.username}:{token}".encode()).decode()
        config = json.dumps({"auths": {"ghcr.io": {"auth": auth}}})
        secret = {
            "apiVersion": "v1",
            "kind": "Secret",
            "metadata": {"name": "registry-credentials", "namespace": args.namespace},
            "type": "kubernetes.io/dockerconfigjson",
            "data": {".dockerconfigjson": base64.b64encode(config.encode()).decode()},
        }
        result = subprocess.run(
            ["kubectl", "--context", args.context, "apply", "--server-side",
             "--field-manager=ghcr-credentials", "-f", "-"],
            input=json.dumps(secret), text=True, capture_output=True,
        )
        if result.returncode:
            # API validation errors can echo Secret data. Keep them local and
            # suppressed; never expose the submitted token or encoded config.
            print("kubectl could not configure registry-credentials. Check the context, "
                  "namespace, access and connectivity, then retry.", file=sys.stderr)
            return 1
        print(f"Configured registry-credentials in namespace {args.namespace}.")
        print("A successful image pull is still required to verify the token.")
        return 0
    except (getpass.GetPassWarning, EOFError):
        print("Use an interactive terminal with a hidden password prompt.", file=sys.stderr)
        return 1
    except (OSError, ValueError) as error:
        print(str(error), file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
