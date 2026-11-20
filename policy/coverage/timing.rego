package timing

import rego.v1

# input: coverage/timings.json (scripts/test-timings.py)
# data.thresholds:
#   time_fastest_level   level that must not be slower than any other (default "unit")
#   time_tolerance_s     allowed extra seconds on total time (default 0)
#   time_per_test_ratio  allowed ratio of mean time per test (default 1: not slower)

fastest := object.get(data.thresholds, "time_fastest_level", "unit")

tolerance := object.get(data.thresholds, "time_tolerance_s", 0)

ratio := object.get(data.thresholds, "time_per_test_ratio", 1)

others contains name if {
	some name, lv in input.levels
	name != fastest
	lv.passed
}

# A failing suite has no meaningful time: report it, do not compare.
violation contains {"rule": "level-tests-failed", "sev": "error", "at": name} if {
	some name, lv in input.levels
	not lv.passed
}

violation contains v if {
	input.levels[fastest].passed
	some name in others
	input.levels[fastest].seconds > input.levels[name].seconds + tolerance
	v := {"rule": "fastest-level-slower-total", "sev": "error", "at": sprintf("%s > %s", [fastest, name]),
		"actual": input.levels[fastest].seconds, "required": input.levels[name].seconds}
}

violation contains v if {
	input.levels[fastest].passed
	input.levels[fastest].ms_per_test != null
	some name in others
	input.levels[name].ms_per_test != null
	input.levels[fastest].ms_per_test > input.levels[name].ms_per_test * ratio
	v := {"rule": "fastest-level-slower-per-test", "sev": "error", "at": sprintf("%s > %s", [fastest, name]),
		"actual": input.levels[fastest].ms_per_test, "required": input.levels[name].ms_per_test * ratio}
}

errors contains v if {
	some v in violation
	v.sev == "error"
}
