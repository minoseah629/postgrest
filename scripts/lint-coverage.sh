#!/usr/bin/env bash
# Evaluate the coverage policy against coverage/summary.json.
# Usage: scripts/lint-coverage.sh [summary.json]   (run `postgrest-coverage` first, then
# scripts/coverage-summary.py). Exit 1 if any error-level violation.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SUMMARY="${1:-$ROOT/coverage/summary.json}"
D="$ROOT/policy/coverage"
opa test "$D" -v 2>&1 | tail -3
echo "== Coverage policy =="
opa eval -f pretty -d "$D/coverage.rego" -d "$D/thresholds.json" -i "$SUMMARY" 'data.coverage.violation'
n=$(opa eval -f raw -d "$D/coverage.rego" -d "$D/thresholds.json" -i "$SUMMARY" 'count(data.coverage.errors)')
echo "Coverage errors: $n"
[[ "$n" == "0" ]]
