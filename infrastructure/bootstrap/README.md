# Terraform bootstrap

Creates the two resources that must exist before any environment root can be
planned: the **S3 bucket for Terraform remote state** and the **AWS Budget cost
guardrail**.

## Why this is a separate root

An S3 backend cannot create the bucket it stores state in. This root therefore
uses **local state** (`terraform.tfstate` in this directory, gitignored). That
file is the only local state in the project and should be retained until the
assessment environment is torn down.

## Prerequisites

1. Terraform 1.17.x (`infrastructure/.terraform-version` records the tested
   version).
2. A valid operator session for the non-root admin profile `AdminDelightsome`
   (`arn:aws:iam::471112980487:user/delightsomeAdmin`):

   ```bash
   aws login --profile AdminDelightsome
   ```

   Verify the returned account ID is the one you intend to bill. This root does
   not create a spending cap, and applying to the wrong account would place
   resources — and a budget — in the wrong place.

## Credentials: always use the wrapper

```bash
cd infrastructure/bootstrap
../scripts/with-operator-creds.sh terraform plan -out=bootstrap.tfplan
../scripts/with-operator-creds.sh terraform apply bootstrap.tfplan
```

**Do not set `aws_profile` in `terraform.tfvars`.** Every profile in this account
authenticates through the AWS CLI console-login mechanism (`login_session` in
`~/.aws/config`). When the Terraform AWS provider is given a `profile`, it
resolves that mechanism through an **account-scoped token cache** and can
silently authenticate as the wrong identity.

This was observed, not theorised: with `aws_profile = "Delightsome"` the plan
rendered `aws_caller_arn = arn:aws:iam::471112980487:root`, even though
`aws sts get-caller-identity --profile AdminDelightsome` reported the IAM user.
Exporting that same session's credentials did not help while `profile` remained
set — the exported environment credentials were ignored.

`with-operator-creds.sh` exports short-lived credentials from the named session,
leaves `profile` null inside Terraform so the standard environment credential
chain applies, and **aborts if the resolved identity is root**.

Cost of getting this wrong: every resource would be created by the account root
user, which is exactly what §9.1 and §12.2 of the design document forbid.

## Apply

```bash
cd infrastructure/bootstrap
cp terraform.tfvars.example terraform.tfvars   # then edit
terraform init
../scripts/with-operator-creds.sh terraform plan -out=bootstrap.tfplan
../scripts/with-operator-creds.sh terraform apply bootstrap.tfplan
terraform output
```

To enable budget email alerts, set `budget_notification_email` in
`terraform.tfvars`. Without it the budget still exists and is still evaluated,
but nothing notifies you.

## Cost

| Resource                                 | Cost                                                                                          |
| ---------------------------------------- | --------------------------------------------------------------------------------------------- |
| S3 bucket (state, a few KB, versioned)   | Fractions of a cent per month                                                                 |
| S3 lifecycle aborting incomplete uploads | $0                                                                                            |
| AWS Budgets                              | **$0** — the first two budgets per account are free and email notifications need no SNS topic |

Server-side encryption uses **SSE-S3**, which is free. SSE-KMS would add a
per-key monthly charge plus key-policy management; state holds resource
attributes and identifiers, not application secrets, so KMS is not justified
here. Revisit if the state ever contains sensitive values.

The budget is a **notification, not a hard cap**. AWS does not stop resources
when a threshold is crossed.

## Outputs consumed downstream

| Output                | Used by                     |
| --------------------- | --------------------------- |
| `state_bucket_name`   | `environments/*/backend.tf` |
| `state_bucket_region` | `environments/*/backend.tf` |

Wire them into the environment root with a partial backend configuration and
pass the values at init time, for example:

```bash
terraform init \
  -backend-config="bucket=$(terraform -chdir=../../bootstrap output -raw state_bucket_name)" \
  -backend-config="region=$(terraform -chdir=../../bootstrap output -raw state_bucket_region)" \
  -backend-config="key=dev/terraform.tfstate"
```

## Teardown order

The state bucket must outlive everything it stores state for.

1. `terraform destroy` in `environments/dev`, then `environments/prod`.
2. **Then** destroy this root — and only if the project is finished.

Deleting the bucket first orphans the state of any remaining resources and makes
them effectively unmanageable. Because versioning is enabled, the bucket also
contains noncurrent versions; destruction requires either removing them or
allowing Terraform to handle them.

## Deliberate omissions

- **No `prevent_destroy`** on the bucket. It would make the documented teardown
  path fail, and the safety it provides is already covered by the ordering rule
  above plus versioning.
- **No DynamoDB lock table.** Terraform 1.10+ supports native S3 state locking
  via `use_lockfile`, which the environment roots enable. A DynamoDB table would
  add a resource with no additional benefit.
- **No CI permissions.** This root is applied by a human operator only. See
  `PROJECT_LOG.md` — the infrastructure workflow never assumes an AWS role.
