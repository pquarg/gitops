# Validate AWS deployments

Use the [common validation guide](../validation.md) for prerequisites and check limits.

```sh
./scripts/validate.sh --environment aws --ready
./scripts/validate-server.sh myfastapiapp --environment aws --context aws-deployment-project
```

For runtime checks, follow the [app runbook](../../apps/myfastapiapp/overlays/aws/README.md).
