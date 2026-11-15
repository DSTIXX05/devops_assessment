# CI identity (GitHub Actions → AWS)

Creates the IAM roles GitHub Actions assumes via OIDC. One role per environment.

## Why a separate root

Deploy credentials are not part of the infrastructure they deploy into. Keeping
them in their own root and state file means the identity can be reviewed,
changed, or revoked independently of the VPC/ECS stack — and that a failed
`terraform destroy` in `environments/dev` cannot take the deploy role with it.

## What it creates

| Resource | Purpose |
| --- | --- |
| `aws_iam_role.deploy["dev"]` | Assumable from `refs/heads/main` |
| `aws_iam_role.deploy["prod"]` | Assumable from the GitHub Environment `prod` |
| `aws_iam_role_policy.deploy["dev"|"prod"]` | Scoped permissions per environment |

The **OIDC provider is referenced, not created.** This account already has
`token.actions.githubusercontent.com` from another project; a second provider
fails with `EntityAlreadyExists`. The project also deliberately does not *manage*
a shared account-level resource — if Terraform owned it, destroying this stack
could remove a provider other projects depend on. Set
`manage_oidc_provider = true` only in an account that has none.

## Trust policy

Both roles differ in exactly one line:

| Environment | `sub` claim required |
| --- | --- |
| dev | `repo:DSTIXX05/devops_assessment:ref:refs/heads/main` |
| prod | `repo:DSTIXX05/devops_assessment:environment:prod` |

Everything else is identical: `aud = sts.amazonaws.com`,
`action = sts:AssumeRoleWithWebIdentity`, principal = the federated provider.

Both use **`StringEquals`**, not `StringLike`. A `*` in that condition would
authorise every branch, tag, pull request, and workflow in the repository.

Prod trusts a GitHub **Environment** rather than a branch, so the deploy job must
satisfy that environment's protection rules (required reviewers) before GitHub
issues a token carrying `environment:prod`.

**Residual risk:** even with `main` pinned, the statement means "any workflow
running on main". The real boundary is branch protection — if someone can merge
workflow changes to `main`, they can use this role. Enable required reviews on
`main` before this is meaningful.

## Permissions

| Scope | Resource | Note |
| --- | --- | --- |
| `ecr:GetAuthorizationToken` | `*` | Account-scoped by AWS; cannot be narrowed |
| ECR push/pull | This environment's repository only | |
| `ecs:RegisterTaskDefinition` | `*` | No resource-level support; blast radius limited by `PassRole` |
| `ecs:DescribeTaskDefinition`, `ecs:TagResource` | This environment's task definition family | |
| `ecs:Describe*/UpdateService` | This environment's cluster, service, tasks | |
| `iam:PassRole` | This environment's two ECS roles, **condition `iam:PassedToService = ecs-tasks.amazonaws.com`** | Prevents using PassRole to escalate into other services |

The dev role cannot reach prod resources: the permissions policy is scoped to
dev's repository, cluster, and service ARNs.

## Apply

```bash
cd infrastructure/ci
cp terraform.tfvars.example terraform.tfvars   # first time only
terraform init
../scripts/with-operator-creds.sh terraform plan -out=ci.tfplan
../scripts/with-operator-creds.sh terraform apply ci.tfplan
terraform output deploy_role_arns
```

## What goes into GitHub

| Kind | Name | Value |
| --- | --- | --- |
| Variable (dev env) | `AWS_ROLE_ARN` | `terraform output -json deploy_role_arns` → `dev` |
| Variable (prod env) | `AWS_ROLE_ARN` | … → `prod` |
| Variable | `AWS_REGION` | `us-east-1` |
| Variable | `ECR_REPOSITORY` | `devops-assessment-<env>-app` |
| Variable | `ECS_CLUSTER` | `devops-assessment-<env>-cluster` |
| Variable | `ECS_SERVICE` | `devops-assessment-<env>-app` |
| Variable | `ALB_DNS_NAME` | `terraform output -raw alb_dns_name` from the environment root |

Role ARNs are not secrets. Nothing here is a credential, and nothing needs to be
stored as a GitHub secret — that is the point of OIDC.
