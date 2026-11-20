package timing_test

import rego.v1

import data.timing

lv(s, n) := {"seconds": s, "tests": n, "ms_per_test": (1000 * s) / n, "passed": true}

ok := {"levels": {"unit": lv(2, 40), "component": lv(10, 20), "api": lv(60, 1000), "e2e": lv(230, 250)}}

slow_unit := {"levels": {"unit": lv(30, 40), "component": lv(10, 20), "api": lv(60, 1000), "e2e": lv(230, 250)}}

slow_per_test := {"levels": {"unit": lv(5, 2), "component": lv(10, 20), "api": lv(60, 1000), "e2e": lv(230, 250)}}

test_fast_unit_is_clean if {
	count(timing.errors) == 0 with input as ok with data.thresholds as {}
}

test_slow_unit_flagged_total if {
	some v in timing.errors with input as slow_unit with data.thresholds as {}
	v.rule == "fastest-level-slower-total"
}

test_slow_per_test_flagged if {
	some v in timing.errors with input as slow_per_test with data.thresholds as {}
	v.rule == "fastest-level-slower-per-test"
}

test_tolerance_allows_small_overrun if {
	count(timing.errors) == 0 with input as {"levels": {"unit": lv(11, 40), "component": lv(10, 20)}} with data.thresholds as {"time_tolerance_s": 2}
}

test_failed_level_reported if {
	some v in timing.errors with input as {"levels": {"unit": lv(1, 40), "api": {"seconds": 5, "tests": 1, "ms_per_test": 5000, "passed": false}}} with data.thresholds as {}
	v.rule == "level-tests-failed"
}
