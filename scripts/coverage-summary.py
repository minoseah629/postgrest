#!/usr/bin/env python3
"""Summarize hpc-codecov JSON (coverage/codecov.json, written by postgrest-coverage)
into coverage/summary.json: line coverage overall and per source file.

Usage: scripts/coverage-summary.py [codecov.json] [summary.json]
A line counts as covered when it was hit at least once; a partially covered line
("1/2", a branch only half taken) counts as covered but is also tallied as partial.
"""
import json
import sys

src = sys.argv[1] if len(sys.argv) > 1 else "coverage/codecov.json"
dst = sys.argv[2] if len(sys.argv) > 2 else "coverage/summary.json"

with open(src, encoding="utf-8") as f:
    cov = json.load(f)["coverage"]

def pct(covered, lines):
    return round(100.0 * covered / lines, 2) if lines else 100.0

files = {}
for path, lines in sorted(cov.items()):
    covered = partial = 0
    for hits in lines.values():
        if isinstance(hits, str):  # "k/n": k of n branches taken
            k, n = (int(x) for x in hits.split("/"))
            covered += k > 0
            partial += 0 < k < n
        else:
            covered += hits > 0
    files[path] = {"lines": len(lines), "covered": covered, "partial": partial,
                   "percent": pct(covered, len(lines))}

total_lines = sum(v["lines"] for v in files.values())
total_cov = sum(v["covered"] for v in files.values())
summary = {"total": {"lines": total_lines, "covered": total_cov,
                     "percent": pct(total_cov, total_lines)},
           "files": files}
with open(dst, "w", encoding="utf-8") as f:
    json.dump(summary, f, indent=2)

print(f"Line coverage: {summary['total']['percent']}% ({total_cov}/{total_lines}) -> {dst}")
worst = sorted(files.items(), key=lambda kv: kv[1]["percent"])[:5]
for p, v in worst:
    print(f"  lowest: {v['percent']:6.2f}%  {p}")
