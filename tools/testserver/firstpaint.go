// First paint tests (color schemes, render-blocking stylesheets, paint holding; examples/site/firstpaint*.html):
//
//	/firstpaint/f/NAME?delay=MS   a file of examples/site/firstpaint, after MS milliseconds (a slow stylesheet or font)
package main

import (
	"mime"
	"net/http"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"
)

func registerFirstPaintHandlers(mux *http.ServeMux) {
	mux.HandleFunc("/firstpaint/f/", func(w http.ResponseWriter, r *http.Request) {
		name := filepath.Base(strings.TrimPrefix(r.URL.Path, "/firstpaint/f/"))
		if d, _ := strconv.Atoi(r.URL.Query().Get("delay")); d > 0 && d <= 60000 {
			select {
			case <-time.After(time.Duration(d) * time.Millisecond):
			case <-r.Context().Done():
				return
			}
		}
		b, err := os.ReadFile(filepath.Join("examples/site/firstpaint", name))
		if err != nil {
			http.NotFound(w, r)
			return
		}
		ct := mime.TypeByExtension(filepath.Ext(name))
		if filepath.Ext(name) == ".css" {
			ct = "text/css; charset=utf-8" // not the Windows registry's idea of it
		} else if ct == "" {
			ct = "application/octet-stream"
		}
		w.Header().Set("Content-Type", ct)
		w.Header().Set("Cache-Control", "no-store")
		w.Write(b)
	})
}
