// The Python handlers of xhr/resources in Go (wpt_python.go: their request and response). Each mirrors its .py file.
package testserver

import (
	"bytes"
	"compress/gzip"
	"compress/zlib"
	"encoding/json"
	"fmt"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"slices"
	"strconv"
	"strings"
	"time"
)

const (
	xhrResources        = "/xhr/resources/"
	preflightCacheAge   = "10"
	cookieLifetime      = 24 * time.Hour // access-control-cookie.py's, get-set-cookie.py's: a day either way
	delayDefaultMs      = 500
	trickleDefaultCount = 50
	badChunkDelay       = 100 * time.Millisecond
	badChunkCount       = 5
)

func init() {
	for name, main := range xhrHandlers {
		wptPyHandlers[xhrResources+name] = wptPy(main)
	}
	for _, folder := range []string{"auth1", "auth2", "auth3", "auth4", "auth5", "auth6", "auth9", "auth10", "auth11"} {
		wptPyHandlers[xhrResources+folder+"/auth.py"] = wptPy(xhrAuthentication)
	}
	wptPyHandlers[xhrResources+"authentication.py"] = wptPy(xhrAuthentication)
	wptPyHandlers[xhrResources+"auth2/corsenabled.py"] = wptPy(xhrAuthCors("authorization, x-user, x-pass"))
	wptPyHandlers[xhrResources+"auth7/corsenabled.py"] = wptPy(xhrAuthCors("authorization, x-user, x-pass"))
	wptPyHandlers[xhrResources+"auth8/corsenabled-no-authorize.py"] = wptPy(xhrAuthCors("x-user, x-pass"))
}

// A fixed answer: Content-Type and body.
func pyFixed(ctype, body string) func(q *pyRequest, p *pyResponse) {
	return func(q *pyRequest, p *pyResponse) {
		p.add("Content-type", ctype)
		p.body = []byte(body)
	}
}

// The request as content.py, corsenabled.py, gzip.py and zlib.py report it.
func reportRequest(q *pyRequest, p *pyResponse) {
	p.add("X-Request-Method", q.r.Method)
	query := q.r.URL.RawQuery
	if query == "" {
		query = "NO"
	}
	p.add("X-Request-Query", query)
	p.add("X-Request-Content-Length", q.header("Content-Length", "NO"))
	p.add("X-Request-Content-Type", q.header("Content-Type", "NO"))
}

func contentOrBody(q *pyRequest) []byte {
	if q.has("content") {
		return []byte(q.q.Get("content"))
	}
	return q.body
}

func compressed(q *pyRequest, p *pyResponse, coding string, output []byte) {
	p.add("Content-type", "text/plain")
	p.add("Content-Encoding", coding)
	reportRequest(q, p)
	p.add("Content-Length", strconv.Itoa(len(output)))
	p.body = output
}

// status.py, the same in xhr and in fetch.
func pyStatus(q *pyRequest, p *pyResponse) {
	p.code, p.text = q.firstInt("code", http.StatusOK), q.first("text", "OMG")
	p.add("Content-Type", q.first("type", ""))
	p.add("X-Request-Method", q.r.Method)
	p.body = []byte(q.first("content", ""))
}

// access-control-basic-preflight-cache*.py: three variants of one machine.
func preflightCache(q *pyRequest, p *pyResponse, script string) {
	p.set("Access-Control-Allow-Origin", q.origin())
	p.set("Access-Control-Allow-Credentials", "true")
	token := q.q.Get("token")
	state := stashState(script, token)
	next := func(s string) { stashPut(script, token, s) }
	method := q.r.Method
	fail := func(message string) {
		p.body = []byte("FAIL " + method + ": " + message)
		if script == "cache" {
			p.status(http.StatusBadRequest)
		}
	}
	switch {
	case state == "Uninitialized" && method == http.MethodOptions:
		p.set("Access-Control-Allow-Methods", "PUT")
		if script == "timeout" {
			p.set("Access-Control-Allow-Headers", "x-test")
			p.set("Access-Control-Max-Age", "1")
		} else {
			p.set("Access-Control-Max-Age", preflightCacheAge)
		}
		next("OPTIONSSent")
	case state == "OPTIONSSent" && method == http.MethodPut:
		p.body = []byte("PASS: First PUT request.")
		next("FirstPUTSent")
	case state == "FirstPUTSent" && script == "cache" && method == http.MethodPut:
		p.body = []byte("PASS: Second PUT request. Preflight worked.")
	case state == "FirstPUTSent" && script == "cache" && method == http.MethodOptions:
		p.set("Access-Control-Allow-Methods", "PUT")
		next("FAILSecondOPTIONSSent")
	case state == "FAILSecondOPTIONSSent" && method == http.MethodPut:
		fail("Second OPTIONS request was sent. Preflight failed.")
	case state == "FirstPUTSent" && script != "cache" && method == http.MethodOptions:
		if script == "invalidation" {
			p.set("Access-Control-Allow-Methods", "PUT, XMETHOD")
		} else {
			p.set("Access-Control-Allow-Methods", "PUT")
		}
		p.set("Access-Control-Allow-Headers", "x-test")
		next("SecondOPTIONSSent")
	case state == "FirstPUTSent" && script != "cache" && method == http.MethodPut:
		fail("Second PUT request sent without preflight")
	case state == "SecondOPTIONSSent" && (method == http.MethodPut || script == "invalidation" && method == "XMETHOD"):
		p.body = []byte("PASS: Second OPTIONS request was sent.")
	default:
		fail(state)
	}
}

const preflightDenied = "preflight-denied" // its stash, which reset-token.py clears too

func pyDenied(q *pyRequest, p *pyResponse) {
	fail := func(message string) {
		p.body = []byte("FAIL: " + message)
		p.status(http.StatusBadRequest)
	}
	p.set("Cache-Control", "no-store")
	p.set("Access-Control-Allow-Origin", q.origin())
	p.set("Access-Control-Max-Age", "1")
	token := q.q.Get("token")
	state, command := stashState(preflightDenied, token), q.q.Get("command")
	reset := func() { stashPut(preflightDenied, token, "") }
	switch {
	case command == "reset":
		if q.r.Method == http.MethodGet {
			reset()
			p.body = []byte("Server state reset")
		} else {
			fail("Invalid Method.")
		}
	case state == "Uninitialized":
		if q.r.Method == http.MethodOptions {
			p.body = []byte("This request should not be displayed.")
			stashPut(preflightDenied, token, "Denied")
		} else {
			fail(state)
		}
	case state == "Denied":
		if q.r.Method == http.MethodGet && command == "complete" {
			reset()
			p.body = []byte("Request successfully blocked.")
		} else {
			stashPut(preflightDenied, token, "Deny Ignored")
			fail("The request was not denied.")
		}
	case state == "Deny Ignored":
		reset()
		fail(state)
	default:
		reset()
		fail("Unknown Error.")
	}
}

func xhrAuthentication(q *pyRequest, p *pyResponse) {
	const script = "authentication"
	user, password, authorized := q.r.BasicAuth()
	token := q.header("X-User", "")
	if !authorized {
		if _, ok := stashTake(script, token); token != "" && ok {
			p.body = []byte("FAIL (did not authorize)")
			return
		}
		if token != "" {
			stashPut(script, token, "1")
		}
		p.code, p.text = http.StatusUnauthorized, "Unauthorized"
		p.add("WWW-Authenticate", `Basic realm="test"`)
		p.body = []byte("FAIL (should be transparent)")
		return
	}
	challenge := "DID-NOT"
	if v, _ := stashTake(script, token); v == "1" {
		challenge = "DID"
	}
	p.add("XHR-USER", token)
	p.add("SES-USER", user)
	p.add("X-challenge", challenge)
	p.body = []byte(user + "\n" + password)
}

func xhrAuthCors(allowed string) func(q *pyRequest, p *pyResponse) {
	return func(q *pyRequest, p *pyResponse) {
		p.set("Access-Control-Allow-Origin", q.origin())
		p.set("Access-Control-Allow-Credentials", "true")
		p.set("Access-Control-Allow-Methods", "GET")
		p.set("Access-Control-Allow-Headers", allowed)
		p.set("Access-Control-Expose-Headers", "x-challenge, xhr-user, ses-user")
		if q.r.Method != http.MethodOptions {
			xhrAuthentication(q, p)
		}
	}
}

// parse_qs's value of the pair "location=...": cut at the first '&', unquoted once more.
func unquoteLocation(location string) string {
	location, _, _ = strings.Cut(location, "&")
	if s, err := url.QueryUnescape(location); err == nil {
		return s
	}
	return location
}

var xhrHandlers = map[string]func(q *pyRequest, p *pyResponse){
	"status.py": pyStatus,
	"content.py": func(q *pyRequest, p *pyResponse) {
		ctype := "text/plain"
		if q.has("response_charset_label") {
			ctype += ";charset=" + q.q.Get("response_charset_label")
		}
		p.add("Content-type", ctype)
		reportRequest(q, p)
		p.body = contentOrBody(q)
	},
	"redirect.py": func(q *pyRequest, p *pyResponse) {
		code := q.firstInt("code", http.StatusFound)
		location := q.first("location", q.r.URL.Path+"?followed")
		if location != "" {
			location = unquoteLocation(location)
			if strings.HasPrefix(location, "redirect.py") {
				location += "&code=" + strconv.Itoa(code)
			}
		}
		time.Sleep(q.firstMs("delay", 0))
		if q.has("followed") {
			p.add("Content:Type", "text/plain")
			p.body = []byte("MAGIC HAPPENED")
			return
		}
		p.code, p.text = code, "WEBSRT MARKETING"
		p.add("Location", location)
		p.body = []byte("TEST")
	},
	"inspect-headers.py": func(q *pyRequest, p *pyResponse) {
		if q.has("cors") {
			p.add("Access-Control-Allow-Origin", "*")
			p.add("Access-Control-Allow-Credentials", "true")
			p.add("Access-Control-Allow-Methods", "GET, POST, PUT, FOO")
			p.add("Access-Control-Allow-Headers", "x-test, x-foo")
			p.add("Access-Control-Expose-Headers", "x-request-method, x-request-content-type, x-request-query, x-request-content-length")
		}
		p.add("content-type", "text/plain")
		value, name := q.q.Get("filter_value"), strings.ToLower(q.q.Get("filter_name"))
		for _, h := range q.raw {
			if value != "" {
				if h[1] == value {
					p.body = append(p.body, h[0]+","...)
				}
			} else if strings.ToLower(h[0]) == name {
				p.body = append(p.body, h[0]+": "+h[1]+"\n"...)
			}
		}
	},
	"delay.py": func(q *pyRequest, p *pyResponse) {
		time.Sleep(q.firstMs("ms", delayDefaultMs))
		p.add("Access-Control-Allow-Origin", "*")
		p.add("Access-Control-Allow-Methods", "YO")
		p.add("Content-type", "text/plain")
		p.body = []byte("TEST_DELAY")
	},
	"trickle.py": func(q *pyRequest, p *pyResponse) {
		const chunk = "TEST_TRICKLE\n"
		delay := q.firstMs("ms", delayDefaultMs)
		count := q.firstInt("count", trickleDefaultCount)
		if q.has("specifylength") {
			p.set("Content-Length", strconv.Itoa(count*len(chunk)))
		}
		time.Sleep(delay)
		p.set("Content-type", "text/plain")
		p.start()
		time.Sleep(delay)
		for range count {
			p.write([]byte(chunk))
			time.Sleep(delay)
		}
	},
	"corsenabled.py": func(q *pyRequest, p *pyResponse) {
		p.add("Access-Control-Allow-Origin", "*")
		p.add("Access-Control-Allow-Credentials", "true")
		p.add("Access-Control-Allow-Methods", "GET, POST, PUT, FOO")
		p.add("Access-Control-Allow-Headers", "x-test, x-foo")
		p.add("Access-Control-Expose-Headers", "x-request-method, x-request-content-type, x-request-query, x-request-content-length, x-request-data")
		time.Sleep(time.Duration(q.firstInt("delay", 0)) * time.Second)
		if q.has("safelist_content_type") {
			p.add("Access-Control-Allow-Headers", "content-type")
		}
		reportRequest(q, p)
		p.add("X-Request-Data", string(q.body))
		p.body = []byte("Test")
	},
	"headers.py": func(q *pyRequest, p *pyResponse) {
		p.set("Content-Type", "text/plain")
		p.set("X-Custom-Header", "test")
		p.set("Set-Cookie", "test")
		p.set("Set-Cookie2", "test")
		p.set("X-Custom-Header-Empty", "")
		p.set("X-Custom-Header-Comma", "1")
		p.add("X-Custom-Header-Comma", "2")
		p.set("X-Custom-Header-Bytes", "…")
		p.body = []byte("TEST")
	},
	"requri.py": func(q *pyRequest, p *pyResponse) {
		if q.has("full") {
			p.body = []byte(q.scheme() + "://" + q.r.Host + q.r.RequestURI)
		} else {
			p.body = []byte(q.r.RequestURI)
		}
	},
	"reset-token.py": func(q *pyRequest, p *pyResponse) {
		p.set("Access-Control-Allow-Origin", q.origin())
		stashPut(preflightDenied, q.q.Get("token"), "")
		p.body = []byte("PASS")
	},
	"infinite-redirects.py": func(q *pyRequest, p *pyResponse) {
		page, kind, mix := "alternate", http.StatusFound, 0
		if q.q.Get("page") == "alternate" {
			page = "default"
		}
		if q.q.Get("type") == "301" {
			kind = http.StatusMovedPermanently
		}
		if q.q.Get("mix") == "1" {
			mix = 1
			kind = map[int]int{http.StatusMovedPermanently: http.StatusFound, http.StatusFound: http.StatusMovedPermanently}[kind]
		}
		location := fmt.Sprintf("%s://%s%s?page=%s&type=%d&mix=%d", q.scheme(), q.r.Host, q.r.URL.Path, page, kind, mix)
		p.status(http.StatusMovedPermanently)
		p.add("Cache-Control", "no-cache")
		p.add("Pragma", "no-cache")
		p.add("Location", location)
		p.body = []byte("Hello guest. You have been redirected to " + location)
	},
	"accept.py": func(q *pyRequest, p *pyResponse) {
		p.add("Content-Type", "text/plain")
		p.body = []byte(q.header("accept", "NO"))
	},
	"access-control-allow-lists.py": func(q *pyRequest, p *pyResponse) {
		for _, a := range [][2]string{{"origin", "Access-Control-Allow-Origin"}, {"headers", "Access-Control-Allow-Headers"}, {"methods", "Access-Control-Allow-Methods"}} {
			if q.has(a[0]) {
				p.set(a[1], q.q.Get(a[0]))
			}
		}
		seen := map[string]string{"host": q.r.Host}
		for name, values := range q.r.Header {
			seen[strings.ToLower(name)] = values[0]
		}
		p.body, _ = json.Marshal(seen)
	},
	"access-control-allow-with-body.py": func(q *pyRequest, p *pyResponse) {
		p.set("Cache-Control", "no-store")
		p.set("Access-Control-Allow-Headers", "X-Requested-With")
		p.set("Access-Control-Max-Age", "0")
		p.set("Access-Control-Allow-Origin", "*")
		p.set("Access-Control-Allow-Methods", "*")
		p.set("Vary", "Accept-Encoding")
		p.set("Content-Type", "text/plain")
		p.body = []byte("PASS")
	},
	"access-control-auth-basic.py": func(q *pyRequest, p *pyResponse) {
		p.set("Cache-Control", "no-store")
		p.set("Access-Control-Allow-Origin", q.origin())
		p.set("Access-Control-Allow-Credentials", "true")
		if q.r.Method == http.MethodOptions {
			p.set("Access-Control-Allow-Methods", "PUT")
			return
		}
		user, password, _ := q.r.BasicAuth()
		if user == "" || user != q.q.Get("uid") {
			p.set("WWW-Authenticate", "Basic realm='Test Realm/Cross Origin'")
			p.status(http.StatusUnauthorized)
			p.body = []byte("Authentication cancelled")
			return
		}
		p.body = []byte("User: " + user + ", Password: " + password)
	},
	"access-control-basic-allow-no-credentials.py": func(q *pyRequest, p *pyResponse) {
		p.set("Content-Type", "text/plain")
		p.set("Access-Control-Allow-Origin", q.origin())
		p.body = []byte("PASS: Cross-domain access allowed.")
	},
	"access-control-basic-allow-star.py": func(q *pyRequest, p *pyResponse) {
		p.set("Content-Type", "text/plain")
		p.set("Access-Control-Allow-Origin", "*")
		p.body = []byte("PASS: Cross-domain access allowed.")
	},
	"access-control-basic-allow.py": func(q *pyRequest, p *pyResponse) {
		p.set("Content-Type", "text/plain")
		p.set("Access-Control-Allow-Credentials", "true")
		p.set("Access-Control-Allow-Origin", q.origin())
		p.body = []byte("PASS: Cross-domain access allowed.")
	},
	"access-control-basic-cors-safelisted-request-headers.py": func(q *pyRequest, p *pyResponse) {
		p.set("Cache-Control", "no-store")
		if q.r.Method != http.MethodPost {
			p.status(http.StatusBadRequest)
			return
		}
		p.set("Access-Control-Allow-Credentials", "true")
		p.set("Access-Control-Allow-Origin", q.origin())
		for _, name := range []string{"Accept", "Accept-Language", "Content-Language", "Content-Type"} {
			p.body = append(p.body, name+": "+q.header(name, "<None>")+"\n"...)
		}
	},
	"access-control-basic-cors-safelisted-response-headers.py": func(q *pyRequest, p *pyResponse) {
		p.set("content-type", "text/plain")
		p.set("cache-control", "no cache")
		p.set("content-language", "en")
		p.set("expires", "Fri, 30 Oct 1998 14:19:41 GMT")
		p.set("last-modified", "Tue, 15 Nov 1994 12:45:26 GMT")
		p.set("pragma", "no-cache")
		p.set("x-test", "foobar")
		p.set("Access-Control-Allow-Origin", "*")
		p.body = []byte("PASS: Cross-domain access allowed.")
	},
	"access-control-basic-denied.py": func(q *pyRequest, p *pyResponse) {
		p.set("Cache-Control", "no-store")
		p.set("Content-Type", "text/plain")
		p.body = []byte("FAIL: Cross-domain access allowed.")
	},
	"access-control-basic-options-not-supported.py": func(q *pyRequest, p *pyResponse) {
		p.set("Cache-Control", "no-store")
		switch {
		case q.r.Method == http.MethodOptions:
			p.status(http.StatusBadRequest)
		case q.hasHeader("origin"):
			p.set("Access-Control-Allow-Credentials", "true")
			p.set("Access-Control-Allow-Origin", q.origin())
		default:
			p.status(http.StatusInternalServerError)
		}
	},
	"access-control-basic-preflight-cache-invalidation.py": func(q *pyRequest, p *pyResponse) { preflightCache(q, p, "invalidation") },
	"access-control-basic-preflight-cache-timeout.py":      func(q *pyRequest, p *pyResponse) { preflightCache(q, p, "timeout") },
	"access-control-basic-preflight-cache.py":              func(q *pyRequest, p *pyResponse) { preflightCache(q, p, "cache") },
	"access-control-basic-put-allow.py": func(q *pyRequest, p *pyResponse) {
		p.set("Content-Type", "text/plain")
		switch q.r.Method {
		case http.MethodOptions:
			p.set("Access-Control-Allow-Credentials", "true")
			p.set("Access-Control-Allow-Methods", "PUT")
			p.set("Access-Control-Allow-Origin", q.origin())
		case http.MethodPut:
			p.set("Access-Control-Allow-Credentials", "true")
			p.set("Access-Control-Allow-Origin", q.origin())
			p.body = append([]byte("PASS: Cross-domain access allowed.\n"), q.body...)
		default:
			p.body = []byte("Wrong method: " + q.r.Method)
		}
	},
	"access-control-cookie.py": func(q *pyRequest, p *pyResponse) {
		p.set("Cache-Control", "no-store")
		p.set("Access-Control-Allow-Origin", q.origin())
		p.set("Access-Control-Allow-Credentials", "true")
		for _, c := range q.r.Cookies() {
			p.cookie(c.Name, "deleted", time.Now().Add(-cookieLifetime), "")
		}
		if name := q.q.Get("cookie_name"); name != "" {
			p.cookie(name, "COOKIE", time.Now().Add(cookieLifetime), "")
		}
	},
	"access-control-origin-header.py": func(q *pyRequest, p *pyResponse) {
		p.set("Content-Type", "text/plain")
		p.set("Cache-Control", "no-cache, no-store")
		p.set("Access-Control-Allow-External", "true")
		p.set("Access-Control-Allow-Origin", "*")
		p.body = []byte("PASS: Cross-domain access allowed.\nHTTP_ORIGIN: " + q.origin())
	},
	"access-control-preflight-denied.py": pyDenied,
	"access-control-preflight-request-allow-headers-returns-star.py": func(q *pyRequest, p *pyResponse) {
		p.set("Access-Control-Allow-Origin", "*")
		if q.r.Method == http.MethodOptions {
			p.set("Access-Control-Allow-Headers", "*")
		} else if q.hasHeader("X-Test") {
			p.set("Content-Type", "text/plain")
			p.body = []byte("PASS")
		} else {
			p.status(http.StatusBadRequest)
		}
	},
	"access-control-preflight-request-header-lowercase.py": func(q *pyRequest, p *pyResponse) {
		p.set("Cache-Control", "no-store")
		p.set("Access-Control-Allow-Origin", "*")
		p.set("Access-Control-Max-Age", "0")
		if q.r.Method == http.MethodOptions {
			names := strings.Split(q.header("Access-Control-Request-Headers", ""), ",")
			for i := range names {
				names[i] = strings.Trim(names[i], " ")
			}
			if slices.Contains(names, "x-test") {
				p.set("Access-Control-Allow-Headers", "X-Test")
			} else {
				p.status(http.StatusBadRequest)
			}
		} else if q.hasHeader("X-Test") {
			p.body = []byte("PASS")
		} else {
			p.status(http.StatusBadRequest)
		}
	},
	"access-control-preflight-request-header-returns-origin.py": func(q *pyRequest, p *pyResponse) {
		if q.r.Method == http.MethodOptions {
			p.set("Access-Control-Allow-Origin", q.origin())
			p.set("Access-Control-Allow-Headers", "X-Test")
			return
		}
		p.set("Access-Control-Allow-Origin", "*")
		if q.hasHeader("X-Test") {
			p.set("Content-Type", "text/plain")
			p.body = []byte("PASS")
		} else {
			p.status(http.StatusBadRequest)
		}
	},
	"access-control-preflight-request-header-sorted.py": func(q *pyRequest, p *pyResponse) {
		const headers = "x-custom-s,x-custom-test,x-custom-u,x-custom-ua,x-custom-v"
		p.set("Cache-Control", "no-store")
		p.set("Access-Control-Allow-Origin", q.origin())
		if q.r.Method == http.MethodOptions {
			p.set("Access-Control-Max-Age", "0")
			p.set("Access-Control-Allow-Headers", headers)
			if q.header("Access-Control-Request-Headers", "") != headers {
				p.status(http.StatusBadRequest)
			}
		} else if q.hasHeader("x-custom-s") {
			p.body = []byte("PASS")
		} else {
			p.status(http.StatusBadRequest)
			p.body = []byte("FAIL")
		}
	},
	"access-control-preflight-request-headers-origin.py": func(q *pyRequest, p *pyResponse) {
		p.set("Cache-Control", "no-store")
		p.set("Access-Control-Allow-Origin", "*")
		if q.r.Method != http.MethodOptions {
			p.body = []byte(q.header("x-pass", ""))
		} else if strings.Contains(strings.ToLower(q.header("Access-Control-Request-Headers", "")), "origin") {
			p.status(http.StatusBadRequest)
			p.body = []byte("Error: 'origin' included in Access-Control-Request-Headers")
		} else {
			p.set("Access-Control-Allow-Headers", "x-pass")
		}
	},
	"access-control-preflight-request-invalid-status.py": func(q *pyRequest, p *pyResponse) {
		if q.r.Method == http.MethodOptions {
			if code := q.firstInt("code", 0); code != 0 {
				p.status(code)
			}
			p.set("Access-Control-Max-Age", "1")
			p.set("Access-Control-Allow-Headers", "x-pass")
		}
		p.set("Cache-Control", "no-store")
		p.set("Access-Control-Allow-Origin", q.origin())
	},
	"access-control-preflight-request-must-not-contain-cookie.py": func(q *pyRequest, p *pyResponse) {
		foo, err := q.r.Cookie("foo")
		if q.r.Method == http.MethodOptions && err == nil {
			p.status(http.StatusBadRequest)
			return
		}
		p.set("Cache-Control", "no-store")
		p.set("Access-Control-Allow-Origin", q.origin())
		p.set("Access-Control-Allow-Credentials", "true")
		p.set("Access-Control-Allow-Headers", "X-Proprietary-Header")
		p.set("Connection", "close")
		if err == nil {
			p.body = []byte(foo.Value)
		}
	},
	"bad-chunk-encoding.py": func(q *pyRequest, p *pyResponse) {
		time.Sleep(badChunkDelay)
		p.set("Transfer-Encoding", "chunked")
		p.set("Content-Type", "text/plain")
		p.set("X-Content-Type-Options", "nosniff")
		p.set("Connection", "close")
		p.start()
		time.Sleep(badChunkDelay)
		for range badChunkCount {
			p.write([]byte("a\r\nTEST_CHUNK\r\n"))
			time.Sleep(badChunkDelay)
		}
		p.write([]byte("garbage"))
	},
	"chunked.py": func(q *pyRequest, p *pyResponse) {
		p.set("Transfer-Encoding", "chunked")
		p.set("Trailer", "X-Test-Me")
		p.set("Content-Type", "text/plain")
		p.start()
		for _, value := range []string{"First chunk\r\n", "Second chunk\r\n", "Yet another (third) chunk\r\n", "Yet another (fourth) chunk\r\n"} {
			p.write([]byte(fmt.Sprintf("%x\r\n%s\r\n", len(value), value)))
		}
		p.write([]byte("0\r\nX-Test-Me: Trailer header value\r\n\r\n"))
	},
	"conditional.py": func(q *pyRequest, p *pyResponse) {
		if q.r.Method == http.MethodOptions {
			p.set("Access-Control-Allow-Origin", "*")
			p.set("Access-Control-Allow-Headers", "IF-NONE-MATCH")
			return
		}
		tag, date, cors := q.q.Get("tag"), q.q.Get("date"), q.q.Get("cors")
		if tag != "" {
			p.set("ETag", `"`+tag+`"`)
		} else if date != "" {
			p.set("Last-Modified", date)
		}
		if cors != "" {
			p.set("Access-Control-Allow-Origin", "*")
		}
		if q.hasHeader("If-None-Match") && q.header("If-None-Match", "") == tag || q.hasHeader("If-Modified-Since") && q.header("If-Modified-Since", "") == date {
			p.code, p.text = http.StatusNotModified, "SUPERCOOL"
			return
		}
		if cors == "" {
			p.set("Access-Control-Allow-Origin", "*")
		}
		p.set("Content-Type", "text/plain")
		p.body = []byte("MAYBE NOT")
	},
	"echo-content-cors.py": func(q *pyRequest, p *pyResponse) {
		p.add("X-Request-Method", q.r.Method)
		p.add("X-Request-Content-Length", q.header("Content-Length", "NO"))
		p.add("X-Request-Content-Type", q.header("Content-Type", "NO"))
		p.add("Access-Control-Allow-Credentials", "true")
		p.add("Content-Type", "text/plain")
		if origin := q.first("origin", q.origin()); origin != "" {
			p.add("Access-Control-Allow-Origin", origin)
		}
		if h := q.first("origin", q.header("access-control-request-headers", "")); h != "" {
			p.add("Access-Control-Allow-Headers", h)
		}
		if m := q.first("origin", q.header("access-control-request-method", "")); m != "" {
			p.add("Access-Control-Allow-Methods", "OPTIONS, "+m)
		}
		p.body = q.body
	},
	"echo-content-type.py": func(q *pyRequest, p *pyResponse) {
		p.set("Content-Type", "text/plain")
		p.set("Connection", "close")
		p.body = []byte(q.header("Content-Type", ""))
	},
	"echo-headers.py": func(q *pyRequest, p *pyResponse) {
		var b strings.Builder
		for _, h := range q.raw {
			b.WriteString(h[0] + ": " + h[1] + "\n")
		}
		b.WriteString("\n")
		p.add("Content-Type", "text/plain")
		p.add("Connection", "close")
		p.body = []byte(b.String())
	},
	// (the body in the packet of the headers, whatever the method: a client must leave a HEAD's alone)
	"echo-method.py": func(q *pyRequest, p *pyResponse) {
		p.takeConn()
		p.write(fmt.Appendf(nil, "HTTP/1.1 200 OK\r\nContent-type: text/plain\r\nContent-Length: %d\r\n\r\n%s", len(q.r.Method), q.r.Method))
	},
	"empty-div-utf8-html.py": pyFixed("text/html;charset=utf-8", "<!DOCTYPE html><div></div>"),
	"img-utf8-html.py":       pyFixed("text/html;charset=utf-8", "<img>foo"),
	"invalid-utf8-html.py":   pyFixed("text/html;charset=utf-8", "\xff"),
	"shift-jis-html.py":      pyFixed("text/html;charset=shift-jis", "\x83\x65\x83\x58\x83\x67"),
	"win-1252-html.py":       pyFixed("text/html;charset=windows-1252", "ÿ"), // (a Python str: wptserve sends it in UTF-8)
	"win-1252-xml.py":        pyFixed("application/xml;charset=windows-1252", "<\xff/>"),
	"invalid-utf8.py":        pyFixed("application/json", `{"key":"`+"\xff"+`"}`),
	"json-with-bom.py":       pyFixed("application/json", "\xef\xbb\xbf"+`{"key":"value"}`),
	"form.py": func(q *pyRequest, p *pyResponse) {
		form, err := q.post()
		if err != nil {
			p.status(http.StatusInternalServerError)
			return
		}
		p.body = fmt.Appendf(nil, "id:%s;value:%s;", form.PostFormValue("id"), form.PostFormValue("value"))
	},
	"get-set-cookie.py": func(q *pyRequest, p *pyResponse) {
		p.set("Content-type", "text/plain")
		var expires time.Time
		if q.q.Get("clear") != "" {
			expires = time.Now().Add(-cookieLifetime)
		}
		p.cookie("WK-test", "1", expires, "")
		p.cookie("WK-test-secure", "1", expires, "; Secure")
		for _, c := range q.r.Cookies() {
			p.body = append(p.body, " "+c.Name+"="+c.Value...)
		}
	},
	"gzip.py": func(q *pyRequest, p *pyResponse) {
		var out bytes.Buffer
		z := gzip.NewWriter(&out)
		z.Write(contentOrBody(q))
		z.Close()
		compressed(q, p, "gzip", out.Bytes())
	},
	"zlib.py": func(q *pyRequest, p *pyResponse) {
		var out bytes.Buffer
		z := zlib.NewWriter(&out)
		z.Write(contentOrBody(q))
		z.Close()
		compressed(q, p, "deflate", out.Bytes())
	},
	"header-user-agent.py": func(q *pyRequest, p *pyResponse) {
		p.set("Access-Control-Allow-Origin", "*")
		p.set("Access-Control-Max-Age", "0")
		p.set("Access-Control-Allow-Headers", "x-test")
		switch {
		case q.hasHeader("User-Agent") && q.r.Method != http.MethodOptions:
			p.body = []byte("PASS")
		case q.hasHeader("User-Agent"):
		case q.r.Method == http.MethodOptions:
			p.body = []byte("FAIL: User-Agent header missing in preflight request.")
			p.status(http.StatusBadRequest)
		default:
			p.body = []byte("FAIL: User-Agent header missing in request")
			p.status(http.StatusBadRequest)
		}
	},
	"last-modified.py": func(q *pyRequest, p *pyResponse) {
		src := filepath.Join(wptRoot, "xhr", "resources", "well-formed.xml")
		st, err := os.Stat(src)
		if err != nil {
			p.status(http.StatusNotFound)
			return
		}
		p.set("Last-Modified", st.ModTime().UTC().Format(http.TimeFormat))
		p.set("Content-Type", "application/xml")
		p.body, _ = os.ReadFile(src)
	},
	"no-custom-header-on-preflight.py": func(q *pyRequest, p *pyResponse) {
		const script = "no-custom-header"
		p.set("Access-Control-Allow-Origin", "*")
		p.set("Access-Control-Allow-Headers", "x-test")
		p.set("Access-Control-Max-Age", "0")
		token := q.q.Get("token")
		switch {
		case q.r.Method == http.MethodOptions && q.hasHeader("x-test"):
			p.body = []byte("FAIL: Invalid header in preflight request.")
			p.status(http.StatusBadRequest)
		case q.r.Method == http.MethodOptions:
			stashPut(script, token, "PASS")
		case q.hasHeader("x-test"):
			p.body = []byte(stashState(script, token))
		default:
			p.body = []byte("FAIL: X-Test header missing in request")
			p.status(http.StatusBadRequest)
		}
	},
	"parse-headers.py": func(q *pyRequest, p *pyResponse) {
		if q.has("my-custom-header") {
			p.set("My-Custom-Header", q.q.Get("my-custom-header"))
		}
	},
	"redirect-cors.py": func(q *pyRequest, p *pyResponse) {
		location := q.q.Get("location")
		switch q.r.Method {
		case http.MethodOptions:
			if q.has("redirect_preflight") {
				p.status(http.StatusFound)
				p.set("Location", location)
			}
			p.set("Access-Control-Allow-Methods", "GET")
			p.set("Access-Control-Max-Age", "1")
		case http.MethodGet:
			p.status(http.StatusFound)
			p.set("Location", location)
		}
		if q.has("allow_origin") {
			p.set("Access-Control-Allow-Origin", q.origin())
		}
		if q.has("allow_header") {
			p.set("Access-Control-Allow-Headers", q.q.Get("allow_header"))
		}
	},
	"upload.py": func(q *pyRequest, p *pyResponse) {
		form, err := q.post()
		if err != nil {
			p.status(http.StatusInternalServerError)
			return
		}
		var fields, files []string
		if form.MultipartForm != nil {
			for key, values := range form.MultipartForm.Value {
				fields = append(fields, key+"="+values[0]+",")
			}
			for key, values := range form.MultipartForm.File {
				f := values[0]
				ctype := f.Header.Get("Content-Type")
				if ctype == "" {
					ctype = "None"
				}
				files = append(files, fmt.Sprintf("%s=%s:%s:%d,", key, f.Filename, ctype, f.Size))
			}
		} else {
			for key, values := range form.PostForm {
				fields = append(fields, key+"="+values[0]+",")
			}
		}
		slices.Sort(fields)
		slices.Sort(files)
		p.body = []byte(strings.Join(fields, "") + "\n" + strings.Join(files, ""))
	},
}
