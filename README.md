# Central Identity Service (`idp.mydomain.com`)

Centralized Identity and Access Management (IAM) service built with **Keycloak 26 (Quarkus distribution)**, **External PostgreSQL 16+**, and **`keycloak-config-cli`**. 

This service provides centralized authentication (OIDC, SSO) and authorization (RBAC via JWT bearer tokens) across multiple internal and customer-facing products.

---

## 1. Architecture Overview

- **Single Shared Realm (`platform`)**: All products share a single `platform` realm to enable unified Single Sign-On (SSO) and shared user identities. The `master` realm is strictly reserved for super-admin infrastructure tasks.
- **Role-Based Authorization on APIs**: Admin vs. user access is strictly controlled by client roles declared on product API resource servers (`<product>-api`), not by separate realms.
- **Environment Isolation**: Dev, staging, and production are completely separate Keycloak instances. The realm name remains `platform` everywhere. Only hostnames, client secrets, and URIs differ via environment variables.
- **GitOps Declarative Configuration**: All realms, clients, roles, and settings are versioned as code in YAML files under `keycloak/import/platform/` and applied automatically via `keycloak-config-cli`.
- **Stateless Consumer Apps**:
  - Web frontends (React) connect through backend BFFs using Authorization Code flow + PKCE.
  - Backends (.NET APIs) act as resource servers validating stateless signed JWT bearer tokens.
  - Machine-to-machine integrations use Client Credentials grant with dedicated service accounts.

### Client Naming Convention
Every product onboarded follows this strict naming structure:
- `<product>-user-web`: User-facing application (confidential, Auth Code + PKCE, used by the BFF)
- `<product>-admin-web`: Admin application (confidential, Auth Code + PKCE, strict session lifetimes)
- `<product>-api`: Backend API resource server (holds client roles: `user`, `admin`, `api-access`)
- `<product>-apiclient-<name>`: Machine client (confidential, service account, client credentials)

*Phase 1 implements the prototype `test` product.*

---

## 2. Directory Structure

```
├── docker-compose.yml              # Base production stack (start mode)
├── docker-compose.override.yml     # Local development conveniences (start-dev, Mailpit)
├── .env.example                    # Comprehensive environment template
├── .gitignore                      # Git exclusion rules
├── README.md                       # This documentation
├── keycloak/
│   ├── Dockerfile                  # Optional pre-built optimized image
│   ├── themes/                     # Custom themes placeholder
│   └── import/
│       └── platform/
│           ├── realm.yml           # Realm security settings, password policy, SMTP
│           ├── roles.yml           # Client roles on test-api
│           ├── clients.yml         # Phase 1 test product clients
│           └── users.dev.yml       # Seeded test users (DEV ONLY)
└── scripts/
    ├── verify.sh                   # Automated smoke test suite (Section 8 criteria)
    └── apply-config.sh             # Re-applies declarative config to target environment
```

---

## 3. Prerequisites

- **Docker**: Version 20.10+ (Docker Desktop or Engine)
- **Docker Compose**: Version 2.20+
- **Bash**, **curl**, and **jq** (for the test suite and CLI scripts)

---

## 4. First-Run Quickstart (Development)

### 1. Initialize Local Environment
```bash
cp .env.example .env
```
Review `.env` and adjust passwords or port mappings if necessary. For local development, the defaults are pre-configured to bind:
- **Keycloak OIDC & Admin**: `http://localhost:8080`
- **Keycloak Management & Health**: `http://localhost:9000`
- **Mailpit Web UI (Dev Inbox)**: `http://localhost:8025`

### 2. Start the Stack
```bash
docker compose up -d
```
Docker Compose connects to your external PostgreSQL database (`POSTGRES_HOST`) and starts:
1. `identity-keycloak`: Boots Keycloak in `start-dev` mode, connects to external PostgreSQL, and runs database migrations.
2. `identity-mailpit`: Dev SMTP catcher and web interface.
3. `identity-config-cli`: Automatically waits for Keycloak to become healthy, then imports `realm.yml`, `roles.yml`, `clients.yml`, and `users.dev.yml`.

### 3. Verify the Installation
Run the automated smoke test suite:
```bash
./scripts/verify.sh
```
All 6 verification checks should report `[ PASS ]`.

### 4. Access UIs
- **Keycloak Admin Console**: `http://localhost:8080/admin` (User: `admin`, Password: value of `KC_BOOTSTRAP_ADMIN_PASSWORD` in `.env`)
- **Mailpit Web Interface**: `http://localhost:8025`

---

## 5. How to Onboard a New Product

To onboard a new product (e.g. `medix`):

1. **Add client roles** in `keycloak/import/platform/roles.yml`:
   ```yaml
   roles:
     client:
       medix-api:
         - name: user
           description: Standard Medix user
         - name: admin
           description: Medix administrator
         - name: api-access
           description: Machine caller access
   ```

2. **Add clients** in `keycloak/import/platform/clients.yml`:
   ```yaml
   clients:
     # User BFF
     - clientId: medix-user-web
       publicClient: false
       clientAuthenticatorType: client-secret
       secret: ${env:MEDIX_USER_WEB_SECRET}
       standardFlowEnabled: true
       attributes:
         pkce.code.challenge.method: S256
       redirectUris:
         - ${env:MEDIX_USER_WEB_REDIRECT_URI}
       protocolMappers:
         - name: audience-medix-api
           protocolMapper: oidc-audience-mapper
           config:
             included.client.audience: medix-api
             access.token.claim: "true"

     # Admin BFF
     - clientId: medix-admin-web
       publicClient: false
       clientAuthenticatorType: client-secret
       secret: ${env:MEDIX_ADMIN_WEB_SECRET}
       standardFlowEnabled: true
       attributes:
         pkce.code.challenge.method: S256
         client.session.idle.timeout: "900"
         client.session.max.lifespan: "3600"
       redirectUris:
         - ${env:MEDIX_ADMIN_WEB_REDIRECT_URI}
       protocolMappers:
         - name: audience-medix-api
           protocolMapper: oidc-audience-mapper
           config:
             included.client.audience: medix-api
             access.token.claim: "true"

     # API Resource Server
     - clientId: medix-api
       bearerOnly: true

     # Machine Client (if needed)
     - clientId: medix-apiclient-reporting
       publicClient: false
       clientAuthenticatorType: client-secret
       secret: ${env:MEDIX_APICLIENT_REPORTING_SECRET}
       serviceAccountsEnabled: true
       standardFlowEnabled: false
       protocolMappers:
         - name: audience-medix-api
           protocolMapper: oidc-audience-mapper
           config:
             included.client.audience: medix-api
             access.token.claim: "true"
   ```

3. **Define secrets and URIs in `.env` and `.env.example`**:
   ```bash
   MEDIX_USER_WEB_SECRET=...
   MEDIX_ADMIN_WEB_SECRET=...
   MEDIX_APICLIENT_REPORTING_SECRET=...
   ```

4. **Apply configuration**:
   ```bash
   ./scripts/apply-config.sh
   ```
   No restarts or downtime required.

---

## 6. How to Point a .NET Backend at Keycloak

### Authority & Token Validation
In `.NET 8 / 9` (`Program.cs`):

```csharp
using System.Security.Claims;
using System.Text.Json;
using Microsoft.AspNetCore.Authentication.JwtBearer;
using Microsoft.IdentityModel.Tokens;

var builder = WebApplication.CreateBuilder(args);

builder.Services.AddAuthentication(JwtBearerDefaults.AuthenticationScheme)
    .AddJwtBearer(options =>
    {
        // Points to Keycloak platform realm
        options.Authority = builder.Configuration["Keycloak:Authority"]; // e.g. "http://localhost:8080/realms/platform"
        options.Audience = "test-api"; // Matches audience-mapper
        options.RequireHttpsMetadata = !builder.Environment.IsDevelopment();

        options.TokenValidationParameters = new TokenValidationParameters
        {
            ValidateAudience = true,
            ValidAudience = "test-api",
            ValidateIssuer = true,
            ValidateLifetime = true,
            ClockSkew = TimeSpan.FromSeconds(30)
        };

        // Map Keycloak nested client roles into ASP.NET Core ClaimsIdentity
        options.Events = new JwtBearerEvents
        {
            OnTokenValidated = context =>
            {
                var claimsIdentity = (ClaimsIdentity)context.Principal!.Identity!;
                var resourceAccessClaim = claimsIdentity.FindFirst("resource_access");

                if (resourceAccessClaim != null)
                {
                    using var doc = JsonDocument.Parse(resourceAccessClaim.Value);
                    if (doc.RootElement.TryGetProperty("test-api", out var clientElement) &&
                        clientElement.TryGetProperty("roles", out var rolesElement))
                    {
                        foreach (var role in rolesElement.EnumerateArray())
                        {
                            claimsIdentity.AddClaim(new Claim(ClaimTypes.Role, role.GetString()!));
                        }
                    }
                }
                return Task.CompletedTask;
            }
        };
    });

builder.Services.AddAuthorization(options =>
{
    options.AddPolicy("RequireAdmin", policy => policy.RequireRole("admin"));
    options.AddPolicy("RequireApiAccess", policy => policy.RequireRole("api-access"));
});

var app = builder.Build();
app.UseAuthentication();
app.UseAuthorization();
app.Run();
```

---

## 7. Environment Differentiation (Dev vs Staging vs Prod)

The code and realm name (`platform`) are 100% identical across all tiers. Differentiation is strictly governed by environment variables and Docker Compose configurations:

| Parameter | Development | Staging | Production |
|---|---|---|---|
| **Compose files** | `docker-compose.yml` + `docker-compose.override.yml` | `docker-compose.yml` only | `docker-compose.yml` only |
| **Keycloak Command** | `start-dev` | `start` | `start` |
| **`KC_HOSTNAME`** | `http://localhost:8080` | `https://idp-staging.mydomain.com` | `https://idp.mydomain.com` |
| **`KC_HOSTNAME_STRICT`** | `false` | `true` | `true` |
| **`KC_PROXY_HEADERS`** | `xforwarded` | `xforwarded` | `xforwarded` |
| **TLS Termination** | None (HTTP) | Reverse Proxy / AWS ALB | Reverse Proxy / Cloudflare |
| **SMTP Delivery** | Mailpit (`mailpit:1025`) | Amazon SES / SMTP relay | Amazon SES / SendGrid |
| **Dev Seed Users** | Loaded from `users.dev.yml` | **NEVER LOADED** | **NEVER LOADED** |

---

## 8. Security Hardening

1. **Protect the Admin Console**:
   In staging and production, the admin console must not be accessible to the public internet. At your reverse proxy (Nginx, Traefik, or ALB), restrict `/admin/*` and `/realms/master/*` to private VPN / corporate CIDR ranges, or host Keycloak behind a dedicated admin hostname.
2. **Strict Redirect URIs**:
   Never use wildcard `*` redirect URIs. All redirect URIs in `clients.yml` reference precise environment variables.
3. **No Direct Access Grants**:
   Resource Owner Password Credentials Grant is globally disabled on all application and machine clients.
4. **Mandatory MFA (TOTP / Passkeys) for Admins**:
   In Keycloak Admin Console, go to **Authentication > Required Actions** and ensure "Configure OTP" / "WebAuthn Register" is enabled. Administrators can be assigned required actions or configured via Keycloak's Conditional OTP Flow.

---

## 9. Backup, Restore, and Upgrades

### PostgreSQL Backup
```bash
# Dump the platform database from external PostgreSQL host
pg_dump -h "${POSTGRES_HOST}" -p "${POSTGRES_PORT:-5432}" -U "${POSTGRES_USER}" -d "${POSTGRES_DB}" -F c -b -v -f ./backup-$(date +%Y%m%d%H%M%S).dump
```

### PostgreSQL Restore
```bash
# Restore from dump to target PostgreSQL host
pg_restore -h "${POSTGRES_HOST}" -p "${POSTGRES_PORT:-5432}" -U "${POSTGRES_USER}" -d "${POSTGRES_DB}" -v --clean ./backup.dump
```

### Keycloak Upgrade Procedure
1. Test upgrades in Staging before applying to Production.
2. Perform a full database backup (`pg_dump`) prior to upgrading.
3. Review the [Keycloak Migration & Upgrading Guide](https://www.keycloak.org/docs/latest/upgrading/index.html).
4. Update `KC_IMAGE_TAG` in `.env` to the new target version.
5. Rebuild/pull images:
   ```bash
   docker compose pull keycloak
   docker compose up -d keycloak
   ```
   Keycloak Quarkus automatically performs schema migrations on startup.
6. Verify service health and functionality with `./scripts/verify.sh`.
