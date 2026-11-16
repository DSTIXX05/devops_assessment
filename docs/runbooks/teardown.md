# Teardown runbook

Back to [README](../../README.md) · Related: [deployment](deployment.md) · [design decisions](../design-decisions.md)

Tearing down takes about five minutes and is proven to work. It was executed twice
during this build, once by accident and once deliberately. The account ends at **$0/month**
with only the state bucket, budget and CI roles remaining.

---

## What is destroyed, and what is not

|                     | Destroyed                                                                                                                                                                  | Survives                                                |
| ------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------- |
| `environments/dev`  | VPC, subnets, IGW, security groups, ALB, target group, listener, ECS cluster, service, task definition, IAM roles, ECR repository + images, log group, 5 alarms, SNS topic |,                                                       |
| `environments/prod` | Same                                                                                                                                                                       |,                                                       |
| `bootstrap/`        |,                                                                                                                                                                          | S3 state bucket, budget, bucket policy, lifecycle rules |
| `ci/`               |,                                                                                                                                                                          | 2 deploy roles, OIDC provider trust                     |

**Do not destroy `bootstrap/` or `ci/`.** The bucket holds the state of the other roots,
and the roles are what let the pipeline run at all. Both are free or near-free.

If you genuinely need to remove everything, that is a separate, final act: destroy
`environments/*` first, then `ci/`, then `bootstrap/`, and note that destroying
`bootstrap/` deletes the state bucket, so any remaining root's state is lost with it.

---

## Order matters

```
1. empty both ECR repositories   ← deliberate step, see below
2. destroy prod
3. destroy dev
4. verify
```

`prod` before `dev` so that if something goes wrong mid-way, the lower environment is
still up and can be used to diagnose.

---

## 1 - Empty the ECR repositories

`modules/ecr` sets `force_delete = false` by default. This means `terraform destroy`
**will refuse** to delete a repository that still contains images:

```
Error: ECR Repository (devops-assessment-prod-app) not empty
RepositoryNotEmptyException: The repository with name 'devops-assessment-prod-app'
in registry with id '471112980487' cannot be deleted because it still contains images
```

That is the protection working. The repository keeps every release artefact, and a
`terraform destroy` should not silently discard them.

Empty it explicitly:

```bash
cd infrastructure
./scripts/with-operator-creds.sh ./scripts/empty-ecr.sh devops-assessment-prod-app
./scripts/with-operator-creds.sh ./scripts/empty-ecr.sh devops-assessment-dev-app
```

Expect output like `deleting 12 image(s)` followed by `remaining images: 0`.

> **Prefer this over setting `force_delete = true`.** Flipping the variable would solve a
> one-off inconvenience permanently, and the next `destroy`, possibly run by someone
> else, possibly by accident, would delete releases without asking.

---

## 2 & 3 - Destroy the environments

Use **absolute paths**. A previous instruction chained `cd environments/prod` then
`cd ../dev`; when the paste was interrupted, the second destroy silently never ran and the
teardown looked "partly failed" when in fact it had never started.

```bash
cd /path/to/repo/infrastructure/environments/prod
../../scripts/with-operator-creds.sh terraform destroy -auto-approve -input=false
```

```bash
cd /path/to/repo/infrastructure/environments/dev
../../scripts/with-operator-creds.sh terraform destroy -auto-approve -input=false
```

Expect `Destroy complete! Resources: 34 destroyed` for each. It takes a few minutes: the
ECS service drains (30s deregistration delay), then the ALB is deleted, then networking.

---

## 4 - Verify

```bash
cd infrastructure
./scripts/with-operator-creds.sh bash -c '
echo "ENVIRONMENTS (expect 0)"
printf "  ALBs             : %s\n" "$(aws elbv2 describe-load-balancers --query "length(LoadBalancers)" --output text)"
printf "  ECS clusters     : %s\n" "$(aws ecs list-clusters --query "length(clusterArns)" --output text)"
printf "  ECR repositories : %s\n" "$(aws ecr describe-repositories --query "length(repositories)" --output text)"
printf "  Non-default VPCs : %s\n" "$(aws ec2 describe-vpcs --filters Name=isDefault,Values=false --query "length(Vpcs)" --output text)"
printf "  Log groups       : %s\n" "$(aws logs describe-log-groups --log-group-name-prefix /ecs/devops-assessment --query "length(logGroups)" --output text)"
printf "  Alarms           : %s\n" "$(aws cloudwatch describe-alarms --alarm-name-prefix devops-assessment --query "length(MetricAlarms)" --output text)"
echo
echo "FOUNDATION (expect these to remain)"
printf "  State bucket     : %s\n" "$(aws s3api get-bucket-versioning --bucket devops-assessment-tfstate-471112980487-us-east-1 --query Status --output text)"
printf "  CI deploy roles  : %s\n" "$(aws iam list-roles --query "Roles[?contains(RoleName, \`github-deploy\`)].RoleName" --output text)"
'
```

Both Terraform states should also be empty of resources:

```bash
cd environments/prod && ../../scripts/with-operator-creds.sh terraform state list
cd ../dev && ../../scripts/with-operator-creds.sh terraform state list
```

---

## Consequence: the live URLs die

Both ALB DNS names disappear. Anything linking to them, a README, a ticket, a message to
a reviewer, becomes a dead link. This README says so explicitly at the top for exactly
that reason.

**The GitHub variables still point at the deleted load balancers.** That is expected. If
someone dispatches the workflow with no infrastructure, the deploy fails at the health
check. That is the gate doing its job, but it looks like a defect to anyone who has not
read this page.

To bring the stack back: [deployment runbook](deployment.md), then **update
`ALB_DNS_NAME` in both scopes** before redeploying. It is a generated value, so it changes
on every rebuild.

---

## If the destroy fails

| Error                                     | Cause                                                       | Fix                                                                        |
| ----------------------------------------- | ----------------------------------------------------------- | -------------------------------------------------------------------------- |
| `ECR Repository … not empty`              | `force_delete = false`                                      | Step 1 above                                                               |
| `Error acquiring the state lock`          | Another Terraform process holds the lock                    | See below                                                                  |
| VPC `DependencyViolation`                 | A resource still references the VPC, usually an ALB or ENI | Check for a leftover load balancer, then re-run; Terraform retries cleanly |
| `ResourceInUseException` on the log group | A task is still writing                                     | Wait for the service to finish draining, then re-run                       |

### State lock

`use_lockfile = true` uses an S3 conditional write. A second operation against the same
state is refused:

```
StatusCode: 412  PreconditionFailed
Lock Info:
  ID:        892713ec-454e-fc55-95fd-b1fdbed79253
  Operation: OperationTypeApply
  Who:       dstixx05@dstixx05-denmark
  Created:   2026-11-16 08:47:21 +0000
```

**This means the lock worked.** Without it, two processes would have written state
concurrently and produced silent divergence rather than an error.

The first question is _what else is running_, not _why is the lock broken_:

```bash
pgrep -af terraform
```

If nothing is running and the lock is genuinely stale, a `SIGKILL`ed process leaves the
object behind, because **S3 lockfile locks do not expire**. Clear it deliberately:

```bash
terraform force-unlock 892713ec-454e-fc55-95fd-b1fdbed79253
```

Only do this when you are certain no other operation is in flight.

> A cancelled command is not a stopped command. Killing the wrapper script does not
> necessarily kill the `terraform` child, which keeps the lock and keeps working. This is
> how the concurrency in this build happened.
