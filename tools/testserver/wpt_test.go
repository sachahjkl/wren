package main

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
	if got := get("/a/b/y.sub.html?q=7").Body.String(); got != "127.0.0.1:8768 localhost 7 /a/b/y.sub.html {{unknown}}" {
		t.Errorf("substitution: %q", got)
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
