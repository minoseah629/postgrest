#!/usr/bin/env bash
# Evaluate the coverage policy against coverage/summary.json.
# Usage: scripts/lint-coverage.sh [summary.json [levels.json]]   (run `postgrest-coverage` first, then
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

# Test levels: needs coverage/levels.json from scripts/coverage-levels.py
LEVELS="${2:-$ROOT/coverage/levels.json}"
m=0
if [[ -f "$LEVELS" ]]; then
  echo "== Test level policy =="
  opa eval -f pretty -d "$D/levels.rego" -d "$D/thresholds.json" -i "$LEVELS" '[data.levels.violation, data.levels.notice]'
  m=$(opa eval -f raw -d "$D/levels.rego" -d "$D/thresholds.json" -i "$LEVELS" 'count(data.levels.errors)')
  echo "Level errors: $m"
fi
[[ "$n" == "0" && "$m" == "0" ]]
