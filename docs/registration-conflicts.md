# Resolve registration and credential conflicts

Bootstrap checks for conflicting Argo CD registrations before applying the
selected environment. The database helper also stops if creating a new app
Secret could replace credentials used by another installation. These checks
protect existing workloads and data. A fresh setup follows [local setup](local/setup.md)
or [AWS setup](aws/setup.md); use this page when a helper reports a conflict.

## Inspect ownership

Select the intended environment and one explicit Kubernetes context. Run these
read-only checks, replacing `CONTEXT` with that context:

```sh
kubectl --context CONTEXT -n argocd get applications,applicationsets
kubectl --context CONTEXT -n argocd get application bootstrap -o yaml
kubectl --context CONTEXT -n argocd get applicationset apps -o yaml
kubectl --context CONTEXT -n demo-api get deployments,jobs,services,ingresses,gateways,httproutes
```

An absent registration is expected before first setup. For existing objects,
inspect source repository/path, destination namespace, owner references,
finalizers and active sync operations. The intended chain is Application
`bootstrap` → ApplicationSet `apps` → Application `<app>`, all in `argocd`.
Each app targets its own namespace and the selected environment's overlay.
Only one Application should reconcile a given workload.

## Resolve a registration conflict

Choose the intended owner before making changes. Save the affected registrations,
workload configuration, credentials and current sync policies privately. Back up
and verify the database before maintenance that can interrupt writers.

During a reviewed maintenance window, pause the affected parent reconciliation
and app syncs, and wait for active operations and migration Jobs to finish.
Account for ApplicationSet ownership and deletion finalizers before removing any
registration. Remove a conflicting registration only with an explicitly reviewed
non-cascading procedure that preserves its workloads and Secrets. Deleting a
namespace or cascading an Application can delete the resources it owns.

Confirm each workload has one owner, then rerun configuration validation and
bootstrap for the selected environment/context. A bootstrap source-path conflict
also requires checking that the context selects the intended cluster. Do not
force or replace registrations to bypass the check.

Verify the full app sync, migration logs, readiness and existing account login.
Restore the intended sync policies after acceptance. Removing unused workloads,
namespaces or AWS load balancers is a separate, explicitly selected cleanup.

## Resolve a database credential conflict

The API and migration Job use `demo-api-secrets` in namespace `demo-api`.
Provisioning a fresh Secret generates a database password; applying that password
to an already used login can disconnect another workload. If the helper detects
another connection Secret, stop and establish which database/login it uses.

When adopting an existing database, preserve its current app password and prepare
the destination connection Secret privately using that password and the verified
endpoint. Keep the source Secret until the destination is verified. Never print
filled Secrets or connection URLs in logs. A namespace does not inherit another
namespace's Secrets, and changing a Secret does not rotate a database password.

Follow the selected app's [local credential setup](../apps/demo-api/overlays/local/README.md#provision-credentials)
or [AWS credential setup](../apps/demo-api/overlays/aws/README.md#provision-credentials).
Verify database connectivity, migration privileges, image pulls, readiness and
existing account login before restoring normal traffic and sync. Coordinate a
deliberate password rotation with every workload using that login.
