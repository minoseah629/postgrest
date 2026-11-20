#!/usr/bin/env bash
# Lint PostgREST's generated OpenAPI (Swagger 2.0) spec with Spectral (OWASP ruleset) and OPA (Rego).
# Usage: scripts/lint-openapi.sh [--raw] [SPEC_FILE_OR_URL]   (default: http://localhost:3000/)
# By default the spec is first patched (scripts/patch-openapi.py) with the behavior the
# gateway adds; --raw lints PostgREST's spec exactly as generated.
# Requires: curl, opa, and either spectral or npx on PATH.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RAW=0
[[ "${1:-}" == "--raw" ]] && { RAW=1; shift; }
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

if [[ "$RAW" == "0" ]]; then
  python3 "$ROOT/scripts/patch-openapi.py" "$SPEC" "$SPEC.patched" && mv "$SPEC.patched" "$SPEC"
fi

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
