#!/usr/bin/env bash
# Lint the OpenAPI spec of the PostgREST you just built, against a throwaway Postgres.
# Run from the repo root on a machine with Nix:
#
#   PGUSER=authenticator PGRST_DB_SCHEMAS=api nix-shell --run \
#     "postgrest-with-pg-17 --fixtures policy/openapi/dev/seed-with-pg.sql scripts/lint-built.sh"
#
# Extra args are passed to scripts/lint-openapi.sh (default: --raw, i.e. only what the code emits).
set -euo pipefail
cd "$(dirname "$0")/.."

# opa: download a static binary if it is not installed
if ! command -v opa >/dev/null; then
  case "$(uname -m)" in aarch64|arm64) arch=arm64 ;; *) arch=amd64 ;; esac
  mkdir -p "$HOME/.local/bin"
  curl -fsSL -o "$HOME/.local/bin/opa" "https://github.com/open-policy-agent/opa/releases/latest/download/opa_linux_${arch}_static"
  chmod +x "$HOME/.local/bin/opa"
  export PATH="$HOME/.local/bin:$PATH"
fi

BIN="$(cabal list-bin exe:postgrest)"
export PGRST_DB_ANON_ROLE=anon
export PGRST_JWT_SECRET="reallyreallyreallyreallyverysafe123"
export PGRST_OPENAPI_SERVER_PROXY_URI=https://localhost
export PGRST_OPENAPI_SECURITY_ACTIVE=true
export PGRST_DB_MAX_ROWS=1000
export PGRST_SERVER_PORT=3000

# the dev build is coverage-instrumented; a .tix file from an earlier build makes it exit with "Hpc failure"
rm -f postgrest.tix

"$BIN" >/tmp/postgrest-lint.log 2>&1 &
PID=$!
trap 'kill $PID 2>/dev/null || true' EXIT

for _ in $(seq 1 30); do
  curl -fsS -o /dev/null http://localhost:3000/ 2>/dev/null && break
  sleep 1
done
curl -fsS -o /dev/null http://localhost:3000/ || { echo "PostgREST did not start; log:"; cat /tmp/postgrest-lint.log; exit 2; }

# keep the raw spec too, so it can be linted elsewhere (e.g. with Spectral)
curl -fsS -H "Accept: application/openapi+json" http://localhost:3000/ -o postgrest-openapi-code.json

scripts/lint-openapi.sh "${@:---raw}" http://localhost:3000/ 2>&1 | tee lint-results-code.txt
exit "${PIPESTATUS[0]}"
