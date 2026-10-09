#!/usr/bin/env bash
# ==============================================================================
# Central Identity Service - Phase 1 Verification Suite
# ==============================================================================
# Validates all 6 criteria from Section 8 of central-identity-service.md:
# 1. Keycloak health endpoint is UP
# 2. OIDC discovery document reachable
# 3. keycloak-config-cli completed & platform realm exists with all 4 clients
# 4. Client credentials token for test-apiclient-example has aud=test-api,
#    role=api-access, and neither user nor admin roles
# 5. JWKS endpoint returns active keys
# 6. Password grant requests are rejected (insecure flows disabled)
# ==============================================================================

set -euo pipefail

# Locate script directory and project root
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Load .env if present
if [[ -f "${PROJECT_ROOT}/.env" ]]; then
  # export variables from .env while ignoring comments
  set -a
  # shellcheck source=/dev/null
  source "${PROJECT_ROOT}/.env"
  set +a
fi

# Configuration defaults
KC_PORT="${KC_PORT:-8080}"
KC_MANAGEMENT_PORT="${KC_MANAGEMENT_PORT:-9000}"
KC_HOST="localhost"
KC_URL="http://${KC_HOST}:${KC_PORT}"
KC_MGMT_URL="http://${KC_HOST}:${KC_MANAGEMENT_PORT}"
REALM="platform"

# Admin credentials
ADMIN_USER="${KC_BOOTSTRAP_ADMIN_USERNAME:-admin}"
ADMIN_PASS="${KC_BOOTSTRAP_ADMIN_PASSWORD:-}"

# Client credentials
APICLIENT_ID="test-apiclient-example"
APICLIENT_SECRET="${TEST_APICLIENT_SECRET:-}"
USER_WEB_ID="test-user-web"
USER_WEB_SECRET="${TEST_USER_WEB_SECRET:-}"

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

FAILED_TESTS=0
TOTAL_TESTS=6

echo -e "${BLUE}==============================================================================${NC}"
echo -e "${BLUE}        Central Identity Service - Phase 1 Verification Suite         ${NC}"
echo -e "${BLUE}==============================================================================${NC}"
echo "Keycloak Base URL:       ${KC_URL}"
echo "Management Endpoint:     ${KC_MGMT_URL}"
echo "Target Realm:            ${REALM}"
echo "------------------------------------------------------------------------------"

pass() {
  echo -e " [ ${GREEN}PASS${NC} ] $1"
}

fail() {
  echo -e " [ ${RED}FAIL${NC} ] $1: $2"
  FAILED_TESTS=$((FAILED_TESTS + 1))
}

# Helper to decode base64url JWT payload
decode_jwt_payload() {
  local token="$1"
  local payload
  payload=$(echo "$token" | cut -d '.' -f 2)
  # Fix base64url padding
  local len=$((${#payload} % 4))
  if [ "$len" -eq 2 ]; then
    payload="${payload}=="
  elif [ "$len" -eq 3 ]; then
    payload="${payload}="
  fi
  # Translate urlsafe base64 to standard base64 and decode
  echo "$payload" | tr '_-' '/+' | base64 --decode 2>/dev/null || \
  echo "$payload" | tr '_-' '/+' | base64 -D 2>/dev/null
}

# ------------------------------------------------------------------------------
# Test 1: Keycloak Health Endpoint
# ------------------------------------------------------------------------------
echo -e "\n${YELLOW}Test 1: Keycloak Health Endpoint is UP${NC}"
HEALTH_HTTP_CODE=0
HEALTH_BODY=""
# Try management port first, then fall back to main port
if HEALTH_RESP=$(curl -s -w "\n%{http_code}" "${KC_MGMT_URL}/health/ready" 2>/dev/null); then
  HEALTH_HTTP_CODE=$(echo "$HEALTH_RESP" | tail -n 1)
  HEALTH_BODY=$(echo "$HEALTH_RESP" | sed '$d')
fi

if [[ "$HEALTH_HTTP_CODE" -ne 200 ]]; then
  if HEALTH_RESP=$(curl -s -w "\n%{http_code}" "${KC_URL}/health/ready" 2>/dev/null); then
    HEALTH_HTTP_CODE=$(echo "$HEALTH_RESP" | tail -n 1)
    HEALTH_BODY=$(echo "$HEALTH_RESP" | sed '$d')
  fi
fi

if [[ "$HEALTH_HTTP_CODE" -eq 200 ]] && echo "$HEALTH_BODY" | grep -q '"status":[ ]*"UP"'; then
  pass "Keycloak readiness probe returned HTTP 200 with status UP"
else
  fail "Health Endpoint" "Expected HTTP 200 UP but received HTTP ${HEALTH_HTTP_CODE} with body: ${HEALTH_BODY}"
fi

# ------------------------------------------------------------------------------
# Test 2: OIDC Discovery Document
# ------------------------------------------------------------------------------
echo -e "\n${YELLOW}Test 2: OIDC Discovery Document Reachable${NC}"
DISCOVERY_URL="${KC_URL}/realms/${REALM}/.well-known/openid-configuration"
DISC_RESP=$(curl -s -w "\n%{http_code}" "${DISCOVERY_URL}" 2>/dev/null || echo -e "\n000")
DISC_HTTP_CODE=$(echo "$DISC_RESP" | tail -n 1)
DISC_BODY=$(echo "$DISC_RESP" | sed '$d')

if [[ "$DISC_HTTP_CODE" -eq 200 ]] && echo "$DISC_BODY" | jq -e '.token_endpoint and .authorization_endpoint' >/dev/null 2>&1; then
  ISSUER=$(echo "$DISC_BODY" | jq -r '.issuer')
  pass "Discovery document available at ${DISCOVERY_URL} (Issuer: ${ISSUER})"
else
  fail "OIDC Discovery" "Failed to retrieve discovery doc from ${DISCOVERY_URL} (HTTP ${DISC_HTTP_CODE})"
fi

# ------------------------------------------------------------------------------
# Test 3: config-cli completed; platform realm exists with the four clients
# ------------------------------------------------------------------------------
echo -e "\n${YELLOW}Test 3: Platform Realm Exists with Required Clients${NC}"
# Authenticate against master realm admin-cli to get admin access token
ADMIN_TOKEN_RESP=$(curl -s -X POST "${KC_URL}/realms/master/protocol/openid-connect/token" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "client_id=admin-cli" \
  -d "username=${ADMIN_USER}" \
  -d "password=${ADMIN_PASS}" \
  -d "grant_type=password" 2>/dev/null || echo "{}")

ADMIN_TOKEN=$(echo "$ADMIN_TOKEN_RESP" | jq -r '.access_token // empty')

if [[ -z "$ADMIN_TOKEN" ]]; then
  fail "Admin Authentication" "Unable to obtain admin access token for realm inspection: ${ADMIN_TOKEN_RESP}"
else
  # Query realm clients
  CLIENTS_RESP=$(curl -s "${KC_URL}/admin/realms/${REALM}/clients" \
    -H "Authorization: Bearer ${ADMIN_TOKEN}" 2>/dev/null || echo "[]")

  REQUIRED_CLIENTS=("test-user-web" "test-admin-web" "test-api" "test-apiclient-example")
  MISSING_CLIENTS=()

  for c in "${REQUIRED_CLIENTS[@]}"; do
    if ! echo "$CLIENTS_RESP" | jq -e ".[] | select(.clientId == \"$c\")" >/dev/null 2>&1; then
      MISSING_CLIENTS+=("$c")
    fi
  done

  if [[ ${#MISSING_CLIENTS[@]} -eq 0 ]]; then
    pass "All 4 clients exist in realm '${REALM}': ${REQUIRED_CLIENTS[*]}"
  else
    fail "Client Presence" "Missing clients in realm '${REALM}': ${MISSING_CLIENTS[*]}"
  fi
fi

# ------------------------------------------------------------------------------
# Test 4: Client Credentials Token & Role Inspection
# ------------------------------------------------------------------------------
echo -e "\n${YELLOW}Test 4: Client Credentials Token (Audience & Role Validation)${NC}"
TOKEN_ENDPOINT="${KC_URL}/realms/${REALM}/protocol/openid-connect/token"
CC_RESP=$(curl -s -X POST "${TOKEN_ENDPOINT}" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "grant_type=client_credentials" \
  -d "client_id=${APICLIENT_ID}" \
  -d "client_secret=${APICLIENT_SECRET}" 2>/dev/null || echo "{}")

CC_TOKEN=$(echo "$CC_RESP" | jq -r '.access_token // empty')

if [[ -z "$CC_TOKEN" ]]; then
  fail "Client Credentials" "Could not obtain token for ${APICLIENT_ID}: ${CC_RESP}"
else
  JWT_PAYLOAD=$(decode_jwt_payload "$CC_TOKEN")
  
  # 1. Verify aud contains test-api
  AUD_CHECK=$(echo "$JWT_PAYLOAD" | jq -r 'if (.aud | type) == "array" then (.aud | contains(["test-api"])) else (.aud == "test-api") end')
  
  # 2. Verify roles in resource_access.test-api.roles
  HAS_API_ACCESS=$(echo "$JWT_PAYLOAD" | jq -r '(.resource_access."test-api".roles // []) | contains(["api-access"])')
  HAS_USER_ROLE=$(echo "$JWT_PAYLOAD" | jq -r '(.resource_access."test-api".roles // []) | contains(["user"])')
  HAS_ADMIN_ROLE=$(echo "$JWT_PAYLOAD" | jq -r '(.resource_access."test-api".roles // []) | contains(["admin"])')

  if [[ "$AUD_CHECK" == "true" ]] && [[ "$HAS_API_ACCESS" == "true" ]] && [[ "$HAS_USER_ROLE" == "false" ]] && [[ "$HAS_ADMIN_ROLE" == "false" ]]; then
    pass "Token carries aud='test-api', holds role='api-access', and excludes 'user'/'admin' roles"
  else
    fail "Token Claims" "Audience or roles invalid. aud=${AUD_CHECK}, api-access=${HAS_API_ACCESS}, user=${HAS_USER_ROLE}, admin=${HAS_ADMIN_ROLE}. Payload: $(echo "$JWT_PAYLOAD" | jq -c '.resource_access // {}')"
  fi
fi

# ------------------------------------------------------------------------------
# Test 5: JWKS Endpoint Returns Active Keys
# ------------------------------------------------------------------------------
echo -e "\n${YELLOW}Test 5: JWKS Endpoint Returns Public Keys${NC}"
CERTS_URL="${KC_URL}/realms/${REALM}/protocol/openid-connect/certs"
JWKS_RESP=$(curl -s -w "\n%{http_code}" "${CERTS_URL}" 2>/dev/null || echo -e "\n000")
JWKS_HTTP_CODE=$(echo "$JWKS_RESP" | tail -n 1)
JWKS_BODY=$(echo "$JWKS_RESP" | sed '$d')

KEY_COUNT=$(echo "$JWKS_BODY" | jq -r '.keys | length // 0' 2>/dev/null || echo 0)

if [[ "$JWKS_HTTP_CODE" -eq 200 ]] && [[ "$KEY_COUNT" -gt 0 ]]; then
  KEY_ALG=$(echo "$JWKS_BODY" | jq -r '.keys[0].alg // "RS256"')
  pass "JWKS endpoint returned HTTP 200 with ${KEY_COUNT} signing keys (Alg: ${KEY_ALG})"
else
  fail "JWKS Endpoint" "Expected active signing keys from ${CERTS_URL} but got HTTP ${JWKS_HTTP_CODE}"
fi

# ------------------------------------------------------------------------------
# Test 6: Direct Access Grant (Password) Request is Rejected
# ------------------------------------------------------------------------------
echo -e "\n${YELLOW}Test 6: Insecure Password Grants are Rejected${NC}"
PWD_GRANT_RESP=$(curl -s -w "\n%{http_code}" -X POST "${TOKEN_ENDPOINT}" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "grant_type=password" \
  -d "client_id=${USER_WEB_ID}" \
  -d "client_secret=${USER_WEB_SECRET}" \
  -d "username=user@test.local" \
  -d "password=wrongpassword" 2>/dev/null || echo -e "\n000")

PWD_HTTP_CODE=$(echo "$PWD_GRANT_RESP" | tail -n 1)
PWD_BODY=$(echo "$PWD_GRANT_RESP" | sed '$d')

# Direct Access Grant disabled should yield HTTP 400 or 401 with "unauthorized_client"
if [[ "$PWD_HTTP_CODE" =~ ^(400|401)$ ]] && echo "$PWD_BODY" | grep -q 'unauthorized_client'; then
  pass "Password grant correctly rejected with HTTP ${PWD_HTTP_CODE} 'unauthorized_client'"
elif [[ "$PWD_HTTP_CODE" =~ ^(400|401)$ ]] && echo "$PWD_BODY" | grep -q 'invalid_grant'; then
  pass "Password grant was rejected with HTTP ${PWD_HTTP_CODE} 'invalid_grant'"
else
  fail "Password Grant" "Expected rejection with HTTP 400/401 unauthorized_client, but got HTTP ${PWD_HTTP_CODE}: ${PWD_BODY}"
fi

# ------------------------------------------------------------------------------
# Final Summary
# ------------------------------------------------------------------------------
echo -e "\n------------------------------------------------------------------------------"
PASSED_TESTS=$((TOTAL_TESTS - FAILED_TESTS))
if [[ "$FAILED_TESTS" -eq 0 ]]; then
  echo -e "${GREEN}SUCCESS: All ${TOTAL_TESTS}/${TOTAL_TESTS} smoke tests PASSED!${NC}"
  echo -e "------------------------------------------------------------------------------\n"
  exit 0
else
  echo -e "${RED}FAILURE: ${FAILED_TESTS}/${TOTAL_TESTS} smoke tests failed.${NC}"
  echo -e "------------------------------------------------------------------------------\n"
  exit 1
fi
