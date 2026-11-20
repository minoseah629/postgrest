package levels

import rego.v1

# input: coverage/levels.json (scripts/coverage-levels.py)
# data.thresholds.level_direction: "ascending" = each higher level must cover at least as
# much as the one below it (unit <= component <= api <= e2e); "descending" = the classic
# pyramid (each higher level covers no more than the one below).
# data.thresholds.level_tolerance: allowed shortfall in percentage points.

measured := [name |
	some name in input.order
	input.levels[name].measured
]

pairs contains [lower, upper] if {
	some i, lower in measured
	upper := measured[i + 1]
}

direction := object.get(data.thresholds, "level_direction", "ascending")

tolerance := object.get(data.thresholds, "level_tolerance", 0)

violation contains v if {
	direction == "ascending"
	some [lower, upper] in pairs
	input.levels[upper].percent + tolerance < input.levels[lower].percent
	v := {"rule": "inverted-level-coverage", "sev": "error", "at": sprintf("%s < %s", [upper, lower]),
		"actual": input.levels[upper].percent, "required": input.levels[lower].percent}
}

violation contains v if {
	direction == "descending"
	some [lower, upper] in pairs
	input.levels[upper].percent > input.levels[lower].percent + tolerance
	v := {"rule": "inverted-level-coverage", "sev": "error", "at": sprintf("%s > %s", [upper, lower]),
		"actual": input.levels[upper].percent, "required": input.levels[lower].percent}
}

violation contains v if {
	some name, min in object.get(data.thresholds, "level_min", {})
	input.levels[name].measured
	input.levels[name].percent < min
	v := {"rule": "level-line-coverage", "sev": "error", "at": name,
		"actual": input.levels[name].percent, "required": min}
}

# A configured level without data is reported, not failed (unit tests cannot be measured with hpc).
notice contains {"rule": "level-not-measured", "at": name} if {
	some name in input.order
	not input.levels[name].measured
}

errors contains v if {
	some v in violation
	v.sev == "error"
}
