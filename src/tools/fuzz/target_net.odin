package fuzz

// What a server sends besides the body: its headers, its cookies, its content security policy.

import "wb:cookies"
import "wb:csp"
import "wb:http"
import "wb:url"

HTTP_SEEDS := []string{
	"HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: 10\r\n\r\n",
	"HTTP/1.1 301 Moved\r\nLocation: /x\r\nSet-Cookie: a=b; Path=/\r\nSet-Cookie: c=d\r\nX-Folded: a\r\n b\r\n\tc\r\n\r\n",
	"Content-Type: text/plain;charset=\"ut\\\"f-8\";x=y, text/html;;charset=gbk\r\nContent-Type: */*\r\n",
	"Content-Type: application/json; foo=bar; charset=ISO-8859-1\r\nVary: *\r\nCache-Control: max-age=0, no-store\r\n",
	"text/html;charset=\"\\\\\"", "multipart/form-data; boundary=----x", "TEXT/HTML ; CHARSET = UTF-8 ",
}

HTTP_TOKENS := []string{"\r\n", "\n", ":", ";", ",", "=", "\"", "\\", " ", "\t", "HTTP/1.1 ", "Content-Type", "charset", "text/html", "*/*", "\x00", "\x7f", "\xff"}

COOKIE_SEEDS := []string{
	"a=b",
	"__Host-id=1; Secure; Path=/; SameSite=Strict; HttpOnly",
	"__Secure-x=y; Domain=.example.org; Max-Age=-1; Expires=Wed, 21 Oct 2015 07:28:00 GMT; Partitioned",
	"=novalue; Path=; Domain=; SameSite=None; Secure", "name=\"quoted value\"; Max-Age=99999999999999999999",
	"Thu, 01 Jan 1970 00:00:00 GMT", "Sunday, 06-Nov-94 08:49:37 GMT", "Sun Nov  6 08:49:37 1994", "1 Jan 99 23:59:60",
}

COOKIE_TOKENS := []string{";", "=", ",", " ", "\"", "Path=", "Domain=", "Expires=", "Max-Age=", "SameSite=", "Secure", "HttpOnly", "Partitioned", "__Host-", "__Secure-", "GMT", ":", "\x00", "\x7f"}

CSP_SEEDS := []string{
	"default-src 'self'; script-src 'nonce-abc' 'strict-dynamic' https: 'unsafe-inline'; object-src 'none'",
	"script-src 'sha256-47DEQpj8HBSa+/TImW+5JCeuQeRkm5NMpJWZG3hSuFU=' 'unsafe-eval' 'wasm-unsafe-eval'; style-src *.example.org:* http://a.b:8080/path/",
	"img-src data: blob: https://*.cdn.example.org/img/; frame-ancestors 'none'; base-uri 'self'; form-action 'self' https://x",
	"default-src 'none', script-src 'self'; report-uri /r; upgrade-insecure-requests; sandbox allow-scripts",
	"connect-src ws: wss://e.org:443 'report-sample'; worker-src 'self' blob:; trusted-types a b 'allow-duplicates'; require-trusted-types-for 'script'",
}

CSP_TOKENS := []string{
	";", ",", " ", "'self'", "'none'", "'unsafe-inline'", "'unsafe-eval'", "'strict-dynamic'", "'nonce-", "'sha256-", "'sha384-", "'sha512-",
	"*", "*.", "https:", "data:", "blob:", ":*", ":443", "/", "default-src", "script-src", "style-src", "img-src", "frame-ancestors", "'",
}

target_http :: proc(data: []u8) {
	text := string(data)
	h := http.parse_header_block(text)
	defer http.headers_destroy(&h)
	_, _ = http.get_header(h, "content-type")
	_ = http.get_all(h, "set-cookie")
	_ = http.unsafe_request_header_names(h)
	m, _ := http.extract_mime(h)
	http.mime_destroy(&m)
	direct, _ := http.parse_mime(text)
	http.mime_destroy(&direct)
}

target_cookies :: proc(data: []u8) {
	text := string(data)
	settings := cookies.settings_default()
	_, _ = cookies.parse_set_cookie(text, settings)
	_, _ = cookies.parse_cookie_date(text)
}

target_csp :: proc(data: []u8) {
	list: csp.Policy_List
	defer csp.list_destroy(&list)
	csp.parse_header(&list, string(data), len(data) % 2 == 0 ? csp.Disposition.Enforce : csp.Disposition.Report_Only)
	self, _ := url.origin_parse("https://example.org")
	defer url.origin_destroy(&self)
	// (requests that the parsed sources must match or refuse: same origin, a subdomain with a port and a path, a scheme only)
	targets := [?]string{"https://example.org/a.js", "http://cdn.example.org:8080/img/x.png?q", "data:image/png;base64,AA", "wss://e.org/socket"}
	for href in targets {
		u, ok := url.parse(href)
		if ok {
			for k in csp.Directive_Kind { _ = csp.check_request(&list, k, u, self, len(data) % 3 == 0, "abc") }
		}
		url.destroy(&u)
	}
	_ = csp.check_nonce(&list, .Script_Src, "abc")
	_ = csp.has_directive(&list, "script-src")
}
