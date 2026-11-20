package levels_test

import rego.v1

import data.levels

lv(p) := {"measured": true, "percent": p}

ok := {"order": ["unit", "component", "api", "e2e"], "levels": {
	"unit": {"measured": false, "percent": null},
	"component": lv(20), "api": lv(60), "e2e": lv(70),
}}

bad := {"order": ["unit", "component", "api", "e2e"], "levels": {
	"unit": {"measured": false, "percent": null},
	"component": lv(20), "api": lv(60), "e2e": lv(50),
}}

test_ascending_ok if {
	count(levels.errors) == 0 with input as ok with data.thresholds as {"level_direction": "ascending"}
}

test_ascending_inverted_flagged if {
	some v in levels.errors with input as bad with data.thresholds as {"level_direction": "ascending"}
	v.at == "e2e < api"
}

test_tolerance_allows_small_dip if {
	count(levels.errors) == 0 with input as bad with data.thresholds as {"level_direction": "ascending", "level_tolerance": 10}
}

test_descending_flags_growth if {
	some v in levels.errors with input as ok with data.thresholds as {"level_direction": "descending"}
	v.rule == "inverted-level-coverage"
}

test_unmeasured_level_is_notice_not_error if {
	some n in levels.notice with input as ok with data.thresholds as {}
	n.at == "unit"
}
