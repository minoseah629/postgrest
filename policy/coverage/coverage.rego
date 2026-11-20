package coverage

import rego.v1

# input: coverage/summary.json (scripts/coverage-summary.py)
# data.thresholds: policy/coverage/thresholds.json

violation contains {"rule": "total-line-coverage", "sev": "error", "at": "total",
	"actual": input.total.percent, "required": data.thresholds.total_min} if {
	input.total.percent < data.thresholds.total_min
}

violation contains {"rule": "file-line-coverage", "sev": "error", "at": path,
	"actual": f.percent, "required": data.thresholds.file_min} if {
	some path, f in input.files
	f.percent < data.thresholds.file_min
}

violation contains {"rule": "required-file-coverage", "sev": "error", "at": path,
	"actual": object.get(input.files, [path, "percent"], 0), "required": min} if {
	some path, min in data.thresholds.required_files
	object.get(input.files, [path, "percent"], 0) < min
}

errors contains v if {
	some v in violation
	v.sev == "error"
}
