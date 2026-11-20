package owasp_test

import rego.v1

import data.owasp

bad_spec := {
	"swagger": "2.0",
	"schemes": ["http"],
	"paths": {"/t": {"post": {"responses": {"201": {"description": "Created"}}}}},
	"definitions": {"t": {"properties": {"name": {"type": "string"}}}},
}

good_spec := {
	"swagger": "2.0",
	"schemes": ["https"],
	"security": [{"jwt": []}],
	"securityDefinitions": {"jwt": {"type": "apiKey", "in": "header", "name": "Authorization"}},
	"paths": {"/t": {"post": {"responses": {
		"201": {"description": "Created", "headers": {"X-RateLimit-Limit": {"type": "integer"}}},
		"401": {"description": "Unauthorized"},
		"429": {"description": "Too many"},
		"500": {"description": "Error"},
	}}}},
	"definitions": {"t": {"properties": {"name": {"type": "string", "maxLength": 50, "pattern": "^[a-z]+$"}}}},
}

test_bad_spec_has_errors if {
	count(owasp.errors) > 0 with input as bad_spec
}

test_bad_spec_flags_http if {
	some v in owasp.violation with input as bad_spec
	v.rule == "api2-always-https"
}

test_bad_spec_flags_unprotected_write if {
	some v in owasp.violation with input as bad_spec
	v.rule == "api2-protection-global-unsafe"
}

test_good_spec_clean if {
	count(owasp.violation) == 0 with input as good_spec
}
