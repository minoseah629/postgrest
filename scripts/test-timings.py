#!/usr/bin/env python3
"""Wall-clock execution time per test level, written to coverage/timings.json.

Runs each suite's nix test command (so run it inside `nix-shell`), times it and reads the
test count from its output (hspec: "N examples", pytest: "N passed"). Levels and suites
come from policy/coverage/levels.json; commands from SUITES below.

Usage (about 6 minutes):
    nix-shell --run scripts/test-timings.py
    scripts/test-timings.py --only unit,component      # just some levels
"seconds" is the execution time the test runner reports (hspec, pytest), so fixed startup
cost (cabal, a temporary Postgres) does not distort the per-test mean; "wall_seconds" is the
whole command, for reference. If a runner prints no time, wall time is used.
"""
import json
import os
import re
import subprocess
import sys
import time

SUITES = {
    "unit": ["postgrest-test-unit"],
    "hasql": ["postgrest-test-hasql"],
    "spec": ["postgrest-test-spec"],
    "observability": ["postgrest-test-observability"],
    "io": ["postgrest-test-io"],
}
# which suites belong to which level (command names above)
LEVELS = {
    "unit": ["unit"],
    "component": ["hasql"],
    "api": ["spec", "observability"],
    "e2e": ["io"],
}
ORDER = ["unit", "component", "api", "e2e"]

def count_tests(output):
    """Sum of 'N examples' (hspec, one per suite run) or 'N passed' (pytest)."""
    ansi = re.sub(r"\x1b\[[0-9;]*m", "", output)
    n = sum(int(m) for m in re.findall(r"(\d+) examples?,", ansi))
    if n == 0:
        n = sum(int(m) for m in re.findall(r"(\d+) passed", ansi))
    return n

def reported_seconds(output):
    """Execution time the test runner itself reports, without process/DB startup:
    hspec 'Finished in 22.6 seconds', pytest '... passed in 227.55s'. None if not found."""
    ansi = re.sub(r"\x1b\[[0-9;]*m", "", output)
    hs = [float(x) for x in re.findall(r"Finished in ([0-9.]+) seconds", ansi)]
    py = [float(x) for x in re.findall(r"(?:passed|failed|skipped|error)[^\n]*? in ([0-9.]+)s", ansi)]
    found = hs + py
    return sum(found) if found else None

def run(cmd):
    start = time.monotonic()
    p = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    return time.monotonic() - start, p.returncode, p.stdout

only = None
if "--only" in sys.argv:
    only = set(sys.argv[sys.argv.index("--only") + 1].split(","))

out_path = os.path.join("coverage", "timings.json")
os.makedirs("coverage", exist_ok=True)
levels = {}
for level in ORDER:
    if only and level not in only:
        continue
    suites, total_s, total_n, ok = {}, 0.0, 0, True
    for suite in LEVELS[level]:
        sys.stderr.write(f"running {suite} ...\n")
        secs, rc, output = run(SUITES[suite])
        n = count_tests(output)
        exec_s = reported_seconds(output)
        exec_s = secs if exec_s is None else exec_s
        suites[suite] = {"seconds": round(exec_s, 2), "wall_seconds": round(secs, 2),
                         "tests": n, "exit_code": rc}
        total_s += exec_s
        total_n += n
        ok = ok and rc == 0
    levels[level] = {"seconds": round(total_s, 2), "tests": total_n,
                     "ms_per_test": round(1000 * total_s / total_n, 2) if total_n else None,
                     "passed": ok, "suites": suites}

with open(out_path, "w", encoding="utf-8") as f:
    json.dump({"order": [l for l in ORDER if l in levels], "levels": levels}, f, indent=2)
for name, lv in levels.items():
    print(f"{name:10s} {lv['seconds']:8.1f}s  {lv['tests']:5d} tests  "
          f"{lv['ms_per_test'] if lv['ms_per_test'] is not None else '-':>9} ms/test"
          f"{'' if lv['passed'] else '  FAILED'}")
