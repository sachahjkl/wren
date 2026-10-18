package main

// Endpoints for the web platform API test (src/tools/webapitest):
//
//	/webapi/slow?ms=N         headers and "start" at once, "end" after N ms (aborted requests stop it early)
//	/webapi/chunks?n=N&ms=M   N lines "chunk-i\n", flushed M ms apart
//	/webapi/split             "€uro" in two chunks cut inside the euro sign, 100 ms apart
//	/webapi/echo              POST: echoes the request body

import (
	"fmt"
	"io"
	"net/http"
	"strconv"
	"time"
)

func registerWebAPIHandlers(mux *http.ServeMux) {
	mux.HandleFunc("/webapi/slow", func(w http.ResponseWriter, r *http.Request) {
		ms, _ := strconv.Atoi(r.URL.Query().Get("ms"))
		w.Header().Set("Content-Type", "text/plain")
		io.WriteString(w, "start")
		w.(http.Flusher).Flush()
		select {
		case <-r.Context().Done():
			return
		case <-time.After(time.Duration(ms) * time.Millisecond):
		}
		io.WriteString(w, "end")
	})
	mux.HandleFunc("/webapi/chunks", func(w http.ResponseWriter, r *http.Request) {
		n, _ := strconv.Atoi(r.URL.Query().Get("n"))
		ms, _ := strconv.Atoi(r.URL.Query().Get("ms"))
		w.Header().Set("Content-Type", "text/plain")
		fl := w.(http.Flusher)
		for i := 0; i < n; i++ {
			fmt.Fprintf(w, "chunk-%d\n", i)
			fl.Flush()
			select {
			case <-r.Context().Done():
				return
			case <-time.After(time.Duration(ms) * time.Millisecond):
			}
		}
	})
	mux.HandleFunc("/webapi/split", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/plain; charset=utf-8")
		euro := []byte("€uro")
		w.Write(euro[:2])
		w.(http.Flusher).Flush()
		time.Sleep(100 * time.Millisecond)
		w.Write(euro[2:])
	})
	mux.HandleFunc("/webapi/echo", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/octet-stream")
		io.Copy(w, r.Body)
	})
}
