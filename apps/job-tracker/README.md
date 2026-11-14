# Job tracker

Source, builds and tests live in the separate private
[job-tracker repository](https://github.com/pquarg/job-tracker).
The shared base provides namespace, API/worker/frontend Deployments, Services
and a wave-0 migration hook. Only the [local overlay](overlays/local/README.md)
is enabled. AWS registrations and demo-api are unchanged.

Private documents, accounts and derived records live in a dedicated PostgreSQL
database provisioned by infra. GitOps owns app resources, never PostgreSQL storage.
Prepare database, private configuration and exact images **before publishing**
the local overlay; discovery/sync is automatic.
