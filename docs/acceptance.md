# Acceptance evidence

Back to [README](../README.md) · Related: [screenshots](screenshots/README.md) · [evidence artefacts](evidence/)

This is the index of proof. Every claim in the README maps to something here, a workflow
run, a commit, a captured API response, or a screenshot. Where the evidence shows a
failure, that is included too, because a record that contains only successes is not
evidence of much.

---

## Claim → evidence

| Claim                                      | Evidence                                                            | Where                                                                                                                                                                                            |
| ------------------------------------------ | ------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| The service runs and passes its tests      | 34 tests, 0 failing                                                 | Screenshot [`09-pipeline-dev-success.png`](screenshots/09-pipeline-dev-success.png), `npm test` output                                                                                           |
| The container is hardened                  | `npm`/`npx`/`corepack` absent from runtime, non-root uid 1000       | `app/Dockerfile`, Trivy gate passing                                                                                                                                                             |
| The vulnerability gate blocks              | Trivy runs before deploy and fails on HIGH/CRITICAL                 | [`09-pipeline-dev-success.png`](screenshots/09-pipeline-dev-success.png), `.github/workflows/application.yml`                                                                                    |
| Deployment is automated                    | Pipeline builds, pushes, registers a revision, updates the service  | [`09`](screenshots/09-pipeline-dev-success.png), [`10`](screenshots/10-pipeline-prod-success.png)                                                                                                |
| The deployed code is the intended code     | `/api/status` `commitSha` compared to `$GITHUB_SHA` in the pipeline | [`11-live-status-commit-match.png`](screenshots/11-live-status-commit-match.png), `evidence/status-dev.json`, `evidence/status-prod.json`                                                        |
| The API is explorable without code         | Swagger UI served from the ALB                                      | [`12-swagger-ui.png`](screenshots/12-swagger-ui.png)                                                                                                                                             |
| Both environments are live and independent | `dev` and `prod` return their own `environment` field               | `evidence/status-dev.json`, `evidence/status-prod.json`                                                                                                                                          |
| Alarms are wired and firing-capable        | 5 alarms per environment, SNS subscription **Confirmed**            | [`13-alarms-ok.png`](screenshots/13-alarms-ok.png), [`15-cloudwatch-alarms-ui.png`](screenshots/15-cloudwatch-alarms-ui.png), [`05b-sns-confirmation.png`](screenshots/05b-sns-confirmation.png) |
| Logs are structured JSON                   | Correlation id, method, path, status, duration per line             | [`14-cloudwatch-logs.png`](screenshots/14-cloudwatch-logs.png)                                                                                                                                   |
| Infrastructure is reproducible from code   | Destroyed and rebuilt, resource counts matched                      | [`01`](screenshots/01-teardown-account-empty.png), [`05`](screenshots/05-rebuild-dev-apply.png), [`07`](screenshots/07-rebuild-prod-apply.png)                                                   |
| Teardown is complete                       | 0 ALBs, 0 clusters, 0 repositories, 0 VPCs                          | [`01-teardown-account-empty.png`](screenshots/01-teardown-account-empty.png)                                                                                                                     |
| The foundation survives teardown           | State bucket, budget, CI roles intact                               | [`02-teardown-foundation-survives.png`](screenshots/02-teardown-foundation-survives.png)                                                                                                         |
| Safety defaults work                       | Destroy refused a non-empty ECR repository                          | [`03-teardown-ecr-refused-delete.png`](screenshots/03-teardown-ecr-refused-delete.png), [`04-ecr-emptied-deliberately.png`](screenshots/04-ecr-emptied-deliberately.png)                         |
| Rebuild requires a variable update         | `ALB_DNS_NAME` changed and was updated in both scopes               | [`06-rebuild-dev-outputs.png`](screenshots/06-rebuild-dev-outputs.png), [`08-github-vars-updated.png`](screenshots/08-github-vars-updated.png)                                                   |

---

## Pipeline runs

| Run           | Environment | Result                                 | What it proved                                                                          |
| ------------- | ----------- | -------------------------------------- | --------------------------------------------------------------------------------------- |
| `43810141216` | PR #8       | test pass, trivy pass, deploys skipped | Gates run on pull requests; deploys do not                                              |
| `43810304007` | `dev`       | exit 0                                 | Full path: OIDC → ECR push → register → update → stable → `/health` → `commitSha` match |
| `43810936644` | `prod`      | exit 0, 2m50s job time                 | Same path plus the environment wait timer and branch policy                             |

## Commits and revisions

| Commit    | What shipped                                            |
| --------- | ------------------------------------------------------- |
| `85f148e` | First successful pipeline deployment to `prod`          |
| `31db5e5` | `POST /api/echo` with validation                        |
| `65317c0` | `/openapi.json` and `/docs` (Swagger UI), PR #8 merged |

Each deployment registered a new ECS task definition revision; the service was updated to
it and `services-stable` was waited on before verification.

---

## Captured artefacts

Raw files in [`evidence/`](evidence/):

| File                                  | Contents                                            |
| ------------------------------------- | --------------------------------------------------- |
| `outputs-dev-pre-teardown.json`       | Full Terraform outputs for `dev` before destruction |
| `outputs-prod-pre-teardown.json`      | Full Terraform outputs for `prod`                   |
| `status-dev.json`                     | `/api/status` response from the live `dev` service  |
| `status-prod.json`                    | `/api/status` response from the live `prod` service |
| `echo-dev.json`, `echo-prod.json`     | `POST /api/echo` responses                          |
| `headers-dev.txt`, `headers-prod.txt` | Full response headers                               |
| `github-variables-pre-teardown.txt`   | Both variable scopes recorded before teardown       |

The recorded `status-pre-teardown` responses are the strongest single artefact: they show
`commitSha: 65317c0`, `environment: dev` / `prod`, and `nodeVersion: v24.14.1` coming from
a running container.

---

## Screenshots

Sixteen images in [`screenshots/`](screenshots/), indexed with the claim each one proves.
Captured during the destroy → rebuild → redeploy drill.

| #                                                     | Proves                                                          |
| ----------------------------------------------------- | --------------------------------------------------------------- |
| [01](screenshots/01-teardown-account-empty.png)       | Account empty of environment resources                          |
| [02](screenshots/02-teardown-foundation-survives.png) | Foundation retained                                             |
| [03](screenshots/03-teardown-ecr-refused-delete.png)  | Destroy refused a non-empty ECR repository                      |
| [04](screenshots/04-ecr-emptied-deliberately.png)     | Repository emptied deliberately                                 |
| [05](screenshots/05-rebuild-dev-apply.png)            | `dev` rebuilt from code (`Apply complete! Resources: 34 added`) |
| [05b](screenshots/05b-sns-confirmation.png)           | SNS subscription `Confirmed`                                    |
| [06](screenshots/06-rebuild-dev-outputs.png)          | New `dev` ALB DNS, changed from the previous build             |
| [07](screenshots/07-rebuild-prod-apply.png)           | `prod` rebuilt from code                                        |
| [08](screenshots/08-github-vars-updated.png)          | `ALB_DNS_NAME` updated in both variable scopes                  |
| [09](screenshots/09-pipeline-dev-success.png)         | `dev` deployed by the pipeline, all gates green                 |
| [10](screenshots/10-pipeline-prod-success.png)        | `prod` deployed by the pipeline, environment gate passed        |
| [11](screenshots/11-live-status-commit-match.png)     | `/api/status` reports the commit the pipeline built             |
| [12](screenshots/12-swagger-ui.png)                   | Swagger UI served from the live ALB                             |
| [13](screenshots/13-alarms-ok.png)                    | Alarms in `OK`, not stuck in `INSUFFICIENT_DATA`                |
| [14](screenshots/14-cloudwatch-logs.png)              | Structured JSON logs from the running task                      |
| [15](screenshots/15-cloudwatch-alarms-ui.png)         | The same alarms in the CloudWatch console                       |

---

## Failures recorded (deliberately)

These are part of the evidence, not omissions from it.

| Failure                                                | What it revealed                                                                                                                          |
| ------------------------------------------------------ | ----------------------------------------------------------------------------------------------------------------------------------------- |
| `trivy-action@0.28.0` does not exist                   | The job failed in 2s during "Set up job", before scanning. A gate that cannot start is indistinguishable from a gate that found something |
| 7 HIGH/CRITICAL in Alpine 3.23.4                       | Fixed with `apk upgrade --no-cache`                                                                                                       |
| `CVE-2026-73566` in `tar` inside npm                   | Fixed by deleting `npm`/`npx`/`corepack` from the runtime image                                                                           |
| OIDC trust never matched                               | GitHub emits **immutable subject claims** with numeric IDs; documented examples are wrong                                                 |
| `ecs:DescribeTaskDefinition` cannot be resource-scoped | Three IAM actions still use `Resource: "*"` because they authorise on `*` regardless of ARN                                               |
| `terraform destroy` stopped on ECR                     | `force_delete = false` was correct; the procedure was wrong                                                                               |
| Concurrent Terraform operations                        | The state lock returned 412, the lock working, not failing                                                                               |
| Terraform 1.17.1 declared, 1.17.2 running              | Snap auto-refreshed; nothing enforced the version file                                                                                    |

All are written up in [PROJECT_LOG.md](../PROJECT_LOG.md) and
[design decisions](design-decisions.md).

---

## What is _not_ evidenced

Being explicit about the gaps:

- **No load or performance test.** The service was never tested beyond functional requests
- **No security scan of the source tree.** Trivy scans the image; the code was not scanned
- **No penetration test or WAF validation**
- **No failure injection.** The circuit breaker rollback path is configured but was never
  triggered deliberately
- **No long-running soak test.** Uptime was minutes, not days
- **`prod` and `dev` were verified minutes apart, not under concurrent load**
