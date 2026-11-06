# Validate local deployments

Use the [common validation guide](../validation.md) for prerequisites and check limits.

```sh
./scripts/validate.sh --environment local --ready
./scripts/validate-server.sh myfastapiapp --environment local --context kind-argocd-postgres
```

For runtime checks, follow the [app runbook](../../apps/myfastapiapp/overlays/local/README.md).
