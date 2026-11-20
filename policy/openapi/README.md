# OpenAPI policy checks

Policy-as-code checks for the OpenAPI (Swagger 2.0) document PostgREST generates at `GET /`.

- `spectral/`: Stoplight OWASP API Security Spectral ruleset (plus standard OpenAPI hygiene rules).
- `owasp.rego`: Rego port of the OWASP rules, plus checks Spectral does not cover here (no auth scheme defined, missing rate-limit headers).
- `owasp_test.rego`: unit tests (`opa test policy/openapi`).

## Run locally

```bash
curl -H "Accept: application/openapi+json" http://localhost:3000/ -o spec.json
scripts/lint-openapi.sh spec.json     # or pass a URL; default http://localhost:3000/
```

Requires `opa` and `spectral` (or `npx`). Spectral fails on errors; OPA fails when `data.owasp.errors` is non-empty.

## Notes

- PostgREST generates the spec from the database, so many findings (HTTP-only schemes, no `securityDefinitions`, missing 401/429/500 responses) are PostgREST defaults. Fix them in a gateway or by post-processing the spec.
- The Rego rules check `#/definitions` and operations. They do not lint the shared `#/parameters` entries, which Spectral does.

## What can be fixed where

`dev/docker-compose.yml` + `dev/seed.sql` are a hardened example stack:

| Finding | Fix | Where |
|---|---|---|
| HTTP-only `schemes` | `openapi-server-proxy-uri=https://...` | PostgREST config (TLS terminates at a proxy) |
| No auth scheme / unprotected writes | `openapi-security-active=true` | PostgREST config |
| Unbounded strings (`maxLength`) | use `varchar(n)` instead of `text` | database schema |
| String without format/pattern | `enum` types, `format` via domain types | database schema |
| Missing 429 + rate-limit headers | nginx rate limiting (`dev/nginx.conf`), documented by `patch-openapi.py` | gateway |
| Missing 400/401/500 responses | PostgREST already returns them; the patch documents them with the `error` schema | spec patch |
| Array `maxItems` | `PGRST_DB_MAX_ROWS=1000`, documented as `maxItems` | PostgREST config + spec patch |
| Unpatterned filter/header parameters | patterns for PostgREST's own grammar (`eq.value`, `select`, `order`, ...) | spec patch |
| Contact/license/tags/operationIds/descriptions | filled in by the patch | spec patch |

### Enforced vs. only declared

The patch writes the contract into the spec; it does not make it true by itself.

- **Enforced:** rate limit and 429/Retry-After (nginx), max rows (PostgREST), URI/header size (nginx, 8k), body size (nginx, 1m), JWT on writes (PostgREST + DB grants), `maxLength` on `varchar` columns (Postgres).
- **Declared only:** the per-parameter `pattern`/`maxLength` values. PostgREST and Postgres reject malformed input, but not with these exact limits.
- **Not provided:** TLS. `openapi-server-proxy-uri=https://...` only changes what the spec advertises. Terminate TLS at a real proxy.
- **Placeholders:** the contact email defaults to a GitHub no-reply address; pass `--contact-*` to `patch-openapi.py` to change it.

### Spectral ruleset changes

The upstream OWASP ruleset targets OpenAPI 3. For Swagger 2.0 (what PostgREST emits) `.spectral.json` was adjusted: the 401/429/500 rules require `.content`, which does not exist in OAS2, so they are scoped to `oas3` and have `-oas2` twins that check the response code only; the rate-limit rule has an `-oas2` twin; `api-servers` is `oas3` only.

Run it:

```bash
docker rm -f pgrst pgdb 2>/dev/null; docker network rm pgrst 2>/dev/null   # clear the earlier manual containers
docker compose -f policy/openapi/dev/docker-compose.yml up -d
scripts/lint-openapi.sh > lint-results-hardened.txt 2>&1      # patched spec
scripts/lint-openapi.sh --raw > lint-results-raw.txt 2>&1      # as generated
```
