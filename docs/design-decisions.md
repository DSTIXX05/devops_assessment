# Design decisions

Back to [README](../README.md) · Related: [architecture](architecture.md) · [limitations](limitations.md) · [build journal](../PROJECT_LOG.md)

Each decision states the choice, the alternative that was rejected, and what it costs.
Where a decision was reversed during the build, that is recorded too, a decisions log
that only contains correct decisions is a fiction.

---

## Summary

| #   | Decision                                    | Rejected alternative              | Primary reason                                    |
| --- | ------------------------------------------- | --------------------------------- | ------------------------------------------------- |
| D1  | ECS on **Fargate**                          | EC2 launch type, EKS, Lambda      | No servers to patch; cost acceptable at this size |
| D2  | **Public subnets**, no NAT                  | Private subnets + NAT Gateway     | ~$32/mo saved; egress simplicity                  |
| D3  | **GitHub Actions**                          | Jenkins, GitLab CI                | No Jenkins infrastructure to run or secure        |
| D4  | **OIDC federation**                         | Static IAM access keys in secrets | No long-lived credential to leak or rotate        |
| D5  | **Trivy in CI** as the blocking gate        | ECR `scan_on_push` as the gate    | ECR scanning is async and cannot block            |
| D6  | **SHA image tags, immutable**               | `latest`, or mutable tags         | A tag that can move is not a version              |
| D7  | **Two environments, one account**           | Separate accounts                 | Simpler; isolation by naming and state            |
| D8  | **Terraform** with S3 + `use_lockfile`      | DynamoDB locking, Terraform Cloud | One fewer billable resource                       |
| D9  | **Dependency-free** docs and logger         | `swagger-ui-express`, `pino`      | Keeps the scanned surface small                   |
| D10 | **`apk upgrade` + remove npm** from runtime | Accept the alerts, or distroless  | Reduced attack surface; 7 CVEs closed             |
| D11 | **Local operator applies** infrastructure   | Apply from CI                     | Honest about what is automated                    |
| D12 | **`force_delete = false`** on ECR           | `force_delete = true`             | A destroy must not discard releases               |

---

## D1 - ECS on Fargate rather than EC2, EKS or Lambda

**Chosen:** Fargate, 0.25 vCPU / 512 MB.

**Rejected:** EC2 launch type requires patching instances and managing AMIs, the exact
work this assessment is meant to automate away. EKS is a control plane to operate and a
cluster to pay for, disproportionate to one container. Lambda would have deleted the
interesting part of the problem: no container image, no ALB target group, no task
definition.

**Cost:** Fargate is more expensive per vCPU-hour than EC2, and single-task Fargate has
no meaningful availability story. Accepted at this scale.

---

## D2 - Public subnets with no NAT Gateway

**Chosen:** Two public subnets, `assign_public_ip = true`, default route to an IGW.

**Rejected:** Private subnets plus a NAT Gateway, which is the standard correct answer.

**Reason:** A NAT Gateway is roughly $32/month plus data processing, comparable to the
entire rest of the stack, for an environment whose only outbound traffic is pulling one
image and writing logs. VPC endpoints for ECR and CloudWatch Logs would remove most of
the need, but cost is per-endpoint-hour and per-GB.

**Cost:** Tasks are directly addressable. Security groups are the only boundary, and
egress is unrestricted. Recorded as L3 and L4 in [limitations](limitations.md). **This is
the weakest decision in the build** and the first one I would revisit (see improvement 3).

---

## D3 - GitHub Actions rather than Jenkins

**Chosen:** GitHub Actions.

**Rejected:** Jenkins, which the original brief's architecture discussion referenced in
one place.

**Reason:** Jenkins means a controller to patch, back up and authenticate, plus plugin
drift, infrastructure to run CI, in an assessment about running infrastructure. Actions
gives hosted runners, native OIDC, and an audit trail attached to the commit.

**Cost:** Vendor coupling; the YAML is not portable. Duplicated deploy jobs (L14) are a
consequence of the workflow syntax being easier to copy than to factor.

> **Note:** this decision contradicts one paragraph of the brief that describes a
> Jenkins pipeline. The contradiction is real and is resolved in favour of Actions.

---

## D4 - OIDC federation rather than static access keys

**Chosen:** GitHub Actions presents a short-lived OIDC token; AWS STS returns temporary
credentials for a role scoped to ECR push and ECS deploy.

**Rejected:** An IAM user with an access key stored in GitHub secrets.

**Reason:** A static key is a permanent credential sitting in a system you do not
control, with no expiry and no binding to the thing using it. An OIDC token expires in
minutes and encodes which repository, branch and environment requested it.

**Cost:** The trust policy is fiddly, and it broke during the build. **Human-authored
documentation is wrong about the subject claim.** Most examples match:

```
repo:owner/name:ref:refs/heads/main
```

A modern repository emits **immutable subject claims** with numeric IDs:

```
repo:DSTIXX05@109713333/devops_assessment@1458162023:ref:refs/heads/main
```

Nothing warns you, the assume-role simply fails with `Not authorized to perform
sts:AssumeRoleWithWebIdentity`. The fix was to add `github_owner_id` and `github_repo_id`
as variables and build the subject from them, and to stop trusting documentation over a
decoded token.

See [deployment runbook](runbooks/deployment.md) for the working trust policy.

---

## D5 - Trivy in CI as the blocking vulnerability gate

**Chosen:** Trivy runs in the workflow and fails the job on HIGH or CRITICAL.

**Rejected:** Relying on ECR `scan_on_push` to gate releases.

**Reason:** ECR scanning is **asynchronous**. The image is pushed, and the scan completes
some seconds or minutes later. A pipeline that reads the scan result either races it or
waits an unbounded time. Trivy runs synchronously, on the image, before the push is
allowed to matter.

**Cost:** A second scanner with its own CVE database and its own false positives.
`ignore-unfixed: true` is set because a HIGH with no available fix would otherwise block
every deploy forever with no action available.

ECR scanning is still enabled, informational, for base-OS coverage.

> **Incident worth recording:** the action was first pinned to `trivy-action@0.28.0`,
> which **does not exist**. The job failed during "Set up job" in about two seconds,
> before running anything, and read exactly like a gate that had found something. A gate
> that cannot start is indistinguishable from a gate that failed, unless you check
> _where_ it failed.

---

## D6 - Immutable SHA tags in ECR

**Chosen:** `image_tag_mutability = "IMMUTABLE"`, images tagged with the Git commit SHA.

**Rejected:** `latest`, or mutable semantic tags.

**Reason:** A mutable tag means the artefact behind a running deployment can silently
change. With `IMMUTABLE`, a re-push of the same SHA fails loudly.

**Cost:** Re-running a pipeline for the same commit fails on the push. The deploy jobs
therefore check `describe-images` first and skip the build when the tag already exists,
idempotent re-runs without weakening the guarantee.

---

## D7 - Two environments in one account

**Chosen:** `dev` and `prod` as separate Terraform roots with separate state, VPCs and
names, in one AWS account.

**Rejected:** Separate AWS accounts per environment, which is the stronger boundary.

**Reason:** Account creation, billing and cross-account roles add setup cost without
adding anything the assessment is testing.

**Cost:** Isolation is naming and state, not an account boundary. `prod` can be damaged
by a mistake in `dev` if a name collides. Accepted, documented as A4.

---

## D8 - S3 state with `use_lockfile`, not DynamoDB

**Chosen:** S3 backend, `use_lockfile = true` (Terraform ≥1.10). No DynamoDB table.

**Rejected:** DynamoDB state locking, or a managed backend.

**Reason:** With native S3 lockfile support, a DynamoDB table is a second billable
resource doing nothing the bucket cannot do.

**Cost:** The lock is an object next to the state and **does not expire**. A killed
process leaves a stale lock that must be cleared with `terraform force-unlock`. DynamoDB
locking has the same failure mode but more tooling around it. Encountered during the
teardown drill, see [teardown runbook](runbooks/teardown.md).

---

## D9 - Dependency-free API documentation and logger

**Chosen:** The OpenAPI document is a plain object in `app/src/api-docs.js`; the viewer is
hand-written HTML loading a **pinned** `swagger-ui-dist` build from a CDN. The logger is
40 lines with no dependency.

**Rejected:** `swagger-ui-express` and `pino`.

**Reason:** Anything added to the runtime image is scanned by Trivy, and a documentation
dependency should never be able to block a release on a vulnerability it introduced.

**Cost:** The `/docs` page requires network access to a CDN. A truly offline viewer would
mean vendoring the bundle into the image. The version is pinned rather than floating
because a floating tag means an unannounced third-party script executing in a reviewer's
browser, on a page served from our own load balancer.

---

## D10 - Patch Alpine, and delete npm from the runtime image

**Chosen:** `apk upgrade --no-cache` in the build stage, and `npm`, `npx`, `corepack`
deleted from the final layer.

**Rejected:** Accepting the scan results, or moving to distroless.

**Reason:** The first Trivy run found 7 HIGH/CRITICAL findings in Alpine 3.23.4, closed
by upgrading to 3.23.8. It then found `CVE-2026-73566` in `tar` 7.5.9 inside
`/usr/local/lib/node_modules/npm`, a build tool shipped in production.

> **A judgement was reversed here.** Earlier in the build I decided _not_ to remove npm,
> reasoning it cost ~17MB and was not worth the complexity. That was the wrong metric.
> Size was never the argument; **attack surface** was. A package manager in a runtime
> container is an interactive installer available to anyone who gets a shell.

---

## D11 - Terraform applied by a human, not by CI

**Chosen:** `infrastructure.yml` runs `fmt -check` and `validate` only. Applying is a
local action through `scripts/with-operator-creds.sh`.

**Rejected:** `apply` on merge, with plan review.

**Reason:** Honest framing. Applying infrastructure from a pipeline that the
infrastructure itself provisions is a bootstrapping problem, and a half-built version of
it is worse than none: it implies automation that does not exist.

**Cost:** Infrastructure changes are not deployed by the pipeline. Recorded as L18. The
application _is_ fully pipeline-deployed; the distinction is stated explicitly rather
than blurred.

---

## D12 - `force_delete = false` on ECR

**Chosen:** The module defaults to refusing to delete a repository that still contains
images.

**Rejected:** `force_delete = true`, for a frictionless `terraform destroy`.

**Reason:** A destroy that silently deletes every release artefact is a foot-gun. The
default makes the operator empty the repository deliberately, `scripts/empty-ecr.sh`,
so the destructive step is visible in the transcript.

**Cost:** Teardown needs an extra step, and the first destroy attempt **failed** on it
during the drill:

```
ECR Repository (devops-assessment-prod-app) not empty
RepositoryNotEmptyException
```

That failure is the feature working. Documented in the
[teardown runbook](runbooks/teardown.md).

---

## Cross-cutting: version pinning

Terraform is pinned in three places, and during the build **two of them disagreed with
reality**:

| Where                               | Value at the time of the drill |
| ----------------------------------- | ------------------------------ |
| snap binary (what actually ran)     | 1.17.2                         |
| `infrastructure/.terraform-version` | 1.17.1                         |
| `infrastructure.yml` pin            | 1.17.1                         |
| `required_version`                  | `~> 1.17.0`, permits both     |

Snap auto-refreshed the package on 2026-11-15 at 20:47, and nothing read the version
file, so CI and the operator ran different binaries for the whole build. `~> 1.17.0` was
permissive enough that nothing complained.

Both are now 1.17.2. The lesson is broader than Terraform: **a version file that nothing
enforces is documentation, not a constraint**. And any tool that auto-updates (snap,
brew, `latest` image tags) cannot be the thing that pins a version.

Full timeline in [PROJECT_LOG.md](../PROJECT_LOG.md).
