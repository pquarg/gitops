# Legacy Kubernetes PostgreSQL

These manifests and helpers remain for existing-database backup, migration and
recovery. They are excluded from the active local overlay. Fresh deployments
use [infra-local's separate database](../../../../../../infra-local/docs/database.md).

Follow the [cutover runbook](../../../../../docs/local/database-migration.md) to move
existing records through a verified dump/restore. Preserve the original mounted
directory, Secrets and PV/PVC until retirement is explicitly authorized.
Applying this directory manually can restart the old server; do so only as part
of reviewed legacy recovery. Its `backup.sh` and `delete-data.py` target only the
legacy Kubernetes/laptop storage, never the new Docker volume.
