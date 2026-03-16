#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
COMPOSE_FILE="${REPO_ROOT}/docker-compose.yml"
CONTROLLER_FILE="${REPO_ROOT}/scripts/controller.sh"

compose_vars=(
  HEALTH_REPORT_URL
  HIVEMOOT_AGENT_TOKEN
  HIVEMOOT_AGENT_TOKEN_FILE
  HEALTH_REPORT_TIMEOUT_SECS
  HEALTH_REPORT_MAX_RETRIES
  HEALTH_REPORT_RUN_SUMMARY
)

fail=0
for var in "${compose_vars[@]}"; do
  pattern="^[[:space:]]+${var}:[[:space:]]+\\$\\{${var}:-"
  if ! grep -Eq "$pattern" "$COMPOSE_FILE"; then
    echo "Missing docker-compose env wiring for ${var}" >&2
    fail=1
  fi
done

controller_env_vars=(
  HEALTH_REPORT_URL
  HEALTH_REPORT_TIMEOUT_SECS
  HEALTH_REPORT_MAX_RETRIES
  HEALTH_REPORT_RUN_SUMMARY
)

for var in "${controller_env_vars[@]}"; do
  if ! grep -Eq "^[[:space:]]+append_env_if_set[[:space:]]+${var}$" "$CONTROLLER_FILE"; then
    echo "Missing controller env forwarding for ${var}" >&2
    fail=1
  fi
done

if ! grep -Eq '^[[:space:]]+append_secret_env[[:space:]]+HIVEMOOT_AGENT_TOKEN$' "$CONTROLLER_FILE"; then
  echo "Missing controller secret forwarding for HIVEMOOT_AGENT_TOKEN/HIVEMOOT_AGENT_TOKEN_FILE" >&2
  fail=1
fi

if [ "$fail" -ne 0 ]; then
  exit 1
fi

echo "PASS: health reporting env vars are wired into docker-compose and controller runtime env"
