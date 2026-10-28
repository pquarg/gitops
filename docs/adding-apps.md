# Add an app

Each immediate directory under `apps/` is a deployable app with a root
`kustomization.yaml`. The ApplicationSet in `argocd/apps.yaml` discovers these
directories from `main` and creates `staging-<directory>` in Argo CD, targeting a
namespace named exactly `<directory>`.

Use a lowercase DNS label of at most 63 characters, such as `billing-api`. Reserve
`myfastapiapp`, `argocd`, `traefik`, `default`, `bootstrap`, and names beginning `kube-`; the
existing app has an explicit registration and stays in `default`.

## App files

```text
apps/billing-api/
  base/
    kustomization.yaml
    deployment.yaml
    service.yaml
  ingress.yaml
  kustomization.yaml
  app-secrets.example.yaml    # Optional, empty values only
```

A root Kustomization might look like:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: billing-api
resources:
  - ./base
  - ingress.yaml
images:
  - name: ghcr.io/pquarg/billing-api
    newTag: "0.1.0"
```

Keep environment-independent workloads in `base/`; keep staging hostnames,
configuration overrides and image selections in the app root. An Ingress using
class `traefik` and host `billing-api.localhost` shares the existing controller
and localhost port. Set CPU/memory requests and limits and meaningful probes in
the workload manifests. Keep the app's resource selectors consistent.

The app may include an optional `postgres/` directory and migration Job. Keep its
database, migration and rollout in the same Application so sync waves can enforce
ordering. If using local storage, use a unique cluster-wide PV name, laptop
directory and kind mount, and set its `claimRef.namespace` to the app namespace.
The existing app's storage is explicitly reserved and must not be copied unchanged.
Preserve data resources with retention and Argo CD deletion/pruning annotations.

New apps share the cluster's existing Argo CD `default` project. Namespaces organise
namespaced resources; they do not by themselves enforce network or tenant isolation.
Add AppProjects, RBAC, quotas or NetworkPolicies when access or capacity needs require them.

## Credentials and registration

Before pushing an auto-deployed app, create its namespace and any required Secrets:

```sh
kubectl --context kind-argocd-postgres create namespace billing-api
```

Copy the app's empty Secret example to `app-secrets.yaml`, set its namespace to
`billing-api`, fill it in your editor, set mode `600`, and check it is ignored.
Provision `registry-credentials` in the same namespace for private images using
the [credential instructions](credentials.md). Secret values stay outside Kustomize.

```sh
git check-ignore apps/billing-api/app-secrets.yaml
./scripts/validate.sh
kubectl --context kind-argocd-postgres -n billing-api \
  apply --dry-run=server -k apps/billing-api
```

Review, commit and push the app manifests. CI discovers the root Kustomization
automatically. The ApplicationSet creates the Application from Git; no extra
registration file or shared ingress script change is needed. Check the generated
`staging-billing-api` Application's sync/health and test its hostname. Add the app
to the README registry and provide a release/backup runbook for stateful apps.

For database releases, pause the live Application's automatic sync and resume it
after verification. `ignoreApplicationDifferences` preserves the pause while the
ApplicationSet updates other fields. See [Argo CD's maintenance pause guidance](https://argo-cd.readthedocs.io/en/stable/operator-manual/applicationset/Controlling-Resource-Modification/#allow-temporarily-toggling-auto-sync).

Application auto-pruning is disabled by default. If a directory is removed, its
generated Application is removed, while `preserveResourcesOnDeletion: true`
preserves workloads. Pause the app before retiring it and deliberately clean up
its resources; removing Git files alone is not a complete decommission procedure.

## Move the existing app to a namespace later

`myfastapiapp` remains excluded from automatic discovery to retain Application
`myfastapiapp-postgres-application` and its existing volume binding in `default`.
Moving it requires a separate maintenance window: back up and verify recovery,
pause sync and stop writers, plan the retained PV's claim rebinding or restore
into a new volume, provision namespace-scoped credentials, then move workloads
and verify recovery before resuming traffic. Changing only the Application's
destination namespace does not migrate the database or its data.
