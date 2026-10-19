package main

import (
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"strconv"
	"strings"
	"sync/atomic"
)

// Endpoints for the policy tests (CORS, cookies, redirects, HSTS, headers). The same server answers on every host name
// that resolves to 127.0.0.1 and on ports 8765 / 8767, so the tests get several origins from one process.
//
//	/cors/open            ACAO: *
//	/cors/reflect         ACAO: <Origin>
//	/cors/creds           ACAO: <Origin>, ACAC: true
//	/cors/none            no CORS headers
//	/cors/expose          ACAO: *, Expose-Headers: X-Shown, plus X-Shown / X-Hidden
//	/cors/api             full preflight support for PUT/DELETE + X-Token; /cors/preflights counts the OPTIONS received
//	/echo-headers         JSON object with the request headers and method
//	/cookie/set?raw=...   replies with Set-Cookie: <raw> (repeat raw for several)
//	/cookie/show          the Cookie header received
//	/redirect-to?to=URL&code=302   /redirect-chain?n=K   /redirect-loop
//	/echo-method          "<METHOD> <body length>"
//	/hsts                 Strict-Transport-Security (meaningful on https only)
//	/wasm /wasm-wrong     the demo module as application/wasm / as text/html
//	/headers?name=value   replies with the given response headers
var preflights int64

func writeJSON(w http.ResponseWriter, v any) {
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(v)
}

func registerPolicyHandlers(mux *http.ServeMux) {
	mux.HandleFunc("/cors/open", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Access-Control-Allow-Origin", "*")
		io.WriteString(w, "open")
	})
	mux.HandleFunc("/cors/reflect", func(w http.ResponseWriter, r *http.Request) {
		if o := r.Header.Get("Origin"); o != "" {
			w.Header().Set("Access-Control-Allow-Origin", o)
		}
		io.WriteString(w, "reflect")
	})
	mux.HandleFunc("/cors/creds", func(w http.ResponseWriter, r *http.Request) {
		if o := r.Header.Get("Origin"); o != "" {
			w.Header().Set("Access-Control-Allow-Origin", o)
			w.Header().Set("Access-Control-Allow-Credentials", "true")
		}
		io.WriteString(w, "creds:"+r.Header.Get("Cookie"))
	})
	mux.HandleFunc("/cors/none", func(w http.ResponseWriter, r *http.Request) { io.WriteString(w, "none") })
	mux.HandleFunc("/cors/expose", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Access-Control-Allow-Origin", "*")
		w.Header().Set("Access-Control-Expose-Headers", "X-Shown")
		w.Header().Set("X-Shown", "yes")
		w.Header().Set("X-Hidden", "no")
		io.WriteString(w, "expose")
	})
	mux.HandleFunc("/cors/api", func(w http.ResponseWriter, r *http.Request) {
		o := r.Header.Get("Origin")
		w.Header().Set("Access-Control-Allow-Origin", o)
		if r.Method == http.MethodOptions {
			atomic.AddInt64(&preflights, 1)
			w.Header().Set("Access-Control-Allow-Methods", "PUT, DELETE")
			w.Header().Set("Access-Control-Allow-Headers", "x-token, content-type")
			w.Header().Set("Access-Control-Max-Age", "60")
			w.WriteHeader(http.StatusNoContent)
			return
		}
		b, _ := io.ReadAll(r.Body)
		fmt.Fprintf(w, "%s token=%q body=%d", r.Method, r.Header.Get("X-Token"), len(b))
	})
	mux.HandleFunc("/cors/preflights", func(w http.ResponseWriter, r *http.Request) {
		fmt.Fprintf(w, "%d", atomic.LoadInt64(&preflights))
	})
	mux.HandleFunc("/cors/bad-preflight", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Access-Control-Allow-Origin", r.Header.Get("Origin"))
		if r.Method == http.MethodOptions {
			w.WriteHeader(http.StatusInternalServerError)
			return
		}
		io.WriteString(w, "should not be reached")
	})
	mux.HandleFunc("/echo-headers", func(w http.ResponseWriter, r *http.Request) {
		h := map[string]string{"_method": r.Method}
		for k, v := range r.Header {
			h[strings.ToLower(k)] = strings.Join(v, ", ")
		}
		w.Header().Set("Access-Control-Allow-Origin", "*")
		writeJSON(w, h)
	})
	mux.HandleFunc("/cookie/set", func(w http.ResponseWriter, r *http.Request) {
		for _, raw := range r.URL.Query()["raw"] {
			w.Header().Add("Set-Cookie", raw)
		}
		io.WriteString(w, "set")
	})
	mux.HandleFunc("/cookie/show", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Access-Control-Allow-Origin", r.Header.Get("Origin"))
		w.Header().Set("Access-Control-Allow-Credentials", "true")
		io.WriteString(w, r.Header.Get("Cookie"))
	})
	mux.HandleFunc("/redirect-to", func(w http.ResponseWriter, r *http.Request) {
		code, _ := strconv.Atoi(r.URL.Query().Get("code"))
		if code == 0 {
			code = 302
		}
		w.Header().Set("Location", r.URL.Query().Get("to"))
		w.WriteHeader(code)
	})
	mux.HandleFunc("/redirect-chain", func(w http.ResponseWriter, r *http.Request) {
		n, _ := strconv.Atoi(r.URL.Query().Get("n"))
		if n <= 0 {
			io.WriteString(w, "end of chain")
			return
		}
		http.Redirect(w, r, fmt.Sprintf("/redirect-chain?n=%d", n-1), http.StatusFound)
	})
	mux.HandleFunc("/redirect-loop", func(w http.ResponseWriter, r *http.Request) {
		http.Redirect(w, r, "/redirect-loop", http.StatusFound)
	})
	mux.HandleFunc("/echo-method", func(w http.ResponseWriter, r *http.Request) {
		b, _ := io.ReadAll(r.Body)
		w.Header().Set("Access-Control-Allow-Origin", "*")
		fmt.Fprintf(w, "%s %d", r.Method, len(b))
	})
	mux.HandleFunc("/hsts", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Strict-Transport-Security", "max-age=3600; includeSubDomains")
		io.WriteString(w, "hsts")
	})
	mux.HandleFunc("/wasm", func(w http.ResponseWriter, r *http.Request) {
		b, err := os.ReadFile(sitePath("counter.wasm"))
		if err != nil {
			http.Error(w, "run from the repo root", 500)
			return
		}
		w.Header().Set("Content-Type", "application/wasm")
		w.Write(b)
	})
	mux.HandleFunc("/wasm-wrong", func(w http.ResponseWriter, r *http.Request) {
		b, _ := os.ReadFile(sitePath("counter.wasm"))
		w.Header().Set("Content-Type", "text/html")
		w.Write(b)
	})
	site := http.FileServer(http.Dir(siteDir))
	mux.Handle("/site/", http.StripPrefix("/site/", site))
	// the same site with a Content-Security-Policy: scripts only from other (unreachable) hosts => the module is blocked
	mux.Handle("/site-csp/", http.StripPrefix("/site-csp/", http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Security-Policy", "script-src https://nowhere.test")
		w.Header().Set("Referrer-Policy", "no-referrer")
		site.ServeHTTP(w, r)
	})))
	// sets a cookie, then redirects to the site: shows cookies and redirects in the shell
	mux.HandleFunc("/start", func(w http.ResponseWriter, r *http.Request) {
		http.SetCookie(w, &http.Cookie{Name: "visited", Value: "yes", Path: "/", MaxAge: 3600, HttpOnly: false, SameSite: http.SameSiteLaxMode})
		http.Redirect(w, r, "/site/index.html", http.StatusFound)
	})
	mux.HandleFunc("/headers", func(w http.ResponseWriter, r *http.Request) {
		for k, v := range r.URL.Query() {
			for _, x := range v {
				w.Header().Add(k, x)
			}
		}
		io.WriteString(w, "headers")
	})
}
