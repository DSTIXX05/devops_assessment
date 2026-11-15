# Project Log — DevOps Assessment

Incremental record of decisions, trade-offs, and learnings. Newest phase at the
bottom of each dated section.

---

## Quick reference

| Area               | Choice                                                                                                              |
| ------------------ | ------------------------------------------------------------------------------------------------------------------- |
| Application        | Node.js 24.14.1 LTS, Express 5.3.0, ESM                                                                             |
| Tests              | Node built-in test runner (`node --test`), no test framework dependency                                             |
| Container          | Multi-stage Dockerfile, `node:24.14.1-alpine`, non-root UID 1000                                                    |
| Container health   | `node -e fetch(...)` in `HEALTHCHECK` — no curl/wget added                                                          |
| Compute            | Amazon ECS on AWS Fargate (desired count **1**)                                                                     |
| Registry           | Amazon ECR, SHA-tagged images, scan-on-push **informational**                                                       |
| Vulnerability gate | **Trivy in CI, blocking on HIGH and CRITICAL**                                                                      |
| Ingress            | ALB, HTTP:80 (no domain → no ACM/TLS), target port 3000                                                             |
| Network            | Two-AZ VPC, public subnets, **no NAT Gateway**                                                                      |
| IaC                | Terraform **1.17.1** (tested build; approved as 1.17.2, amended), region **us-east-1**, S3 backend + `use_lockfile` |
| Terraform provider | `hashicorp/aws` **6.73.0** (pinned in `.terraform.lock.hcl`)                                                        |
| Operator profile   | `AdminDelightsome` (IAM user + MFA) via `scripts/with-operator-creds.sh` — never root                               |
| Environments       | Separate `dev` and `prod` roots sharing reusable modules                                                            |
| Terraform apply    | **Local operator using an AWS admin CLI profile**                                                                   |
| CI/CD              | GitHub Actions (see ADR-003 justification below)                                                                    |
| AWS auth in CI     | GitHub OIDC → role scoped to ECR push + ECS deploy only                                                             |

---

## 2026-11-14 — Approved architecture decisions (pre-build)

Confirmed by the user before implementation:

1. Terraform 1.17.2, AWS region `us-east-1`.
2. Separate `dev` and `prod` environment roots that share reusable modules.
3. Initial ECS desired count is 1. The deployment must **not** be described as
   highly available (single task = single point of failure).
4. Trivy runs in CI as a **blocking** scanner; fail on HIGH and CRITICAL. ECR
   scanning remains informational only.
5. Terraform provisioning is performed **locally** with the operator's AWS admin
   CLI profile. That admin identity is never used in GitHub Actions, so the
   infrastructure workflow cannot and must not run `terraform apply`.
6. The ALB DNS name is exported through Terraform outputs for the deployment
   workflow to consume.
7. Container health checks use Node's built-in HTTP client (`fetch`) rather than
   adding `curl` to the image.
8. The GitHub Actions vs Jenkins decision is documented with the operational
   overhead of maintaining a Jenkins server as the primary justification.

### Resolution of open items from §20 of the design document

- **Infrastructure workflow scope.** Because `apply` is local-only (decision 5),
  the `infrastructure.yml` workflow runs `fmt`, `init -backend=false`,
  `validate`, and a `plan` against the `dev` root, and stops there. It does not
  assume an AWS role. Operator applies happen from the workstation with the
  admin profile. This removes the second OIDC role the design document implied
  but never defined, and eliminates the privilege-escalation risk of a CI role
  that can create IAM resources.
- **Image scanning.** ECR scan-on-push is asynchronous and therefore cannot
  block a pipeline. Trivy runs synchronously in CI and fails the build on HIGH
  or CRITICAL findings. ECR scanning stays enabled as informational depth
  (including base-OS findings Trivy may classify differently).
- **ALB DNS consumption.** The `alb` module outputs `dns_name`; the `dev` and
  `prod` roots re-export it. The deployment workflow reads it from a GitHub
  repository variable that the operator sets from `terraform output`, so the
  deploy role needs no `elasticloadbalancing:Describe*` permission.

---

## 2026-11-14 — Phase 1: application, container, local verification

### Implemented

- `app/src/config.js` — environment-driven config with validation. Port 0 is
  allowed for ephemeral test binds; invalid `PORT` fails fast instead of
  silently falling back to a default.
- `app/src/logger.js` — dependency-free JSON logger, one object per line.
  `info`/`debug` → stdout, `warn`/`error` → stderr. Non-serialisable fields are
  caught so logging can never crash a request.
- `app/src/app.js` — app factory (no port binding) so tests can drive it
  directly. Request correlation id, access logging, JSON 404, central error
  handler, `x-powered-by` disabled.
- `app/src/server.js` — listener plus shutdown lifecycle: SIGTERM/SIGINT →
  `/health` returns 503 → close idle sockets → drain → exit 0, force-exit 1
  after `SHUTDOWN_TIMEOUT_MS`.
- `app/Dockerfile` — three stages (`deps`, `test`, `runtime`).
- 23 tests across 4 suites; all pass on host and inside the container test
  stage.

### Key decisions & trade-offs

**Structured logging without a framework.** Pino/Bunyan would add a dependency
and an extra HIGH/CRITICAL surface for the Trivy gate. A ~40-line logger covers
what the assessment needs: JSON lines the `awslogs` driver can parse. Cost:
no log redaction helpers or transports; acceptable because no sensitive fields
are logged at all.

**`/health` returns 503 during drain.** A health endpoint that keeps returning
200 while the process is shutting down causes the ALB to keep routing traffic to
a dying task. Reporting 503 from the moment shutdown starts lets the load
balancer remove the target before the listener closes. This is why the endpoint
is behind a mutable `draining` flag on the app rather than a constant response.

**Two distinct health checks, deliberately.** The Docker `HEALTHCHECK` uses a
Node one-liner (decision 7) so no `curl`/`wget` is added purely for health. On
ECS, the Docker `HEALTHCHECK` is ignored — Fargate uses the task definition
`healthCheck`, and the ALB has its own target-group check. Three mechanisms,
two boundaries: in-container liveness vs. reachability through the task ENI.

**Keep-alive and header timeouts raised above the ALB idle timeout.** Node's
default 5s keep-alive is shorter than the ALB's 60s idle timeout. Without
raising it to 65s/66s, the server can close a connection the ALB still believes
is usable, producing sporadic 502s under low traffic — exactly the traffic
pattern of an assessment environment.

**`--ignore-scripts` on `npm ci` in the image.** Dependency lifecycle scripts
are arbitrary code execution at build time. Nothing in this tree requires them.

**Drain timeout 10s, deliberately below a 30s ALB deregistration delay.** The
app finishes draining well before ECS stops waiting, so ECS never has to
SIGKILL the container. Both values are asserted by tests rather than left to
drift.

**Image is 230 MB on disk.** The `node:24-alpine` base accounts for most of it;
the Express tree is small. A distroless base would cut size and CVE surface
further but complicates debugging (`no shell`) — a bad trade for an assessment
a reviewer needs to inspect.

**Tests use the real HTTP server, not a mocked request object.** Fetching over
loopback exercises the same path the ALB will hit. The shutdown suite spawns the
actual `src/server.js` child process and asserts exit code 0 plus the log
sequence, so signal handling is verified end to end and not just by calling a
function.

### Observations / non-blocking notes

- `ecr:GetAuthorizationToken` is account-scoped in AWS and cannot be resource
  restricted. The deploy role will have exactly one `Resource: "*"` statement
  for this action, with a comment explaining why. Flagged so it reads as a
  known AWS constraint rather than an oversight.
- Local Trivy is not installed. The first real scan happens in CI; if it
  surfaces a base-image HIGH/CRITICAL, the fix is bumping the pinned Node base
  image, not suppressing the finding.
- No `dev` dependencies exist, so the `test` stage currently installs the same
  production tree plus test sources. It still validates that tests run against
  the lockfile that ships.

### Verification evidence (Phase 1)

| Check                               | Result                                                                |
| ----------------------------------- | --------------------------------------------------------------------- |
| `npm test` (host, Node 24.14.1)     | 23/23 pass, 0 fail                                                    |
| `npm test` (container `test` stage) | 23/23 pass, 0 fail                                                    |
| `docker build`                      | success, 230 MB                                                       |
| Container user                      | `uid=1000(node) gid=1000(node)`                                       |
| `GET /`                             | 200, JSON service info                                                |
| `GET /health`                       | 200 `{"status":"ok"}`                                                 |
| `GET /api/status`                   | 200, full status payload                                              |
| `HEALTHCHECK`                       | `healthy`                                                             |
| `docker stop` (SIGTERM)             | exit code **0**, logs show `shutdown initiated` → `shutdown complete` |
| Runtime image contents              | `node_modules`, `package.json`, `src` only — no tests, no dev deps    |
| `npm audit`                         | 0 vulnerabilities                                                     |

### Key learnings

- Node's `server.close()` does not release idle keep-alive sockets; without
  `closeIdleConnections()` shutdown waits for the keep-alive timeout. Measured
  behaviour, not assumed.
- Fargate ignores Dockerfile `HEALTHCHECK` entirely. Assuming it applies is a
  common and silent mistake — the task definition must declare its own check.
- Config read at module import time cannot be tested by mutating
  `process.env` inside the run; a child process with a controlled environment is
  the reliable pattern.

---

## 2026-11-14 — Container size review (decision: no change)

Reviewer question: _"use multistage build to reduce the size of the container."_
The build was already multi-stage (`deps` → `test` → `runtime`). Measured, rather
than assumed:

| Measurement                                                     | Value                      |
| --------------------------------------------------------------- | -------------------------- |
| `node:24.14.1-alpine` base, on disk                             | 225 MB                     |
| Final image, on disk                                            | 230 MB                     |
| Final image, **compressed** (what ECR stores and Fargate pulls) | **54.2 MB**                |
| Base image, compressed                                          | 53.6 MB                    |
| Our contribution: `node_modules` + `src`                        | **4.3 MB + 20 KB ≈ 1.9 %** |
| `node` binary alone                                             | 119.3 MB                   |
| `npm` + `corepack` (unused at runtime)                          | 17.0 MB                    |

The multi-stage build is already delivering what it can: the runtime stage
copies only production `node_modules` and `src`. Our code is 1.9 % of the image;
the other 98 % is the Node runtime, which no stage split can remove.

Options considered and rejected:

- **Strip `npm`/`corepack` from the runtime stage.** Saves ~17 MB on disk (~7 %),
  effectively nothing after compression, and removes the tooling someone uses to
  debug the running container. Not worth it.
- **Distroless `nodejs24-debian12:nonroot`.** Removes the shell, which is the
  main reason a reviewer can inspect a running task. The manifest query from this
  environment returned no usable layer sizes, so the saving could not be verified;
  adopting an unverified base change to save maybe 20 MB compressed is a bad
  trade against losing debuggability.
- **Bundle to a single file with esbuild.** Does not remove the Node runtime, which
  is the floor. It would shrink our 4.3 MB and add a build step.

**Decision: keep the current Dockerfile.** For this workload, image size is
bounded by the Node runtime, and the number that matters — 54 MB compressed — is
already at that floor.

---

## 2026-11-14 — Phase 2: AWS foundation

### Amendments to approved decisions

- **Terraform 1.17.2 → 1.17.1.** Approved as 1.17.2, but the installed binary is
  1.17.1 from snap and upgrading would require `sudo`. Both versions support the
  S3 `use_lockfile` backend, so the architecture is unaffected. `required_version`
  is `~> 1.17.0` and `infrastructure/.terraform-version` records 1.17.1.
- **AWS provider pinned to 6.73.0** in `infrastructure/bootstrap/.terraform.lock.hcl`.
  The lock file is committed; the `.terraform/` directory is not.

### Delivered

- `infrastructure/bootstrap/` — the state bucket and cost guardrail, as a local-state
  root (an S3 backend cannot create its own bucket):
  - S3 bucket with versioning, SSE-S3, full public-access block, TLS-only bucket
    policy, and lifecycle rules (abort incomplete multipart uploads after 7 days,
    expire noncurrent state versions after 90 days).
  - `aws_budgets_budget` monthly cost guardrail, thresholds at 50 % / 80 % / 100 %
    actual and 100 % forecasted, email notifications only when an address is supplied.
  - Outputs: bucket name, bucket region, account ID, caller ARN, budget name.
  - `README.md` with the apply procedure, cost table, and teardown ordering rule.
- `docs/runbooks/operator-identity.md` — see the blocker below.
- `terraform fmt -check` clean, `terraform init` successful, `terraform validate`
  successful.

### Cost of this phase

| Item                                   | Cost                                                                                   |
| -------------------------------------- | -------------------------------------------------------------------------------------- |
| S3 state bucket (kilobytes, versioned) | fractions of a cent per month                                                          |
| AWS Budgets                            | **$0** — first two budgets per account are free; email notifications need no SNS topic |

**No AWS resources have been created.** `plan`/`apply` are intentionally withheld
until the identity question below is resolved.

### Resolved: operator identity

**Was blocked:** both us-east-1 profiles resolved to
`arn:aws:iam::471112980487:root`. Applying Terraform as root would violate §9.1
and §12.2 of the approved architecture, collapse the required separation between
"human administrator" and "Terraform execution identity", and leave the root ARN
in state and CloudTrail for every resource.

**Resolution:** a dedicated IAM user was created — `AdminDelightsome` →
`arn:aws:iam::471112980487:user/delightsomeAdmin`, in `us-east-1`, with
`AdministratorAccess` and MFA enrolled (TOTP + two U2F devices). Root MFA is
enabled (`RootMFA: 1`).

**Residual finding:** the root user still has an **active access key**
(`RootKeys: 1`). Root MFA does not protect API access through a key, and root
keys cannot be scoped by policy. Deletion is recommended but was not performed —
it is destructive and the blast radius on existing tooling is unknown. Recorded
in `docs/runbooks/operator-identity.md`.

### Incident: Terraform silently authenticated as root

**Symptom.** With `aws_profile = "Delightsome"` the plan rendered
`aws_caller_arn = arn:aws:iam::471112980487:root`, while
`aws sts get-caller-identity --profile AdminDelightsome` and
`--profile Delightsome` both correctly reported
`user/delightsomeAdmin`.

**Cause.** These profiles authenticate through the AWS CLI console-login
mechanism (`login_session`). When the Terraform AWS provider is handed an
explicit `profile`, it resolves that mechanism through an **account-scoped token
cache** rather than the identity named in the profile. A root session cached from
an earlier sign-in was reused. Setting `profile` also causes the provider to
ignore exported environment credentials, so `aws configure export-credentials`
did not fix it either — proven by re-planning with credentials exported and still
getting `:root`.

**Fix.**

1. `profile = var.aws_profile == "" ? null : var.aws_profile` — null by default,
   so the standard environment credential chain applies.
2. `infrastructure/scripts/with-operator-creds.sh` exports the session's
   short-lived credentials once, prints the resolved identity and account, and
   **aborts if the ARN ends in `:root`**.
3. `terraform.tfvars` no longer sets a profile; the example file explains why.

**Second bug found while fixing the first.** The wrapper originally called
`aws configure export-credentials` twice (once to probe, once to export). The
second call returned _"Credentials were refreshed, but the refreshed credentials
are still expired"_. Capturing the output from a single call removed it.

**Lesson.** A green plan is not evidence of the right identity. `aws_caller_arn`
as an output is a cheap, permanent check — and it caught a root-authenticated
apply that the CLI itself reported as an IAM user.

### Verification evidence (Phase 2)

| Check                        | Result                                                  |
| ---------------------------- | ------------------------------------------------------- |
| Applying identity            | `arn:aws:iam::471112980487:user/delightsomeAdmin`       |
| `terraform plan` after apply | **No changes** (idempotent)                             |
| Apply result                 | 8 added, 0 changed, 0 destroyed                         |
| Bucket versioning            | `Enabled`                                               |
| Bucket encryption            | `AES256` (SSE-S3)                                       |
| Public access block          | all four `True`                                         |
| Lifecycle rules              | `abort-incomplete-uploads`, `expire-old-state-versions` |
| Plain HTTP to bucket         | `403`                                                   |
| Budget                       | `devops-assessment-monthly`, `COST`, 30 USD/month       |
| Budget notifications         | none — `budget_notification_email` is unset             |

### Key learnings

- `aws login` writes `login_session = arn:...` into `~/.aws/config`, so the
  identity type (root vs IAM user vs assumed role) is inspectable locally before
  any API call — no credentials needed to catch a root profile.
- An explicit Terraform `profile` can override both the profile's stated identity
  and exported environment credentials. Verify identity through Terraform's own
  `aws_caller_identity`, not through the AWS CLI.
- `aws_budgets_budget.display_name` is not accepted by AWS provider 6.73.0;
  `validate` rejects it immediately.
- `terraform validate` does not require AWS credentials, so configuration errors
  are caught without an authenticated session.

---

## 2026-11-15 — Scope decisions on the AWS account

Recorded so these are not re-litigated later and a reviewer sees intent, not
omission.

1. **Root user: retained, explicitly out of scope.** The account root user still
   has an active access key (`RootKeys: 1`). Deleting keys and hardening the root
   identity is the account owner's responsibility and sits outside this project's
   scope. No project resource is created, read, or managed by root — verified via
   the `aws_caller_arn` output, which reports
   `arn:aws:iam::471112980487:user/delightsomeAdmin`.

   This must be stated plainly in the README rather than presented as a
   completed control: §9.1/§12.2 are satisfied in the sense that **this project's
   operator path never uses root**, but the account as a whole is not hardened.

2. **Budget notifications enabled.** `budget_notification_email` is configured in
   `terraform.tfvars` and applied — state serial 12 records notifications at
   50 % / 80 % / 100 % actual and 100 % forecasted. The address itself is local
   configuration (gitignored), not committed.

3. **Operator sessions are short-lived.** `aws login` console sessions expire in
   well under an hour, so `with-operator-creds.sh` must be re-run — or
   `aws login --profile AdminDelightsome` re-run — between work sessions. A bare
   `terraform apply` bypasses the root-identity guard in that script; always use
   the wrapper.

---

## 2026-11-15 — Phase 3: environment roots (backend wiring)

### Delivered

`infrastructure/environments/dev/` and `prod/`, each containing:

| File                       | Purpose                                                                          |
| -------------------------- | -------------------------------------------------------------------------------- |
| `versions.tf`              | `required_version ~> 1.17.0`, AWS provider `~> 6.0`                              |
| `backend.tf`               | S3 backend, `encrypt = true`, **`use_lockfile = true`**, key `dev/…` or `prod/…` |
| `providers.tf`             | region from variable, `profile` null, default tags                               |
| `variables.tf`             | `environment` and `vpc_cidr` deliberately have **no defaults**                   |
| `main.tf`                  | locals (`name_prefix`, `common_tags`), identity guard, module wiring plan        |
| `outputs.tf`               | environment, name_prefix, region, account, caller ARN                            |
| `terraform.tfvars.example` | per-environment values                                                           |

Plus `environments/README.md` covering the workflow, state keys, CIDR allocation
(dev `10.20.0.0/16`, prod `10.30.0.0/16`), locking behaviour, and teardown order.

### Key decisions & trade-offs

**Identity guard moved into Terraform.** A `terraform_data` resource with a
precondition fails the plan when `aws_caller_identity` ends in `:root`. The
wrapper only guards invocations that go through it; this guard runs on _every_
plan and apply regardless of how Terraform was started. Belt and braces, cheap.

**Separate roots, not workspaces.** Workspaces share a backend key pattern and
make applying to the wrong environment a single flag away. Two roots cost six
small files and remove that class of mistake.

**Fully specified `backend.tf` rather than partial configuration.** `terraform
init` works with no extra flags. Cost: the bucket name (which embeds the account
ID) is committed, so forking requires a one-line edit per root. Judged a better
trade than a gitignored `backend.hcl` plus a mandatory `-backend-config` flag.

**`environment` and `vpc_cidr` have no defaults.** A defaulting environment
variable is how `dev` inputs get applied to `prod` after a directory copy. Both
must come from `terraform.tfvars`, which is per-directory and gitignored.

### Verification so far

| Check                                | Result                     |
| ------------------------------------ | -------------------------- |
| `terraform fmt -recursive -check`    | clean                      |
| `init -backend=false` (dev, prod)    | success                    |
| `terraform validate` (dev, prod)     | **valid**                  |
| `init` against the remote S3 backend | **success** (dev and prod) |

**Phase 3 exit condition met.** Both roots initialise remote state and plan
cleanly: `1 to add` — the identity guard only — `0 to change`, `0 to destroy`.
Identity resolved as `arn:aws:iam::471112980487:user/delightsomeAdmin` in both
plans. State reachability was confirmed independently: the bucket held no objects
before `apply` (as expected) and the `use_lockfile` lock was acquired and released
cleanly ("Releasing state lock").

### Key learnings

- `use_lockfile` is a _backend_ argument, so it belongs in `backend.tf` and
  cannot appear in a resource file. The bootstrap root has no backend block at
  all — local state locks itself via `.terraform.tfstate.lock.info`.
- `init -backend=false` and `validate` need no credentials, which makes
  configuration errors catchable while an AWS session is expired.
- **Expired exported credentials shadow everything.** A long-lived shell that once
  ran `eval "$(aws configure export-credentials ...)"` keeps
  `AWS_ACCESS_KEY_ID` / `AWS_SESSION_TOKEN` in its environment indefinitely. After
  those expire, `aws login` on the profile still succeeds and
  `aws sts --profile X` still succeeds (an explicit profile wins), but anything
  reading the default credential chain — Terraform, `export-credentials`, the
  wrapper — fails with _"Credentials were refreshed, but the refreshed
  credentials are still expired."_ Clearing the `AWS_*` variables fixed it. When
  a session appears not to refresh, inspect the shell before re-authenticating.
- A bare `terraform plan` (no wrapper) with `AWS_PROFILE` pointing at a
  `login_session` profile can resolve to root through the same token cache. The
  `identity_guard` precondition now fails that plan instead of applying it.

---

## 2026-11-15 — Phase 4: networking and security groups

### Delivered

Two reusable modules, wired into both environment roots.

**`modules/networking`** — VPC, two public subnets across two AZs, internet
gateway, public route table, associations. Inputs: `name_prefix`, `vpc_cidr`,
`availability_zone_count`, `tags`. Outputs: `vpc_id`, `public_subnet_ids`,
`public_subnet_cidrs`, `availability_zones`, `internet_gateway_id`.

**`modules/security`** — ALB and task security groups plus four rules. Inputs:
`name_prefix`, `vpc_id`, `app_port`, `tags`. Outputs: `alb_security_group_id`,
`task_security_group_id`.

### Key decisions & trade-offs

**Standalone rule resources, not inline blocks.** The ALB group's egress refers
to the task group, and the task group's ingress refers back to the ALB group. As
inline `ingress`/`egress` blocks that is a dependency cycle Terraform refuses to
plan. `aws_vpc_security_group_ingress_rule` / `_egress_rule` remove the cycle and
are the pattern AWS now recommends.

**AZ filter on `opt-in-status`.** `data.aws_availability_zones` is filtered to
`opt-in-not-required`. Unfiltered, an account without every zone enabled fails
subnet creation with an error that reads like a permissions problem.

**`map_public_ip_on_launch = true`, with a caveat in the code.** This attribute
does not govern awsvpc task ENIs — public IPs for Fargate are controlled by
`assign_public_ip` on the ECS service (Phase 5). It is set so the subnet's intent
is explicit, not because it is what makes tasks reachable.

**Task egress left unrestricted, and documented as such.** Fargate needs egress
for ECR pulls and CloudWatch Logs, and there is no NAT Gateway to traverse
(ADR-002). Restricting it would need interface endpoints at roughly $7/month per
endpoint per AZ — more than the resources they protect. The comment in
`security/main.tf` states this plainly rather than implying a control that does
not exist.

### Incident: empty AWS CLI results caused by the wrong region

Verification returned **empty output with exit code 0** for every `ec2`
describe call, which reads as "the resources were not created".

Cause: exported credentials carry no region, so the CLI fell back to the
`[default]` profile's region — `eu-north-1` — while the project lives in
`us-east-1`. Terraform was unaffected because the provider sets `region`
explicitly.

Fix: `with-operator-creds.sh` now pins `AWS_REGION` / `AWS_DEFAULT_REGION` from
the profile's own region, without overriding values already set.

**Lesson.** An empty list is not evidence of absence. Any verification command
must prove which region it queried.

### Verification evidence (Phase 4)

Both environments applied: **15 added, 0 changed, 0 destroyed**; re-plan reports
**No changes** in dev and prod.

| Check                                               | dev                                                     | prod                                     |
| --------------------------------------------------- | ------------------------------------------------------- | ---------------------------------------- |
| VPC CIDR                                            | `10.20.0.0/16`                                          | `10.30.0.0/16`                           |
| Subnets                                             | `10.20.0.0/24` (1a), `10.20.1.0/24` (1b)                | `10.30.0.0/24` (1a), `10.30.1.0/24` (1b) |
| Default route                                       | `0.0.0.0/0 → igw-0048143c8c8a00632`                     | same pattern                             |
| Task SG ingress                                     | TCP 3000 from `sg-04dc577b54fb2ab1f` (ALB), **no CIDR** | TCP 3000 from ALB SG, **no CIDR**        |
| ALB SG ingress                                      | TCP 80 from `0.0.0.0/0`                                 | same                                     |
| ALB SG egress                                       | TCP 3000 to task SG only                                | same                                     |
| Port 3000 reachable from any `0.0.0.0/0` in the VPC | **none**                                                | **none**                                 |

Cost incurred: **$0**. VPCs, subnets, route tables, internet gateways, and
security groups are free. Console IDs for dev: `vpc-0dc7ff0118a348616`,
`sg-04dc577b54fb2ab1f` (ALB), `sg-0bf3dd8626b4cfef7` (task).

---

## 2026-11-15 — Phase 5 (first half): registry, logs, ingress, compute

### Delivered

| Module       | Creates                                        | Resources |
| ------------ | ---------------------------------------------- | --------- |
| `ecr`        | Repository + lifecycle policy                  | 2         |
| `monitoring` | CloudWatch log group                           | 1         |
| `alb`        | ALB, target group, HTTP listener               | 3         |
| `ecs`        | Cluster, 2 IAM roles, task definition, service | 6         |

Applied to **dev only** so far (12 new resources). Prod has the repositories and
log group; its ALB/ECS wait on the cost decision below.

### Key decisions & trade-offs

**ECR tags are IMMUTABLE.** Releases are tagged by Git SHA, so a tag never
legitimately moves. A re-push of the same SHA now fails loudly instead of
silently replacing an artefact that may already be running. Lifecycle policy
expires untagged images after 7 days and keeps the 20 most recent tagged ones.

**ECR scan-on-push stays informational.** It is asynchronous and cannot gate a
pipeline; Trivy in CI is the blocking control. This is the compromise recorded
against decision 4.

**The ECS service ignores changes to `task_definition` and `desired_count`.**
This is the single most important line in the module. CI registers new task
definition revisions and updates the service; without `ignore_changes`, every
`terraform plan` after a release would try to revert the running service to the
seed revision Terraform created. Terraform owns the _shape_ of the service, the
pipeline owns _which revision runs_.

**Seed image, not a placeholder.** The image was built and pushed to ECR before
ECS was applied, so the first task to start was the real application rather than
a stand-in that would be replaced later. Same artefact (`f9654b3`) promoted to
prod's repository.

**Two IAM roles, deliberately separate.** The execution role (managed
`AmazonECSTaskExecutionRolePolicy`, partition-aware) pulls images and writes
logs. The task role has **no policies at all** — the application calls no AWS
APIs. `enable_execute_command` is left off because it would require adding SSM
permissions to the task role.

**Container Insights disabled.** It adds CloudWatch metric cost; the assessment's
needs are covered by the ECS and ALB metrics that are always emitted.

**Deployment 100/200 with circuit breaker + rollback.** A replacement task must
be healthy before the old one drains, so a one-task service does not drop
requests during a deploy. A deployment that never stabilises rolls back
automatically. This detects infrastructure failure, not application bugs.

**Timeout pairing, all three checked against each other.** App drain 10s <
target group deregistration 30s < ALB idle timeout 70s > app keep-alive 65s. Get
any of these out of order and deploys either drop requests or stall.

### Verification evidence (dev)

| Check                     | Result                                                            |
| ------------------------- | ----------------------------------------------------------------- |
| ECS service               | desired 1, running 1, pending 0, deployment `COMPLETED`           |
| Task                      | `RUNNING`, container health `HEALTHY`, IP `10.20.1.167`           |
| Target group              | `healthy`                                                         |
| `GET /` via ALB           | 200                                                               |
| `GET /health` via ALB     | 200 `{"status":"ok"}`                                             |
| `GET /api/status` via ALB | 200, `commitSha: "f9654b3"`, `environment: "dev"`                 |
| CloudWatch Logs           | structured JSON request logs arriving                             |
| ALB DNS                   | `devops-assessment-dev-alb-343497269.us-east-1.elb.amazonaws.com` |

`commitSha` in the status payload matching the ECR tag is the traceability claim
actually proven end to end, rather than asserted in a diagram.

### Key learnings

- **AWS provider v6 replaced `scheme = "internet-facing"` with `internal = false`
  on `aws_lb`.** `validate` catches it immediately; the error reads as though the
  resource type were wrong.
- `data.aws_region.current.name` is deprecated in v6 — use `.region`.
- `terraform output` now validates provider credentials, so it fails with an
  expired session even though it only reads state. Run it through the wrapper.
- The provider schema can be inspected directly with
  `terraform providers schema -json` when an argument name is in doubt, rather
  than guessing at a changelog.

---

## 2026-11-15 — Phase 6: alarms

### Delivered (dev)

`modules/monitoring` gained an SNS topic, an optional email subscription, and
five CloudWatch alarms. Nine resources in total now, still effectively $0: the
first ten alarm metrics are free and SNS email delivery is free at this volume.

| Alarm                 | Signal (§11.2)     | Condition                                      |
| --------------------- | ------------------ | ---------------------------------------------- |
| `target-5xx`          | ALB 5xx            | `HTTPCode_Target_5XX_Count` sum > 5 in 2×1 min |
| `unhealthy-hosts`     | Healthy host count | `UnHealthyHostCount` max > 0 in 2×1 min        |
| `live-task-count-low` | Running task count | `LiveTaskCount` min < 1 in 2×1 min             |
| `ecs-cpu-high`        | ECS CPU            | average > 80 % over 2×5 min                    |
| `ecs-memory-high`     | ECS memory         | average > 85 % over 2×5 min                    |

### Incident: an alarm that could never have fired

The first apply produced five alarms, four of which sat in `INSUFFICIENT_DATA`.
That is expected for a few minutes after creation — but one of them was never
going to resolve.

**The CloudWatch metric is `UnHealthyHostCount`, with a capital H.** The natural
spelling `UnhealthyHostCount` does not exist. A misspelled metric name is not a
deployment error: Terraform creates the alarm happily, and the alarm reports
`INSUFFICIENT_DATA` forever. It looks exactly like "no data yet".

Found by listing the metrics actually published for the load balancer:

```bash
aws cloudwatch list-metrics --namespace AWS/ApplicationELB \
  --dimensions Name=LoadBalancer,Value=app/<alb-name>/<id>
```

**Lesson:** an alarm that is `INSUFFICIENT_DATA` is not evidence of a healthy
service. Every alarm should be proven to resolve to `OK` at least once against
real datapoints before it counts as monitoring.

### Second finding: a signal I had wrongly written off

An earlier comment claimed `LiveTaskCount` requires Container Insights. Listing
`AWS/ECS` metrics for the cluster disproved it — `LiveTaskCount`,
`CPUUtilization`, and `MemoryUtilization` are all published per service without
Container Insights. The comment was corrected and the task-count alarm added,
which closes §11.2's "running task count" item at no cost.

### Third finding: `HTTPCode_Target_5XX_Count` does not exist yet

CloudWatch creates a metric only once a datapoint exists. No 5xx has ever been
served by this service, so the metric is absent and the alarm sits at
`INSUFFICIENT_DATA` — resolving to `OK` because `treat_missing_data =
"notBreaching"`. Correct behaviour, but worth stating explicitly: the first real
5xx is what brings the alarm to life.

Deliberate choice on `live-task-count-low`: `treat_missing_data = "breaching"`,
because zero live tasks is the failure being alarmed on. The trade-off is a
brief alarm window during a fresh deploy, smoothed by the 2-period evaluation.

### Verification

| Alarm                 | Metric                      | State                       |
| --------------------- | --------------------------- | --------------------------- |
| `ecs-cpu-high`        | `CPUUtilization`            | **OK**                      |
| `ecs-memory-high`     | `MemoryUtilization`         | **OK**                      |
| `target-5xx`          | `HTTPCode_Target_5XX_Count` | **OK** (notBreaching)       |
| `unhealthy-hosts`     | `UnHealthyHostCount`        | resolved after the name fix |
| `live-task-count-low` | `LiveTaskCount`             | resolved after creation     |

SNS subscription: `delightsomedunsiasolo24@gmail.com` in
`PendingConfirmation` — AWS requires the confirmation link to be clicked before
any alarm notification is delivered. Until then the alarms change state
correctly but nobody is told.

*(Update, later the same day: the subscription is now **Confirmed** and alarm
notifications deliver.)*

---

## 2026-11-15 — Phase 7: OIDC, workflows, and the first pipeline deployment

### Outcome

The pipeline deploys dev end to end, with no stored credentials anywhere.

| Evidence | Value |
| --- | --- |
| Pipeline commit | `e6c570c534f38aaaf13fc98e7b843e32fd9c7127` |
| Live `/api/status` → `commitSha` | `e6c570c534f38aaaf13fc98e7b843e32fd9c7127` ✅ |
| ECS task definition | revision **2**, rollout `COMPLETED`, 1 task running |
| Chain exercised | OIDC assume → ECR push → register revision → update service → `services-stable` → `/health` 200 → commit match |

### The six defects this phase exposed

Everything below failed *before* a single deployment succeeded. Each is a
distinct failure mode worth knowing.

**1. `working-directory: .` in the test job.** The job defaults to `app/`; the
override put Docker at the repo root looking for `/Dockerfile`. My bug.

**2. `trivy-action@0.28.0` does not exist.** The action failed to resolve during
"Set up job" and the job reported failure in 2 seconds. The scan never ran. A
security gate that cannot start is *indistinguishable in the summary* from one
that found something — the worst failure mode a gate has. Pinned to the commit
behind `v0.36.0`.

**3. Seven HIGH/CRITICAL CVEs in the Alpine base OS.** Real findings. Fixed with
`apk upgrade --no-cache` (Alpine 3.23.4 → 3.23.8).

**4. `CVE-2026-73566` in `tar` 7.5.9.** Not our dependency — it is bundled inside
npm at `/usr/local/lib/node_modules/npm`. Fixed by deleting npm, npx and corepack
from the runtime stage. Earlier in the build this was rejected as a 17 MB size
optimisation; size was the wrong argument, attack surface was the right one.

**5. OIDC trust could never match.** The trust policy expected

```
repo:DSTIXX05/devops_assessment:ref:refs/heads/main
```

The token actually carried

```
repo:DSTIXX05@109713333/devops_assessment@1458162023:ref:refs/heads/main
```

GitHub issues **immutable subject claims** containing numeric owner and
repository IDs, so the claim cannot be forged by renaming or transferring the
repository. Almost all documentation still shows the older, ID-less form.
`sts:AssumeRoleWithWebIdentity` returns a bare `Not authorized` with no
indication of which condition failed.

Diagnosed by adding a throwaway `workflow_dispatch` step that requested a token
and printed its decoded claims — not by re-reading documentation. The branch was
deleted afterwards.

**6. `ecs:DescribeTaskDefinition` cannot be resource-scoped.** ECS authorises it
against `*` regardless of the ARN supplied, so granting only
`task-definition/<family>:*` produced `AccessDeniedException on resource: *` even
when the workflow passed a full revision ARN. The deploy role now has exactly
three `Resource:"*"` statements, all documented: `ecr:GetAuthorizationToken`,
`ecs:RegisterTaskDefinition`, `ecs:DescribeTaskDefinition`.

### Design details that did hold up

- **`deploy-dev` declares no GitHub Environment.** Adding one would change its
  subject to `...:environment:dev` and break its trust policy. Dev is
  branch-scoped; prod is environment-scoped. The asymmetry is deliberate.
- **The pipeline is also a guard.** A step aborts if `sts get-caller-identity`
  ends in `:root`, mirroring `with-operator-creds.sh`.
- **Idempotent image push.** ECR tags are immutable, so an `ecr:DescribeImages`
  check skips the build when the commit was already published. Without it, a
  re-run after a transient failure could never succeed.
- **Task definition rendering updates `COMMIT_SHA`.** Terraform seeds the value;
  if the pipeline only swapped the image, `/api/status` would keep reporting the
  old commit and the traceability claim would quietly become false.
- **Branch ruleset works.** Direct pushes to `main` are rejected with
  `GH013: Changes must be made through a pull request`. Every change this phase
  went through a PR, which is why the first attempt to push was refused.

### Key learnings

- Read the token, not the documentation. OIDC claim formats change; a decoded
  claim is ground truth and takes two minutes to obtain.
- Not every IAM action supports resource-level permissions. When AWS reports
  `resource: *` while the policy names an ARN, the action likely ignores ARNs
  entirely.
- A CI job that fails during "Set up job" failed before running anything. Check
  *where* it failed before assuming the check did its job.
- Duplicated deploy jobs in a workflow are a maintenance trap: the same edit had
  to be applied twice, twice. A composite action would be the fix if the workflow
  grows further.
