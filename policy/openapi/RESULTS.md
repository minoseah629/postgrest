# OpenAPI policy results

PostgREST's generated OpenAPI (Swagger 2.0) spec, linted with Spectral (OWASP ruleset, `policy/openapi/spectral`) and Open Policy Agent (Rego, `policy/openapi/owasp.rego`).

| | Stock PostgREST | This branch |
|---|--:|--:|
| Spectral problems | 92 (30 errors, 57 warnings, 5 infos) | **0** |
| OPA violations | 29 (14 errors) | **0** |

"This branch" is the spec produced by PostgREST built from this branch, linted unpatched (`scripts/lint-openapi.sh --raw`). CI runs exactly that on every push: `.github/workflows/openapi-policy.yaml`.

## How to reproduce

```bash
# Locally, with a built binary and a temporary Postgres
PGUSER=authenticator PGRST_DB_SCHEMAS=api nix-shell --run \
  "postgrest-with-pg-17 --fixtures policy/openapi/dev/seed-with-pg.sql scripts/lint-built.sh"
```

Required settings for the clean result: `openapi-security-active`, `openapi-server-proxy-uri` (https), `db-max-rows`, `openapi-rate-limit`, `openapi-contact-email`. `openapi-rate-limit` only documents the limit; the gateway enforces it (`policy/openapi/dev/nginx.conf`).

## Spectral: 92 findings on the stock spec

| Rule | Severity | Stock spec | Now | Addressed by | Where |
|---|---|--:|--:|---|---|
| `owasp:api4:2019-string-limit` | error | 13 | **0** | `maxLength` on string params/properties; uuid bounded to 36 | PostgREST source |
| `owasp:api4:2019-string-restricted` | error | 11 | **0** | `pattern` on params, `Range-Unit` enum | PostgREST source |
| `owasp:api3:2019-define-error-responses-401` | warning | 10 | **0** | 401 response with `PostgrestError` schema | PostgREST source |
| `owasp:api3:2019-define-error-responses-500` | warning | 10 | **0** | 500 response with `PostgrestError` schema | PostgREST source |
| `owasp:api4:2019-rate-limit-responses-429` | warning | 10 | **0** | 429 response when `openapi-rate-limit` is set | PostgREST source + config |
| `operation-description` | warning | 5 | **0** | description fallback on every operation | PostgREST source |
| `operation-operationId` | warning | 5 | **0** | unique `operationId` per operation | PostgREST source |
| `owasp:api3:2019-define-error-validation` | warning | 5 | **0** | 400 response documented | PostgREST source |
| `operation-tag-defined` | warning | 5 | **0** | top-level tag definitions | PostgREST source |
| `owasp:api2:2019-protection-global-unsafe` | error | 3 | **0** | `openapi-security-active = true` | PostgREST config |
| `parameter-description` | warning | 3 | **0** | description fallback on row-filter params | PostgREST source |
| `owasp:api2:2019-protection-global-safe` | info | 2 | **0** | `openapi-security-active = true` | PostgREST config |
| `owasp:api2:2019-protection-global-unsafe-strict` | info | 3 | **0** | `openapi-security-active = true` | PostgREST config |
| `openapi-tags` | warning | 1 | **0** | top-level tag definitions | PostgREST source |
| `info-contact` | warning | 1 | **0** | `info.contact` (email from `openapi-contact-email`) | PostgREST source + config |
| `info-license` | warning | 1 | **0** | `info.license` (MIT) | PostgREST source |
| `api-servers` | warning | 1 | **0** | rule scoped to OpenAPI 3 only (Swagger 2.0 has no `servers`) | ruleset |
| `oas2-always-use-https` | error | 1 | **0** | `openapi-server-proxy-uri = https://...` | PostgREST config |
| `owasp:api4:2019-array-limit` | error | 1 | **0** | `maxItems` from `db-max-rows` | PostgREST source + config |
| `oas2-valid-schema-example` | error | 1 | **0** | omit uuid defaults that are SQL function calls | PostgREST source |

## OPA: 29 violations on the stock spec

| Rule | Severity | Stock spec | Now | Addressed by | Where |
|---|---|--:|--:|---|---|
| `api4-rate-limit-headers` | error | 6 | **0** | `X-RateLimit-Limit` / `Retry-After` headers | PostgREST source + config |
| `api3-define-error-responses-401` | warn | 5 | **0** | 401 response | PostgREST source |
| `api3-define-error-responses-500` | warn | 5 | **0** | 500 response | PostgREST source |
| `api4-rate-limit-responses-429` | warn | 5 | **0** | 429 response | PostgREST source + config |
| `api2-protection-global-unsafe` | error | 3 | **0** | `openapi-security-active = true` | PostgREST config |
| `api4-string-limit` | error | 2 | **0** | `maxLength` | PostgREST source |
| `api4-array-limit` | error | 1 | **0** | `maxItems` from `db-max-rows` | PostgREST source + config |
| `api2-always-https` | error | 1 | **0** | `openapi-server-proxy-uri` | PostgREST config |
| `api2-no-security-definitions` | error | 1 | **0** | `openapi-security-active = true` | PostgREST config |

Stock counts come from the first lint run on an unmodified PostgREST (`lint-results.txt`). The two linters overlap: the same missing 401/500/429 responses, rate-limit headers, string and array limits, HTTPS and security definitions are reported by both.
