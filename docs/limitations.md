# Assumptions, limitations and improvements

Back to [README](../README.md) · Related: [architecture](architecture.md) · [design decisions](design-decisions.md)

A README that lists only strengths is a sales document. This file is the counterweight:
what was assumed, what is missing, and what it would take to close each gap.

---

## Assumptions made

| #   | Assumption                                                                       | Why it matters if wrong                                                                                             |
| --- | -------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------- |
| A1  | **No domain name was available**, so no ACM certificate and no HTTPS listener    | Forces plain HTTP. With a domain this becomes a five-line change: certificate, `:443` listener, redirect from `:80` |
| A2  | The assessment account is **single-account and disposable**                      | No multi-account separation, no organisation SCPs, no cross-account state                                           |
| A3  | An **admin IAM user with MFA** exists (`AdminDelightsome`)                       | Terraform applies use an admin profile. A real setup would use a scoped deployment role with permissions boundaries |
| A4  | `dev` and `prod` are **logical** environments in one account                     | Isolation is by naming and separate state, not by account boundary. A blast radius mistake in `prod` is possible    |
| A5  | Traffic is **negligible**: one task can serve it                                | Sizing and lack of autoscaling are acceptable only under this assumption                                            |
| A6  | The repository is **public** and `main` is protected by a ruleset requiring a PR | Direct pushes are rejected; every change went through a PR                                                          |
| A7  | Cost matters more than availability                                              | Explains the missing NAT Gateway and the single task                                                                |

---

## Limitations

### Infrastructure and availability

| #   | Limitation                                                          | Consequence                                                                                                                                                 | Effort to fix                                                      |
| --- | ------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------ |
| L1  | **`desired_count = 1`**                                             | No high availability. A single task failure is a full outage until ECS restarts it. The deployment cannot be zero-downtime despite the ALB spanning two AZs | Low, raise count, add autoscaling, add a second target group      |
| L2  | **HTTP only**                                                       | Credentials and payloads travel in plaintext. Not acceptable for anything real                                                                              | Low, given a domain (A1)                                           |
| L3  | **Tasks in public subnets with public IPs**                         | The task has a public address. Protected by security groups, not by network topology, defence in depth is weaker than it looks                             | Medium, private subnets + NAT Gateway (~$32/mo) or VPC endpoints  |
| L4  | **Unrestricted task egress** (`0.0.0.0/0`)                          | A compromised container could reach the internet freely                                                                                                     | Medium, VPC endpoints for ECR and CloudWatch, then tighten egress |
| L5  | **No NAT Gateway**                                                  | Forces public subnets (L3)                                                                                                                                  | Cost decision, see [design decisions](design-decisions.md)         |
| L6  | **Single region**                                                   | No regional failover                                                                                                                                        | High                                                               |
| L7  | **No WAF, no rate limiting, no DDoS protection beyond AWS default** | `/api/echo` can be hammered; there is no throttle                                                                                                           | Low for WAF, medium for a real rate limiter                        |

### Operations

| #   | Limitation                           | Consequence                                                                                           | Effort to fix                                              |
| --- | ------------------------------------ | ----------------------------------------------------------------------------------------------------- | ---------------------------------------------------------- |
| L8  | **No autoscaling policy**            | Capacity is fixed at 0.25 vCPU regardless of load                                                     | Low                                                        |
| L9  | **Alarms notify by email only**      | No paging, no on-call route, no runbook link in the alert                                             | Low, SNS to PagerDuty/Opsgenie                            |
| L10 | **No dashboard**                     | No single pane of glass; you read raw metrics                                                         | Low                                                        |
| L11 | **No scheduled drift detection**     | `terraform plan` runs only when a human runs it. Drift is invisible until the next apply              | Low, scheduled workflow running `plan -detailed-exitcode` |
| L12 | **No ECS Exec / break-glass access** | Deliberately absent: a shell in a container is a capability, not a feature. Debugging is by logs only |, (this is a choice, not a gap)                            |
| L13 | **Log retention is finite**          | Old logs expire; no export to S3 or a SIEM                                                            | Low                                                        |

### Delivery

| #   | Limitation                                                  | Consequence                                                                                                                                                          | Effort to fix                                   |
| --- | ----------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------- |
| L14 | **`deploy-dev` and `deploy-prod` duplicate the same steps** | Every change to deploy logic must be made twice. Already a maintenance trap in a workflow this small                                                                 | Low, a composite action                        |
| L15 | **No rollback automation beyond the ECS circuit breaker**   | Rolling back to a specific previous revision is a manual `update-service --task-definition <arn>`                                                                    | Low                                             |
| L16 | **No integration or load tests**                            | The 34 tests are unit/route tests against the app; nothing exercises the deployed stack beyond a health check and a commit check                                     | Medium                                          |
| L17 | **No SAST/secret scanning gate**                            | Trivy covers the image; the source and history are not scanned                                                                                                       | Low, CodeQL and `gitleaks`                     |
| L18 | **Terraform runs from a laptop, not from CI**               | `infrastructure.yml` only formats and validates. Applying is a human action, so "the pipeline deploys everything" is true of the application, not the infrastructure | Medium, apply on merge with a plan-review step |

### Security posture

| #   | Limitation                                        | Consequence                                                                                                                                                             | Effort to fix                                     |
| --- | ------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------- |
| L19 | **Operator identity holds `AdministratorAccess`** | Anything that runs under this profile can do anything in the account. The wrapper script guards against root, not against excess permission                             | Medium, scoped deploy role, permissions boundary |
| L20 | **A root access key still exists** on the account | Accepted and documented as out of scope; see [operator identity runbook](runbooks/operator-identity.md)                                                                 | Low, but account-level risk                       |
| L21 | **No secrets management**                         | There are no application secrets today, so nothing is stored. The moment one is needed, the answer is Secrets Manager or SSM Parameter Store, not environment variables | Low                                               |
| L22 | **Image is pinned by tag, not digest**            | SHA tags are immutable in ECR, which mitigates this, but a digest is stronger                                                                                           | Low                                               |

---

## Improvements, in the order I would do them

Ordered by risk reduced per unit of effort, not by how interesting they are.

1. **Add a domain and TLS** (fixes L2, the loudest gap). Certificate in ACM, `:443`
   listener, redirect `:80 → :443`, HSTS header.
2. **Raise the task count to 2 and add autoscaling** (L1, L8). This is what turns the
   two-AZ ALB into an actual availability story. Cheapest meaningful availability win.
3. **Move tasks to private subnets with a NAT Gateway or VPC endpoints** (L3, L4). ~$32/mo
   buys the difference between "protected by security groups" and "not reachable".
4. **Collapse the duplicated deploy jobs into a composite action** (L14). Two identical
   40-line blocks are already a defect waiting to diverge.
5. **Add a scheduled drift-detection workflow** (L11). `plan -detailed-exitcode` on a
   cron, alerting on non-zero. Cheap, and it converts "state matches code" from a hope
   into a check.
6. **Scope down the operator identity** (L19). Replace admin-with-MFA with a deployment
   role and a permissions boundary.
7. **Add WAF with a rate-based rule** (L7) on `/api/echo` and `/`.
8. **Add CodeQL and `gitleaks` to CI** (L17). Neither existed, and the repository is
   public.
9. **Move Terraform apply into CI with plan-on-PR** (L18). The remaining human step.
10. **Add an integration test against the deployed ALB** (L16), the pipeline currently
    proves the service is _up_ and _is the right commit_, not that it _works_.

---

## What this build does prove

For balance, the things that are genuinely done and evidenced:

- Infrastructure is reproducible: destroyed and rebuilt from code alone, twice
- Deployments are traceable: `/api/status` returns the exact commit, verified by the pipeline
- No long-lived AWS credentials exist in the repository or in GitHub
- The vulnerability gate blocks rather than reports
- The container is non-root with package managers removed from the runtime layer
- State is versioned, encrypted, private and locked
- Teardown is complete and proven, so the environment can be left costing $0
