package main

// Endpoints for the nested documents test (src/tools/framestest) and the frames demo (examples/site/frames/):
//
//	/frames/doc?body=HTML&h=Name:%20value&h=...   an HTML page made of `body`, with each `h` as a response header
//	                                              (X-Frame-Options, Content-Security-Policy, Permissions-Policy...)
//	/frames/text?body=TEXT                        the same as text/plain
//
// Every origin of the block serves them (base+0 and base+2 are two origins of one site, 127.0.0.1 and localhost two
// sites), so a page of one origin can frame another.

import (
	"io"
	"net/http"
	"strings"
)

func registerFrameHandlers(mux *http.ServeMux) {
	serve := func(w http.ResponseWriter, r *http.Request, ctype string) {
		q := r.URL.Query()
		for _, h := range q["h"] {
			if i := strings.IndexByte(h, ':'); i > 0 {
				w.Header().Add(strings.TrimSpace(h[:i]), strings.TrimSpace(h[i+1:]))
			}
		}
		w.Header().Set("Content-Type", ctype)
		w.Header().Set("Cache-Control", "no-store")
		io.WriteString(w, q.Get("body"))
	}
	mux.HandleFunc("/frames/doc", func(w http.ResponseWriter, r *http.Request) { serve(w, r, "text/html; charset=utf-8") })
	mux.HandleFunc("/frames/text", func(w http.ResponseWriter, r *http.Request) { serve(w, r, "text/plain; charset=utf-8") })
}
