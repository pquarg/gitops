# Set up and verify AWS production

Production uses `infra/environments/aws/prod`, the `aws-project-prod` profile
and its own EKS cluster, RDS database and state. Finish the foundation and
platform steps in the [production infrastructure runbook](https://github.com/pquarg/infra/blob/main/environments/aws/prod/README.md).
Connect the GitOps repository to production Argo CD with a separate read-only
credential. The application and its migration Job obtain the connection URL
from `demo-api-secrets`. Keep credentials and backups outside Git.

Prepare the database and registry credentials on the production cluster:

```sh
PROD_CONTEXT=aws-deployment-project-prod
PROD_ACCOUNT=$(cat ../infra/environments/aws/prod/config/account-id)
python3 scripts/bootstrap-demo-api-rds.py "$PROD_CONTEXT" \
  --environment prod --account-id "$PROD_ACCOUNT"
```

Follow the [registry instructions](../aws/credentials.md#registry-authentication)
using the production context and namespace `demo-api`. Verify the ALB security
group name in the overlay matches the production foundation output
`myfastapiapp_alb_security_group`.

The checked-in initialization uses a reserved all-zero digest. Bootstrap rejects
it until a tested staging digest has been [promoted](../release-promotion.md#verify-staging-and-promote).
On the clean, published GitOps `main` revision:

```sh
./scripts/validate.sh --environment prod --no-placeholders
./scripts/validate-server.sh demo-api --environment prod --context "$PROD_CONTEXT"
./scripts/bootstrap.sh --environment prod --context "$PROD_CONTEXT"
```

Review Argo CD's diff and manually sync the full `demo-api` Application at the
approved revision so the migration hook runs. Confirm the migration succeeded,
both replicas are ready, and the Gateway and HTTPRoute are accepted. The
production ALB is `prod-demo-api`. Verify it has healthy targets before planning
edge, then run the staging [endpoint checks](../aws/setup.md#5-sync-and-verify-the-app)
using the production CloudFront URL and context. Use read-only smoke tests for
production and record the image digest, migration result and GitOps revision.
