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
