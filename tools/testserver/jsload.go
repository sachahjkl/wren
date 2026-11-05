package testserver

// Endpoints for the script loading test (src/tools/e2e/web_jsload.odin):
//
//	/jsload/gen?code=JS&ms=N&type=T&nosniff=1&status=S   the code (URL-decoded) as a script, after N ms, with Content-Type
//	                                                      T (text/javascript by default), X-Content-Type-Options:
//	                                                      nosniff when asked, status S (200 by default)
//	/jsload/files/PATH?ms=N                               examples/jsload/PATH (modules, workers), after N ms
//	/jsload/hits?path=P                                   how many times /jsload/gen or /jsload/files was asked for
//	                                                      with path and query P (preload: one download per script)
//	/jsload/cors?code=JS                                  the code with Access-Control-Allow-Origin: * (crossorigin)
//	/jsload/held?head=H&until=P&ms=N                      a document: H, then, once P was asked for (hits) or after N ms, a
//	                                                      <body data-asked=yes|no>: what its bytes alone made leave

import (
	"fmt"
	"io"
	"mime"
	"net/http"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"time"
)

// How often /jsload/held looks at the hits.
const jsloadHeldPoll = 5 * time.Millisecond

var jsloadHits = struct {
	sync.Mutex
	m map[string]int
}{m: map[string]int{}}

func jsloadHit(r *http.Request) {
	key := r.URL.Path
	if r.URL.RawQuery != "" {
		key += "?" + r.URL.RawQuery
	}
	jsloadHits.Lock()
	jsloadHits.m[key]++
	jsloadHits.Unlock()
}

func jsloadDelay(r *http.Request) bool {
	ms, _ := strconv.Atoi(r.URL.Query().Get("ms"))
	if ms <= 0 {
		return true
	}
	select {
	case <-r.Context().Done():
		return false
	case <-time.After(time.Duration(ms) * time.Millisecond):
		return true
	}
}

func registerJSLoadHandlers(mux *http.ServeMux) {
	mux.HandleFunc("/jsload/gen", func(w http.ResponseWriter, r *http.Request) {
		jsloadHit(r)
		if !jsloadDelay(r) {
			return
		}
		q := r.URL.Query()
		t := q.Get("type")
		if t == "" {
			t = "text/javascript"
		}
		w.Header().Set("Content-Type", t)
		w.Header().Set("Cache-Control", "no-store")
		if q.Get("nosniff") != "" {
			w.Header().Set("X-Content-Type-Options", "nosniff")
		}
		if s, _ := strconv.Atoi(q.Get("status")); s != 0 {
			w.WriteHeader(s)
		}
		io.WriteString(w, q.Get("code"))
	})
	mux.HandleFunc("/jsload/cors", func(w http.ResponseWriter, r *http.Request) {
		jsloadHit(r)
		w.Header().Set("Content-Type", "text/javascript")
		w.Header().Set("Access-Control-Allow-Origin", "*")
		io.WriteString(w, r.URL.Query().Get("code"))
	})
	mux.HandleFunc("/jsload/files/", func(w http.ResponseWriter, r *http.Request) {
		jsloadHit(r)
		if !jsloadDelay(r) {
			return
		}
		rel := strings.TrimPrefix(r.URL.Path, "/jsload/files/")
		if strings.Contains(rel, "..") {
			http.NotFound(w, r)
			return
		}
		data, err := os.ReadFile(filepath.Join("examples", "jsload", filepath.FromSlash(rel)))
		if err != nil {
			http.NotFound(w, r)
			return
		}
		t := mime.TypeByExtension(filepath.Ext(rel))
		switch filepath.Ext(rel) {
		case ".js", ".mjs":
			t = "text/javascript"
		case ".json":
			t = "application/json"
		case ".html":
			t = "text/html; charset=utf-8"
		}
		w.Header().Set("Content-Type", t)
		w.Header().Set("Cache-Control", "no-store")
		w.Write(data)
	})
	// /jsload/big?kb=N&id=X: about N KiB of script (functions and data) that logs "big X N" when run
	mux.HandleFunc("/jsload/big", func(w http.ResponseWriter, r *http.Request) {
		jsloadHit(r)
		if !jsloadDelay(r) {
			return
		}
		q := r.URL.Query()
		kb, _ := strconv.Atoi(q.Get("kb"))
		w.Header().Set("Content-Type", "text/javascript")
		w.Header().Set("Cache-Control", "no-store")
		var sb strings.Builder
		fmt.Fprintf(&sb, "var big_%s = 0;\n", q.Get("id"))
		for i := 0; sb.Len() < kb<<10; i++ {
			fmt.Fprintf(&sb, "function f_%s_%d(a, b) { var s = 0; for (var i = 0; i < a; i++) { s += (i * %d) %% (b + 1); } return s + %q.length; }\n", q.Get("id"), i, i, strings.Repeat("x", i%40))
		}
		fmt.Fprintf(&sb, "big_%s = f_%s_1(10, 3);\nconsole.log(\"big %s \" + %d);\n", q.Get("id"), q.Get("id"), q.Get("id"), kb)
		io.WriteString(w, sb.String())
	})
	mux.HandleFunc("/jsload/held", func(w http.ResponseWriter, r *http.Request) {
		q := r.URL.Query()
		w.Header().Set("Content-Type", "text/html; charset=utf-8")
		w.Header().Set("Cache-Control", "no-store")
		io.WriteString(w, q.Get("head"))
		w.(http.Flusher).Flush()
		ms, _ := strconv.Atoi(q.Get("ms"))
		asked := "no"
		for end := time.Now().Add(time.Duration(ms) * time.Millisecond); time.Now().Before(end); time.Sleep(jsloadHeldPoll) {
			jsloadHits.Lock()
			n := jsloadHits.m[q.Get("until")]
			jsloadHits.Unlock()
			if n > 0 {
				asked = "yes"
				break
			}
		}
		fmt.Fprintf(w, `<body data-asked=%s></body>`, asked)
	})
	mux.HandleFunc("/jsload/hits", func(w http.ResponseWriter, r *http.Request) {
		jsloadHits.Lock()
		n := jsloadHits.m[r.URL.Query().Get("path")]
		jsloadHits.Unlock()
		w.Header().Set("Content-Type", "text/plain")
		w.Header().Set("Access-Control-Allow-Origin", "*")
		fmt.Fprintf(w, "%d", n)
	})
}
