# Screenshot evidence

Captured during the teardown → rebuild → redeploy drill on 2026-11-16.

Naming: `NN-<what-it-proves>.png`, so the folder sorts in narrative order.

Each image should prove **one** claim. A screenshot that shows everything proves
nothing in particular, and a reviewer cannot tell whether it was cropped.

| #   | Image                                                                      | Claim it proves                                                                                               |
| --- | -------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------- |
| 01  | [01-teardown-account-empty.png](01-teardown-account-empty.png)             | Every environment resource is gone: 0 ALBs, 0 ECS clusters, 0 ECR repos, 0 VPCs, 0 alarms, 0 log groups       |
| 02  | [02-teardown-foundation-survives.png](02-teardown-foundation-survives.png) | The state bucket, budget, CI roles and OIDC provider were deliberately **not** destroyed                      |
| 03  | [03-teardown-ecr-refused-delete.png](03-teardown-ecr-refused-delete.png)   | `terraform destroy` refused to delete a non-empty ECR repo, the safety default firing                        |
| 04  | [04-ecr-emptied-deliberately.png](04-ecr-emptied-deliberately.png)         | The repository emptied only via an explicit script, not as a side effect                                      |
| 05  | [05-rebuild-dev-apply.png](05-rebuild-dev-apply.png)                       | Dev rebuilt from code alone: `Apply complete! Resources: 34 added`                                            |
| 05b | [05b-sns-confirmation.png](05b-sns-confirmation.png)                       | The SNS alarm subscription is `Confirmed`, not left in `PendingConfirmation`, otherwise alarms fire silently |
| 06  | [06-rebuild-dev-outputs.png](06-rebuild-dev-outputs.png)                   | New dev ALB DNS, compare with 01/03 evidence; it changed                                                     |
| 07  | [07-rebuild-prod-apply.png](07-rebuild-prod-apply.png)                     | Prod rebuilt from code alone                                                                                  |
| 08  | [08-github-vars-updated.png](08-github-vars-updated.png)                   | `ALB_DNS_NAME` updated in both scopes, otherwise the pipeline health check targets a dead host                |
| 09  | [09-pipeline-dev-success.png](09-pipeline-dev-success.png)                 | Dev deployed by the pipeline, all gates green                                                                 |
| 10  | [10-pipeline-prod-success.png](10-pipeline-prod-success.png)               | Prod deployed by the pipeline, environment gate passed                                                        |
| 11  | [11-live-status-commit-match.png](11-live-status-commit-match.png)         | `/api/status` reports the commit the pipeline just built                                                      |
| 12  | [12-swagger-ui.png](12-swagger-ui.png)                                     | Swagger UI loaded from the live ALB, endpoints expandable                                                     |
| 13  | [13-alarms-ok.png](13-alarms-ok.png)                                       | CloudWatch alarms back in `OK`, not stuck in `INSUFFICIENT_DATA`                                              |
| 14  | [14-cloudwatch-logs.png](14-cloudwatch-logs.png)                           | JSON structured logs from the running task                                                                    |
| 15  | [15-cloudwatch-alarms-ui.png](15-cloudwatch-alarms-ui.png)                 | The same five alarms as `13`, in the CloudWatch console, a UI view, not just CLI output                      |

## Rules for capturing

- Include the **browser URL bar** or the shell prompt in frame. A cropped
  terminal screenshot is not attributable to anything.
- Prefer one command per shot. If the output needs scrolling, split it.
- Do not edit images. A blurry screenshot is evidence; a tidy illustration is not.
