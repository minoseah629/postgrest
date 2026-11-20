#!/usr/bin/env python3
"""Line coverage per test level, written to coverage/levels.json.

Levels and their suites come from policy/coverage/levels.json. Each suite's coverage is
coverage/suites/<suite>.json (written by postgrest-coverage). All levels are measured
over the same set of lines, the ones in the merged coverage/codecov.json, so a level that
runs only part of the code is not flattered by a smaller denominator.

Usage: scripts/coverage-levels.py [coverage_dir] [levels_config] [out]
"""
import json
import os
import sys

cdir = sys.argv[1] if len(sys.argv) > 1 else "coverage"
cfg_path = sys.argv[2] if len(sys.argv) > 2 else "policy/coverage/levels.json"
out = sys.argv[3] if len(sys.argv) > 3 else os.path.join(cdir, "levels.json")

def hit(v):
    if isinstance(v, str):
        return int(v.split("/")[0]) > 0
    return v > 0

def load(path):
    with open(path, encoding="utf-8") as f:
        return json.load(f)["coverage"]

cfg = load_cfg = json.load(open(cfg_path, encoding="utf-8"))
universe = {(p, l) for p, lines in load(os.path.join(cdir, "codecov.json")).items() for l in lines}

levels = {}
for name in cfg["order"]:
    suites = cfg["levels"][name]["suites"]
    covered, found = set(), []
    for suite in suites:
        path = os.path.join(cdir, "suites", suite + ".json")
        if not os.path.exists(path):
            continue
        found.append(suite)
        for p, lines in load(path).items():
            covered |= {(p, l) for l, v in lines.items() if hit(v) and (p, l) in universe}
    measured = bool(found)
    levels[name] = {"suites": suites, "measured_suites": found, "measured": measured,
                    "lines": len(universe), "covered": len(covered),
                    "percent": round(100.0 * len(covered) / len(universe), 2) if measured else None}

with open(out, "w", encoding="utf-8") as f:
    json.dump({"order": cfg["order"], "levels": levels}, f, indent=2)
for name in cfg["order"]:
    lv = levels[name]
    shown = f"{lv['percent']}%" if lv["measured"] else "not measured"
    print(f"{name:10s} {shown:>13s}  {','.join(lv['measured_suites']) or '-'}")
