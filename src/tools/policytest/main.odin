// End-to-end test of the network policy layer (package fetch) against tools\testserver: CORS, preflights, cookies,
// redirects, referrer policy, mixed content, schemes, MIME checks, HSTS, cancellation.
//   policytest.exe            (run from the repository root with build\testserver.exe running)
package policytest

import _ "wb:tools/crashtrace"   // a crash prints its symbolized stack

import "core:encoding/json"
import "core:fmt"
import vmem "core:mem/virtual"
import "core:os"
import "core:strings"
import "core:time"
import "wb:base"
import "wb:cookies"
import "wb:csp"
import "wb:fetch"
import "wb:host"
import "wb:http"
import "wb:net"
import "wb:url"
import "wb:tools/testenv"

failures, checks: int
last: Result   // the most recent result, printed with a failure

loop:     host.Loop
client:   net.Client
blocking: host.Blocking_Pool
profile:  fetch.Profile
loader:   fetch.Loader

// The default block of ports: every address goes through testenv.url (the run's block, WREN_TEST_BASE_PORT).
A :: "http://127.0.0.1:8765"
B :: "http://localhost:8765"        // different site from A
C :: "http://localhost:8767"        // same site as B, different origin

check :: proc(ok: bool, what: string, loc := #caller_location) {
	checks += 1
	if !ok { failures += 1; fmt.printf("FAIL %s  (line %d)   [last: failed=%v error=%v status=%d detail=%q body=%q]\n", what, loc.line, last.failed, last.error, last.status, last.detail, last.body[:min(len(last.body), 60)]) }
}

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

// the results (texts, headers), kept until the end of the run
results: vmem.Arena

on_event :: proc(user: rawptr, task: base.Handle, ev: ^fetch.Event) {
	r := (^Result)(user)
	context.allocator = vmem.arena_allocator(&results)
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

pump :: proc(r: ^Result) {
	start := time.tick_now()
	for !r.done && time.duration_seconds(time.tick_since(start)) < 120 { host.loop_wait(&loop, 20) }   // the bound only ends a failing run
}

// Runs a request and waits for its end.
run :: proc(d: fetch.Request_Desc) -> Result {
	r := new(Result, vmem.arena_allocator(&results))
	fetch.start(&loader, {request = d, on_event = on_event, user = r, collect = true})
	pump(r)
	if !r.done { r.failed, r.detail = true, "timeout" }
	last = r^
	return r^
}

envs: [dynamic]^fetch.Environment
env :: proc(doc_url: string) -> ^fetch.Environment {
	u, _ := url.parse_absolute(doc_url, context.temp_allocator)
	e := new(fetch.Environment)
	e^ = fetch.environment_make(u)
	append(&envs, e)
	return e
}

get :: proc(target: string, from: ^fetch.Environment, mode := fetch.Mode.Cors, creds := fetch.Credentials.Same_Origin) -> Result {
	return run({url = target, mode = mode, credentials = creds, initiator = from, guard = .Request})
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

reset_state :: proc() {
	cookies.clear_all(&profile.jar)
	fetch.preflight_cache_destroy(&profile.preflights)
	profile.preflights = fetch.preflight_cache_make()
	profile.settings.third_party_cookies = .Block
}

main :: proc() {
	context = testenv.context_of_process()
	host.loop_init(&loop)
	if !net.client_init(&client, &loop) { fmt.eprintln("net init failed"); os.exit(2) }
	host.blocking_init(&blocking, &loop, 2)
	profile = fetch.profile_make()
	fetch.loader_init(&loader, &loop, &client, &blocking, &profile)

	doc := env(testenv.url(A + "/page.html"))

	////////////////////////////////
	fmt.println("-- same-origin basics, request headers")
	{
		r := get(testenv.url(A + "/echo-headers"), doc)
		h := echo(r)
		check(!r.failed && r.type == .Basic && r.status == 200, "same-origin GET is a basic response")
		check(h["referer"] == testenv.url(A + "/page.html"), "full referrer for same-origin")
		check(h["sec-fetch-site"] == "same-origin" && h["sec-fetch-mode"] == "cors" && h["sec-fetch-dest"] == "empty", "Fetch Metadata headers")
		check(h["origin"] == "", "no Origin on a same-origin GET")
		check(h["accept-language"] != "" && h["accept"] == "*/*", "default Accept / Accept-Language")
		check(r.mime == "application/json", "MIME type is extracted for the browser")

		r = run({url = testenv.url(A + "/echo-headers"), method = "POST", body = transmute([]byte)string("12345"), mode = .Cors, initiator = doc, guard = .Request})
		check(echo(r)["origin"] == testenv.url(A), "same-origin POST carries Origin")
		r = run({url = testenv.url(A + "/echo-headers"), mode = .Cors, initiator = doc, no_referrer = true})
		check(echo(r)["referer"] == "", "no-referrer request")
		r = run({url = testenv.url(A + "/echo-headers"), mode = .Cors, initiator = doc, referrer_policy = .Origin})
		check(echo(r)["referer"] == testenv.url(A + "/"), "origin-only referrer policy")
		r = run({url = testenv.url(A + "/echo-headers"), mode = .Cors, initiator = doc, guard = .Request, headers = {{"Cookie", "evil=1"}, {"Host", "evil"}, {"Sec-Fetch-Site", "none"}, {"X-Fine", "ok"}}})
		h = echo(r)
		check(!strings.contains(h["cookie"], "evil") && h["host"] != "evil" && h["sec-fetch-site"] == "same-origin" && h["x-fine"] == "ok", "script cannot set forbidden headers")
		r = run({url = testenv.url(A + "/echo-headers"), mode = .Navigate, initiator = nil, headers = {{"Cookie", "mine=1"}}, guard = .None})
		check(!r.failed, "browser-internal requests are not restricted")

		r = run({url = testenv.url(A + "/x"), mode = .Cors, initiator = doc, headers = {{"bad name", "x"}}})
		check(r.failed && r.error == .Bad_Header, "invalid header name")
		r = run({url = testenv.url(A + "/x"), method = "TRACE", mode = .Cors, initiator = doc})
		check(r.failed && r.error == .Bad_Method, "forbidden method")
		r = run({url = testenv.url(A + "/x"), mode = .Cors, initiator = doc, body = transmute([]byte)string("x")})
		check(r.failed && r.error == .Bad_Method, "body on GET")
		r = run({url = "http://", mode = .Cors, initiator = doc})
		check(r.failed && r.error == .Bad_URL, "bad URL")
		r = run({url = "ftp://example.com/", mode = .Cors, initiator = doc})
		check(r.failed && r.error == .Bad_Scheme, "unsupported scheme")
		r = run({url = "http://127.0.0.1:22/", mode = .Cors, initiator = doc})
		check(r.failed && r.error == .Bad_Port, "blocked port")
		r = run({url = testenv.url("http://user:pw@127.0.0.1:8765/"), mode = .Cors, initiator = doc})
		check(r.failed && r.error == .Credentials_In_URL, "credentials in the URL of a fetch")
	}

	////////////////////////////////
	fmt.println("-- CORS")
	{
		r := get(testenv.url(B + "/cors/none"), doc)
		check(r.failed && r.error == .Blocked_Cors, "cross-origin without CORS headers is blocked")
		r = get(testenv.url(B + "/cors/open"), doc)
		check(!r.failed && r.type == .Cors && r.body == "open", "Access-Control-Allow-Origin: *")
		r = get(testenv.url(B + "/echo-headers"), doc)
		h := echo(r)
		check(h["origin"] == testenv.url(A) && h["sec-fetch-site"] == "cross-site", "Origin and cross-site metadata")
		check(h["referer"] == testenv.url(A + "/"), "cross-origin referrer is origin only")
		r = get(testenv.url(B + "/cors/reflect"), doc)
		check(!r.failed && r.type == .Cors, "reflected origin")
		r = get(testenv.url(B + "/cors/expose"), doc)
		check(http.has_header(r.headers, "x-shown") && !http.has_header(r.headers, "x-hidden"), "only exposed headers are visible")
		check(http.has_header(r.headers, "content-type"), "safelisted response headers are visible")

		r = get(testenv.url(B + "/cors/none"), doc, .No_Cors)
		check(!r.failed && r.type == .Opaque && r.status == 0 && len(r.headers.list) == 0 && !r.usable, "no-cors cross-origin is opaque")
		r = get(testenv.url(B + "/cors/none"), doc, .Same_Origin)
		check(r.failed && r.error == .Blocked_Same_Origin, "same-origin mode refuses cross-origin")
		r = get(testenv.url(C + "/cors/open"), env(testenv.url(B + "/p")))
		check(!r.failed && r.type == .Cors, "same-site but cross-origin still needs CORS")
		h = echo(get(testenv.url(C + "/echo-headers"), env(testenv.url(B + "/p"))))
		check(h["sec-fetch-site"] == "same-site", "Sec-Fetch-Site: same-site")

		// credentials
		r = get(testenv.url(B + "/cors/open"), doc, .Cors, .Include)
		check(r.failed && r.error == .Blocked_Cors, "credentials + wildcard origin is refused")
		r = get(testenv.url(B + "/cors/creds"), doc, .Cors, .Include)
		check(!r.failed && r.type == .Cors, "credentials with a matching origin and Allow-Credentials")
		r = get(testenv.url(B + "/cors/reflect"), doc, .Cors, .Include)
		check(r.failed && r.error == .Blocked_Cors, "credentials need Access-Control-Allow-Credentials")

		// preflight
		reset_state()
		count :: proc() -> int {
			r := run({url = testenv.url(A + "/cors/preflights"), mode = .Same_Origin, initiator = env(testenv.url(A + "/p"))})
			n := 0
			for c in r.body { if c >= '0' && c <= '9' { n = n * 10 + int(c - '0') } }
			return n
		}
		before := count()
		put := proc(method: string, target: string, headers: []fetch.Header_Pair) -> Result {
			return run({url = target, method = method, body = transmute([]byte)string("abc"), headers = headers, mode = .Cors, initiator = env(testenv.url(A + "/p")), guard = .Request})
		}
		r = put("PUT", testenv.url(B + "/cors/api"), {{"X-Token", "t1"}})
		check(!r.failed && r.body == `PUT token="t1" body=3`, "PUT with a custom header after a preflight")
		check(count() == before + 1, "exactly one preflight was sent")
		r = put("PUT", testenv.url(B + "/cors/api"), {{"X-Token", "t2"}})
		check(!r.failed && count() == before + 1, "the preflight is cached")
		r = put("DELETE", testenv.url(B + "/cors/api"), {{"X-Token", "t3"}})
		check(!r.failed, "DELETE is allowed too")
		check(count() == before + 1, "the cached preflight covers every method the server listed")
		r = put("PATCH", testenv.url(B + "/cors/api"), {})
		check(r.failed && r.error == .Blocked_Preflight, "a method the server does not list is refused")
		r = put("PUT", testenv.url(B + "/cors/api"), {{"X-Unlisted", "1"}})
		check(r.failed && r.error == .Blocked_Preflight, "a header the server does not list is refused")
		r = put("POST", testenv.url(B + "/cors/api"), {{"Content-Type", "application/json"}})
		check(!r.failed, "a non-safelisted Content-Type triggers (and passes) a preflight")
		r = put("PUT", testenv.url(B + "/cors/bad-preflight"), {})
		check(r.failed && r.error == .Blocked_Preflight && !strings.contains(r.body, "reached"), "a failing preflight stops the request")
		r = put("POST", testenv.url(B + "/cors/api"), {{"Content-Type", "text/plain"}})
		check(!r.failed, "simple requests need no preflight")
	}

	////////////////////////////////
	fmt.println("-- cookies")
	{
		reset_state()
		r := run({url = testenv.url(A + "/cookie/set?raw=sid=abc%3B%20Path=/&raw=pref=1%3B%20Path=/"), mode = .Navigate, credentials = .Include, initiator = nil})
		check(!r.failed && cookies.count(&profile.jar) == 2, "Set-Cookie headers are stored")
		r = get(testenv.url(A + "/cookie/show"), doc, .Same_Origin, .Same_Origin)
		check(r.body == "sid=abc; pref=1", "cookies are sent same-origin")
		r = get(testenv.url(A + "/cookie/show"), doc, .Same_Origin, .Omit)
		check(r.body == "", "credentials: omit sends nothing")
		r = run({url = testenv.url(A + "/cookie/set?raw=gone=1%3B%20Max-Age=60"), mode = .Cors, credentials = .Omit, initiator = doc})
		check(cookies.count(&profile.jar) == 2, "credentials: omit stores nothing")
		r = run({url = testenv.url(A + "/cookie/set?raw=h=1%3B%20HttpOnly%3B%20Path=/&raw=bad=1%3B%20Domain=example.org"), mode = .Navigate, credentials = .Include, initiator = nil})
		check(cookies.count(&profile.jar) == 3, "invalid cookies are dropped, HttpOnly kept")
		r = get(testenv.url(A + "/echo-headers"), doc, .Same_Origin, .Same_Origin)
		check(strings.contains(echo(r)["cookie"], "h=1"), "HttpOnly cookies are sent by the browser")

		// third parties and SameSite
		reset_state()
		run({url = testenv.url(B + "/cookie/set?raw=lax=1%3B%20Path=/&raw=none=1%3B%20SameSite=None%3B%20Secure%3B%20Path=/"), mode = .Navigate, credentials = .Include, initiator = nil})
		check(cookies.count(&profile.jar) == 2, "first-party cookies for B (localhost is a secure context)")
		r = get(testenv.url(B + "/cookie/show"), doc, .Cors, .Include)
		check(!r.failed && r.body == "", "third-party cookies are blocked by policy")
		profile.settings.third_party_cookies = .Allow
		r = get(testenv.url(B + "/cookie/show"), doc, .Cors, .Include)
		check(r.body == "none=1", "with the policy relaxed only SameSite=None cookies travel cross-site")
		profile.settings.third_party_cookies = .Block
		r = run({url = testenv.url(B + "/cookie/show"), mode = .Navigate, credentials = .Include, initiator = doc, user_activation = true})
		check(r.body == "lax=1; none=1" || r.body == "none=1; lax=1", "a top-level cross-site GET navigation sends Lax cookies")
		r = run({url = testenv.url(B + "/cookie/show"), method = "POST", body = transmute([]byte)string("x"), mode = .Navigate, credentials = .Include, initiator = doc})
		check(r.body == "none=1", "a cross-site POST navigation does not send Lax cookies")
		r = run({url = testenv.url(B + "/cookie/set?raw=x=1%3B%20Path=/"), mode = .Cors, credentials = .Include, initiator = doc})
		check(r.failed, "(CORS failure) cross-site subresource")
		r = run({url = testenv.url(B + "/cookie/show"), mode = .Navigate, credentials = .Include, initiator = nil})
		check(r.body == "lax=1; none=1" || r.body == "none=1; lax=1", "typed URL is first-party")
	}

	////////////////////////////////
	fmt.println("-- redirects")
	{
		reset_state()
		r := get(testenv.url(A + "/redirect-chain?n=3"), doc, .Same_Origin)
		check(!r.failed && r.redirected && r.body == "end of chain" && strings.has_suffix(r.final_url, "?n=0"), "a chain of redirects is followed")
		r = get(testenv.url(A + "/redirect-loop"), doc, .Same_Origin)
		check(r.failed && r.error == .Redirect_Loop, "redirect loop is stopped at 20")
		r = run({url = testenv.url(A + "/redirect-chain?n=1"), mode = .Same_Origin, redirect = .Error, initiator = doc})
		check(r.failed && r.error == .Redirect_Error, "redirect: error")
		r = run({url = testenv.url(A + "/redirect-chain?n=1"), mode = .Same_Origin, redirect = .Manual, initiator = doc})
		check(!r.failed && r.type == .Opaque_Redirect, "redirect: manual")

		post := proc(code: int) -> Result {
			target := fmt.tprintf("%s/redirect-to?code=%d&to=/echo-method", testenv.url(A), code)
			return run({url = target, method = "POST", body = transmute([]byte)string("hello"), mode = .Cors, initiator = env(testenv.url(A + "/p")), guard = .Request})
		}
		check(post(302).body == "GET 0", "302 turns POST into GET")
		check(post(303).body == "GET 0", "303 turns POST into GET")
		check(post(307).body == "POST 5", "307 keeps the method and the body")
		check(post(308).body == "POST 5", "308 keeps the method and the body")

		r = get(testenv.url(A + "/redirect-to?to=" + B + "/cors/reflect"), doc)
		check(!r.failed && r.type == .Cors && r.redirected, "same-origin request redirected to a CORS-enabled origin")
		r = get(testenv.url(A + "/redirect-to?to=" + B + "/cors/none"), doc)
		check(r.failed && r.error == .Blocked_Cors, "the redirect target must pass the CORS check")
		r = get(testenv.url(A + "/redirect-to?to=file:///C:/Windows/win.ini"), doc)
		check(r.failed && r.error == .Bad_Redirect, "redirect to file: is refused")
		r = get(testenv.url(A + "/redirect-to?to=data:text/plain,hi"), doc)
		check(r.failed && r.error == .Bad_Redirect, "redirect to data: is refused")
		r = run({url = testenv.url(A + "/redirect-to?to=" + B + "/echo-headers"), mode = .Cors, initiator = doc, guard = .Request, headers = {{"Authorization", "Bearer secret"}}})
		check(!r.failed && echo(r)["authorization"] == "", "Authorization is dropped on a cross-origin redirect")
		r = get(testenv.url(A + "/redirect-to?to=http://127.0.0.1:22/"), doc, .Same_Origin)
		check(r.failed && r.error == .Bad_Port, "every hop is re-checked (bad port)")
	}

	////////////////////////////////
	fmt.println("-- Content Security Policy")
	{
		violations := 0
		cenv := env(testenv.url(A + "/page.html"))
		cenv.on_violation = proc(user: rawptr, v: csp.Violation) { (^int)(user)^ += 1 }
		cenv.violation_user = &violations
		csp.parse_header(&cenv.policies, testenv.url("default-src 'self'; connect-src 'self' http://localhost:8765; script-src 'self'"), .Enforce)

		r := get(testenv.url(A + "/echo-headers"), cenv)
		check(!r.failed, "'self' is allowed")
		r = get(testenv.url(B + "/cors/open"), cenv)
		check(!r.failed, "a host listed in connect-src is allowed")
		r = get(testenv.url(C + "/cors/open"), cenv)
		check(r.failed && r.error == .Blocked_Csp, "a host that is not listed is blocked")
		check(violations == 1, "the violation was reported")
		r = get("data:text/plain,x", cenv)
		check(r.failed && r.error == .Blocked_Csp, "data: needs to be listed")
		r = run({url = testenv.url(C + "/cors/open"), mode = .No_Cors, destination = .Image, initiator = cenv})
		check(r.failed && r.error == .Blocked_Csp, "img-src falls back to default-src")
		r = run({url = testenv.url(A + "/wasm"), mode = .Cors, destination = .Script, initiator = cenv})
		check(!r.failed, "script-src 'self' allows a same-origin module")
		r = run({url = testenv.url(B + "/wasm"), mode = .Cors, destination = .Script, initiator = cenv})
		check(r.failed && r.error == .Blocked_Csp, "script-src blocks other origins before CORS is even consulted")
		r = get(testenv.url(A + "/redirect-to?to=" + C + "/cors/open"), cenv)
		check(r.failed && r.error == .Blocked_Csp, "redirect targets are checked too")

		report := env(testenv.url(A + "/page.html"))
		report.on_violation = cenv.on_violation
		report.violation_user = &violations
		csp.parse_header(&report.policies, "connect-src 'none'", .Report_Only)
		before := violations
		r = get(testenv.url(A + "/echo-headers"), report)
		check(!r.failed && violations == before + 1, "report-only policies report but never block")

		up := env(testenv.url("https://127.0.0.1:8766/page.html"))
		csp.parse_header(&up.policies, "upgrade-insecure-requests", .Enforce)
		r = run({url = "http://insecure.invalid/x", mode = .Cors, initiator = up})
		check(r.failed && r.error == .Transport, "upgrade-insecure-requests upgrades instead of blocking")
		blockall := env(testenv.url("https://127.0.0.1:8766/page.html"))
		csp.parse_header(&blockall.policies, "block-all-mixed-content", .Enforce)
		r = run({url = "http://insecure.invalid/x.png", mode = .No_Cors, destination = .Image, initiator = blockall})
		check(r.failed && r.error == .Blocked_Mixed_Content, "block-all-mixed-content blocks even images")
	}
	////////////////////////////////
	fmt.println("-- mixed content, HSTS, schemes, MIME")
	{
		secure := env(testenv.url("https://127.0.0.1:8766/page.html"))
		r := run({url = "http://insecure.invalid/x", mode = .Cors, initiator = secure})
		check(r.failed && r.error == .Blocked_Mixed_Content, "insecure fetch from a secure document is blocked")
		r = run({url = "http://insecure.invalid/x.png", mode = .No_Cors, destination = .Image, initiator = secure})
		check(r.failed && r.error != .Blocked_Mixed_Content, "insecure images are upgraded, not blocked")
		r = run({url = testenv.url(A + "/echo-headers"), mode = .Cors, initiator = secure})
		check(r.failed && r.error == .Transport || !r.failed, "loopback http is potentially trustworthy (allowed)")

		fetch.hsts_note(&profile.hsts, "localhost", "max-age=3600", fetch.now_ms())
		r = get(testenv.url(B + "/echo-headers"), doc, .No_Cors)
		check(r.failed && r.error == .Transport, "an HSTS host is upgraded to https before anything is sent")
		fetch.hsts_destroy(&profile.hsts)
		profile.hsts = fetch.hsts_make()

		r = get("data:text/plain;charset=utf-8,hello%20data", doc)
		check(!r.failed && r.body == "hello data" && r.mime == "text/plain", "data: URLs work")
		r = run({url = "data:text/html,x", mode = .Navigate, initiator = doc})
		check(r.failed && r.error == .Unsupported, "top-level navigation to data: is blocked")
		r = run({url = "about:blank", mode = .Navigate, initiator = nil})
		check(!r.failed && r.status == 200 && r.mime == "text/html", "about:blank")

		r = run({url = testenv.url(A + "/wasm"), mode = .Cors, destination = .Script, initiator = doc})
		check(!r.failed && r.mime == "application/wasm" && len(r.body) > 100, "a module served as application/wasm loads")
		r = run({url = testenv.url(A + "/wasm-wrong"), mode = .Cors, destination = .Script, initiator = doc})
		check(r.failed && r.error == .Bad_Mime, "a module served as text/html is refused")
		r = run({url = testenv.url(B + "/wasm"), mode = .Cors, destination = .Script, initiator = doc})
		check(r.failed && r.error == .Blocked_Cors, "cross-origin modules need CORS")
		r = run({url = testenv.url(A + "/big?mb=50"), mode = .Same_Origin, initiator = doc, max_body = 1 << 20})
		check(r.failed && r.error == .Body_Too_Large, "response size cap")
	}

	////////////////////////////////
	fmt.println("-- local files")
	{
		_ = os.make_directory("build/policy_site")
		_ = os.make_directory("build/policy_site/sub")
		_ = os.write_entire_file("build/policy_site/index.html", transmute([]byte)string("<h1>hi</h1>"))
		_ = os.write_entire_file("build/policy_site/sub/data.txt", transmute([]byte)string("deep"))
		_ = os.write_entire_file("build/policy_other.txt", transmute([]byte)string("outside"))
		cwd, _ := os.get_working_directory(context.temp_allocator)
		slashed, _ := strings.replace_all(cwd, "\\", "/", context.temp_allocator)
		root := strings.concatenate({"file:///", slashed, "/build/policy_site/"}, context.temp_allocator)
		fdoc := env(strings.concatenate({root, "index.html"}, context.temp_allocator))

		r := run({url = strings.concatenate({root, "sub/data.txt"}, context.temp_allocator), mode = .Cors, initiator = fdoc})
		check(!r.failed && r.body == "deep" && r.mime == "text/plain", "a file: document reads files in its own tree")
		r = run({url = strings.concatenate({root, "../policy_other.txt"}, context.temp_allocator), mode = .Cors, initiator = fdoc})
		check(r.failed && r.error == .Blocked_File, "...but not outside it")
		r = run({url = strings.concatenate({root, "missing.txt"}, context.temp_allocator), mode = .Cors, initiator = fdoc})
		check(r.failed, "a missing file fails")
		r = run({url = strings.concatenate({root, "index.html"}, context.temp_allocator), mode = .Cors, initiator = doc})
		check(r.failed && r.error == .Blocked_File, "web pages never read local files")
		r = run({url = strings.concatenate({root, "../policy_other.txt"}, context.temp_allocator), mode = .Navigate, initiator = nil})
		check(!r.failed && r.body == "outside", "the browser UI may open any file")
		r = run({url = testenv.url(A + "/cors/none"), mode = .Cors, initiator = fdoc})
		check(r.failed && r.error == .Blocked_Cors, "a file: document has a null origin: CORS applies")
		r = run({url = testenv.url(A + "/cors/open"), mode = .Cors, initiator = fdoc})
		check(!r.failed && r.type == .Cors, "...and a wildcard server accepts it")
	}

	////////////////////////////////
	fmt.println("-- cancellation")
	{
		scope := base.scope_make("doc")
		r := new(Result, vmem.arena_allocator(&results))
		fetch.start(&loader, {request = {url = testenv.url(A + "/slow"), mode = .Same_Origin, initiator = doc}, on_event = on_event, user = r, scope = scope})
		for _ in 0 ..< 5 { host.loop_wait(&loop, 20) }
		check(fetch.in_flight(&loader) == 1, "a task is in flight")
		seen_response := r.got_response
		base.scope_close(scope)
		check(fetch.in_flight(&loader) == 0 && net.in_flight(&client) == 0, "closing the scope cancels the task and its transport")
		for _ in 0 ..< 20 { host.loop_wait(&loop, 20) }
		check(!r.done && r.got_response == seen_response, "no event is delivered after cancellation")
	}

	for e in envs { fetch.environment_destroy(e); free(e) }
	delete(envs)
	vmem.arena_destroy(&results)
	fetch.loader_destroy(&loader)
	host.blocking_destroy(&blocking)
	net.client_destroy(&client)
	fetch.profile_destroy(&profile)
	host.loop_destroy(&loop)
	failures += testenv.mem_check("policytest")
	fmt.printf("\n%d checks, %d failure(s)\n", checks, failures)
	os.exit(failures)
}
