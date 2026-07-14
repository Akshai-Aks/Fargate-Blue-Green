#!/usr/bin/env bash
# Hit the ALB and print what version is currently serving + the health status.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ALB="$(terraform -chdir="${ROOT}/terraform" output -raw alb_dns_name)"

echo ">> GET http://${ALB}/"
curl -fsS "http://${ALB}/" || true
echo
echo ">> GET http://${ALB}/health"
curl -s -o /dev/null -w "HTTP %{http_code}\n" "http://${ALB}/health"
