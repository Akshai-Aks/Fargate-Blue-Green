#!/usr/bin/env bash
# Dump CodeDeploy deployment details to evidence/ for the submission.
#   ./scripts/collect_evidence.sh [deployment-id]
# With no argument, uses the id from the most recent deploy.sh run.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REGION="$(terraform -chdir="${ROOT}/terraform" output -raw region)"
DEP_ID="${1:-$(cat "${ROOT}/.last_deployment_id" 2>/dev/null || true)}"

if [ -z "${DEP_ID}" ]; then
  echo "no deployment id given and .last_deployment_id not found" >&2
  exit 1
fi

OUT="${ROOT}/evidence/deployment-${DEP_ID}.json"
echo ">> writing ${OUT}"
aws deploy get-deployment --deployment-id "${DEP_ID}" --region "${REGION}" > "${OUT}"

echo ">> summary:"
jq '.deploymentInfo | {status, deploymentConfigName, rollbackInfo, errorInformation, createTime, completeTime}' "${OUT}"
