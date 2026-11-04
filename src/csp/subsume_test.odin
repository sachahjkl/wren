package csp

import "core:testing"
import "wb:url"

// CSP Embedded Enforcement's subsumption (subsume.odin): is the response's enforced policy list as strict as the required policy?
@(private = "file")
subsumes :: proc(returned, required: string, self := "https://app.example/") -> bool {
	l: Policy_List
	defer list_destroy(&l)
	parse_header(&l, returned, .Enforce)
	req := parse_policy(required, .Enforce)
	defer policy_destroy(&req)
	u, _ := url.parse_absolute(self, context.temp_allocator)
	return policy_list_subsumes(&l, &req, url.origin_of(u, context.temp_allocator))
}

@(test)
subsumption_of_source_lists :: proc(t: ^testing.T) {
	testing.expect(t, subsumes("script-src https://a.example.com/js/", "script-src https://*.example.com"), "a host within a wildcard, a path within none")
	testing.expect(t, !subsumes("script-src https://*.example.com", "script-src https://a.example.com"), "a wildcard is wider than one of its hosts")
	testing.expect(t, subsumes("script-src https://a.example.com/js/x.js", "script-src https://a.example.com/js/"), "a file within its folder")
	testing.expect(t, !subsumes("script-src https://a.example.com/", "script-src https://a.example.com/js/"), "a folder wider than the required one")
	testing.expect(t, subsumes("script-src 'none'", "script-src https://a.example.com"), "'none' within anything")
	testing.expect(t, !subsumes("script-src https://a.example.com", "script-src 'none'"), "nothing within 'none'")
	testing.expect(t, subsumes("script-src https://a.example.com", "script-src https:"), "a host within its scheme")
	testing.expect(t, !subsumes("script-src http:", "script-src https:"), "http: is wider than https:")
	testing.expect(t, subsumes("script-src https://a.example.com", "script-src http://a.example.com:443"), "an upgrade of http to https on its port")
	testing.expect(t, !subsumes("script-src https://a.example.com", "script-src https://a.example.com:8443"), "another port")
	testing.expect(t, subsumes("script-src https://a.example.com:8443", "script-src https://a.example.com:*"), "any port")
	testing.expect(t, subsumes("script-src https://b.example 'self'", "script-src https://app.example https://b.example"), "'self' within a host source of the origin")
	testing.expect(t, subsumes("script-src https://app.example/js/", "script-src 'self'"), "a host source of the origin within 'self'")
	testing.expect(t, !subsumes("script-src https://*.app.example", "script-src 'self'"), "a wildcard is not 'self'")
	testing.expect(t, !subsumes("script-src 'self' 'unsafe-inline'", "script-src 'self'"), "a keyword that allows more")
	testing.expect(t, subsumes("script-src 'self' 'nonce-abc'", "script-src 'self' 'nonce-abc' 'nonce-def'"), "a nonce among the required ones")
	testing.expect(t, !subsumes("script-src 'self' 'nonce-xyz'", "script-src 'self' 'nonce-abc'"), "a nonce the required list does not have")
	testing.expect(t, subsumes("img-src https://a.example", "img-src *"), "a network host within *")
	testing.expect(t, !subsumes("img-src *", "img-src https:"), "* allows http too")
}

@(test)
subsumption_of_directives :: proc(t: ^testing.T) {
	testing.expect(t, subsumes("default-src 'self'", "img-src 'self'"), "a fetch directive through default-src")
	testing.expect(t, !subsumes("img-src 'self'", "script-src 'self'"), "a directive the response does not govern")
	testing.expect(t, !subsumes("default-src https:; img-src *", "default-src https:"), "a fetch directive of its own wider than the required default-src")
	testing.expect(t, subsumes("default-src https://a.example; img-src https://b.example", "default-src https:"))
	testing.expect(t, subsumes("default-src 'none', script-src https://a.example", "default-src 'none'; script-src https://a.example"), "each directive in one policy or another")
	testing.expect(t, subsumes("sandbox", "sandbox allow-scripts"), "a sandbox that allows less")
	testing.expect(t, !subsumes("sandbox allow-scripts allow-forms", "sandbox allow-scripts"), "a sandbox that allows more")
	testing.expect(t, !subsumes("script-src 'self'", "sandbox"), "no sandbox")
	testing.expect(t, subsumes("upgrade-insecure-requests; script-src 'self'", "upgrade-insecure-requests"))
	l: Policy_List
	defer list_destroy(&l)
	parse_header(&l, "script-src 'none'", .Report_Only)
	req := parse_policy("script-src 'none'", .Enforce)
	defer policy_destroy(&req)
	testing.expect(t, !policy_list_subsumes(&l, &req, {}), "a report-only policy enforces nothing")
}
