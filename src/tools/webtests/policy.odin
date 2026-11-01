#+private file
// The network policy layer (package fetch) against the test server: request headers, CORS and preflights, cookies, redirects, Content
// Security Policy, mixed content, HSTS, schemes, MIME checks, local files, cancellation.
package webtests

import "core:encoding/json"
import "core:os"
import "core:strings"
import "core:testing"
import "wb:base"
import "wb:cookies"
import "wb:csp"
import "wb:fetch"
import "wb:http"
import "wb:net"
import "wb:tools/testenv"
import "wb:url"

// The default block of ports: every address goes through testenv.url.
A :: "http://127.0.0.1:8765"
B :: "http://localhost:8765"        // a different site from A
C :: "http://localhost:8767"        // the same site as B, a different origin
SECURE_PAGE :: "https://127.0.0.1:8766/page.html"
INSECURE :: "http://insecure.invalid/x"
INSECURE_IMAGE :: "http://insecure.invalid/x.png"
BLOCKED_PORT_URL :: "http://127.0.0.1:22/"
SITE :: "build/policy_site"
OUTSIDE_FILE :: "build/policy_other.txt"
BODY_CAP :: 1 << 20
BIG_BODY :: "/big?mb=50"
MIN_MODULE_BYTES :: 100
HSTS_HEADER :: "max-age=3600"
RUN_LIMIT :: 120.0
SLOW_BYTES_THAT_TAKE_A_SERVER_TICK :: 2      // /slow sends a byte at each of its ticks

Result :: struct {
	done:      bool,
	failed:    bool,
	error:     fetch.Error_Kind,
	detail:    string,
	status:    int,
	type:      fetch.Response_Type,
	got_response: bool,
	usable:    bool,
	redirected: bool,
	final_url: string,
	headers:   http.Headers,
	body:      string,
	mime:      string,
}

last: Result   // the most recent result, said with a failure

// A check on what just came back.
expect :: proc(t: ^testing.T, ok: bool, what: string, loc := #caller_location) {
	testing.expectf(t, ok, "%s   [last: failed=%v error=%v status=%d detail=%q body=%q]", what, last.failed, last.error, last.status, last.detail, last.body[:min(len(last.body), 60)], loc = loc)
}

// What a test keeps of its requests, until its end: a temporary allocator (the runner frees it after each test).
on_event :: proc(user: rawptr, task: base.Handle, ev: ^fetch.Event) {
	r := (^Result)(user)
	context.allocator = base.process_context().temp_allocator
	switch ev.kind {
	case .Response:
		r.got_response = true
		r.status, r.type, r.usable, r.redirected = ev.response.status, ev.response.type, ev.response.body_usable, ev.response.redirected
		r.final_url = strings.clone(ev.response.url)
		r.headers = http.headers_clone(ev.response.headers)
		if ev.response.has_mime { r.mime = strings.clone(http.mime_essence(ev.response.mime)) }
	case .Data:
		r.body = strings.concatenate({r.body, string(ev.data)})
	case .Done:
		r.done = true
		if len(ev.data) > 0 { r.body = strings.clone(string(ev.data)) }
	case .Failed:
		r.done, r.failed = true, true
		r.error = ev.error
		r.detail = strings.clone(ev.detail)
	}
}

// Runs a request and waits for its end.
run_fetch :: proc(t: ^testing.T, d: fetch.Request_Desc) -> Result {
	r := new(Result, context.temp_allocator)
	fetch.start(&loader, {request = d, on_event = on_event, user = r, collect = true})
	if !wait_until(t, d.url, r, proc(r: ^Result) -> bool { return r.done }, RUN_LIMIT) { r.failed, r.detail = true, "timeout" }
	last = r^
	return r^
}

env :: proc(t: ^testing.T, doc_url: string) -> ^fetch.Environment {
	u, _ := url.parse_absolute(doc_url, context.temp_allocator)
	e := new(fetch.Environment)
	e^ = fetch.environment_make(u)
	testing.cleanup(t, proc(ptr: rawptr) { e := (^fetch.Environment)(ptr); fetch.environment_destroy(e); free(e) }, e)
	return e
}

get :: proc(t: ^testing.T, target: string, from: ^fetch.Environment, mode := fetch.Mode.Cors, creds := fetch.Credentials.Same_Origin) -> Result {
	return run_fetch(t, {url = target, mode = mode, credentials = creds, initiator = from, guard = .Request})
}

echo :: proc(r: Result) -> map[string]string {
	out := make(map[string]string, 16, context.temp_allocator)
	v, err := json.parse(transmute([]byte)r.body, allocator = context.temp_allocator)
	if err != nil { return out }
	if obj, ok := v.(json.Object); ok {
		for k, val in obj { if s, is_str := val.(json.String); is_str { out[k] = string(s) } }
	}
	return out
}

// Nothing of the profile's from another test: no cookie, no preflight remembered, third-party cookies blocked. The next test finds it so too.
fresh_profile :: proc(t: ^testing.T) {
	forget :: proc(_: rawptr) {
		cookies.clear_all(&profile.jar)
		fetch.preflight_cache_destroy(&profile.preflights)
		profile.preflights = fetch.preflight_cache_make()
	}
	forget(nil)
	third_party := profile.settings.third_party_cookies
	profile.settings.third_party_cookies = .Block
	testing.cleanup(t, proc(ptr: rawptr) { profile.settings.third_party_cookies = fetch.Third_Party_Cookies(uintptr(ptr)) }, rawptr(uintptr(third_party)))
	testing.cleanup(t, forget, nil)
}

@(test)
policy_same_origin_requests_and_their_headers :: proc(t: ^testing.T) {
	context.allocator = base.process_allocator()
	begin(t, .Net)
	defer end()
	serve(t)
	fresh_profile(t)
	doc := env(t, testenv.url(A + "/page.html"))

	r := get(t, testenv.url(A + "/echo-headers"), doc)
	h := echo(r)
	expect(t, !r.failed && r.type == .Basic && r.status == 200, "same-origin GET is a basic response")
	expect(t, h["referer"] == testenv.url(A + "/page.html"), "full referrer for same-origin")
	expect(t, h["sec-fetch-site"] == "same-origin" && h["sec-fetch-mode"] == "cors" && h["sec-fetch-dest"] == "empty", "Fetch Metadata headers")
	expect(t, h["origin"] == "", "no Origin on a same-origin GET")
	expect(t, h["accept-language"] != "" && h["accept"] == "*/*", "default Accept / Accept-Language")
	expect(t, r.mime == "application/json", "MIME type is extracted for the browser")

	r = run_fetch(t, {url = testenv.url(A + "/echo-headers"), method = "POST", body = transmute([]byte)string("12345"), mode = .Cors, initiator = doc, guard = .Request})
	expect(t, echo(r)["origin"] == testenv.url(A), "same-origin POST carries Origin")
	r = run_fetch(t, {url = testenv.url(A + "/echo-headers"), mode = .Cors, initiator = doc, no_referrer = true})
	expect(t, echo(r)["referer"] == "", "no-referrer request")
	r = run_fetch(t, {url = testenv.url(A + "/echo-headers"), mode = .Cors, initiator = doc, referrer_policy = .Origin})
	expect(t, echo(r)["referer"] == testenv.url(A + "/"), "origin-only referrer policy")
	r = run_fetch(t, {url = testenv.url(A + "/echo-headers"), mode = .Cors, initiator = doc, guard = .Request, headers = {{"Cookie", "evil=1"}, {"Host", "evil"}, {"Sec-Fetch-Site", "none"}, {"X-Fine", "ok"}}})
	h = echo(r)
	expect(t, !strings.contains(h["cookie"], "evil") && h["host"] != "evil" && h["sec-fetch-site"] == "same-origin" && h["x-fine"] == "ok", "script cannot set forbidden headers")
	r = run_fetch(t, {url = testenv.url(A + "/echo-headers"), mode = .Navigate, initiator = nil, headers = {{"Cookie", "mine=1"}}, guard = .None})
	expect(t, !r.failed && echo(r)["cookie"] == "mine=1", "browser-internal requests are not restricted")
}

@(test)
policy_requests_refused_before_the_network :: proc(t: ^testing.T) {
	context.allocator = base.process_allocator()
	begin(t, .Net)
	defer end()
	serve(t)
	doc := env(t, testenv.url(A + "/page.html"))

	r := run_fetch(t, {url = testenv.url(A + "/x"), mode = .Cors, initiator = doc, headers = {{"bad name", "x"}}})
	expect(t, r.failed && r.error == .Bad_Header, "invalid header name")
	r = run_fetch(t, {url = testenv.url(A + "/x"), method = "TRACE", mode = .Cors, initiator = doc})
	expect(t, r.failed && r.error == .Bad_Method, "forbidden method")
	r = run_fetch(t, {url = testenv.url(A + "/x"), mode = .Cors, initiator = doc, body = transmute([]byte)string("x")})
	expect(t, r.failed && r.error == .Bad_Method, "body on GET")
	r = run_fetch(t, {url = "http://", mode = .Cors, initiator = doc})
	expect(t, r.failed && r.error == .Bad_URL, "bad URL")
	r = run_fetch(t, {url = "ftp://example.com/", mode = .Cors, initiator = doc})
	expect(t, r.failed && r.error == .Bad_Scheme, "unsupported scheme")
	r = run_fetch(t, {url = BLOCKED_PORT_URL, mode = .Cors, initiator = doc})
	expect(t, r.failed && r.error == .Bad_Port, "blocked port")
	r = run_fetch(t, {url = testenv.url("http://user:pw@127.0.0.1:8765/"), mode = .Cors, initiator = doc})
	expect(t, r.failed && r.error == .Credentials_In_URL, "credentials in the URL of a fetch")
}

@(test)
policy_cors :: proc(t: ^testing.T) {
	context.allocator = base.process_allocator()
	begin(t, .Net)
	defer end()
	serve(t)
	fresh_profile(t)
	doc := env(t, testenv.url(A + "/page.html"))

	r := get(t, testenv.url(B + "/cors/none"), doc)
	expect(t, r.failed && r.error == .Blocked_Cors, "cross-origin without CORS headers is blocked")
	r = get(t, testenv.url(B + "/cors/open"), doc)
	expect(t, !r.failed && r.type == .Cors && r.body == "open", "Access-Control-Allow-Origin: *")
	r = get(t, testenv.url(B + "/echo-headers"), doc)
	h := echo(r)
	expect(t, h["origin"] == testenv.url(A) && h["sec-fetch-site"] == "cross-site", "Origin and cross-site metadata")
	expect(t, h["referer"] == testenv.url(A + "/"), "cross-origin referrer is origin only")
	r = get(t, testenv.url(B + "/cors/reflect"), doc)
	expect(t, !r.failed && r.type == .Cors, "reflected origin")
	r = get(t, testenv.url(B + "/cors/expose"), doc)
	expect(t, http.has_header(r.headers, "x-shown") && !http.has_header(r.headers, "x-hidden"), "only exposed headers are visible")
	expect(t, http.has_header(r.headers, "content-type"), "safelisted response headers are visible")

	r = get(t, testenv.url(B + "/cors/none"), doc, .No_Cors)
	expect(t, !r.failed && r.type == .Opaque && r.status == 0 && len(r.headers.list) == 0 && !r.usable, "no-cors cross-origin is opaque")
	r = get(t, testenv.url(B + "/cors/none"), doc, .Same_Origin)
	expect(t, r.failed && r.error == .Blocked_Same_Origin, "same-origin mode refuses cross-origin")
	r = get(t, testenv.url(C + "/cors/open"), env(t, testenv.url(B + "/p")))
	expect(t, !r.failed && r.type == .Cors, "same-site but cross-origin still needs CORS")
	h = echo(get(t, testenv.url(C + "/echo-headers"), env(t, testenv.url(B + "/p"))))
	expect(t, h["sec-fetch-site"] == "same-site", "Sec-Fetch-Site: same-site")
}

@(test)
policy_cors_with_credentials :: proc(t: ^testing.T) {
	context.allocator = base.process_allocator()
	begin(t, .Net)
	defer end()
	serve(t)
	fresh_profile(t)
	doc := env(t, testenv.url(A + "/page.html"))

	r := get(t, testenv.url(B + "/cors/open"), doc, .Cors, .Include)
	expect(t, r.failed && r.error == .Blocked_Cors, "credentials + wildcard origin is refused")
	r = get(t, testenv.url(B + "/cors/creds"), doc, .Cors, .Include)
	expect(t, !r.failed && r.type == .Cors, "credentials with a matching origin and Allow-Credentials")
	r = get(t, testenv.url(B + "/cors/reflect"), doc, .Cors, .Include)
	expect(t, r.failed && r.error == .Blocked_Cors, "credentials need Access-Control-Allow-Credentials")
}

preflights_seen :: proc(t: ^testing.T) -> int {
	r := run_fetch(t, {url = testenv.url(A + "/cors/preflights"), mode = .Same_Origin, initiator = env(t, testenv.url(A + "/p"))})
	n := 0
	for c in r.body { if c >= '0' && c <= '9' { n = n * 10 + int(c - '0') } }
	return n
}

send :: proc(t: ^testing.T, method: string, target: string, headers: []fetch.Header_Pair) -> Result {
	return run_fetch(t, {url = target, method = method, body = transmute([]byte)string("abc"), headers = headers, mode = .Cors, initiator = env(t, testenv.url(A + "/p")), guard = .Request})
}

@(test)
policy_preflights :: proc(t: ^testing.T) {
	context.allocator = base.process_allocator()
	begin(t, .Net)
	defer end()
	serve(t)
	fresh_profile(t)
	before := preflights_seen(t)
	r := send(t, "PUT", testenv.url(B + "/cors/api"), {{"X-Token", "t1"}})
	expect(t, !r.failed && r.body == `PUT token="t1" body=3`, "PUT with a custom header after a preflight")
	expect(t, preflights_seen(t) == before + 1, "exactly one preflight was sent")
	r = send(t, "PUT", testenv.url(B + "/cors/api"), {{"X-Token", "t2"}})
	expect(t, !r.failed && preflights_seen(t) == before + 1, "the preflight is cached")
	r = send(t, "DELETE", testenv.url(B + "/cors/api"), {{"X-Token", "t3"}})
	expect(t, !r.failed, "DELETE is allowed too")
	expect(t, preflights_seen(t) == before + 1, "the cached preflight covers every method the server listed")
	r = send(t, "PATCH", testenv.url(B + "/cors/api"), {})
	expect(t, r.failed && r.error == .Blocked_Preflight, "a method the server does not list is refused")
	r = send(t, "PUT", testenv.url(B + "/cors/api"), {{"X-Unlisted", "1"}})
	expect(t, r.failed && r.error == .Blocked_Preflight, "a header the server does not list is refused")
	r = send(t, "POST", testenv.url(B + "/cors/api"), {{"Content-Type", "application/json"}})
	expect(t, !r.failed, "a non-safelisted Content-Type triggers (and passes) a preflight")
	r = send(t, "PUT", testenv.url(B + "/cors/bad-preflight"), {})
	expect(t, r.failed && r.error == .Blocked_Preflight && !strings.contains(r.body, "reached"), "a failing preflight stops the request")
	r = send(t, "POST", testenv.url(B + "/cors/api"), {{"Content-Type", "text/plain"}})
	expect(t, !r.failed, "simple requests need no preflight")
}

@(test)
policy_cookies :: proc(t: ^testing.T) {
	context.allocator = base.process_allocator()
	begin(t, .Net)
	defer end()
	serve(t)
	fresh_profile(t)
	doc := env(t, testenv.url(A + "/page.html"))

	r := run_fetch(t, {url = testenv.url(A + "/cookie/set?raw=sid=abc%3B%20Path=/&raw=pref=1%3B%20Path=/"), mode = .Navigate, credentials = .Include, initiator = nil})
	expect(t, !r.failed && cookies.count(&profile.jar) == 2, "Set-Cookie headers are stored")
	r = get(t, testenv.url(A + "/cookie/show"), doc, .Same_Origin, .Same_Origin)
	expect(t, r.body == "sid=abc; pref=1", "cookies are sent same-origin")
	r = get(t, testenv.url(A + "/cookie/show"), doc, .Same_Origin, .Omit)
	expect(t, r.body == "", "credentials: omit sends nothing")
	r = run_fetch(t, {url = testenv.url(A + "/cookie/set?raw=gone=1%3B%20Max-Age=60"), mode = .Cors, credentials = .Omit, initiator = doc})
	expect(t, cookies.count(&profile.jar) == 2, "credentials: omit stores nothing")
	r = run_fetch(t, {url = testenv.url(A + "/cookie/set?raw=h=1%3B%20HttpOnly%3B%20Path=/&raw=bad=1%3B%20Domain=example.org"), mode = .Navigate, credentials = .Include, initiator = nil})
	expect(t, cookies.count(&profile.jar) == 3, "invalid cookies are dropped, HttpOnly kept")
	r = get(t, testenv.url(A + "/echo-headers"), doc, .Same_Origin, .Same_Origin)
	expect(t, strings.contains(echo(r)["cookie"], "h=1"), "HttpOnly cookies are sent by the browser")
}

@(test)
policy_third_party_cookies_and_same_site :: proc(t: ^testing.T) {
	context.allocator = base.process_allocator()
	begin(t, .Net)
	defer end()
	serve(t)
	fresh_profile(t)
	doc := env(t, testenv.url(A + "/page.html"))

	run_fetch(t, {url = testenv.url(B + "/cookie/set?raw=lax=1%3B%20Path=/&raw=none=1%3B%20SameSite=None%3B%20Secure%3B%20Path=/"), mode = .Navigate, credentials = .Include, initiator = nil})
	expect(t, cookies.count(&profile.jar) == 2, "first-party cookies for B (localhost is a secure context)")
	r := get(t, testenv.url(B + "/cookie/show"), doc, .Cors, .Include)
	expect(t, !r.failed && r.body == "", "third-party cookies are blocked by policy")
	profile.settings.third_party_cookies = .Allow
	// (partitioned, as it is by default, the cookies B set as a top-level site are not the ones B gets inside A: storage_access, storage_partition_test)
	r = get(t, testenv.url(B + "/cookie/show"), doc, .Cors, .Include)
	expect(t, r.body == "", "with the policy relaxed, a partitioned third party does not get the cookies it has as a first party")
	profile.settings.partitioned = false
	defer profile.settings.partitioned = true
	r = get(t, testenv.url(B + "/cookie/show"), doc, .Cors, .Include)
	expect(t, r.body == "none=1", "with the policy relaxed and no partitioning only SameSite=None cookies travel cross-site")
	profile.settings.partitioned = true
	profile.settings.third_party_cookies = .Block
	r = run_fetch(t, {url = testenv.url(B + "/cookie/show"), mode = .Navigate, credentials = .Include, initiator = doc, user_activation = true})
	expect(t, r.body == "lax=1; none=1" || r.body == "none=1; lax=1", "a top-level cross-site GET navigation sends Lax cookies")
	r = run_fetch(t, {url = testenv.url(B + "/cookie/show"), method = "POST", body = transmute([]byte)string("x"), mode = .Navigate, credentials = .Include, initiator = doc})
	expect(t, r.body == "none=1", "a cross-site POST navigation does not send Lax cookies")
	r = run_fetch(t, {url = testenv.url(B + "/cookie/set?raw=x=1%3B%20Path=/"), mode = .Cors, credentials = .Include, initiator = doc})
	expect(t, r.failed, "(CORS failure) cross-site subresource")
	r = run_fetch(t, {url = testenv.url(B + "/cookie/show"), mode = .Navigate, credentials = .Include, initiator = nil})
	expect(t, r.body == "lax=1; none=1" || r.body == "none=1; lax=1", "typed URL is first-party")
}

redirect_post :: proc(t: ^testing.T, code: string) -> Result {
	target := strings.concatenate({testenv.url(A), "/redirect-to?code=", code, "&to=/echo-method"}, context.temp_allocator)
	return run_fetch(t, {url = target, method = "POST", body = transmute([]byte)string("hello"), mode = .Cors, initiator = env(t, testenv.url(A + "/p")), guard = .Request})
}

@(test)
policy_redirects :: proc(t: ^testing.T) {
	context.allocator = base.process_allocator()
	begin(t, .Net)
	defer end()
	serve(t)
	fresh_profile(t)
	doc := env(t, testenv.url(A + "/page.html"))

	r := get(t, testenv.url(A + "/redirect-chain?n=3"), doc, .Same_Origin)
	expect(t, !r.failed && r.redirected && r.body == "end of chain" && strings.has_suffix(r.final_url, "?n=0"), "a chain of redirects is followed")
	r = get(t, testenv.url(A + "/redirect-loop"), doc, .Same_Origin)
	expect(t, r.failed && r.error == .Redirect_Loop, "redirect loop is stopped at 20")
	r = run_fetch(t, {url = testenv.url(A + "/redirect-chain?n=1"), mode = .Same_Origin, redirect = .Error, initiator = doc})
	expect(t, r.failed && r.error == .Redirect_Error, "redirect: error")
	r = run_fetch(t, {url = testenv.url(A + "/redirect-chain?n=1"), mode = .Same_Origin, redirect = .Manual, initiator = doc})
	expect(t, !r.failed && r.type == .Opaque_Redirect, "redirect: manual")

	expect(t, redirect_post(t, "302").body == "GET 0", "302 turns POST into GET")
	expect(t, redirect_post(t, "303").body == "GET 0", "303 turns POST into GET")
	expect(t, redirect_post(t, "307").body == "POST 5", "307 keeps the method and the body")
	expect(t, redirect_post(t, "308").body == "POST 5", "308 keeps the method and the body")

	r = get(t, testenv.url(A + "/redirect-to?to=" + B + "/cors/reflect"), doc)
	expect(t, !r.failed && r.type == .Cors && r.redirected, "same-origin request redirected to a CORS-enabled origin")
	r = get(t, testenv.url(A + "/redirect-to?to=" + B + "/cors/none"), doc)
	expect(t, r.failed && r.error == .Blocked_Cors, "the redirect target must pass the CORS check")
	r = get(t, testenv.url(A + "/redirect-to?to=file:///C:/Windows/win.ini"), doc)
	expect(t, r.failed && r.error == .Bad_Redirect, "redirect to file: is refused")
	r = get(t, testenv.url(A + "/redirect-to?to=data:text/plain,hi"), doc)
	expect(t, r.failed && r.error == .Bad_Redirect, "redirect to data: is refused")
	r = run_fetch(t, {url = testenv.url(A + "/redirect-to?to=" + B + "/echo-headers"), mode = .Cors, initiator = doc, guard = .Request, headers = {{"Authorization", "Bearer secret"}}})
	expect(t, !r.failed && echo(r)["authorization"] == "", "Authorization is dropped on a cross-origin redirect")
	r = get(t, testenv.url(A + "/redirect-to?to=" + BLOCKED_PORT_URL), doc, .Same_Origin)
	expect(t, r.failed && r.error == .Bad_Port, "every hop is re-checked (bad port)")
}

@(test)
policy_content_security_policy :: proc(t: ^testing.T) {
	context.allocator = base.process_allocator()
	begin(t, .Net)
	defer end()
	serve(t)
	violations := 0
	cenv := env(t, testenv.url(A + "/page.html"))
	cenv.on_violation = proc(user: rawptr, v: csp.Violation) { (^int)(user)^ += 1 }
	cenv.violation_user = &violations
	csp.parse_header(&cenv.policies, testenv.url("default-src 'self'; connect-src 'self' http://localhost:8765; script-src 'self'"), .Enforce)

	r := get(t, testenv.url(A + "/echo-headers"), cenv)
	expect(t, !r.failed, "'self' is allowed")
	r = get(t, testenv.url(B + "/cors/open"), cenv)
	expect(t, !r.failed, "a host listed in connect-src is allowed")
	r = get(t, testenv.url(C + "/cors/open"), cenv)
	expect(t, r.failed && r.error == .Blocked_Csp, "a host that is not listed is blocked")
	expect(t, violations == 1, "the violation was reported")
	r = get(t, "data:text/plain,x", cenv)
	expect(t, r.failed && r.error == .Blocked_Csp, "data: needs to be listed")
	r = run_fetch(t, {url = testenv.url(C + "/cors/open"), mode = .No_Cors, destination = .Image, initiator = cenv})
	expect(t, r.failed && r.error == .Blocked_Csp, "img-src falls back to default-src")
	r = run_fetch(t, {url = testenv.url(A + "/wasm"), mode = .Cors, destination = .Script, initiator = cenv})
	expect(t, !r.failed, "script-src 'self' allows a same-origin module")
	r = run_fetch(t, {url = testenv.url(B + "/wasm"), mode = .Cors, destination = .Script, initiator = cenv})
	expect(t, r.failed && r.error == .Blocked_Csp, "script-src blocks other origins before CORS is even consulted")
	r = get(t, testenv.url(A + "/redirect-to?to=" + C + "/cors/open"), cenv)
	expect(t, r.failed && r.error == .Blocked_Csp, "redirect targets are checked too")

	report := env(t, testenv.url(A + "/page.html"))
	report.on_violation = cenv.on_violation
	report.violation_user = &violations
	csp.parse_header(&report.policies, "connect-src 'none'", .Report_Only)
	before := violations
	r = get(t, testenv.url(A + "/echo-headers"), report)
	expect(t, !r.failed && violations == before + 1, "report-only policies report but never block")

	up := env(t, testenv.url(SECURE_PAGE))
	csp.parse_header(&up.policies, "upgrade-insecure-requests", .Enforce)
	r = run_fetch(t, {url = INSECURE, mode = .Cors, initiator = up})
	expect(t, r.failed && r.error == .Transport, "upgrade-insecure-requests upgrades instead of blocking")
	blockall := env(t, testenv.url(SECURE_PAGE))
	csp.parse_header(&blockall.policies, "block-all-mixed-content", .Enforce)
	r = run_fetch(t, {url = INSECURE_IMAGE, mode = .No_Cors, destination = .Image, initiator = blockall})
	expect(t, r.failed && r.error == .Blocked_Mixed_Content, "block-all-mixed-content blocks even images")
}

@(test)
policy_mixed_content :: proc(t: ^testing.T) {
	context.allocator = base.process_allocator()
	begin(t, .Net)
	defer end()
	serve(t)
	secure := env(t, testenv.url(SECURE_PAGE))
	r := run_fetch(t, {url = INSECURE, mode = .Cors, initiator = secure})
	expect(t, r.failed && r.error == .Blocked_Mixed_Content, "insecure fetch from a secure document is blocked")
	r = run_fetch(t, {url = INSECURE_IMAGE, mode = .No_Cors, destination = .Image, initiator = secure})
	expect(t, r.failed && r.error == .Transport, "insecure images are upgraded, not blocked")
	r = run_fetch(t, {url = testenv.url(A + "/echo-headers"), mode = .Cors, initiator = secure})
	expect(t, !r.failed && r.status == 200, "loopback http is potentially trustworthy (allowed)")
}

@(test)
policy_hsts :: proc(t: ^testing.T) {
	context.allocator = base.process_allocator()
	begin(t, .Net)
	defer end()
	serve(t)
	doc := env(t, testenv.url(A + "/page.html"))
	fetch.hsts_note(&profile.hsts, "localhost", HSTS_HEADER, fetch.now_ms())
	r := get(t, testenv.url(B + "/echo-headers"), doc, .No_Cors)
	expect(t, r.failed && r.error == .Transport, "an HSTS host is upgraded to https before anything is sent")
	fetch.hsts_destroy(&profile.hsts)
	profile.hsts = fetch.hsts_make()
}

@(test)
policy_schemes_and_mime_types :: proc(t: ^testing.T) {
	context.allocator = base.process_allocator()
	begin(t, .Net)
	defer end()
	serve(t)
	doc := env(t, testenv.url(A + "/page.html"))
	r := get(t, "data:text/plain;charset=utf-8,hello%20data", doc)
	expect(t, !r.failed && r.body == "hello data" && r.mime == "text/plain", "data: URLs work")
	r = run_fetch(t, {url = "data:text/html,x", mode = .Navigate, initiator = doc})
	expect(t, r.failed && r.error == .Unsupported, "top-level navigation to data: is blocked")
	r = run_fetch(t, {url = "about:blank", mode = .Navigate, initiator = nil})
	expect(t, !r.failed && r.status == 200 && r.mime == "text/html", "about:blank")

	r = run_fetch(t, {url = testenv.url(A + "/wasm"), mode = .Cors, destination = .Script, initiator = doc})
	expect(t, !r.failed && r.mime == "application/wasm" && len(r.body) > MIN_MODULE_BYTES, "a module served as application/wasm loads")
	r = run_fetch(t, {url = testenv.url(A + "/wasm-wrong"), mode = .Cors, destination = .Script, initiator = doc})
	expect(t, r.failed && r.error == .Bad_Mime, "a module served as text/html is refused")
	r = run_fetch(t, {url = testenv.url(B + "/wasm"), mode = .Cors, destination = .Script, initiator = doc})
	expect(t, r.failed && r.error == .Blocked_Cors, "cross-origin modules need CORS")
	r = run_fetch(t, {url = testenv.url(A + BIG_BODY), mode = .Same_Origin, initiator = doc, max_body = BODY_CAP})
	expect(t, r.failed && r.error == .Body_Too_Large, "response size cap")
}

under :: proc(root, rel: string) -> string { return strings.concatenate({root, rel}, context.temp_allocator) }

@(test)
policy_local_files :: proc(t: ^testing.T) {
	context.allocator = base.process_allocator()
	begin(t, .Net)
	defer end()
	serve(t)
	doc := env(t, testenv.url(A + "/page.html"))
	_ = os.make_directory_all(SITE + "/sub")
	_ = os.write_entire_file(SITE + "/index.html", transmute([]byte)string("<h1>hi</h1>"))
	_ = os.write_entire_file(SITE + "/sub/data.txt", transmute([]byte)string("deep"))
	_ = os.write_entire_file(OUTSIDE_FILE, transmute([]byte)string("outside"))
	cwd, _ := os.get_working_directory(context.temp_allocator)
	slashed, _ := strings.replace_all(cwd, "\\", "/", context.temp_allocator)
	root := strings.concatenate({"file:///", slashed, "/", SITE, "/"}, context.temp_allocator)
	fdoc := env(t, under(root, "index.html"))

	r := run_fetch(t, {url = under(root, "sub/data.txt"), mode = .Cors, initiator = fdoc})
	expect(t, !r.failed && r.body == "deep" && r.mime == "text/plain", "a file: document reads files in its own tree")
	r = run_fetch(t, {url = under(root, "../policy_other.txt"), mode = .Cors, initiator = fdoc})
	expect(t, r.failed && r.error == .Blocked_File, "...but not outside it")
	r = run_fetch(t, {url = under(root, "missing.txt"), mode = .Cors, initiator = fdoc})
	expect(t, r.failed, "a missing file fails")
	r = run_fetch(t, {url = under(root, "index.html"), mode = .Cors, initiator = doc})
	expect(t, r.failed && r.error == .Blocked_File, "web pages never read local files")
	r = run_fetch(t, {url = under(root, "../policy_other.txt"), mode = .Navigate, initiator = nil})
	expect(t, !r.failed && r.body == "outside", "the browser UI may open any file")
	r = run_fetch(t, {url = testenv.url(A + "/cors/none"), mode = .Cors, initiator = fdoc})
	expect(t, r.failed && r.error == .Blocked_Cors, "a file: document has a null origin: CORS applies")
	r = run_fetch(t, {url = testenv.url(A + "/cors/open"), mode = .Cors, initiator = fdoc})
	expect(t, !r.failed && r.type == .Cors, "...and a wildcard server accepts it")
}

@(test)
policy_cancellation :: proc(t: ^testing.T) {
	context.allocator = base.process_allocator()
	begin(t, .Net)
	defer end()
	serve(t)
	doc := env(t, testenv.url(A + "/page.html"))
	slow := testenv.url(A + "/slow")
	scope := base.scope_make("doc")
	r := new(Result, context.temp_allocator)
	fetch.start(&loader, {request = {url = slow, mode = .Same_Origin, initiator = doc}, on_event = on_event, user = r, scope = scope})
	wait_until(t, "the first byte of the slow body", r, proc(r: ^Result) -> bool { return len(r.body) > 0 })
	expect(t, fetch.in_flight(&loader) == 1, "a task is in flight")
	seen := r^
	base.scope_close(scope)
	expect(t, fetch.in_flight(&loader) == 0 && net.in_flight(&client) == 0, "closing the scope cancels the task and its transport")

	// another slow body gets a byte of a later tick of the server: the cancelled one would have had its own by then
	other_scope := base.scope_make("doc")
	defer base.scope_close(other_scope)
	other := new(Result, context.temp_allocator)
	fetch.start(&loader, {request = {url = slow, mode = .Same_Origin, initiator = doc}, on_event = on_event, user = other, scope = other_scope})
	wait_until(t, "a later tick of the server", other, proc(r: ^Result) -> bool { return len(r.body) >= SLOW_BYTES_THAT_TAKE_A_SERVER_TICK })
	expect(t, !r.done && r.got_response == seen.got_response && r.body == seen.body, "no event is delivered after cancellation")
}
