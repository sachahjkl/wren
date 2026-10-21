package csp

// frame-ancestors (CSP 3 §6.4.2): which documents may embed the protected one. Unlike the fetch directives it is
// checked by the embedded document's own policy, against the origin of every ancestor, when the response of a nested
// navigation arrives; it has no fallback (default-src does not apply) and is ignored in a <meta> policy (callers pass
// the header policies only).

import "core:strings"
import "wb:url"

// May a document of origin `self`, whose policies are `l` (from its response headers), be embedded by `ancestors`
// (the parent first, the top level last)? An opaque ancestor matches no source.
check_frame_ancestors :: proc(l: ^Policy_List, self: url.Origin, ancestors: []url.Origin) -> Verdict {
	v := Verdict{allowed = true, violations = make([dynamic]Violation, context.temp_allocator)}
	for &p in l.policies {
		d, name := effective(&p, .Frame_Ancestors)
		if d == nil { continue }
		for a in ancestors {
			if ancestor_allowed(d, self, a) { continue }
			ser := url.origin_serialize(a, context.temp_allocator)
			append(&v.violations, Violation{directive = name, original = p.raw, blocked = ser, enforced = p.disposition == .Enforce})
			if p.disposition == .Enforce { v.allowed = false }
			break
		}
	}
	return v
}

@(private)
ancestor_allowed :: proc(d: ^Directive, self: url.Origin, a: url.Origin) -> bool {
	if a.opaque { return false }
	u, ok := url.parse_absolute(strings.concatenate({url.origin_serialize(a, context.temp_allocator), "/"}, context.temp_allocator), context.temp_allocator)
	if !ok { return false }
	for s in d.sources {
		if s.kind == .Keyword && s.keyword == .None { continue }
		if s.kind == .Nonce || s.kind == .Hash { continue }
		if source_matches_url(s, self, u, false) { return true }
	}
	return false
}
