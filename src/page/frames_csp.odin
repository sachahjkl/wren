package page

// Content Security Policy: Embedded Enforcement (https://w3c.github.io/webappsec-cspee/). An <iframe csp="..."> requires a policy of
// the documents it embeds (Navigable.required_csp, read with the other attributes at a navigation; a frame without one takes its
// parent's own). Its requests say which (Sec-Required-CSP). A response takes it:
//   * when it allows blanket enforcement, Allow-CSP-From: * or the parent's origin: the policy is enforced on the document;
//   * when its own enforced policies subsume it (here: one of them has each of its directives, with the same sources);
//   * when it is of a local scheme (about:blank, srcdoc, data:, blob:): the policy is enforced on the document.
// Any other is refused, as X-Frame-Options refuses. The policy's sandbox directive sandboxes the document, as any enforced policy's
// does (csp_sandbox_apply).

import "core:slice"
import "core:strings"
import "wb:csp"
import "wb:http"
import "wb:url"

REQUIRED_CSP_HEADER :: "Sec-Required-CSP"

Required_Csp_Verdict :: enum u8 { Allowed, Enforced, Refused }

// The csp attribute as a required policy (CSPEE "is valid required CSP": one serialized policy of printable ASCII, without
// report-uri nor report-to), else the parent's own required policy, which holds for what it embeds too; "" none.
@(private)
frame_required_csp :: proc(n: ^Navigable, value: string, has: bool) -> string {
	if has && required_csp_valid(value) { return strings.trim_space(value) }
	if pn := frame_navigable_of(n.parent); pn != nil { return pn.required_csp }
	return ""
}

required_csp_valid :: proc(value: string) -> bool {
	t := strings.trim_space(value)
	if t == "" { return false }
	for i in 0 ..< len(t) {
		if c := t[i]; c < ' ' || c > '~' || c == ',' { return false }
	}
	pol := csp.parse_policy(t, .Enforce)
	defer csp.policy_destroy(&pol)
	for d in pol.directives {
		if d.name == "report-uri" || d.name == "report-to" { return false }
	}
	return len(pol.directives) > 0
}

// What the response of a frame's navigation does with the policy its frame requires.
@(private)
required_csp_verdict :: proc(n: ^Navigable, final: url.URL, headers: http.Headers) -> Required_Csp_Verdict {
	if n.required_csp == "" { return .Allowed }
	switch final.scheme {
	case "about", "data", "blob": return .Enforced
	}
	if v, ok := http.get_header(headers, "allow-csp-from"); ok {
		from := strings.trim_space(v)
		if from == "*" { return .Enforced }
		if u, uok := url.parse(from, nil, context.temp_allocator); uok && url.same_origin(url.origin_of(u, context.temp_allocator), n.parent.env.origin) { return .Enforced }
	}
	own: csp.Policy_List
	defer csp.list_destroy(&own)
	for v in http.get_all(headers, "content-security-policy") { csp.parse_header(&own, v, .Enforce) }
	return policies_subsume(&own, n.required_csp) ? .Allowed : .Refused
}

// Whether an enforced policy of `l` has each directive of `required` with the same sources (in any order): a policy as strict at
// least, the part of CSPEE's subsumption that does not compare source lists.
@(private)
policies_subsume :: proc(l: ^csp.Policy_List, required: string) -> bool {
	req := csp.parse_policy(required, .Enforce)
	defer csp.policy_destroy(&req)
	sorted_tokens :: proc(raw: string) -> []string {
		tokens := csp.split_ws(raw)
		slice.sort(tokens)
		return tokens
	}
	next_policy: for &pol in l.policies {
		if pol.disposition != .Enforce { continue }
		for want in req.directives {
			found := false
			for have in pol.directives {
				if have.name == want.name && slice.equal(sorted_tokens(have.raw), sorted_tokens(want.raw)) { found = true; break }
			}
			if !found { continue next_policy }
		}
		return true
	}
	return false
}

// The frame's required policy is the document's: enforced, its sandbox directive applied.
@(private)
frame_enforce_required_csp :: proc(n: ^Navigable, c: ^Page) {
	if n.required_csp == "" || !csp_on(c) { return }
	csp.parse_header(&c.env.policies, n.required_csp, .Enforce)
	csp_sandbox_apply(c)
}

// The sandbox directive of the document's enforced policies sandboxes it (CSP 3 §6.3.2), on top of what its container and its
// opener ask: an opaque origin without allow-same-origin, no scripts without allow-scripts, no document.domain.
@(private)
csp_sandbox_apply :: proc(p: ^Page) {
	sb: Sandbox
	for &pol in p.env.policies.policies {
		if pol.disposition != .Enforce { continue }
		for d in pol.directives {
			if d.name == "sandbox" { sb = sandbox_combine(sb, sandbox_parse(d.raw)) }
		}
	}
	if !sb.active { return }
	f := frames_of(p)
	f.sandbox = sandbox_combine(f.sandbox, sb)
	if .Same_Origin not_in f.sandbox.allow {
		env_set_origin(&p.env, url.new_opaque_origin())
		p.origin_owner = 0
	}
}
