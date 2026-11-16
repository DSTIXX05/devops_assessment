# Runbook: operator identity for Terraform

**Status:** **Resolved 2026-11-14.** `AdminDelightsome` →
`arn:aws:iam::471112980487:user/delightsomeAdmin`, IAM user, MFA enrolled (TOTP +
two U2F devices), `AdministratorAccess` attached directly. The bootstrap was
applied with this identity.

**Residual finding:** `aws iam get-account-summary` reports `RootKeys: 1`, the
account root user still has an active access key. See _Open item_ at the end.

## Why this matters

The approved architecture states, in two places:

- §9.1, _"Do not use the account root user for routine work. Protect privileged
  human identities with MFA."_
- §12.2, _"Do not use root credentials for routine operations."_

Both `Delightsome` and `delightsome-wordpress` resolve to
`arn:aws:iam::471112980487:root`. Applying Terraform with either profile would:

1. Contradict two explicit security requirements in the document being graded.
2. Record the root ARN in Terraform state and CloudTrail for every resource.
3. Give the provisioning session unrestricted access with no permission
   boundary and no way to scope it down.
4. Leave no separation between "human administrator" and "Terraform execution
   identity", which §9.1 requires as distinct identities.

Root access keys cannot be restricted. If they leak, the account is lost.

## Step 1 - Enable MFA on the root user (do this first)

Console → account menu → **Security credentials** → _Multi-factor authentication_
→ assign an authenticator app or hardware key.

Also delete any root **access keys** that exist. The `login_session` entry in
your CLI config is a console session, not a long-lived key, so removing keys does
not break it.

## Step 2 - Create a dedicated operator identity

One-time use of the root session to create the identity it will be replaced by.
This is the accepted bootstrap exception: root creates the admin, then root is
not used again.

Console → **IAM** → **User groups** → create `assessment-admins` → attach the
AWS managed policy `AdministratorAccess`.

Then **IAM** → **Users** → create `devops-assessment-admin` → add to
`assessment-admins` → enable console access → require MFA.

**Trade-off:** `AdministratorAccess` is broad. It is pragmatic here because the
Terraform roots create IAM roles, policies, VPCs, ECS services, and load
balancers, and a hand-scoped policy would be larger than the code it protects. A
production setup would use IAM Identity Center permission sets and short-lived
credentials. Record either choice, do not leave it unstated.

## Step 3 - Authenticate as the new identity

```bash
aws login --profile assessment-admin     # console-session flow
# or, if that flow is unavailable for IAM users:
aws configure --profile assessment-admin
```

## Step 4 - Verify before touching Terraform

```bash
aws sts get-caller-identity --profile assessment-admin
```

The `Arn` **must** contain `:user/`, not `:root`. If it does not, stop and fix
the profile.

```bash
aws configure get region --profile assessment-admin   # expect us-east-1
```

## Step 5 - Supply credentials to Terraform

Do **not** set `aws_profile` in `terraform.tfvars`, despite the variable still
existing. An explicit profile makes the AWS provider resolve the CLI's
account-scoped `login_session` cache, which attached the **root** identity during
this build even after the IAM user was verified by `sts`. Use the wrapper:

```bash
cd infrastructure/bootstrap
../scripts/with-operator-creds.sh terraform plan
```

It exports short-lived credentials from the named session, leaves `profile` null
so Terraform uses the environment credential chain, and refuses to run if the
resolved identity is root. Details in `infrastructure/bootstrap/README.md`.

## Open item - accepted risk, out of scope

The root user has an active access key (`RootKeys: 1` in the account summary).
Root MFA is enabled, but a root access key bypasses MFA entirely and cannot be
scoped by policy.

**Decision (2026-11-15): account-level root hardening is out of scope for this
project.** The account is not exclusively used for the assessment, so deleting
the key carries risk outside the project's control.

Scope of what _is_ closed: no project resource is created or managed by root. The
`aws_caller_arn` output is the standing evidence,
`arn:aws:iam::471112980487:user/delightsomeAdmin`.

The README must describe this accurately: the **project's operator path** avoids
root; the **account** is not hardened.

## If root is used anyway

That is a conscious deviation from the approved architecture, not an oversight.
It must be recorded in `PROJECT_LOG.md` with the residual risk stated, and the
README must not claim least-privilege operator access. Not recommended: it is one
of the cheapest criteria on the assessment to satisfy correctly.
