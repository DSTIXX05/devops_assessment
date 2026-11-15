# Environment roots

One Terraform root per environment. They share reusable modules from
`../modules/` and differ only in inputs, state key, and CIDR range.

| Root    | State key                | VPC CIDR (planned) | Purpose                      |
| ------- | ------------------------ | ------------------ | ---------------------------- |
| `dev/`  | `dev/terraform.tfstate`  | `10.20.0.0/16`     | Build and validate the stack |
| `prod/` | `prod/terraform.tfstate` | `10.30.0.0/16`     | Final deployment evidence    |

Separate roots rather than Terraform workspaces: a workspace shares one backend
key pattern and is easy to apply against the wrong environment by accident,
whereas a separate root has its own directory, its own `terraform.tfvars`, and
its own state object. Duplication is 6 small files.

## Why the backend is fully specified, not partial

`backend.tf` contains the bucket name outright rather than relying on
`-backend-config` flags at init time. It means `terraform init` just works, and
the state location is discoverable by reading the code.

The bucket name embeds the AWS account ID, so forking this repository into
another account requires editing one line in each `backend.tf`. That is a
documented one-line change; the alternative — a gitignored `backend.hcl` per
environment — trades that one line for a mandatory flag on every `init`.

## Workflow

```bash
cd infrastructure/environments/dev
cp terraform.tfvars.example terraform.tfvars     # first time only, then edit
../../scripts/with-operator-creds.sh terraform init
../../scripts/with-operator-creds.sh terraform plan
../../scripts/with-operator-creds.sh terraform apply
```

Never run `terraform` directly in these directories. A bare invocation skips the
credential export and the root-identity check, and can authenticate as the wrong
identity through the CLI's cached login session. The `identity_guard` resource in
`main.tf` is the second line of defence: it fails the plan outright if the
caller ARN ends in `:root`.

## State locking

`use_lockfile = true` uses S3 conditional writes to write a lock object beside
the state object. A concurrent `apply` fails immediately rather than racing.
Requires Terraform >= 1.10 (pinned to 1.17.x) and no DynamoDB table.

If a lock is ever left behind after a crash, confirm no other run is active, then
remove the `.tflock` object for that key — do not delete the state object.

## Teardown order

1. `terraform destroy` in `prod/`
2. `terraform destroy` in `dev/`
3. `terraform destroy` in `bootstrap/` — only when the project is finished

The state bucket must outlive every root that stores state in it.

## Current phase

**Phase 4 — networking and security groups.** `main.tf` calls two modules:

| Module       | Creates                                                                  | Cost |
| ------------ | ------------------------------------------------------------------------ | ---- |
| `networking` | VPC, 2 public subnets across 2 AZs, internet gateway, public route table | $0   |
| `security`   | ALB security group, task security group, and their four rules            | $0   |

Still to come: `ecr`, `alb`, `ecs` (Phase 5 — first phase with a real hourly
cost) and `monitoring` (Phase 6).

`plan` in `dev` currently shows **15 resources to add, all free**.
