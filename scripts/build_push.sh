#!/usr/bin/env bash
# Build and push an image version to ECR.
#   ./scripts/build_push.sh v1   -> healthy
#   ./scripts/build_push.sh v2   -> healthy
#   ./scripts/build_push.sh v3   -> broken /health (returns 500) to trigger rollback
set -euo pipefail

VERSION="${1:?usage: build_push.sh <v1|v2|v3>}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TF="terraform -chdir=${ROOT}/terraform output -raw"

REPO_URL="$(${TF} ecr_repository_url)"
REGISTRY="${REPO_URL%%/*}"
# The `region` output isn't evaluated during the ECR-only bootstrap apply
# (-target prunes outputs not tied to the targeted resource), so fall back to
# deriving it from the registry host: <acct>.dkr.ecr.<region>.amazonaws.com
REGION="$(${TF} region 2>/dev/null || true)"
[ -z "${REGION}" ] && REGION="$(echo "${REGISTRY}" | cut -d. -f4)"

# v3 is the intentionally broken release.
HEALTHY="true"
[ "${VERSION}" = "v3" ] && HEALTHY="false"

echo ">> logging in to ECR (${REGISTRY})"
aws ecr get-login-password --region "${REGION}" \
  | docker login --username AWS --password-stdin "${REGISTRY}"

echo ">> building ${REPO_URL}:${VERSION} (healthy=${HEALTHY})"
docker build \
  --platform linux/amd64 \
  --build-arg APP_VERSION="${VERSION}" \
  --build-arg HEALTHY="${HEALTHY}" \
  -t "${REPO_URL}:${VERSION}" \
  "${ROOT}/app"

echo ">> pushing ${REPO_URL}:${VERSION}"
docker push "${REPO_URL}:${VERSION}"
echo ">> done: ${REPO_URL}:${VERSION}"
