# Public RDS CA bundle

`global-bundle.pem` was downloaded on 2026-10-30 from AWS's public trust store:
https://truststore.pki.rds.amazonaws.com/global/global-bundle.pem

These are public CA certificates, not database credentials or private keys.
Kustomize generates `demo-api-rds-ca` from this file and rewrites references
in both workloads to the generated name with a content hash.

When AWS updates its CA bundle, refresh it from the official HTTPS endpoint,
check that it parses as certificates, review the change, and run validation:

```sh
bundle_file="$(mktemp)"
curl -fsSL https://truststore.pki.rds.amazonaws.com/global/global-bundle.pem \
  -o "$bundle_file" &&
  openssl crl2pkcs7 -nocrl -certfile "$bundle_file" -out /dev/null &&
  mv "$bundle_file" apps/demo-api/overlays/aws/certs/global-bundle.pem &&
  ./scripts/validate.sh --environment aws --no-placeholders
```

Commit the verified bundle and sync the entire app. Retain any CA still required
by the RDS certificate rotation plan. See
[RDS TLS documentation](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/UsingWithRDS.SSL.html).
