# Upgrade an existing staging installation

The directory simplification preserves the rendered app resources, release
image, Application name, namespace, Postgres volume path and retained binding.
It requires no database reset or namespace migration.

Ingress now requires the direct `127.0.0.1:80` to node port `30080` mapping in
`kind/cluster.example.yaml`. Clusters without it require the planned rebuild
below. `setup-ingress-kind.sh` reports a missing mapping before checking Traefik;
it no longer creates a separate ingress container.

## Updated paths

- App manifests moved from `apps/myfastapiapp/base/` into `apps/myfastapiapp/`.
  Continue deploying the root `apps/myfastapiapp/kustomization.yaml`.
- App configuration now lives directly in `configmap.yaml`; the root selects
  the release image for both the API and migration Job.
- The backup command is now `./apps/myfastapiapp/postgres/backup.sh`.
- App setup, releases and recovery are in [the app README](../apps/myfastapiapp/README.md).
  The database reset procedure is [alongside Postgres](../apps/myfastapiapp/postgres/reset.md).
- Fresh clusters use `kind/cluster.example.yaml` and an ignored
  `kind/cluster.local.yaml`. Keep existing ignored kind configs and their mounts
  until a planned rebuild.

Current Secret file paths are unchanged. For a checkout predating the earlier
Postgres directory move, copy an ignored Secret from the old path only if it exists:

```sh
cp -n apps/myfastapiapp/overlays/postgres/postgres-secrets.yaml \
  apps/myfastapiapp/postgres/postgres-secrets.yaml
chmod 600 apps/myfastapiapp/postgres/postgres-secrets.yaml
git check-ignore apps/myfastapiapp/postgres/postgres-secrets.yaml
```

Keep the existing password. Git does not relocate ignored files when pulling
tracked directory changes.

## Registration management

Validate and push the changes. Argo CD reads `main` from GitHub. If the existing
cluster has not adopted the root registration, connect the Git repository using
a credential without a project scope, then run:

```sh
./scripts/bootstrap-kind.sh
./scripts/setup-ingress-kind.sh
```

The `staging-bootstrap` Application manages Traefik, the new-app ApplicationSet
and the existing app registration. It preserves live auto-sync pauses. The
ApplicationSet excludes `myfastapiapp`, preserving its current identity and
namespace. Continue using `default` for its workloads and Secrets. Moving the
app into its own namespace remains a separate data and ownership migration;
see [the namespace migration guidance](adding-apps.md#move-the-existing-app-to-a-namespace-later).

## Shared storage at the next rebuild

The new kind example mounts a single laptop parent into `/mnt`. Each database
uses its own `<app>-postgres/` subdirectory. It retains the current app's node
label so its PV can continue using `/mnt/myfastapiapp-postgres` unchanged.

Do this during a deliberate rebuild, after backing up and verifying recovery:

1. Record the actual `hostPath` from the existing local kind config and preserve
   that directory and the original database credentials. Follow the app's
   [backup procedure](../apps/myfastapiapp/README.md#back-up-and-release-a-database-change),
   pause auto-sync, stop writers and shut down Postgres cleanly before replacing
   the cluster or copying its files. Only one server may use a data directory.
2. Create a new laptop storage parent outside Git, such as
   `$HOME/.local/share/staging/postgres`. With Postgres stopped, copy the complete
   original data directory into its `myfastapiapp-postgres/` subdirectory,
   including `pgdata` and its permissions. Keep the original copy until recovery
   is verified. An empty subdirectory would initialize a new database.
3. Copy `kind/cluster.example.yaml` to the ignored `kind/cluster.local.yaml`.
   Set `hostPath` to the new parent, retaining `/mnt`, both node labels and the
   direct localhost port mapping. Editing this file does not change a running cluster.
4. Free localhost port 80 before creating the replacement cluster. Identify any
   container publishing that port:

   ```sh
   docker ps --filter publish=80 --format 'table {{.Names}}\t{{.Ports}}'
   ```

   Stop and remove the old ingress container if present. For the default cluster,
   its name is `kind-ingress-argocd-postgres-gateway-1`. This cleanup does not need
   the removed Compose configuration.

5. Recreate the cluster using the new config and [setup guide](setup.md), then
   restore the app's Secrets and selected image before bootstrapping. Verify the
   database contains the expected records and the app works. The existing PV/PVC
   names and namespace stay the same.

After this one-time change, adding a database requires creating its subdirectory
and app-owned PV/PVC; the kind mount stays unchanged.

The checkout changes do not rebuild a cluster, copy database files, stop the
old ingress container or migrate the existing namespace automatically.
