# Set up local app deployment

Run commands from `gitops` unless stated otherwise. The default cluster is
`deployment`, context `kind-deployment`. App sync connects to a separately
provisioned Compose database; it does not create PostgreSQL or mount storage.

## 1. Prepare the platform with infra/environments/local

Follow [infra/environments/local's README](https://github.com/pquarg/infra/blob/main/environments/local/README.md) to provision separate
Compose PostgreSQL, configure the kind localhost port mapping, create the cluster, install Argo CD
and install shared Traefik through Terraform Helm. Complete its database first
setup and create the ignored kind configuration before running its platform
scripts. Skip cluster creation for an existing cluster. From `gitops`, switch
to `infra/environments/local` for these commands, then return:

```sh
cd ../infra/environments/local
./scripts/local-database.sh up
./scripts/local-database.sh status
./scripts/create-cluster.sh
./scripts/bootstrap-kind.sh
cd ../../../gitops
```

Expect PostgreSQL to be healthy before continuing. If `database/.env` or its
password files are missing, follow [database first setup](https://github.com/pquarg/infra/blob/main/environments/local/docs/database.md#first-setup).
Installing Argo CD does not create those files or start PostgreSQL.

The platform must provide:

- Argo CD in namespace `argocd`, with Application and ApplicationSet CRDs ready.
- Shared Traefik in namespace `traefik` and IngressClass `traefik`.
- `127.0.0.1:80` mapped to Traefik's NodePort `30080`.
- A running separate PostgreSQL database reachable from kind Pods at
  `host.docker.internal:5433` using the restricted app login (Docker Desktop).

The cluster needs no app database mount or storage node label.

## 2. Connect the deployment Git repository

Open the Argo CD UI following [infra/environments/local's sign-in instructions](https://github.com/pquarg/infra/blob/main/environments/local/README.md#2-install-argo-cd-and-shared-ingress).
Under **Settings → Repositories**, connect
`git@github.com:pquarg/gitops.git` with a read-only Git credential usable
by the `default` project. Argo CD must show the repository connection as
successful before registration. If using another remote, update every
`repoURL` in `bootstrap/local.yaml` and `argocd/local/apps.yaml` to match it.

This credential reads deployment manifests. App registry credentials are
separate and belong in each app's namespace. No credential for an `infra/environments/local`
Git remote is required: its platform configuration is applied from disk.

## 3. Prepare the apps

Follow each app's README to provision its namespace, connection and registry
Secrets and selected image before automatic sync. Run its Pod-to-database
connectivity probe before registration.
Start with [demo-api](../../apps/demo-api/overlays/local/README.md#provision-credentials).
For more apps, follow [adding apps](../adding-apps.md) and
[registry credentials](credentials.md#registry-authentication).

For `demo-api`, complete these checks in order before bootstrap:

1. Create namespace `demo-api` if it does not exist.
2. Configure `registry-credentials` with the [interactive helper](credentials.md#registry-authentication)
   and a classic GitHub PAT with `read:packages`.
3. Apply `demo-api-secrets` using the existing Compose **app** password
   and `host.docker.internal:5433`, as shown in the app runbook.
4. Make the selected image available and run
   `./scripts/check-demo-api-local-database.py --environment local --context kind-deployment`.
   Continue only after it prints
   `Database connectivity, app privileges and transactional DDL passed.`

A `secret/... created` message confirms storage of a Secret, not that its
credentials work. A `job.batch/... created` message confirms submission of the
probe, not a successful database connection. If it appears to hang, use
[probe troubleshooting](../../apps/demo-api/overlays/local/README.md#troubleshoot-the-first-sync).

The same release image is used for the API and its migration Job. Build and
publish it, or load that exact image into the local kind cluster. Database
credentials and filled Secret files stay outside Git and Kustomize.

## 4. Validate, publish and register apps

Install the [validation tools](../validation.md), then run:

```sh
./scripts/validate.sh
git diff --check
```

Review, commit and push any manifest changes. Keep filled Secrets ignored;
applying or rotating credentials does not require committing them.
Argo CD reads GitHub `main`; it cannot deploy manifests that exist only in this
checkout. With the platform and credentials ready:

```sh
./scripts/bootstrap.sh --environment local --context kind-deployment
kubectl --context kind-deployment -n argocd get applications
```

The script validates first, checks the Argo CD controllers and shared ingress, then applies only
`bootstrap`. The bootstrap Application manages the ApplicationSet in `argocd/local/kustomization.yaml`.
It discovers every `apps/*/overlays/local` entry point and creates an independent Application,
including `demo-api` in namespace `demo-api`. Each app runs
migrations against the existing database and rolls out the API. Traefik
is managed separately by `infra/environments/local`.

Bootstrap **Synced** means registration was applied; wait for the app's own
**Synced / Healthy** status before testing. Follow its
[verification procedure](../../apps/demo-api/overlays/local/README.md#verify-the-deployment).
The HTTP route is localhost port 80 → kind node port 30080 → shared Traefik →
app Service. Docker Desktop and the cluster must remain running.

## Recovery

The current Compose database survives kind replacement independently. Follow
[platform rebuild](https://github.com/pquarg/infra/blob/main/environments/local/docs/rebuild.md#rebuild-with-the-external-compose-database)
and [database backup/restore](https://github.com/pquarg/infra/blob/main/environments/local/docs/database.md#backup-and-restore).
Recreate Kubernetes Secrets/images and verify Pod connectivity before registration;
verify existing records and login afterward.

The common entry point also accepts `--kubeconfig /absolute/path`. It requires an
explicit context and uses the same file/context for every Kubernetes command.
Shared Traefik is a Terraform Helm release; Argo CD reconciles application resources.
