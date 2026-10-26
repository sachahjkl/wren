// Small Python handlers of web-platform-tests, in Go (wptserve's Python handlers do not run here): redirects, scripts
// that echo a request header or a cookie, a script served with a MIME type of the query. Each mirrors its .py file.
package main

import (
	"fmt"
	"net/http"
	"strings"
	"time"
)

// wptPyHandlers: the ported handlers by path (relative to the WPT root).
var wptPyHandlers = map[string]func(w http.ResponseWriter, r *http.Request){
	"/common/redirect.py":                                         wptRedirect,
	"/workers/modules/resources/redirect.py":                      wptRedirect,
	"/workers/baseurl/beta/import.py":                             wptMovedTo("../gamma/import.js"),
	"/workers/baseurl/beta/importScripts.py":                      wptMovedTo("../gamma/importScripts.js"),
	"/workers/baseurl/beta/worker.py":                             wptMovedTo("../gamma/worker.js"),
	"/workers/baseurl/beta/xhr-worker.py":                         wptMovedTo("../gamma/xhr-worker.js"),
	"/workers/baseurl/beta/xhr.py":                                wptMovedTo("../gamma/xhr.js"),
	"/workers/interfaces/WorkerGlobalScope/location/helper-redirect.py": func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Location", "post-location-members.js?a")
		w.WriteHeader(302)
	},
	"/workers/modules/resources/export-on-load-script.py": func(w http.ResponseWriter, r *http.Request) {
		h := w.Header()
		h.Set("Content-Type", "text/javascript")
		h.Set("Access-Control-Allow-Origin", "*")
		h.Set("Access-Control-Allow-Headers", "Service-Worker")
		fmt.Fprintf(w, "export const importedModules = ['export-on-load-script.js'];// %d", time.Now().Unix())
	},
	"/workers/modules/resources/export-referrer-checker.py": func(w http.ResponseWriter, r *http.Request) {
		jsHeaders(w, "*")
		fmt.Fprintf(w, "export const referrer = '%s';", r.Header.Get("Referer"))
	},
	"/workers/modules/resources/postmessage-referrer-checker.py": func(w http.ResponseWriter, r *http.Request) {
		jsHeaders(w, "*")
		postBoth(w, r.Header.Get("Referer"))
	},
	"/workers/modules/resources/export-credentials.py": func(w http.ResponseWriter, r *http.Request) {
		credHeaders(w, r)
		fmt.Fprintf(w, "export const cookie = '%s';", cookieValue(r))
	},
	"/workers/modules/resources/postmessage-credentials.py": func(w http.ResponseWriter, r *http.Request) {
		credHeaders(w, r)
		postBoth(w, cookieValue(r))
	},
	"/workers/semantics/encodings/003-1.py": func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Query().Get("x") == "Ǿ" {
			fmt.Fprint(w, "PASS")
		} else {
			fmt.Fprint(w, "FAIL")
		}
	},
	"/workers/support/imported_script.py": func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", r.URL.Query().Get("mime"))
	},
	"/workers/support/nosiniff-error-worker.py": func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/html")
		w.Header().Set("X-Content-Type-Options", "nosniff")
	},
}

// common/redirect.py: status (302 by default) to `location`, CORS when enable-cors is present.
func wptRedirect(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()
	status := 302
	if s := q.Get("status"); s != "" {
		fmt.Sscanf(s, "%d", &status)
	}
	w.Header().Set("Location", q.Get("location"))
	if _, ok := q["enable-cors"]; ok {
		if o := r.Header.Get("Origin"); o != "" {
			w.Header().Set("Content-Type", "text/plain")
			w.Header().Set("Access-Control-Allow-Origin", o)
			w.Header().Set("Access-Control-Allow-Credentials", "true")
		}
	}
	w.WriteHeader(status)
}

// (302, "Moved"), Location, and a body that must never run
func wptMovedTo(location string) func(w http.ResponseWriter, r *http.Request) {
	return func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Location", location)
		w.WriteHeader(302)
		fmt.Fprint(w, "postMessage('executed redirecting script');")
	}
}

func jsHeaders(w http.ResponseWriter, origin string) {
	w.Header().Set("Content-Type", "text/javascript")
	w.Header().Set("Access-Control-Allow-Origin", origin)
}

func credHeaders(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "text/javascript")
	w.Header().Set("Access-Control-Allow-Credentials", "true")
	if o := r.Header.Get("Origin"); o != "" {
		w.Header().Set("Access-Control-Allow-Origin", o)
	}
}

func cookieValue(r *http.Request) string {
	if c, err := r.Cookie("COOKIE_NAME"); err == nil {
		return strings.ReplaceAll(c.Value, "'", "\\'")
	}
	return ""
}

// a script posting `v` to its owner, from a dedicated or a shared worker
func postBoth(w http.ResponseWriter, v string) {
	v = strings.ReplaceAll(v, "'", "\\'")
	fmt.Fprintf(w, "if ('DedicatedWorkerGlobalScope' in self && self instanceof DedicatedWorkerGlobalScope) {  postMessage('%s');} else if (    'SharedWorkerGlobalScope' in self &&    self instanceof SharedWorkerGlobalScope) {  onconnect = e => e.ports[0].postMessage('%s');}", v, v)
}
