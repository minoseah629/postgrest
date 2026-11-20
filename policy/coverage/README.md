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

The suites fall into levels (`levels.json`): **unit** (doctests, not measurable by hpc), **component** (`hasql-pool`, `hasql-statements`), **api** (`spec`, `observability`, in-process against Postgres) and **e2e** (`io`, `big_schema`, `replica`, the real binary).

`postgrest-coverage` now keeps per-suite coverage in `coverage/suites/`. `scripts/coverage-levels.py` turns it into `coverage/levels.json`: line coverage per level, all measured over the same lines (those in the merged report). `levels.rego` then checks the ordering:

| Setting (`thresholds.json`) | Meaning |
|---|---|
| `level_direction: "ascending"` | a higher level must cover at least as much as the level below it (unit <= component <= api <= e2e); a dip is `inverted-level-coverage`. `"descending"` is the classic pyramid. |
| `level_tolerance` | allowed shortfall in percentage points |
| `level_min` | optional per-level minimum, e.g. `{"api": 60}` |

A level with no data is reported as a notice, not an error.
