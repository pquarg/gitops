# Validate GitOps configuration

Install kubectl, kubeconform and Python 3. CI pins kubectl `v1.36.1`, kubeconform
`v0.8.0` and Kubernetes schemas `1.36.0`. Use matching tools for matching results;
`KUBERNETES_VERSION` selects another available schema version.

Run from this repository, or invoke the script by its absolute path:

```sh
./scripts/validate.sh
./scripts/validate.sh --no-placeholders
./scripts/validate.sh --environment local
./scripts/validate.sh --environment aws --no-placeholders
git diff --check
```

By default all app overlays and environment-specific registrations are rendered.
The validator checks app names, base/overlay entry points, Bash syntax, bootstrap
failure/selection behavior, credential helper tests and strict schemas. Additional
regression checks protect external-database ownership, AWS/local resource
isolation, sync policies and matching API/migration images. `--environment`
selects the rendered resources for schema/placeholder checking; the shared safety
regression checks still cover all environments.

`--no-placeholders` rejects `REPLACE_...` values and reserved example domains in rendered
manifests. Empty Secret examples are deliberately excluded. Strict kubeconform
validation fetches built-in schemas and Argo CD schemas from the configured CRD
catalog; unknown kinds fail instead of being silently skipped. Internet access
is required. No Docker, AWS credentials or Kubernetes API access is required.
CI runs the same script with `--no-placeholders` on pushes and pull requests.
The `--ready` spelling is an alias for `--no-placeholders`; it performs the same
configuration checks and never checks runtime readiness.

## Server dry-run

After provisioning the namespace and cluster CRDs, select the environment and
context explicitly:

```sh
./scripts/validate-server.sh demo-api --environment local --context kind-deployment
./scripts/validate-server.sh demo-api --environment aws --context aws-deployment-project
./scripts/validate-server.sh demo-api --environment prod --context aws-deployment-project-prod
```

`--kubeconfig /absolute/file` is also supported. The script dry-runs ordinary
updates and creates hook Jobs under generated names, preserving the existing
migration Job and logs. It does not run migrations or persist resources. Admission
webhooks must support/reach the dry-run. Local selection requires a kind context;
AWS selection rejects kind contexts, and bootstrap additionally checks the matching
platform routing controller before registering anything. Local checks include
Standard CRDs, GatewayClass acceptance and shared Gateway/listener readiness;
AWS checks its Gateway CRDs and GatewayClass before app sync; it does not
require the app-owned Gateway to exist before registration. HTTPRoutes and AWS custom resources use schemas pinned to Gateway API v1.6.2
and AWS controller v3.6.2 under `schemas/`.

Configuration validation cannot prove image availability, Secret presence,
database compatibility, successful migrations, cluster health or endpoint health.
Use the environment's app verification runbook for those checks. Platform
configuration is validated in the owning infrastructure repository.
