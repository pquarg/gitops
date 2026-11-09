# Validate AWS deployments

Use the [common validation guide](../validation.md) for prerequisites and check limits.

```sh
./scripts/validate.sh --environment aws --no-placeholders
./scripts/validate-server.sh demo-api --environment aws --context aws-deployment-project
```

For runtime checks, follow the [app runbook](../../apps/demo-api/overlays/aws/README.md).
