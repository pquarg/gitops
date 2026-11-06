# myfastapiapp

`base/` holds the shared Deployment, Service and migration Job. Each overlay
includes that base and selects the API/migration release image together.

- [Local overlay and database runbook](overlays/local/README.md)
- [AWS overlay and RDS runbook](overlays/aws/README.md)
- [Release and promotion model](../../README.md#change-and-promote-an-app)

Keep the app namespace and resource names stable when editing shared manifests.
Database credentials and contents are separate in each environment.
