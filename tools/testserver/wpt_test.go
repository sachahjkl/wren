package testserver

import (
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestWPTWrappers(t *testing.T) {
	dir := t.TempDir()
	os.MkdirAll(filepath.Join(dir, "a", "b"), 0o755)
	os.WriteFile(filepath.Join(dir, "a", "b", "x.any.js"), []byte("// META: title=The <title>\n// META: script=/common/utils.js\n// META: timeout=long\ntest(() => {});\n"), 0o644)
	os.WriteFile(filepath.Join(dir, "a", "b", "y.sub.html"), []byte("{{host}}:{{ports[http][0]}} {{domains[www]}} {{GET[q]}} {{location[path]}} {{unknown}}"), 0o644)
	os.WriteFile(filepath.Join(dir, "a", "b", "z.txt"), []byte("plain"), 0o644)
	os.WriteFile(filepath.Join(dir, "a", "b", "z.txt.headers"), []byte("X-One: 1\n"), 0o644)
	os.WriteFile(filepath.Join(dir, "a", "b", "__dir__.headers"), []byte("X-Dir: d\n"), 0o644)
	report := filepath.Join(dir, "report.js")
	os.WriteFile(report, []byte("// report"), 0o644)
	saved, savedReport := wptRoot, wptReport
	wptRoot, wptReport = dir, report
	defer func() { wptRoot, wptReport = saved, savedReport }()

	get := func(u string) *httptest.ResponseRecorder {
		rr := httptest.NewRecorder()
		req := httptest.NewRequest(http.MethodGet, "http://127.0.0.1:8768"+u, nil)
		serveWPT(rr, req)
		return rr
	}
	page := get("/a/b/x.any.html").Body.String()
	for _, want := range []string{"<title>The &lt;title&gt;</title>", `<meta name="timeout" content="long">`, "isWindow: function() { return true; }",
		`<script src="/resources/testharnessreport.js">`, `<script src="/common/utils.js">`, `<script src="x.any.js">`} {
		if !strings.Contains(page, want) {
			t.Errorf("x.any.html lacks %q:\n%s", want, page)
		}
	}
	if w := get("/a/b/x.any.worker.html?v=1").Body.String(); !strings.Contains(w, `new Worker("x.any.worker.js?v=1")`) {
		t.Errorf("x.any.worker.html: %s", w)
	}
	if w := get("/a/b/x.any.worker.js").Body.String(); !strings.Contains(w, `importScripts("/common/utils.js");`) || !strings.Contains(w, `importScripts("x.any.js");`) || !strings.HasSuffix(w, "done();\n") {
		t.Errorf("x.any.worker.js: %s", w)
	}
	if got := get("/a/b/y.sub.html?q=7").Body.String(); got != "web-platform.test:8768 www.web-platform.test 7 /a/b/y.sub.html {{unknown}}" {
		t.Errorf("substitution: %q", got)
	}
	os.WriteFile(filepath.Join(dir, "a", "b", "h.sub.js"), []byte("{{domains[www1]}} {{domains[élève]}} {{hosts[alt][]}} {{hosts[alt][www2]}} {{hosts[][www]}}"), 0o644)
	if got := get("/a/b/h.sub.js").Body.String(); got != "www1.web-platform.test xn--lve-6lad.web-platform.test not-web-platform.test www2.not-web-platform.test www.web-platform.test" {
		t.Errorf("host names: %q", got)
	}
	rr := get("/a/b/z.txt?pipe=header(X-Two,a\\,b)|status(202)")
	if rr.Code != 202 || rr.Header().Get("X-One") != "1" || rr.Header().Get("X-Dir") != "d" || rr.Header().Get("X-Two") != "a,b" || rr.Header().Get("Content-Type") != "text/plain" {
		t.Errorf("pipes and headers files: %d %v", rr.Code, rr.Header())
	}
	if got := get("/resources/testharnessreport.js").Body.String(); got != "// report" {
		t.Errorf("testharnessreport.js: %q", got)
	}
	if rr := get("/a/b/handler.py"); rr.Code != http.StatusNotImplemented {
		t.Errorf("a .py handler: %d", rr.Code)
	}
	if rr := get("/a/b/missing.html"); rr.Code != http.StatusNotFound {
		t.Errorf("missing: %d", rr.Code)
	}
}

// The stash of /common/dispatcher/dispatcher.py: what is posted to a uuid comes back once, in order, to whoever asks, from any origin.
func TestWPTDispatcher(t *testing.T) {
	saved := wptRoot
	wptRoot = t.TempDir()
	defer func() { wptRoot = saved }()
	call := func(method, query, body, origin string) *httptest.ResponseRecorder {
		rr := httptest.NewRecorder()
		req := httptest.NewRequest(method, "https://www1.web-platform.test:8769/common/dispatcher/dispatcher.py"+query, strings.NewReader(body))
		if origin != "" {
			req.Header.Set("Origin", origin)
		}
		serveWPT(rr, req)
		return rr
	}
	if got := call(http.MethodGet, "?uuid=u1", "", "").Body.String(); got != "not ready" {
		t.Errorf("an empty queue: %q", got)
	}
	if got := call(http.MethodPost, "?uuid=u1", "first", "https://web-platform.test:8769").Body.String(); got != "done" {
		t.Errorf("a post: %q", got)
	}
	call(http.MethodPost, "?uuid=u1", "second", "")
	rr := call(http.MethodGet, "?uuid=u1", "", "https://not-web-platform.test:8769")
	if rr.Body.String() != "first" || rr.Header().Get("Access-Control-Allow-Origin") != "https://not-web-platform.test:8769" || rr.Header().Get("Access-Control-Allow-Credentials") != "true" {
		t.Errorf("the first message, with CORS for its origin: %q %v", rr.Body.String(), rr.Header())
	}
	if got := call(http.MethodGet, "?uuid=u1", "", "").Body.String(); got != "second" {
		t.Errorf("the second: %q", got)
	}
	if got := call(http.MethodGet, "?uuid=u2", "", "").Body.String(); got != "not ready" {
		t.Errorf("another uuid: %q", got)
	}
	if rr := call(http.MethodOptions, "?uuid=u1", "", "https://x"); rr.Code != http.StatusOK || rr.Body.Len() != 0 {
		t.Errorf("a preflight: %d %q", rr.Code, rr.Body.String())
	}
}

// resources/coop-coep.py of html/cross-origin-opener-policy: the policies of the query, a redirect, the page that reports to its opener.
func TestWPTCoopCoep(t *testing.T) {
	saved := wptRoot
	wptRoot = t.TempDir()
	defer func() { wptRoot = saved }()
	get := func(query string) *httptest.ResponseRecorder {
		rr := httptest.NewRecorder()
		serveWPT(rr, httptest.NewRequest(http.MethodGet, "https://web-platform.test:8769/html/cross-origin-opener-policy/resources/coop-coep.py"+query, nil))
		return rr
	}
	rr := get("?coop=same-origin&coep=require-corp&channel=c1")
	if rr.Header().Get("Cross-Origin-Opener-Policy") != "same-origin" || rr.Header().Get("Cross-Origin-Embedder-Policy") != "require-corp" {
		t.Errorf("the policies: %v", rr.Header())
	}
	if body := rr.Body.String(); !strings.Contains(body, `"channel": "c1"`) || !strings.Contains(body, `"navigate": null`) || !strings.Contains(body, "postback.html") {
		t.Errorf("the page: %s", body)
	}
	rr = get("?coop=&coep=&redirect=/x")
	if rr.Code != http.StatusFound || rr.Header().Get("Location") != "/x" || rr.Header().Get("Cross-Origin-Opener-Policy") != "" {
		t.Errorf("a redirect without policies: %d %v", rr.Code, rr.Header())
	}
}

// fetch/cross-origin-resource-policy/resources/hello.py and redirect.py: the policy of the query, CORS for the asking origin.
func TestWPTCorpHandlers(t *testing.T) {
	saved := wptRoot
	wptRoot = t.TempDir()
	defer func() { wptRoot = saved }()
	rr := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodGet, "https://www1.web-platform.test:8769/fetch/cross-origin-resource-policy/resources/hello.py?corp=same-site", nil)
	req.Header.Set("Origin", "https://web-platform.test:8769")
	serveWPT(rr, req)
	if rr.Body.String() != "hello" || rr.Header().Get("Cross-Origin-Resource-Policy") != "same-site" || rr.Header().Get("Access-Control-Allow-Origin") != "https://web-platform.test:8769" {
		t.Errorf("hello.py: %q %v", rr.Body.String(), rr.Header())
	}
	rr = httptest.NewRecorder()
	serveWPT(rr, httptest.NewRequest(http.MethodGet, "https://web-platform.test:8769/fetch/cross-origin-resource-policy/resources/redirect.py?redirectTo=/x&corp=same-origin", nil))
	if rr.Code != http.StatusFound || rr.Header().Get("Location") != "/x" || rr.Header().Get("Cross-Origin-Resource-Policy") != "same-origin" {
		t.Errorf("redirect.py: %d %v", rr.Code, rr.Header())
	}
}
