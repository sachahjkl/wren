package main

import (
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"strconv"
	"strings"
	"sync"
	"time"
)

// Server-sent events for the EventSource tests. Every endpoint reflects the Origin with credentials allowed, so the
// streams can be read cross-origin too.
//
//	/sse/basic          an unnamed event, a named one ("ping"), a multi-line one, ids, CR / CRLF line ends, a comment,
//	                    a BOM; then the stream stays open until the client goes away
//	/sse/reconnect      without Last-Event-ID: "retry: 200", one event with id 41, then the stream ends.
//	                    With Last-Event-ID: one event "resumed:<id>" (id 42), then it stays open
//	/sse/wrong-type     text/plain: the client must fail and never come back
//	/sse/status?code=N  replies N with a text/event-stream body
//	/sse/headers        one event whose data is a JSON object of the request headers that matter
//	/sse/hits?name=X    how many requests /sse/X received
var (
	sseMu   sync.Mutex
	sseHits = map[string]int{}
)

func sseHit(name string) {
	sseMu.Lock()
	sseHits[name]++
	sseMu.Unlock()
}

func sseStart(w http.ResponseWriter, r *http.Request) http.Flusher {
	if o := r.Header.Get("Origin"); o != "" {
		w.Header().Set("Access-Control-Allow-Origin", o)
		w.Header().Set("Access-Control-Allow-Credentials", "true")
	}
	w.Header().Set("Content-Type", "text/event-stream; charset=utf-8")
	w.Header().Set("Cache-Control", "no-store")
	w.WriteHeader(http.StatusOK)
	fl := w.(http.Flusher)
	fl.Flush()
	return fl
}

// Holds the response open until the client disconnects (or a minute passes), with a comment every few seconds.
func sseHold(w http.ResponseWriter, r *http.Request, fl http.Flusher) {
	tick := time.NewTicker(5 * time.Second)
	defer tick.Stop()
	deadline := time.After(time.Minute)
	for {
		select {
		case <-r.Context().Done():
			return
		case <-deadline:
			return
		case <-tick.C:
			if _, err := io.WriteString(w, ": keep-alive\n\n"); err != nil {
				return
			}
			fl.Flush()
		}
	}
}

func registerSSEHandlers(mux *http.ServeMux) {
	mux.HandleFunc("/sse/basic", func(w http.ResponseWriter, r *http.Request) {
		sseHit("basic")
		fl := sseStart(w, r)
		io.WriteString(w, "\xEF\xBB\xBF: the stream starts with a BOM and a comment\n")
		io.WriteString(w, "data: hello\n\n")
		fl.Flush()
		io.WriteString(w, "event: ping\r\ndata: p1\r\nid: 1\r\n\r\n")
		fl.Flush()
		io.WriteString(w, "data: line1\rdata: line2\rid: 2\r\r")
		fl.Flush()
		io.WriteString(w, "event: done\ndata: 3\n\n")
		fl.Flush()
		sseHold(w, r, fl)
	})
	mux.HandleFunc("/sse/reconnect", func(w http.ResponseWriter, r *http.Request) {
		sseHit("reconnect")
		last := r.Header.Get("Last-Event-ID")
		fl := sseStart(w, r)
		if last == "" {
			io.WriteString(w, "retry: 200\nid: 41\ndata: first\n\n")
			io.WriteString(w, "id: 99\ndata: never dispatched") // cut: the id must not be used
			fl.Flush()
			return
		}
		fmt.Fprintf(w, "id: 42\ndata: resumed:%s\n\n", last)
		fl.Flush()
		sseHold(w, r, fl)
	})
	mux.HandleFunc("/sse/wrong-type", func(w http.ResponseWriter, r *http.Request) {
		sseHit("wrong-type")
		w.Header().Set("Content-Type", "text/plain")
		io.WriteString(w, "data: not an event stream\n\n")
	})
	mux.HandleFunc("/sse/status", func(w http.ResponseWriter, r *http.Request) {
		sseHit("status")
		code, _ := strconv.Atoi(r.URL.Query().Get("code"))
		if code == 0 {
			code = 500
		}
		w.Header().Set("Content-Type", "text/event-stream")
		w.WriteHeader(code)
		io.WriteString(w, "data: x\n\n")
	})
	mux.HandleFunc("/sse/headers", func(w http.ResponseWriter, r *http.Request) {
		sseHit("headers")
		h := map[string]string{}
		for _, k := range []string{"Accept", "Cache-Control", "Cookie", "Last-Event-Id", "Origin", "Sec-Fetch-Mode", "Sec-Fetch-Dest"} {
			h[strings.ToLower(k)] = r.Header.Get(k)
		}
		b, _ := json.Marshal(h)
		fl := sseStart(w, r)
		fmt.Fprintf(w, "data: %s\n\n", b)
		fl.Flush()
		sseHold(w, r, fl)
	})
	mux.HandleFunc("/sse/hits", func(w http.ResponseWriter, r *http.Request) {
		sseMu.Lock()
		n := sseHits[r.URL.Query().Get("name")]
		sseMu.Unlock()
		fmt.Fprintf(w, "%d", n)
	})
}
