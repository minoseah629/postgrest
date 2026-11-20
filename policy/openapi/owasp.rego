package owasp

import rego.v1

unsafe := {"post", "put", "patch", "delete"}
methods := {"get", "head", "post", "put", "patch", "delete", "options"}

ops[[path, method]] := op if {
	some path, item in input.paths
	some method, op in item
	method in methods
}

# API2: unsafe operations need security (global or per-operation)
violation contains {"rule": "api2-protection-global-unsafe", "sev": "error", "at": sprintf("%s %s", [upper(m), p])} if {
	some [p, m], op in ops
	m in unsafe
	not op.security
	count(object.get(input, "security", [])) == 0
}

# API2: transport must be https
violation contains {"rule": "api2-always-https", "sev": "error", "at": "schemes"} if {
	some s in object.get(input, "schemes", [])
	s != "https"
}

# API2: spec must define an auth scheme at all
violation contains {"rule": "api2-no-security-definitions", "sev": "error", "at": "securityDefinitions"} if {
	count(object.get(input, "securityDefinitions", {})) == 0
}

# API3/API4: expected responses
required_codes := {"401": "api3-define-error-responses-401", "500": "api3-define-error-responses-500", "429": "api4-rate-limit-responses-429"}

violation contains {"rule": rule, "sev": "warn", "at": sprintf("%s %s", [upper(m), p])} if {
	some [p, m], op in ops
	some code, rule in required_codes
	not op.responses[code]
}

# API4: bounds on definitions
violation contains {"rule": "api4-string-limit", "sev": "error", "at": sprintf("#/definitions/%s/%s", [d, prop])} if {
	some d, def in input.definitions
	some prop, s in def.properties
	s.type == "string"
	not s.maxLength
	not s.enum
}

violation contains {"rule": "api4-string-restricted", "sev": "error", "at": sprintf("#/definitions/%s/%s", [d, prop])} if {
	some d, def in input.definitions
	some prop, s in def.properties
	s.type == "string"
	not s.format
	not s.enum
	not s.pattern
}

violation contains {"rule": "api4-integer-limit", "sev": "error", "at": sprintf("#/definitions/%s/%s", [d, prop])} if {
	some d, def in input.definitions
	some prop, s in def.properties
	s.type == "integer"
	not bounded(s)
}

bounded(s) if {
	s.minimum
	s.maximum
}

violation contains {"rule": "api4-array-limit", "sev": "error", "at": at} if {
	some at, s in arrays
	not s.maxItems
}

arrays[at] := s if {
	some p, item in input.paths
	some m, op in item
	m in methods
	some code, r in op.responses
	s := r.schema
	s.type == "array"
	at := sprintf("%s %s response %s", [upper(m), p, code])
}

# API1: no numeric ids
violation contains {"rule": "api1-no-numeric-ids", "sev": "error", "at": sprintf("#/definitions/%s/%s", [d, prop])} if {
	some d, def in input.definitions
	some prop, s in def.properties
	s.type in {"integer", "number"}
	regex.match(`(^|_)id$`, lower(prop))
}

# API4: rate-limit headers on success responses
violation contains {"rule": "api4-rate-limit-headers", "sev": "error", "at": sprintf("%s %s %s", [upper(m), p, code])} if {
	some [p, m], op in ops
	some code, r in op.responses
	startswith(code, "2")
	not r.headers
}

# Violations that should fail CI.
errors contains v if {
	some v in violation
	v.sev == "error"
}
