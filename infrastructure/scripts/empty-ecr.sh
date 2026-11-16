#!/usr/bin/env bash
# Delete every image in an ECR repository.
#
# Teardown prerequisite. The ECR module sets force_delete = false by default so
# that `terraform destroy` cannot silently discard release artefacts - the
# repository refuses to be deleted while it still contains images. That means a
# full teardown needs an explicit, deliberate delete first, which is this script.
#
# Requires operator credentials, e.g.:
#   ./scripts/with-operator-creds.sh ./scripts/empty-ecr.sh devops-assessment-dev-app
set -euo pipefail

repo="${1:?usage: empty-ecr.sh <repository-name>}"
registry="$(aws sts get-caller-identity --query Account --output text).dkr.ecr.${AWS_REGION:-us-east-1}.amazonaws.com"

digests="$(aws ecr list-images --repository-name "$repo" \
  --query 'imageIds[*].imageDigest' --output text | tr '\t' '\n' | sed '/^$/d')"

if [ -z "$digests" ]; then
  echo "$repo: already empty"
  exit 0
fi

count="$(printf '%s\n' "$digests" | wc -l | tr -d ' ')"
echo "$repo: deleting $count image(s)"

# ECR accepts at most 100 image ids per BatchDeleteImage call.
printf '%s\n' "$digests" | split -l 100 - /tmp/ecr-batch-
for f in /tmp/ecr-batch-*; do
  ids="$(python3 -c \
    "import json,sys;print(json.dumps([{'imageDigest':l.strip()} for l in open('$f') if l.strip()]))")"
  aws ecr batch-delete-image --repository-name "$repo" --image-ids "$ids" \
    --query 'failures[]' --output json
  rm -f "$f"
done

echo "$repo: remaining images: $(aws ecr list-images --repository-name "$repo" --query 'length(imageIds)' --output text)"
