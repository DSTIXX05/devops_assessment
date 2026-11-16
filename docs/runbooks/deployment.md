# Deployment runbook

Back to [README](../../README.md) · Related: [teardown](teardown.md) · [architecture](../architecture.md) · [design decisions](../design-decisions.md)

Building this from nothing takes about ten minutes. Steps are ordered; several depend on
outputs from the one before.

---

## Prerequisites

| Tool       | Version | Check               |
| ---------- | ------- | ------------------- |
| Terraform  | 1.17.2  | `terraform version` |
| AWS CLI v2 | recent  | `aws --version`     |
| Docker     | recent  | `docker version`    |
| Node.js    | 24.14.1 | `node --version`    |
| `gh` CLI   | recent  | `gh auth status`    |
| `jq`       | any     | `jq --version`      |

An AWS IAM user with MFA and administrator access, configured as a named CLI profile.
This build used `AdminDelightsome`.

> **Never run Terraform as root.** Every command below goes through
> `infrastructure/scripts/with-operator-creds.sh`, which exports short-lived credentials
> from the named profile, pins the region, and **aborts if the resulting identity ARN ends
> in `:root`**. See [operator identity](operator-identity.md) for why this wrapper exists.

---

## 1 - Verify the application locally first

Do not deploy an image you have not run.

```bash
cd app
npm ci
npm test                    # expect 34 passing, 0 failing
npm start &                 # or: node src/server.js
curl -s localhost:3000/health
curl -s localhost:3000/api/status | jq .
kill %1
```

Then prove the container behaves the same way:

```bash
cd app
docker build -t devops-assessment:local .
docker run --rm -d -p 3001:3000 --name app devops-assessment:local
sleep 2
curl -s localhost:3001/api/status | jq '.commitSha, .nodeVersion'
docker logs app | head -5
docker rm -f app
```

Confirm the runtime image contains no package manager, if this succeeds, the hardening
step regressed:

```bash
docker run --rm devops-assessment:local sh -c 'command -v npm || echo "npm absent, as intended"'
```

---

## 2 - Bootstrap the state bucket and budget

The S3 backend cannot create the bucket that holds its own state, so this root uses
**local state** and is applied exactly once.

```bash
cd infrastructure/bootstrap
../scripts/with-operator-creds.sh terraform init
../scripts/with-operator-creds.sh terraform apply
```

Creates:

- `devops-assessment-tfstate-471112980487-us-east-1`, versioned, SSE-S3, public access
  blocked, TLS-only bucket policy, lifecycle rules (abort incomplete multipart after 7d,
  expire noncurrent versions after 90d)
- `devops-assessment-monthly`, $30 budget with alerts at 50/80/100% actual and 100%
  forecasted

**Keep this state file.** It is the only root without remote state.

---

## 3 - Create the CI deploy roles

```bash
cd infrastructure/ci
../scripts/with-operator-creds.sh terraform init
../scripts/with-operator-creds.sh terraform apply
```

Creates one role per environment, `devops-assessment-{dev,prod}-github-deploy`, trusting
GitHub's OIDC provider.

**If the OIDC provider does not exist yet**, this root references an existing one
(`manage_oidc_provider = false`). Either create it once:

```bash
aws iam create-open-id-connect-provider \
  --url https://token.actions.githubusercontent.com \
  --client-id-list sts.amazonaws.com
```

or set `manage_oidc_provider = true` before applying.

Collect the role ARNs; they are needed in step 5:

```bash
../scripts/with-operator-creds.sh terraform output
```

### The trust policy detail that breaks silently

The subject claim is matched from variables, and must use **immutable** claims. A modern
GitHub repository emits this:

```
repo:DSTIXX05@109713333/devops_assessment@1458162023:ref:refs/heads/main
```

Most examples on the internet show the _mutable_ form:

```
repo:DSTIXX05/devops_assessment:ref:refs/heads/main
```

The mutable form will not match, and the error is an unhelpful
`Not authorized to perform sts:AssumeRoleWithWebIdentity`. If you fork this, update
`github_owner_id` and `github_repo_id` in `infrastructure/ci/terraform.tfvars`. Get them
from:

```bash
gh api repos/:owner/:repo --jq '{owner_id: .owner.id, repo_id: .id}'
```

The two subject patterns in use:

| Environment | Subject                                     |
| ----------- | ------------------------------------------- |
| `dev`       | `repo:OWNER@ID/REPO@ID:ref:refs/heads/main` |
| `prod`      | `repo:OWNER@ID/REPO@ID:environment:prod`    |

`prod` is scoped to the **environment**, not the branch, so the wait timer and branch
policy on the `prod` GitHub environment become part of the authorisation.

---

## 4 - Apply the environments

`dev` first, then `prod`. Each is independent.

```bash
cd infrastructure/environments/dev
../../scripts/with-operator-creds.sh terraform init
../../scripts/with-operator-creds.sh terraform apply      # ~34 resources
../../scripts/with-operator-creds.sh terraform output
```

```bash
cd ../prod
../../scripts/with-operator-creds.sh terraform init
../../scripts/with-operator-creds.sh terraform apply
../../scripts/with-operator-creds.sh terraform output
```

Record `alb_dns_name`, `ecr_repository_url`, `ecs_cluster_name` and `ecs_service_name`
from each. Expect **34 resources** per environment; a different number means the rebuild
is not reproducing what was tested.

> The first apply deploys whatever `container_image` in `terraform.tfvars` points at.
> That tag may not exist yet in a fresh repository. The service will fail to start until
> the pipeline pushes an image, **this is expected**, and the pipeline deployment in
> step 6 resolves it. The alarms will sit in `INSUFFICIENT_DATA` until then.

---

## 5 - Configure GitHub variables

Two scopes. Getting this wrong is the most common failure: the pipeline deploys
successfully, then fails curling a load balancer that does not exist.

| Variable         | Scope                  | Value                                      |
| ---------------- | ---------------------- | ------------------------------------------ |
| `ALB_DNS_NAME`   | **repository**         | `dev` ALB DNS                              |
| `AWS_REGION`     | repository             | `us-east-1`                                |
| `AWS_ROLE_ARN`   | repository             | `devops-assessment-dev-github-deploy` ARN  |
| `ECR_REPOSITORY` | repository             | `dev` ECR repository URL                   |
| `ECS_CLUSTER`    | repository             | `devops-assessment-dev-cluster`            |
| `ECS_SERVICE`    | repository             | `devops-assessment-dev-app`                |
| `ALB_DNS_NAME`   | **environment `prod`** | `prod` ALB DNS                             |
| `AWS_REGION`     | environment `prod`     | `us-east-1`                                |
| `AWS_ROLE_ARN`   | environment `prod`     | `devops-assessment-prod-github-deploy` ARN |
| `ECR_REPOSITORY` | environment `prod`     | `prod` ECR repository URL                  |
| `ECS_CLUSTER`    | environment `prod`     | `devops-assessment-prod-cluster`           |
| `ECS_SERVICE`    | environment `prod`     | `devops-assessment-prod-app`               |

```bash
cd /home/dstixx05/Damolak_assessment_build
DEV_ALB=$(cd infrastructure/environments/dev && ../../scripts/with-operator-creds.sh terraform output -raw alb_dns_name 2>/dev/null | tail -n +4)
PROD_ALB=$(cd infrastructure/environments/prod && ../../scripts/with-operator-creds.sh terraform output -raw alb_dns_name 2>/dev/null | tail -n +4)

gh variable set ALB_DNS_NAME -R OWNER/REPO -b "$DEV_ALB"
gh variable set ALB_DNS_NAME -R OWNER/REPO -e prod -b "$PROD_ALB"
# … remaining variables per the table above
```

> **`tail -n +4` is load-bearing.** The wrapper prints an identity banner to stdout before
> `exec`, which corrupts any `terraform output -raw` captured into a variable. Without it
> `$DEV_ALB` contains the banner as well as the hostname.

**`ALB_DNS_NAME` changes on every rebuild.** ECR repository names, cluster names and
service names are deterministic and do not. If you destroy and re-apply, this is the only
variable that needs updating, and forgetting it makes the pipeline fail at the final
health check.

Also confirm the `prod` environment exists (Settings → Environments) with:

- Required reviewers: optional, but recommended
- Wait timer: 5 minutes
- Deployment branch policy: **`main` only**. Without this, any branch can deploy to prod

---

## 6 - Deploy through the pipeline

Push to `main` (via pull request, the ruleset rejects direct pushes) for `dev`. For
`prod`, dispatch manually:

```bash
gh workflow run application.yml --ref main -f environment=dev  -R OWNER/REPO
gh workflow run application.yml --ref main -f environment=prod -R OWNER/REPO

gh run list --workflow application.yml -L 3 -R OWNER/REPO
gh run watch <run-id> -R OWNER/REPO --interval 20 --exit-status
```

Each deploy job performs, in order:

1. Assume the deploy role via OIDC, then **assert the ARN is not root**
2. Log in to ECR
3. Check whether an image tagged with this SHA already exists, skip the build if so
4. Build and push (immutable SHA tag)
5. Render the current task definition, patch image and `COMMIT_SHA`, strip read-only
   fields, register a new revision
6. `update-service` to the new revision
7. `aws ecs wait services-stable`
8. `curl /health` with 12 retries
9. `curl /api/status` and compare `commitSha` to `$GITHUB_SHA`

Step 9 is the one that turns "the deploy returned 0" into "the right code is running".

---

## 7 - Verify

```bash
ALB=http://<alb-dns-name>

curl -s $ALB/health
curl -s $ALB/api/status | jq '{environment, commitSha, nodeVersion}'
curl -s -o /dev/null -w '%{http_code} %{content_type}\n' $ALB/docs
curl -s $ALB/openapi.json | jq '.openapi, (.paths | keys)'
curl -s -X POST $ALB/api/echo -H 'content-type: application/json' -d '{"message":"hello"}'
```

Expect `commitSha` to equal `git rev-parse origin/main`.

Alarms take a few minutes to leave `INSUFFICIENT_DATA` after the first task starts:

```bash
cd infrastructure
./scripts/with-operator-creds.sh aws cloudwatch describe-alarms \
  --alarm-name-prefix devops-assessment \
  --query 'MetricAlarms[].[AlarmName,StateValue]' --output table
```

---

## Troubleshooting

| Symptom                                                   | Cause                                                      | Fix                                                                                        |
| --------------------------------------------------------- | ---------------------------------------------------------- | ------------------------------------------------------------------------------------------ |
| `Not authorized to perform sts:AssumeRoleWithWebIdentity` | Trust policy subject does not match the immutable claim    | Update `github_owner_id` / `github_repo_id`; decode a real token rather than trusting docs |
| Job fails in ~2s during "Set up job"                      | A pinned action version does not exist                     | Check the tag exists; a gate that cannot start looks like a gate that failed               |
| `ResourceNotFoundException` on the service                | Variables point at another environment's service           | Re-check the two variable scopes                                                           |
| Final health check fails after a _rebuild_                | `ALB_DNS_NAME` still points at the destroyed load balancer | Update it in both scopes                                                                   |
| `Specified tag already exists` on push                    | ECR tags are immutable and the tag is not new              | The idempotency check should have skipped the build; verify it ran                         |
| `terraform destroy` fails: ECR not empty                  | `force_delete = false` by design                           | See [teardown](teardown.md)                                                                |
