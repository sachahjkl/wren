// Image formats of the built-in decoders (src/tools/mediatest, examples/site/media.html).
//
//	/media/f/NAME          a file of examples/site/media with its type (image/avif, image/webp, image/svg+xml...);
//	                       the request's Accept header is remembered for NAME
//	/media/accept?name=N   the Accept header the last request for N carried
//	/media/neg             content negotiation on Accept: quad8a.avif if image/avif is accepted, else quad-lossy.webp if
//	                       image/webp is, else ../images/red.png (Vary: Accept)
package main

import (
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"sync"
)

var mediaAccept = struct {
	sync.Mutex
	m map[string]string
}{m: map[string]string{}}

func mediaType(name string) string {
	switch strings.ToLower(filepath.Ext(name)) {
	case ".avif":
		return "image/avif"
	case ".webp":
		return "image/webp"
	case ".svg":
		return "image/svg+xml"
	case ".png":
		return "image/png"
	case ".jpg":
		return "image/jpeg"
	}
	return "application/octet-stream"
}

func serveMedia(w http.ResponseWriter, path string) {
	b, err := os.ReadFile(path)
	if err != nil {
		http.NotFound(w, nil)
		return
	}
	w.Header().Set("Content-Type", mediaType(path))
	w.Header().Set("Cache-Control", "no-store")
	w.Write(b)
}

func registerMediaHandlers(mux *http.ServeMux) {
	mux.HandleFunc("/media/f/", func(w http.ResponseWriter, r *http.Request) {
		name := filepath.Base(strings.TrimPrefix(r.URL.Path, "/media/f/"))
		mediaAccept.Lock()
		mediaAccept.m[name] = r.Header.Get("Accept")
		mediaAccept.Unlock()
		serveMedia(w, filepath.Join("examples/site/media", name))
	})
	mux.HandleFunc("/media/accept", func(w http.ResponseWriter, r *http.Request) {
		mediaAccept.Lock()
		v := mediaAccept.m[r.URL.Query().Get("name")]
		mediaAccept.Unlock()
		w.Header().Set("Access-Control-Allow-Origin", "*")
		w.Write([]byte(v))
	})
	mux.HandleFunc("/media/neg", func(w http.ResponseWriter, r *http.Request) {
		accept := r.Header.Get("Accept")
		w.Header().Set("Vary", "Accept")
		switch {
		case strings.Contains(accept, "image/avif"):
			serveMedia(w, "examples/site/media/quad8a.avif")
		case strings.Contains(accept, "image/webp"):
			serveMedia(w, "examples/site/media/quad-lossy.webp")
		default:
			serveMedia(w, "examples/site/images/red.png")
		}
	})
}
