#!/usr/bin/env bash
# ==============================================================================
# Central Identity Service - Apply Configuration Script
# ==============================================================================
# Executes keycloak-config-cli against a target environment to synchronize
# realm settings, clients, roles, and users without downtime.
#
# Usage:
#   ./scripts/apply-config.sh                  # Runs via docker compose with current .env
#   ./scripts/apply-config.sh [ENV_FILE]       # Runs with a specific .env file (e.g. .env.staging)
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

ENV_FILE="${1:-${PROJECT_ROOT}/.env}"

if [[ ! -f "$ENV_FILE" ]]; then
  echo "Error: Environment file not found at '$ENV_FILE'"
  echo "Please create a .env file or supply the path as an argument."
  exit 1
fi

echo "Applying Keycloak configuration using environment file: ${ENV_FILE}"

cd "${PROJECT_ROOT}"

# Run keycloak-config-cli container as a one-shot job using the specified environment
docker compose --env-file "${ENV_FILE}" run --rm keycloak-config-cli

echo "Configuration successfully applied!"
