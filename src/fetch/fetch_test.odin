package fetch

import "core:os"
import "core:strings"
import "core:testing"
import "wb:http"
import "wb:url"

@(private = "file")
U :: proc(s: string) -> url.URL {
	u, _ := url.parse_absolute(s, context.temp_allocator)
	return u
}

@(private = "file")
O :: proc(s: string) -> url.Origin { return url.origin_of(U(s), context.temp_allocator) }

@(private = "file")
H :: proc(raw: string) -> http.Headers { return http.parse_header_block(raw, context.temp_allocator) }

////////////////////////////////

@(test)
hsts_parsing_and_upgrade :: proc(t: ^testing.T) {
	h := hsts_make()
	defer hsts_destroy(&h)
	NOW :: i64(1_000_000)
	testing.expect(t, hsts_note(&h, "example.com", "max-age=31536000; includeSubDomains", NOW))
	testing.expect(t, hsts_should_upgrade(&h, "example.com", NOW))
	testing.expect(t, hsts_should_upgrade(&h, "a.b.example.com", NOW), "includeSubDomains")
	testing.expect(t, !hsts_should_upgrade(&h, "badexample.com", NOW))
	testing.expect(t, !hsts_should_upgrade(&h, "example.com", NOW + 32_000_000_000), "expired")

	testing.expect(t, hsts_note(&h, "plain.org", "max-age=100", NOW))
	testing.expect(t, hsts_should_upgrade(&h, "plain.org", NOW))
	testing.expect(t, !hsts_should_upgrade(&h, "sub.plain.org", NOW), "no includeSubDomains")

	testing.expect(t, !hsts_note(&h, "bad.org", "includeSubDomains", NOW), "max-age is required")
	testing.expect(t, !hsts_note(&h, "bad.org", "max-age=1; max-age=2", NOW), "duplicate directives")
	testing.expect(t, !hsts_note(&h, "bad.org", "max-age=abc", NOW))
	testing.expect(t, !hsts_note(&h, "127.0.0.1", "max-age=100", NOW), "never for IP literals")
	testing.expect(t, !hsts_note(&h, "[::1]", "max-age=100", NOW))
	testing.expect(t, hsts_note(&h, "quoted.org", `max-age="500"`, NOW))
	testing.expect(t, hsts_should_upgrade(&h, "quoted.org", NOW))

	testing.expect(t, hsts_note(&h, "plain.org", "max-age=0", NOW), "max-age=0 removes the entry")
	testing.expect(t, !hsts_should_upgrade(&h, "plain.org", NOW))

	up, ok := upgrade_to_https(U("http://example.com/a?b=1#c"), context.temp_allocator)
	testing.expect(t, ok)
	testing.expect_value(t, up.href, "https://example.com/a?b=1#c")
	up, _ = upgrade_to_https(U("http://example.com:8080/x"), context.temp_allocator)
	testing.expect_value(t, up.href, "https://example.com:8080/x")
}

@(test)
hsts_persistence :: proc(t: ^testing.T) {
	h := hsts_make()
	defer hsts_destroy(&h)
	hsts_note(&h, "keep.org", "max-age=1000; includeSubDomains", 0)
	hsts_note(&h, "gone.org", "max-age=1", 0)
	path := "build/hsts_test.txt"
	defer os.remove(path)
	testing.expect(t, hsts_save(&h, path, 5000))   // gone.org expired by 5000 ms
	h2 := hsts_make()
	defer hsts_destroy(&h2)
	n, ok := hsts_load(&h2, path, 5000)
	testing.expect(t, ok)
	testing.expect_value(t, n, 1)
	testing.expect(t, hsts_should_upgrade(&h2, "x.keep.org", 5000))
}

@(test)
referrer_policies :: proc(t: ^testing.T) {
	ref :: proc(src, dst: string, p: Referrer_Policy) -> string {
		v, ok := determine_referrer(U(src), U(dst), p, 4096, context.temp_allocator)
		return ok ? v : "<none>"
	}
	same_src := "https://a.example/page/x?q=1#frag"
	testing.expect_value(t, ref(same_src, "https://a.example/other", .Strict_Origin_When_Cross_Origin), "https://a.example/page/x?q=1")
	testing.expect_value(t, ref(same_src, "https://b.example/other", .Strict_Origin_When_Cross_Origin), "https://a.example/")
	testing.expect_value(t, ref(same_src, "http://b.example/other", .Strict_Origin_When_Cross_Origin), "<none>")   // downgrade
	testing.expect_value(t, ref(same_src, "https://b.example/", .No_Referrer), "<none>")
	testing.expect_value(t, ref(same_src, "https://b.example/", .Origin), "https://a.example/")
	testing.expect_value(t, ref(same_src, "http://b.example/", .Origin), "https://a.example/")
	testing.expect_value(t, ref(same_src, "http://b.example/", .Strict_Origin), "<none>")
	testing.expect_value(t, ref(same_src, "https://b.example/", .Same_Origin), "<none>")
	testing.expect_value(t, ref(same_src, "https://a.example/z", .Same_Origin), "https://a.example/page/x?q=1")
	testing.expect_value(t, ref(same_src, "http://b.example/", .Unsafe_Url), "https://a.example/page/x?q=1")
	testing.expect_value(t, ref(same_src, "http://b.example/", .No_Referrer_When_Downgrade), "<none>")
	testing.expect_value(t, ref(same_src, "https://b.example/", .Origin_When_Cross_Origin), "https://a.example/")
	testing.expect_value(t, ref("https://u:p@a.example:8443/p", "https://a.example:8443/q", .Strict_Origin_When_Cross_Origin), "https://a.example:8443/p")   // credentials stripped
	testing.expect_value(t, ref("file:///x.html", "https://b.example/", .Unsafe_Url), "<none>")                    // nothing to send from file:
	long := strings.concatenate({"https://a.example/", strings.repeat("p", 5000, context.temp_allocator)}, context.temp_allocator)
	testing.expect_value(t, ref(long, "https://a.example/z", .Strict_Origin_When_Cross_Origin), "https://a.example/")   // > 4096: origin only

	testing.expect_value(t, parse_referrer_policy("origin, no-referrer"), Referrer_Policy.No_Referrer)
	testing.expect_value(t, parse_referrer_policy("bogus, origin"), Referrer_Policy.Origin)
	testing.expect_value(t, parse_referrer_policy("bogus"), Referrer_Policy.Default)
}

@(test)
cors_checks :: proc(t: ^testing.T) {
	origin := O("https://app.example/page")
	ok, _ := cors_check(origin, false, H("Access-Control-Allow-Origin: *\r\n"))
	testing.expect(t, ok)
	ok, _ = cors_check(origin, true, H("Access-Control-Allow-Origin: *\r\n"))
	testing.expect(t, !ok, "wildcard is refused with credentials")
	ok, _ = cors_check(origin, true, H("Access-Control-Allow-Origin: https://app.example\r\n"))
	testing.expect(t, !ok, "credentials need Access-Control-Allow-Credentials")
	ok, _ = cors_check(origin, true, H("Access-Control-Allow-Origin: https://app.example\r\nAccess-Control-Allow-Credentials: true\r\n"))
	testing.expect(t, ok)
	ok, _ = cors_check(origin, false, H("Access-Control-Allow-Origin: https://other.example\r\n"))
	testing.expect(t, !ok)
	ok, _ = cors_check(origin, false, H("Access-Control-Allow-Origin: https://app.example/\r\n"))
	testing.expect(t, !ok, "origin must match exactly, no path")
	ok, _ = cors_check(origin, false, H(""))
	testing.expect(t, !ok)
	ok, _ = cors_check(origin, false, H("Access-Control-Allow-Origin: *\r\nAccess-Control-Allow-Origin: *\r\n"))
	testing.expect(t, !ok, "two values are refused")
	// opaque origins (file: documents, redirect-tainted requests) serialise to "null"
	opaque := url.new_opaque_origin()
	ok, _ = cors_check(opaque, false, H("Access-Control-Allow-Origin: null\r\n"))
	testing.expect(t, ok)
}

@(test)
preflight_validation :: proc(t: ^testing.T) {
	origin := O("https://app.example/")
	good := H("Access-Control-Allow-Origin: https://app.example\r\nAccess-Control-Allow-Methods: PUT, DELETE\r\nAccess-Control-Allow-Headers: X-Token, Content-Type\r\nAccess-Control-Max-Age: 600\r\n")
	v := check_preflight_response(origin, false, 204, good, "PUT", {"x-token"}, 5)
	testing.expect(t, v.ok, v.reason)
	testing.expect_value(t, v.max_age_s, 600)
	v = check_preflight_response(origin, false, 204, good, "PATCH", {}, 5)
	testing.expect(t, !v.ok, "method not listed")
	v = check_preflight_response(origin, false, 204, good, "PUT", {"x-other"}, 5)
	testing.expect(t, !v.ok, "header not listed")
	v = check_preflight_response(origin, false, 500, good, "PUT", {"x-token"}, 5)
	testing.expect(t, !v.ok, "status must be ok")
	v = check_preflight_response(origin, false, 200, good, "GET", {}, 5)
	testing.expect(t, v.ok, "safelisted methods never need listing")

	star := H("Access-Control-Allow-Origin: https://app.example\r\nAccess-Control-Allow-Methods: *\r\nAccess-Control-Allow-Headers: *\r\n")
	v = check_preflight_response(origin, false, 200, star, "DELETE", {"x-a", "x-b"}, 5)
	testing.expect(t, v.ok, "* covers everything without credentials")
	v = check_preflight_response(origin, false, 200, star, "DELETE", {"authorization"}, 5)
	testing.expect(t, !v.ok, "* never covers Authorization")
	star_cred := H("Access-Control-Allow-Origin: https://app.example\r\nAccess-Control-Allow-Credentials: true\r\nAccess-Control-Allow-Methods: *\r\nAccess-Control-Allow-Headers: *\r\n")
	v = check_preflight_response(origin, true, 200, star_cred, "DELETE", {"x-a"}, 5)
	testing.expect(t, !v.ok, "* is a literal with credentials")
}

@(test)
preflight_cache_behaviour :: proc(t: ^testing.T) {
	c := preflight_cache_make()
	defer preflight_cache_destroy(&c)
	NOW :: i64(10_000)
	preflight_cache_store(&c, "https://a", "https://b/x", false, {"PUT"}, {"X-Token"}, 60, NOW, 7200, 1000)
	testing.expect(t, preflight_cache_allows(&c, "https://a", "https://b/x", false, "PUT", {"x-token"}, NOW + 1000))
	testing.expect(t, preflight_cache_allows(&c, "https://a", "https://b/x", false, "GET", {}, NOW + 1000))
	testing.expect(t, !preflight_cache_allows(&c, "https://a", "https://b/x", false, "DELETE", {}, NOW + 1000))
	testing.expect(t, !preflight_cache_allows(&c, "https://a", "https://b/x", false, "PUT", {"x-other"}, NOW + 1000))
	testing.expect(t, !preflight_cache_allows(&c, "https://a", "https://b/x", true, "PUT", {"x-token"}, NOW + 1000), "credentials mode is part of the key")
	testing.expect(t, !preflight_cache_allows(&c, "https://other", "https://b/x", false, "PUT", {"x-token"}, NOW + 1000))
	testing.expect(t, !preflight_cache_allows(&c, "https://a", "https://b/x", false, "PUT", {"x-token"}, NOW + 61_000), "expired")
	preflight_cache_store(&c, "https://a", "https://b/y", false, {"PUT"}, {}, 0, NOW, 7200, 1000)   // max-age 0: not cached
	testing.expect_value(t, len(c.entries), 0)
}

@(test)
response_header_filtering :: proc(t: ^testing.T) {
	raw := H("Content-Type: text/plain\r\nSet-Cookie: a=1\r\nX-Secret: 1\r\nX-Shown: 2\r\nAccess-Control-Expose-Headers: X-Shown\r\nCache-Control: no-store\r\n")
	b := filter_basic_response_headers(raw, context.temp_allocator)
	testing.expect(t, !http.has_header(b, "set-cookie"))
	testing.expect(t, http.has_header(b, "x-secret"))
	c := filter_cors_response_headers(raw, false, context.temp_allocator)
	testing.expect(t, http.has_header(c, "content-type") && http.has_header(c, "cache-control"))
	testing.expect(t, http.has_header(c, "x-shown"), "listed in Access-Control-Expose-Headers")
	testing.expect(t, !http.has_header(c, "x-secret"))
	testing.expect(t, !http.has_header(c, "set-cookie"))
	star := H("X-A: 1\r\nAccess-Control-Expose-Headers: *\r\n")
	testing.expect(t, http.has_header(filter_cors_response_headers(star, false, context.temp_allocator), "x-a"))
	testing.expect(t, !http.has_header(filter_cors_response_headers(star, true, context.temp_allocator), "x-a"), "* is a literal with credentials")
}

@(test)
data_urls :: proc(t: ^testing.T) {
	d, ok := process_data_url(U("data:text/plain;charset=utf-8,Hello%20World%21"))
	testing.expect(t, ok)
	defer data_url_destroy(&d)
	testing.expect_value(t, string(d.body), "Hello World!")
	testing.expect_value(t, d.mime, "text/plain;charset=utf-8")

	d2, ok2 := process_data_url(U("data:;base64,SGVsbG8gV29ybGQ"))   // no padding, no type
	testing.expect(t, ok2)
	defer data_url_destroy(&d2)
	testing.expect_value(t, string(d2.body), "Hello World")
	testing.expect_value(t, d2.mime, "text/plain")

	d3, ok3 := process_data_url(U("data:application/wasm;base64, AGFz bQ== "))
	testing.expect(t, ok3)
	defer data_url_destroy(&d3)
	testing.expect_value(t, len(d3.body), 4)
	testing.expect_value(t, d3.mime, "application/wasm")

	_, bad := process_data_url(U("data:text/plain"))
	testing.expect(t, !bad, "no comma")
	_, bad = process_data_url(U("data:;base64,@@@@"))
	testing.expect(t, !bad)
	_, bad = process_data_url(U("data:;base64,A"))
	testing.expect(t, !bad, "length % 4 == 1")
}

@(test)
file_urls_and_access :: proc(t: ^testing.T) {
	p, ok := file_path_from_url(U("file:///C:/Dir%20One/a.html"), context.temp_allocator)
	testing.expect(t, ok)
	testing.expect_value(t, p, `C:\Dir One\a.html`)
	p, _ = file_path_from_url(U("file://server/share/f.txt"), context.temp_allocator)
	testing.expect_value(t, p, `\\server\share\f.txt`)

	env := environment_make(U("file:///C:/site/pages/index.html"))
	defer environment_destroy(&env)
	testing.expect_value(t, env.file_root, `C:\site\pages`)
	testing.expect(t, env.origin.opaque)
	testing.expect(t, file_access_allowed(&env, `C:\site\pages\app.wasm`, .Own_Tree))
	testing.expect(t, file_access_allowed(&env, `c:\SITE\pages\sub\deep\x.png`, .Own_Tree), "case-insensitive, subdirectories")
	testing.expect(t, !file_access_allowed(&env, `C:\site\other.txt`, .Own_Tree))
	testing.expect(t, !file_access_allowed(&env, `C:\site\pages2\x`, .Own_Tree), "sibling with a common prefix")
	testing.expect(t, file_access_allowed(nil, `C:\anything`, .Own_Tree), "the browser UI may open any file")

	web := environment_make(U("https://example.com/"))
	defer environment_destroy(&web)
	testing.expect(t, !file_access_allowed(&web, `C:\site\pages\app.wasm`, .Own_Tree), "web pages never read local files")
}

@(test)
destination_checks :: proc(t: ^testing.T) {
	wasm, _ := http.parse_mime("application/wasm", context.temp_allocator)
	html_m, _ := http.parse_mime("text/html", context.temp_allocator)
	css, _ := http.parse_mime("text/css", context.temp_allocator)
	_, ok := check_destination_mime(.Script, wasm, true, false)
	testing.expect(t, ok)
	_, ok = check_destination_mime(.Script, html_m, true, false)
	testing.expect(t, !ok, "a module must be application/wasm")
	_, ok = check_destination_mime(.Script, {}, false, false)
	testing.expect(t, !ok, "missing Content-Type")
	_, ok = check_destination_mime(.Style, html_m, true, true)
	testing.expect(t, !ok, "nosniff + not css")
	_, ok = check_destination_mime(.Style, css, true, true)
	testing.expect(t, ok)
	_, ok = check_destination_mime(.Document, html_m, true, true)
	testing.expect(t, ok)
}

@(test)
bad_ports :: proc(t: ^testing.T) {
	S := settings_default()
	defer settings_destroy(&S)
	testing.expect(t, is_bad_port(22, &S))
	testing.expect(t, is_bad_port(6667, &S))
	testing.expect(t, is_bad_port(10080, &S))
	testing.expect(t, !is_bad_port(80, &S))
	testing.expect(t, !is_bad_port(443, &S))
	testing.expect(t, !is_bad_port(8080, &S))
	S.bad_ports_allowed = {22}
	S.bad_ports_blocked = {8080}
	testing.expect(t, !is_bad_port(22, &S), "an allowed port is taken off the list")
	testing.expect(t, is_bad_port(8080, &S), "a port can be added to the list")
	S.bad_ports_allowed, S.bad_ports_blocked = nil, nil
}

@(test)
hsts_and_preflight_stores_can_be_emptied :: proc(t: ^testing.T) {
	h := hsts_make()
	defer hsts_destroy(&h)
	hsts_note(&h, "a.org", "max-age=1000", 0)
	hsts_note(&h, "b.org", "max-age=1000; includeSubDomains", 0)
	testing.expect_value(t, hsts_clear(&h), 2)
	testing.expect(t, !hsts_should_upgrade(&h, "a.org", 1))
	testing.expect(t, !hsts_should_upgrade(&h, "x.b.org", 1))
	testing.expect_value(t, hsts_clear(&h), 0)
	testing.expect(t, hsts_note(&h, "a.org", "max-age=1000", 0), "and it takes new ones")

	c := preflight_cache_make()
	defer preflight_cache_destroy(&c)
	preflight_cache_store(&c, "https://a", "https://b/x", false, {"PUT"}, {"X-Token"}, 60, 10_000, 7200, 1000)
	testing.expect_value(t, preflight_cache_clear(&c), 1)
	testing.expect(t, !preflight_cache_allows(&c, "https://a", "https://b/x", false, "PUT", {"x-token"}, 10_001))
}
