# Upgrade an existing staging installation

This refactor preserves the existing app's rendered resources, Application name,
namespace and retained database binding. Local validation renders exactly the
same complete app manifests as before the directory changes. The base itself now
has neutral configuration; the app root supplies staging's hostname and message.

## Checkout and secret paths

The tracked Postgres files moved from `apps/myfastapiapp/overlays/postgres/` to
`apps/myfastapiapp/postgres/`. Git does not move ignored files when another
checkout pulls the changes. If your filled Secret remains at the old path:

```sh
cp -n apps/myfastapiapp/overlays/postgres/postgres-secrets.yaml \
  apps/myfastapiapp/postgres/postgres-secrets.yaml
chmod 600 apps/myfastapiapp/postgres/postgres-secrets.yaml
git check-ignore apps/myfastapiapp/postgres/postgres-secrets.yaml
```

Use this only if the old file exists. Keep the existing password; no credential
rotation or database restart is needed for this move. App Secret exclusions now
cover every app, including both old and new paths.

## Adopt registration management

Validate and push the refactor before applying the root registration. Confirm
Argo CD can read `main`; the ApplicationSet needs a repository credential without
a project scope. Then run:

```sh
./scripts/bootstrap-kind.sh
./scripts/setup-ingress-kind.sh
```

The new `staging-bootstrap` Application manages the existing app registration,
Traefik registration and ApplicationSet. It preserves live automatic-sync pauses
on child Applications. The ApplicationSet excludes the existing app, so it never
creates a competing registration for that deployment. Future registration changes
under `argocd/` take effect through Git. The root Application itself remains a
one-time bootstrap file; reapply it if its source settings change.

The manual `deploy-kind.sh` sequence has been removed. On fresh clusters, install
Argo CD first and let its existing migration hooks and waves deploy apps. For
routine changes, follow [releases](releases.md).

## Keep the current gateway until a planned rebuild

Existing kind clusters have no new port mapping just because a config file
changed. `setup-ingress-kind.sh` detects the mapping and uses the legacy gateway
under `kind/legacy/` when needed. Its Compose project name is unchanged, so it
updates the existing gateway rather than starting another one. The shared setup
script no longer applies app Ingress resources.

During the next deliberate cluster rebuild:

1. Follow the backup and recovery procedure; preserve the database directory and
   its original credential. A rebuild removes Kubernetes objects and Secrets.
2. Stop and remove the legacy gateway before creating the new cluster so port 80
   is free:

   ```sh
   KIND_NODE=argocd-postgres-control-plane docker compose \
     --project-name kind-ingress-argocd-postgres -f kind/legacy/compose.yaml down
   ```

3. Add the example config's `extraPortMappings` to your ignored local kind config:

   ```yaml
   extraPortMappings:
     - containerPort: 30080
       hostPort: 80
       listenAddress: "127.0.0.1"
       protocol: TCP
   ```

4. Recreate and recover using the [setup guide](postgres-kind.md). The shared
   ingress script will detect the direct mapping and skip the gateway container.

No cluster deletion, namespace migration, live apply, or gateway shutdown is part
of editing this repository. Review and push the changes before adopting them.
