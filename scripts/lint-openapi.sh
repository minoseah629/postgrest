#!/usr/bin/env bash
# Lint PostgREST's generated OpenAPI (Swagger 2.0) spec with Spectral (OWASP ruleset) and OPA (Rego).
# Usage: scripts/lint-openapi.sh [SPEC_FILE_OR_URL]   (default: http://localhost:3000/)
# Requires: curl, opa, and either spectral or npx on PATH.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="${1:-http://localhost:3000/}"
SPEC="$(mktemp --suffix=.json)"
trap 'rm -f "$SPEC"' EXIT

if [[ "$SRC" =~ ^https?:// ]]; then
  curl -fsS -H "Accept: application/openapi+json" "$SRC" -o "$SPEC"
else
  cp "$SRC" "$SPEC"
fi

SPECTRAL=(spectral)
command -v spectral >/dev/null || SPECTRAL=(npx --yes @stoplight/spectral-cli)

status=0

echo "== Spectral (OWASP ruleset) =="
"${SPECTRAL[@]}" lint "$SPEC" -r "$ROOT/policy/openapi/spectral/.spectral.json" --fail-severity=error || status=1

echo
echo "== OPA (Rego) =="
opa test "$ROOT/policy/openapi" || status=1
opa eval -I -d "$ROOT/policy/openapi/owasp.rego" -f pretty 'data.owasp.violation' < "$SPEC"
count=$(opa eval -I -d "$ROOT/policy/openapi/owasp.rego" -f raw 'count(data.owasp.errors)' < "$SPEC")
echo "OPA errors: $count"
[[ "$count" == "0" ]] || status=1

exit $status
