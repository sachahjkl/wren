// The Python handlers of fetch/cross-origin-resource-policy/resources in Go: a response with the Cross-Origin-Resource-Policy of the
// query (hello.py, script.py), a redirect that may carry one (redirect.py), an image with one (image.py). Each mirrors its .py file.
package testserver

import (
	"net/http"
	"os"
	"path/filepath"
	"strconv"
)

const corpResources = "/fetch/cross-origin-resource-policy/resources/"

func init() {
	wptPyHandlers[corpResources+"hello.py"] = func(w http.ResponseWriter, r *http.Request) { corpBody(w, r, "hello") }
	wptPyHandlers[corpResources+"script.py"] = func(w http.ResponseWriter, r *http.Request) { corpBody(w, r, "") }
	wptPyHandlers[corpResources+"redirect.py"] = corpRedirect
	wptPyHandlers[corpResources+"image.py"] = corpImage
}

func corpBody(w http.ResponseWriter, r *http.Request, body string) {
	w.Header().Set("Cross-Origin-Resource-Policy", r.URL.Query().Get("corp"))
	if origin := r.Header.Get("Origin"); origin != "" {
		w.Header().Set("Access-Control-Allow-Origin", origin)
	}
	w.Write([]byte(body))
}

func corpRedirect(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()
	w.Header().Set("Location", q.Get("redirectTo"))
	if q.Has("corp") {
		w.Header().Set("Cross-Origin-Resource-Policy", q.Get("corp"))
	}
	w.WriteHeader(http.StatusFound)
}

func corpImage(w http.ResponseWriter, r *http.Request) {
	body, err := os.ReadFile(filepath.Join(wptRoot, filepath.FromSlash(corpResources), "green.png"))
	if err != nil {
		http.NotFound(w, r)
		return
	}
	q := r.URL.Query()
	h := w.Header()
	if q.Has("corp") {
		h.Set("Cross-Origin-Resource-Policy", q.Get("corp"))
	}
	if q.Has("acao") {
		h.Set("Access-Control-Allow-Origin", q.Get("acao"))
	}
	h.Set("Content-Length", strconv.Itoa(len(body)))
	if q.Has("type") {
		h.Set("Content-Type", q.Get("type"))
	} else {
		h["Content-Type"] = nil // (wptserve writes none: the browser sniffs)
	}
	w.Write(body)
}
