# Test coverage policy

PostgREST already measures coverage: `postgrest-coverage` runs the spec, io, replica, observability and hasql tests with hpc and writes `coverage/codecov.json` (line coverage per file). This policy turns that into a gate.

```bash
nix-shell --run postgrest-coverage          # ~10-15 min, writes coverage/codecov.json
python3 scripts/coverage-summary.py         # -> coverage/summary.json (overall + per file)
scripts/lint-coverage.sh                    # OPA policy, exit 1 on errors
```

Rules (`coverage.rego`, limits in `thresholds.json`):

| Rule | Fails when |
|---|---|
| `total-line-coverage` | overall line coverage < `total_min` |
| `file-line-coverage` | any file < `file_min` |
| `required-file-coverage` | a file in `required_files` (or missing from the report) is below its own minimum |

Set the thresholds from a measured baseline (a few points below it, then ratchet up), not from a guess.

## Test levels

The suites fall into levels (`levels.json`): **unit** (`test/unit`, compiled pure-function tests; the doctests run in GHCi and cannot be measured by hpc), **component** (`hasql-pool`, `hasql-statements`), **api** (`spec`, `observability`, in-process against Postgres) and **e2e** (`io`, `big_schema`, `replica`, the real binary).

`postgrest-coverage` now keeps per-suite coverage in `coverage/suites/`. `scripts/coverage-levels.py` turns it into `coverage/levels.json`: line coverage per level, all measured over the same lines (those in the merged report). `levels.rego` then checks the ordering:

| Setting (`thresholds.json`) | Meaning |
|---|---|
| `level_direction: "ascending"` | a higher level must cover at least as much as the level below it (unit <= component <= api <= e2e); a dip is `inverted-level-coverage`. `"descending"` is the classic pyramid. |
| `level_tolerance` | allowed shortfall in percentage points |
| `level_min` | optional per-level minimum, e.g. `{"api": 60}` |

A level with no data is reported as a notice, not an error.

## Baseline (2026-11-20)

Measured with `postgrest-coverage` on the branch after rebasing onto upstream `main`:

| Measure | Value | Threshold |
|---|--:|--:|
| Overall line coverage | 92.13% | `total_min` 90 |
| `Response/OpenAPI.hs` | 99.39% | 97 |
| `Config.hs` | 98.48% | 95 |
| unit (`test/unit`) | 1.33% | `level_min` 1 |
| component (hasql suites) | 8.89% | none |
| api (`spec`, `observability`) | 71.24% | `level_min` 68 |
| e2e (`io`, `big_schema`, `replica`) | 74.40% | `level_min` 71 |

Levels ascend (unit < component < api < e2e), so `level_direction: "ascending"` passes with no tolerance. The e2e margin over api is 3.2 points; that is the first check to trip.

## Test execution time

`scripts/test-timings.py` (run inside `nix-shell`, about 6 minutes) runs each level's suites, reads the execution time and test count each runner reports and writes `coverage/timings.json`. `timing.rego` enforces that the fastest level (`time_fastest_level`, default `unit`) is not slower than any other level:

| Rule | Fails when |
|---|---|
| `fastest-level-slower-total` | unit's total execution time > another level's (plus `time_tolerance_s`) |
| `fastest-level-slower-per-test` | unit's mean ms per test > another level's mean (times `time_per_test_ratio`) |
| `level-tests-failed` | a level's tests failed, so its time is not comparable |

Times are the runner-reported execution times, so fixed startup cost (cabal, a temporary Postgres) does not distort the per-test mean; the whole-command wall time is kept in the JSON for reference.
