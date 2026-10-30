package csp

import "core:testing"
import "wb:url"

@(private = "file")
U :: proc(s: string) -> url.URL {
	u, _ := url.parse_absolute(s, context.temp_allocator)
	return u
}

@(private = "file")
allowed :: proc(policy: string, kind: Directive_Kind, target: string, doc := "https://app.example/page", redirected := false) -> bool {
	l: Policy_List
	defer list_destroy(&l)
	parse_header(&l, policy, .Enforce)
	self := url.origin_of(U(doc), context.temp_allocator)
	return check_request(&l, kind, U(target), self, redirected).allowed
}

@(test)
parsing :: proc(t: ^testing.T) {
	p := parse_policy("default-src 'self'; script-src 'self' https://cdn.example.com *.trusted.org:8443/lib/ 'nonce-abc123' 'sha256-AbC+/=' ; img-src data: https: ; bogus ??? ; default-src 'none'", .Enforce)
	defer policy_destroy(&p)
	testing.expect_value(t, len(p.directives), 4)   // default-src, script-src, img-src, bogus (the second default-src is ignored)
	testing.expect_value(t, p.directives[0].name, "default-src")
	testing.expect_value(t, p.directives[0].sources[0].keyword, Keyword.Self)
	ss := p.directives[1].sources
	testing.expect_value(t, len(ss), 5)
	testing.expect_value(t, ss[1].host, "cdn.example.com")
	testing.expect_value(t, ss[1].scheme, "https")
	testing.expect_value(t, ss[2].host, "*.trusted.org")
	testing.expect_value(t, ss[2].port, "8443")
	testing.expect_value(t, ss[2].path, "/lib/")
	testing.expect_value(t, ss[3].kind, Source_Kind.Nonce)
	testing.expect_value(t, ss[4].kind, Source_Kind.Hash)
	testing.expect_value(t, p.directives[2].sources[0].kind, Source_Kind.Scheme)

	p2 := parse_policy("script-src 'self' 'bad-keyword' 'nonce-' ht!tp://x", .Enforce)
	defer policy_destroy(&p2)
	testing.expect_value(t, len(p2.directives[0].sources), 1)
	testing.expect(t, len(p2.warnings) >= 3)
}

@(test)
self_and_hosts :: proc(t: ^testing.T) {
	pol := "script-src 'self'"
	testing.expect(t, allowed(pol, .Script_Src_Elem, "https://app.example/app.wasm"))
	testing.expect(t, !allowed(pol, .Script_Src_Elem, "https://other.example/app.wasm"))
	testing.expect(t, !allowed(pol, .Script_Src_Elem, "https://app.example:8443/app.wasm"), "'self' includes the port")
	testing.expect(t, !allowed(pol, .Script_Src_Elem, "http://app.example/app.wasm"), "no downgrade from an https self")
	testing.expect(t, allowed(pol, .Script_Src_Elem, "https://app.example/x", "http://app.example/p"), "http self may upgrade to https")
	testing.expect(t, !allowed(pol, .Script_Src_Elem, "https://app.example/x", "file:///a.html"), "opaque self matches nothing")

	hosts := "script-src https://cdn.example.com *.trusted.org example.net:8443 https://paths.test/lib/ https://exact.test/a.wasm"
	testing.expect(t, allowed(hosts, .Script_Src_Elem, "https://cdn.example.com/x"))
	testing.expect(t, !allowed(hosts, .Script_Src_Elem, "https://cdn.example.com:444/x"), "port must be default when not stated")
	testing.expect(t, !allowed(hosts, .Script_Src_Elem, "http://cdn.example.com/x"))
	testing.expect(t, allowed(hosts, .Script_Src_Elem, "https://a.trusted.org/x"))
	testing.expect(t, !allowed(hosts, .Script_Src_Elem, "https://trusted.org/x"), "*. needs a subdomain")
	testing.expect(t, allowed(hosts, .Script_Src_Elem, "https://example.net:8443/x"))
	testing.expect(t, !allowed(hosts, .Script_Src_Elem, "https://example.net/x"))
	testing.expect(t, allowed(hosts, .Script_Src_Elem, "https://paths.test/lib/deep/x.wasm"), "path prefix")
	testing.expect(t, !allowed(hosts, .Script_Src_Elem, "https://paths.test/other/x.wasm"))
	testing.expect(t, allowed(hosts, .Script_Src_Elem, "https://exact.test/a.wasm"))
	testing.expect(t, !allowed(hosts, .Script_Src_Elem, "https://exact.test/a.wasm2"))
	testing.expect(t, allowed(hosts, .Script_Src_Elem, "https://paths.test/other/x.wasm", "https://app.example/p", true), "after a redirect the path is ignored")
	testing.expect(t, allowed("connect-src *", .Connect_Src, "https://anything.example/x"))
	testing.expect(t, !allowed("connect-src *", .Connect_Src, "data:text/plain,x"), "* does not match data:")
	testing.expect(t, allowed("img-src data: https:", .Img_Src, "data:image/png;base64,AAAA"))
	testing.expect(t, allowed("img-src https:", .Img_Src, "https://x.test/a.png"))
	testing.expect(t, !allowed("img-src https:", .Img_Src, "http://x.test/a.png"))
	testing.expect(t, allowed("connect-src ws:", .Connect_Src, "wss://x.test/"), "ws: covers wss:")
	testing.expect(t, allowed("connect-src http:", .Connect_Src, "https://x.test/"), "http: covers https:")
	testing.expect(t, allowed("connect-src https://x.test:443", .Connect_Src, "https://x.test/"), "explicit default port")
}

@(test)
none_empty_and_fallbacks :: proc(t: ^testing.T) {
	testing.expect(t, !allowed("default-src 'none'", .Connect_Src, "https://app.example/x"))
	testing.expect(t, !allowed("script-src 'none'", .Script_Src_Elem, "https://app.example/x"))
	testing.expect(t, !allowed("script-src", .Script_Src_Elem, "https://app.example/x"), "an empty list means 'none'")
	testing.expect(t, allowed("script-src 'none'", .Connect_Src, "https://app.example/x"), "a policy silent about a directive allows it")
	testing.expect(t, allowed("default-src 'self'; connect-src https://api.example", .Connect_Src, "https://api.example/x"))
	testing.expect(t, !allowed("default-src 'self'; connect-src https://api.example", .Connect_Src, "https://app.example/x"), "the specific directive replaces the fallback")
	testing.expect(t, allowed("default-src https://a.test; script-src https://b.test", .Script_Src_Elem, "https://b.test/x"))
	testing.expect(t, allowed("default-src https://a.test", .Script_Src_Elem, "https://a.test/x"), "script-src-elem -> script-src -> default-src")
	testing.expect(t, allowed("script-src https://a.test; script-src-elem https://b.test", .Script_Src_Elem, "https://b.test/x"))
	testing.expect(t, !allowed("script-src https://a.test; script-src-elem https://b.test", .Script_Src_Elem, "https://a.test/x"))
	testing.expect(t, allowed("child-src https://w.test", .Worker_Src, "https://w.test/x"), "worker-src -> child-src")
	testing.expect(t, allowed("DEFAULT-SRC 'SELF'", .Connect_Src, "https://app.example/x"), "names and keywords are case-insensitive")
}

@(test)
multiple_policies_and_report_only :: proc(t: ^testing.T) {
	l: Policy_List
	defer list_destroy(&l)
	parse_header(&l, "default-src 'self', script-src https://a.test", .Enforce)   // two policies in one header
	parse_header(&l, "connect-src 'none'", .Report_Only)
	testing.expect_value(t, len(l.policies), 3)
	self := url.origin_of(U("https://app.example/"), context.temp_allocator)

	v := check_request(&l, .Script_Src_Elem, U("https://a.test/x"), self)
	testing.expect(t, !v.allowed, "every enforced policy must allow: default-src 'self' refuses a.test")
	v = check_request(&l, .Script_Src_Elem, U("https://app.example/x"), self)
	testing.expect(t, !v.allowed, "...and script-src https://a.test refuses 'self'")
	v = check_request(&l, .Connect_Src, U("https://app.example/x"), self)
	testing.expect(t, v.allowed, "report-only does not block")
	testing.expect_value(t, len(v.violations), 1)
	testing.expect(t, !v.violations[0].enforced)
	testing.expect_value(t, v.violations[0].directive, "connect-src")
}

@(test)
nonces_and_flags :: proc(t: ^testing.T) {
	l: Policy_List
	defer list_destroy(&l)
	parse_header(&l, "script-src 'nonce-r4nd0m' https://a.test; upgrade-insecure-requests", .Enforce)
	self := url.origin_of(U("https://app.example/"), context.temp_allocator)
	testing.expect(t, check_nonce(&l, .Script_Src_Elem, "r4nd0m").allowed)
	testing.expect(t, !check_nonce(&l, .Script_Src_Elem, "other").allowed)
	testing.expect(t, !check_nonce(&l, .Script_Src_Elem, "").allowed)
	testing.expect(t, check_request(&l, .Script_Src_Elem, U("https://nowhere.test/x"), self, false, "r4nd0m").allowed, "a matching nonce allows the element")
	testing.expect(t, has_directive(&l, "upgrade-insecure-requests"))
	testing.expect(t, !has_directive(&l, "block-all-mixed-content"))
}

@(test)
wasm_eval :: proc(t: ^testing.T) {
	allows :: proc(policy: string) -> bool {
		l: Policy_List
		defer list_destroy(&l)
		parse_header(&l, policy, .Enforce)
		return check_wasm_eval(&l).allowed
	}
	testing.expect(t, allows("img-src 'none'"), "no script-src, no default-src")
	testing.expect(t, allows("script-src 'wasm-unsafe-eval'"), "'wasm-unsafe-eval'")
	testing.expect(t, allows("script-src 'unsafe-eval'"), "'unsafe-eval'")
	testing.expect(t, allows("default-src 'wasm-unsafe-eval'"), "default-src")
	testing.expect(t, !allows("script-src 'self'"), "neither")
	testing.expect(t, !allows("default-src 'self'"), "default-src, neither")
	testing.expect(t, !allows("default-src 'wasm-unsafe-eval'; script-src 'self'"), "script-src decides")
}
