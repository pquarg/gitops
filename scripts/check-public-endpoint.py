#!/usr/bin/env python3
"""Check the public API; --auth creates one synthetic account and revokes its session.

Passwords and bearer tokens stay in memory and are never printed or saved.
The account remains in the target database. Its generated password is discarded.
Requires only Python 3. Redirects are inspected, never followed with credentials.
"""

import argparse
import json
import secrets
import sys
from urllib.error import HTTPError, URLError
from urllib.parse import urlencode, urlsplit
from urllib.request import HTTPRedirectHandler, Request, build_opener


class NoRedirect(HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


class CheckFailure(Exception):
    pass


class Checks:
    def __init__(self, base):
        self.base = base
        self.client = build_opener(NoRedirect())

    def request(self, path, *, method="GET", data=None, content_type=None,
                token=None, expected=200, secure=True):
        url = self.base + path
        if not secure:
            url = "http://" + urlsplit(self.base).netloc + path
        headers = {"Accept": "application/json"}
        if content_type:
            headers["Content-Type"] = content_type
        if token:
            headers["Authorization"] = "Bearer " + token
        request = Request(url, data=data, headers=headers, method=method)
        try:
            response = self.client.open(request, timeout=30)
        except HTTPError as error:
            response = error
        with response:
            status, response_headers, body = response.code, response.headers, response.read()
        if status != expected:
            raise CheckFailure(f"{method} {path}: expected {expected}, received {status}")
        if "no-store" not in response_headers.get("Cache-Control", "").lower():
            raise CheckFailure(f"{method} {path}: missing Cache-Control: no-store")
        if "hit from cloudfront" in response_headers.get("X-Cache", "").lower():
            raise CheckFailure(f"{method} {path}: unexpected cached response")
        if response_headers.get("Age", "0") != "0":
            raise CheckFailure(f"{method} {path}: unexpected response Age")
        return response_headers, body

    def public(self):
        for path in ("/health", "/ready"):
            headers, body = self.request(path)
            if json.loads(body).get("status") != "ok":
                raise CheckFailure(f"{path}: status is not ok")
            required = {
                "X-Frame-Options": "DENY",
                "X-Content-Type-Options": "nosniff",
                "Referrer-Policy": "no-referrer",
            }
            if any(headers.get(key) != value for key, value in required.items()):
                raise CheckFailure(f"{path}: missing expected browser security headers")
            if not headers.get("Strict-Transport-Security") or not headers.get("Content-Security-Policy"):
                raise CheckFailure(f"{path}: missing HSTS or CSP")
        _, html = self.request("/api/v1/docs/")
        if b"SwaggerUIBundle" not in html:
            raise CheckFailure("Swagger HTML did not contain its initialization")
        _, schema = self.request("/api/v1/docs/openapi.json")
        if "/api/v1/auth/token" not in json.loads(schema).get("paths", {}):
            raise CheckFailure("OpenAPI is missing the login endpoint")
        headers, _ = self.request("/api/v1/docs?smoke=redirect", expected=307)
        if headers.get("Location") != self.base + "/api/v1/docs/?smoke=redirect":
            raise CheckFailure("Docs slash redirect did not preserve HTTPS, host and query")
        self.request("/health", expected=403, secure=False)
        self.request("/api/v1/auth/me", expected=401)
        print("PUBLIC_OK health readiness Swagger OpenAPI HTTPS redirect HTTP rejection headers no-store")

    def auth(self):
        username = "deploy_check_" + secrets.token_hex(5)
        password = secrets.token_urlsafe(32)
        token = None
        print("Creating one synthetic test account; credentials will not be printed.")
        try:
            _, body = self.request(
                "/api/v1/auth/register", method="POST", expected=201,
                content_type="application/json",
                data=json.dumps({"username": username, "email": username + "@example.com",
                                 "password": password}).encode(),
            )
            if json.loads(body).get("username") != username:
                raise CheckFailure("Registration returned an unexpected account")
            form = {"grant_type": "password", "username": username, "password": password}
            _, body = self.request(
                "/api/v1/auth/token", method="POST",
                content_type="application/x-www-form-urlencoded",
                data=urlencode(form).encode(),
            )
            issued_token = json.loads(body).get("access_token")
            if not isinstance(issued_token, str) or not issued_token:
                raise CheckFailure("Login did not return an access token")
            token = issued_token
            for _ in range(2):
                _, body = self.request("/api/v1/auth/me", token=token)
                if json.loads(body).get("username") != username:
                    raise CheckFailure("Authenticated identity did not match the test account")
                self.request("/api/v1/auth/me", expected=401)
            self.request("/api/v1/auth/logout", method="POST", token=token, expected=204)
            self.request("/api/v1/auth/me", token=token, expected=401)
            token = None
            print(f"AUTH_OK account={username} registration login identity logout revoked-token rejection no-store")
            print("The synthetic account remains; its session was revoked and password discarded.")
        finally:
            if token:
                try:
                    self.request("/api/v1/auth/logout", method="POST", token=token, expected=204)
                except (CheckFailure, URLError, OSError):
                    print("Test session cleanup could not be confirmed; it will expire normally.", file=sys.stderr)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("url", help="Public HTTPS base URL, without a path")
    parser.add_argument("--auth", action="store_true", help="Create one test account and verify login/logout")
    args = parser.parse_args()
    parsed = urlsplit(args.url)
    if (parsed.scheme != "https" or not parsed.hostname or parsed.username or parsed.password
            or parsed.path not in ("", "/") or parsed.query or parsed.fragment):
        parser.error("Provide an HTTPS base URL without credentials, path, query or fragment")
    checks = Checks(args.url.rstrip("/"))
    try:
        checks.public()
        if args.auth:
            checks.auth()
    except CheckFailure as error:
        # CheckFailure messages contain only fixed descriptions, paths and statuses.
        print(f"CHECK_FAILED: {error}", file=sys.stderr)
        return 1
    except (URLError, OSError, ValueError):
        # HTTP bodies can contain credentials. Report no body, token or request data.
        print("CHECK_FAILED: public endpoint verification did not pass; credentials were not displayed.",
              file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
