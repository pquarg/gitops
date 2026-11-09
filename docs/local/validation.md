# Validate local deployments

Use the [common validation guide](../validation.md) for prerequisites and check limits.

```sh
./scripts/validate.sh --environment local --no-placeholders
./scripts/validate-server.sh demo-api --environment local --context kind-deployment
```

For runtime checks, follow the [app runbook](../../apps/demo-api/overlays/local/README.md).
