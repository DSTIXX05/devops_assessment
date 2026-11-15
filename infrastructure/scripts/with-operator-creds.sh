#!/usr/bin/env bash
#
# Runs a command with short-lived operator credentials exported from a named
# AWS CLI profile.
#
# Why this exists:
#   The profiles on this workstation authenticate through the AWS CLI console
#   login mechanism (`login_session` in ~/.aws/config). Terraform's AWS provider
#   resolves that mechanism differently from the CLI: when `profile` is set it
#   consumes an account-scoped token cache and can silently authenticate as the
#   wrong identity - observed attaching the root user even though the CLI
#   reported an IAM user.
#
#   Exporting the session's credentials and leaving `profile` unset inside
#   Terraform removes that failure mode, and keeps credentials short-lived
#   instead of writing long-lived keys to disk.
#
# Usage:
#   ./scripts/with-operator-creds.sh terraform plan
#   ./scripts/with-operator-creds.sh terraform apply bootstrap.tfplan
#   AWS_OPERATOR_PROFILE=some-other-profile ./scripts/with-operator-creds.sh terraform plan
#
set -euo pipefail

PROFILE="${AWS_OPERATOR_PROFILE:-AdminDelightsome}"

if ! command -v aws >/dev/null 2>&1; then
  echo "error: aws CLI not found" >&2
  exit 1
fi

# Exactly one export-credentials call per invocation.
#
# Calling it twice trips the console-login refresh into returning expired
# credentials on the second call ("Credentials were refreshed, but the refreshed
# credentials are still expired"), so the output is captured once and reused.
if ! CREDS="$(aws configure export-credentials --profile "$PROFILE" --format env 2>/dev/null)"; then
  echo "error: no usable session for profile '$PROFILE'." >&2
  echo "       Run: aws login --profile $PROFILE" >&2
  exit 1
fi

# Export without echoing - the values are secrets.
#
# AWS_CREDENTIAL_EXPIRATION is informational and is dropped so a stale value
# does not confuse tooling that inspects credential metadata.
eval "$(printf '%s\n' "$CREDS" | grep -v '^export AWS_CREDENTIAL_EXPIRATION=')"

# Pin the region to the profile's region.
#
# Exported credentials carry no region. Without this, AWS CLI calls fall back to
# whatever region the [default] profile happens to use - which here is
# eu-north-1, while the project lives in us-east-1. Queries then return empty
# results rather than errors, which reads as "the resource is missing".
if [[ -z "${AWS_REGION:-}" && -z "${AWS_DEFAULT_REGION:-}" ]]; then
  PROFILE_REGION="$(aws configure get region --profile "$PROFILE" 2>/dev/null || true)"

  if [[ -n "$PROFILE_REGION" ]]; then
    export AWS_REGION="$PROFILE_REGION"
    export AWS_DEFAULT_REGION="$PROFILE_REGION"
  fi
fi

# Prove the identity before doing anything destructive.
IDENTITY_ARN="$(aws sts get-caller-identity --query Arn --output text)"
ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"

if [[ "$IDENTITY_ARN" == *":root" ]]; then
  echo "error: resolved identity is the account root user ($IDENTITY_ARN)." >&2
  echo "       Refusing to run. Sign in as a non-root IAM identity." >&2
  exit 1
fi

echo "operator identity : $IDENTITY_ARN"
echo "account           : $ACCOUNT_ID"
echo "---"

exec "$@"
