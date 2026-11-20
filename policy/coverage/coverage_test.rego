package coverage_test

import rego.v1

import data.coverage

th := {"total_min": 80, "file_min": 50, "required_files": {"a.hs": 90}}

good := {"total": {"percent": 85}, "files": {"a.hs": {"percent": 95}, "b.hs": {"percent": 60}}}

test_good_is_clean if {
	count(coverage.violation) == 0 with input as good with data.thresholds as th
}

test_low_total_flagged if {
	some v in coverage.errors with input as {"total": {"percent": 70}, "files": {"a.hs": {"percent": 95}}} with data.thresholds as th
	v.rule == "total-line-coverage"
}

test_low_file_flagged if {
	some v in coverage.errors with input as {"total": {"percent": 85}, "files": {"a.hs": {"percent": 95}, "b.hs": {"percent": 10}}} with data.thresholds as th
	v.rule == "file-line-coverage"
}

test_missing_required_file_flagged if {
	some v in coverage.errors with input as {"total": {"percent": 85}, "files": {"b.hs": {"percent": 60}}} with data.thresholds as th
	v.rule == "required-file-coverage"
}
