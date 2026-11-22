# Reaction Explorer

The portable base runs the React UI and read-only FastAPI API in one web image.
Only the [local overlay](overlays/local/README.md) is enabled. Argo CD discovers
it through the existing local ApplicationSet; no per-app registration is needed.
The source and image builds live in the separate reaction-explorer app checkout.

The external deployment warehouse is provisioned by infra. Source schema and
pinned-data preparation are explicit operator steps using [schema.sql](schema.sql)
and the app's locked pipeline/dbt code. Web sync does not run the pipeline or
receive warehouse writer credentials. No PostgreSQL, storage or Airflow resources
are managed by this Application.
