# TASK (PHASE 1): Stand up a central Keycloak identity service with Docker Compose

## 1. Context
I am building a central identity service (`idp.mydomain.com`) providing authentication and
authorization for multiple products. Keycloak is the chosen IdP. KYC/identity verification is OUT OF SCOPE.

This is PHASE 1 only: get the identity service running and verified using a single TEST product.
Real products (Medix, SpendXR, KiraScreen and their admin apps) will be onboarded later, one at a
time, by adding clients to the config. Do NOT create clients for them now.

Stack of future consumers: React frontends, .NET backends. Frontends use a BFF pattern (the .NET
backend does the OIDC login as a confidential client and issues an HttpOnly cookie). APIs validate
JWT bearer tokens.

## 2. Architecture decisions (do not change without asking)
- ONE realm named `platform` shared by all products (global users + SSO). Use `master` only for administration.
- Admin vs user is controlled by ROLES on API clients, not separate realms.
- Environments (dev / staging / prod) are SEPARATE Keycloak instances, never separate realms.
  The realm name stays `platform` in every environment. Only hostnames, secrets and URIs differ via env vars.
- Machine/API callers use confidential clients with service accounts (client credentials grant).
- Never copy production users into lower environments. Use seeded test users only.

## 3. Client naming convention (mandatory)
- `<product>-user-web`  : the user-facing app (confidential, auth code + PKCE, used by the BFF)
- `<product>-admin-web` : the admin app (confidential, auth code + PKCE, stricter settings)
- `<product>-api`       : the backend API (resource server; holds the roles)
- Machine clients (not covered by the convention above): `<product>-apiclient-<name>`

For phase 1 the product name is `test`.

## 4. Deliverables
Create this repository layout:

```
identity/
  docker-compose.yml
  docker-compose.override.yml        # dev-only conveniences
  .env.example                       # all variables, no real secrets
  .gitignore                         # must ignore .env and any exported secrets
  README.md
  keycloak/
    Dockerfile                       # optional: pre-built optimized image
    themes/                          # empty placeholder for a future custom theme
    import/                          # keycloak-config-cli YAML/JSON
      platform/
        realm.yml                    # realm settings, password policy, brute force, required actions
        clients.yml                  # clients (see section 6)
        roles.yml                    # client roles
        users.dev.yml                # seeded test user, DEV ONLY
  scripts/
    verify.sh                        # smoke tests (see section 8)
    apply-config.sh                  # runs keycloak-config-cli against a target env
```

## 5. Docker Compose requirements
- Services: `postgres` (dedicated DB for Keycloak), `keycloak`, `keycloak-config-cli` (one-shot job
  that runs after Keycloak is healthy), and `mailpit` (dev SMTP catcher, dev override only).
- Use the official Keycloak image (Quarkus distribution). Look up the current stable version and pin
  an exact tag. Do not use `latest`. Pin exact tags for Postgres, keycloak-config-cli and Mailpit too.
- Keycloak runs in production mode (`start`) in the base compose file and `start-dev` only in the override file.
- Configure the database via env vars (`KC_DB=postgres`, URL, user, password from `.env`).
- Hostname and proxy settings driven by env vars (`KC_HOSTNAME`, `KC_PROXY_HEADERS`, `KC_HTTP_ENABLED`
  as appropriate), because staging/prod sit behind a reverse proxy that terminates TLS. Document the
  correct values for dev (http://localhost) vs staging/prod (https behind proxy).
- Enable health and metrics endpoints. Add healthchecks for Postgres and Keycloak, and make dependent
  services wait via `depends_on: condition: service_healthy`.
- Named volumes for Postgres data. Private network; expose only the Keycloak HTTP port (plus the
  Mailpit UI in dev).
- Bootstrap admin credentials come from env vars and are only used on first start. Note in the README
  that they must be changed and that the admin console must not be publicly exposed in staging/prod.
- No secrets hardcoded anywhere. Everything secret comes from `.env`; `.env.example` documents each variable.

## 6. Realm and client configuration (as code via keycloak-config-cli)

### Realm `platform`
- Login with email; email verification required; registration enabled; forgot-password enabled.
- Password policy: minimum length 12, must not equal username/email. Brute-force detection ON.
- Users may configure TOTP and WebAuthn (passkeys). Do not build SMS OTP.
- Short access token lifetime (about 5-10 min); refresh token rotation with reuse detection where supported.
- SMTP pointing at Mailpit in dev; env-var driven for other environments.

### Phase 1 clients (env-var placeholders for URLs and secrets; no wildcard redirect URIs)
| Client ID | Type | Purpose |
|---|---|---|
| `test-user-web` | confidential, auth code + PKCE | BFF login for the test user app |
| `test-admin-web` | confidential, auth code + PKCE, stricter settings | BFF login for the test admin app |
| `test-api` | resource server (bearer validation) | roles: `user`, `admin`, `api-access` |
| `test-apiclient-example` | confidential, service account, client credentials | machine caller with role `api-access` only |

Requirements:
- Add an audience mapper so tokens for the API carry `aud` = `test-api`.
- Roles must be present in tokens in a form .NET can map. Document where they land
  (e.g. `resource_access.test-api.roles`).
- Admin client: shorter session. If forcing OTP for the `admin` role is achievable via flow config,
  do it; otherwise document how to do it manually.
- The machine client must obtain a token via client credentials and must NOT hold the `user` or `admin` role.
- Disable direct access (password) grants and implicit flow on every client.

### Dev seed users (users.dev.yml, DEV ONLY)
- `customer@test.local` with role `customer` on `test-api`
- `administrator@test.local` with role `administrator` on `test-api`
Never include these in staging/production configs.

## 7. Security rules
- No secrets committed. `.env` is gitignored.
- Different client secrets and signing keys per environment.
- Admin console not publicly exposed in staging/prod (document an allowlist or separate admin hostname).
- Strict redirect URIs and web origins per client.

## 8. Verification (scripts/verify.sh)
After `docker compose up`, report pass/fail for:
1. Keycloak health endpoint is up.
2. OIDC discovery document reachable at `/realms/platform/.well-known/openid-configuration`.
3. config-cli job completed; the `platform` realm exists with the four clients in section 6.
4. A client-credentials token can be obtained for `test-apiclient-example`; decoded token shows the
   expected `aud` and role.
5. JWKS endpoint returns keys.
6. A password-grant request is rejected (confirms insecure flows are disabled).

## 9. README must include
Prerequisites, first-run steps, how to add a new product (add the three `<product>-*` clients and
roles to the YAML, run apply-config), how to point a .NET app at it (authority URL, JwtBearer snippet,
note on mapping role claims), how dev/staging/prod differ (env vars only), upgrade procedure (test on
staging first, back up the DB), and Postgres backup/restore notes.

## 10. Working method
1. First state your plan and list assumptions or open questions. Ask before proceeding if anything is
   ambiguous (e.g. hostnames, or which reverse proxy staging/prod will use).
2. Implement step by step, running `docker compose config` to validate before starting services.
3. Bring the stack up, run `scripts/verify.sh`, and fix failures until all checks pass.
4. Summarize what was built, what is intentionally left out, and recommended next steps.

## 11. Out of scope
KYC/verification, SMS OTP, HA/clustering, custom SPIs, custom themes, real product clients, and the
actual .NET/React integration (only document how to integrate).
