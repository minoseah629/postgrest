#!/usr/bin/env python3
"""Patch PostgREST's generated Swagger 2.0 spec with what the gateway adds or enforces.

PostgREST does not emit error responses, rate-limit headers, array bounds or
parameter patterns. policy/openapi/dev/nginx.conf and PGRST_DB_MAX_ROWS provide
(or constrain) these at runtime; this script documents them in the spec so the
Spectral and OPA checks can verify the contract.

Usage: patch-openapi.py IN.json OUT.json [--max-rows N] [--rate-limit N]
"""
import argparse
import json
import re

METHODS = ("get", "put", "post", "patch", "delete", "head", "options")

FILTER_OPS = (
    "eq|neq|gt|gte|lt|lte|like|ilike|match|imatch|in|is|isdistinct|cs|cd|ov|"
    "sl|sr|nxl|nxr|adj|fts|plfts|phfts|wfts"
)
# Patterns for PostgREST's own query/header grammar (not catch-alls).
PARAM_PATTERNS = {
    "select": r"^[A-Za-z0-9_.,:()*>!\-]{1,500}$",
    "order": r"^[A-Za-z0-9_.,]{1,200}$",
    "on_conflict": r"^[A-Za-z0-9_,]{1,200}$",
    "offset": r"^[0-9]{1,9}$",
    "limit": r"^[0-9]{1,9}$",
    "range": r"^[0-9]*-[0-9]*$",
    "preferParams": r"^[A-Za-z0-9=,;_\- ]{1,200}$",
}
ROW_FILTER = r"^(not\.)?(%s)(\([a-z]+\))?\..{0,200}$" % FILTER_OPS


def schema_ref(name):
    return {"$ref": "#/definitions/%s" % name}


def camel(s):
    return "".join(w.capitalize() for w in re.split(r"[^A-Za-z0-9]+", s) if w)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("src")
    ap.add_argument("dst")
    ap.add_argument("--max-rows", type=int, default=1000)
    ap.add_argument("--rate-limit", type=int, default=10, help="requests/second per client enforced by the gateway")
    ap.add_argument("--contact-name", default="minoseah629")
    ap.add_argument("--contact-url", default="https://github.com/minoseah629/postgrest")
    ap.add_argument("--contact-email", default="noreply@users.noreply.github.com")
    a = ap.parse_args()

    spec = json.load(open(a.src))

    # ---- info -----------------------------------------------------------
    info = spec.setdefault("info", {})
    info.setdefault("contact", {"name": a.contact_name, "url": a.contact_url, "email": a.contact_email})
    info.setdefault("license", {"name": "MIT", "url": "https://github.com/PostgREST/postgrest/blob/main/LICENSE"})

    # ---- error model ----------------------------------------------------
    defs = spec.setdefault("definitions", {})
    defs["error"] = {
        "type": "object",
        "description": "PostgREST error body.",
        "properties": {
            "code": {"type": "string", "format": "text", "maxLength": 64},
            "message": {"type": "string", "format": "text", "maxLength": 2000},
            "details": {"type": "string", "format": "text", "maxLength": 2000, "x-nullable": True},
            "hint": {"type": "string", "format": "text", "maxLength": 2000, "x-nullable": True},
        },
    }

    # ---- definitions: bound uuids; drop DB-expression defaults ----------
    for d in defs.values():
        for prop in (d.get("properties") or {}).values():
            if prop.get("type") != "string":
                continue
            if prop.get("format") == "uuid":
                prop.setdefault("maxLength", 36)
            default = prop.get("default")
            if isinstance(default, str) and re.match(r"^\w+\(.*\)$", default):
                del prop["default"]  # a SQL expression, not a valid example value

    # ---- shared parameters ---------------------------------------------
    for name, p in (spec.get("parameters") or {}).items():
        if p.get("in") == "body" or p.get("type") != "string":
            continue
        p.setdefault("description", name)
        if name == "rangeUnit":
            p["enum"] = ["items"]  # the only unit PostgREST supports
        if "enum" in p:
            continue
        if name.startswith("rowFilter."):
            p["pattern"] = ROW_FILTER
            p["maxLength"] = 256
            p.setdefault("description", "Filter on %s (PostgREST operator syntax, e.g. eq.value)" % name.split(".", 1)[1])
        elif name in PARAM_PATTERNS:
            p["pattern"] = PARAM_PATTERNS[name]
            p["maxLength"] = 500 if name == "select" else 200

    # ---- operations -----------------------------------------------------
    rl_hdr = {
        "type": "integer", "format": "int32", "minimum": 1, "maximum": 100000,
        "description": "Requests per second allowed per client (enforced by the gateway).",
    }
    tags = {}
    for path, item in (spec.get("paths") or {}).items():
        for method, op in item.items():
            if method not in METHODS:
                continue
            op.setdefault("operationId", method + camel(path) if path != "/" else method + "Root")
            op.setdefault("description", op.get("summary") or "%s %s" % (method.upper(), path))
            for t in op.get("tags", []):
                tags.setdefault(t, "Operations on %s" % t if t != "Introspection" else "API self-description")
            resp = op.setdefault("responses", {})
            resp.setdefault("400", {"description": "Bad request", "schema": schema_ref("error")})
            resp.setdefault("401", {"description": "Missing, invalid or expired JWT", "schema": schema_ref("error")})
            resp.setdefault("429", {
                "description": "Too many requests",
                "schema": schema_ref("error"),
                "headers": {
                    "Retry-After": {
                        "type": "integer", "format": "int32", "minimum": 1, "maximum": 3600,
                        "description": "Seconds to wait before retrying.",
                    },
                },
            })
            resp.setdefault("500", {"description": "Internal server error", "schema": schema_ref("error")})
            for code, r in resp.items():
                if re.match(r"^[245]", code):
                    r.setdefault("headers", {})["X-RateLimit-Limit"] = dict(rl_hdr)
                s = r.get("schema")
                if s and s.get("type") == "array":
                    s["maxItems"] = a.max_rows  # matches PGRST_DB_MAX_ROWS

    spec["tags"] = [{"name": n, "description": tags[n]} for n in sorted(tags)]
    json.dump(spec, open(a.dst, "w"), indent=2)
    open(a.dst, "a").write("\n")


if __name__ == "__main__":
    main()
