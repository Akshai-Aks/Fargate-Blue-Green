#!/usr/bin/env bash
# Roll out an image version through CodeDeploy (ECS blue/green).
#   ./scripts/deploy.sh v2   -> healthy upgrade, traffic shifts blue->green
#   ./scripts/deploy.sh v3   -> broken release, deployment fails and auto-rolls back
#
# Steps: register a new task-def revision pointing at the given image tag,
# build an ECS AppSpec that references it, then create a CodeDeploy deployment
# and wait for the outcome.
set -euo pipefail

VERSION="${1:?usage: deploy.sh <version-tag>}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TF="terraform -chdir=${ROOT}/terraform output -raw"

REGION="$(${TF} region)"
FAMILY="$(${TF} task_definition_family)"
REPO_URL="$(${TF} ecr_repository_url)"
CONTAINER="$(${TF} container_name)"
PORT="$(${TF} container_port)"
CD_APP="$(${TF} codedeploy_app_name)"
CD_DG="$(${TF} codedeploy_deployment_group_name)"
IMAGE="${REPO_URL}:${VERSION}"

echo ">> registering new task definition revision for ${IMAGE}"
CURRENT="$(aws ecs describe-task-definition --task-definition "${FAMILY}" --region "${REGION}")"
NEW_TD="$(echo "${CURRENT}" | jq --arg IMG "${IMAGE}" '
  .taskDefinition
  | .containerDefinitions[0].image = $IMG
  | {family, taskRoleArn, executionRoleArn, networkMode, containerDefinitions,
     requiresCompatibilities, cpu, memory, runtimePlatform, volumes, placementConstraints}
  | with_entries(select(.value != null and .value != []))')"

NEW_ARN="$(aws ecs register-task-definition \
  --region "${REGION}" \
  --cli-input-json "${NEW_TD}" \
  --query 'taskDefinition.taskDefinitionArn' --output text)"
echo ">> registered ${NEW_ARN}"

APPSPEC="$(jq -n --arg TD "${NEW_ARN}" --arg C "${CONTAINER}" --argjson P "${PORT}" '
  {
    version: "0.0",
    Resources: [
      { TargetService: {
          Type: "AWS::ECS::Service",
          Properties: {
            TaskDefinition: $TD,
            LoadBalancerInfo: { ContainerName: $C, ContainerPort: $P }
          }
      }}
    ]
  }')"

CREATE="$(jq -n \
  --arg APP "${CD_APP}" \
  --arg DG "${CD_DG}" \
  --arg SPEC "$(echo "${APPSPEC}" | jq -c .)" '
  {
    applicationName: $APP,
    deploymentGroupName: $DG,
    revision: { revisionType: "AppSpecContent", appSpecContent: { content: $SPEC } }
  }')"

echo ">> creating CodeDeploy deployment"
DEP_ID="$(aws deploy create-deployment \
  --region "${REGION}" \
  --cli-input-json "${CREATE}" \
  --query 'deploymentId' --output text)"
echo ">> deployment id: ${DEP_ID}"
echo "${DEP_ID}" > "${ROOT}/.last_deployment_id"

echo ">> waiting for deployment to finish (this can take a few minutes)..."
if aws deploy wait deployment-successful --deployment-id "${DEP_ID}" --region "${REGION}" 2>/dev/null; then
  echo ">> SUCCESS: deployment ${DEP_ID} completed"
else
  echo ">> deployment ${DEP_ID} did not succeed (expected for the broken v3 release)"
fi

echo ">> final status:"
aws deploy get-deployment --deployment-id "${DEP_ID}" --region "${REGION}" \
  --query 'deploymentInfo.{status:status, deploymentConfig:deploymentConfigName, rollbackInfo:rollbackInfo, errorInfo:errorInformation}' \
  --output json
