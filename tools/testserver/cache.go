// HTTP cache tests (src/tools/cachetest):
//
//	/cache/r/NAME?cc=...&etag=...&lm=SECONDS_AGO&expires=SECONDS&vary=FIELD&age=N&status=NNN&type=...&body=...&location=...&cookie=1
//	        a response with the caching fields asked for; If-None-Match / If-Modified-Since against them give a 304.
//	        Every request is counted per NAME (path and query, so each test uses its own NAME). delay=MS answers late.
//	/cache/count?name=NAME   how many requests NAME got, and how many were answered 304: "N M" (no-store)
//	/cache/last?name=NAME    the request fields of the last request for NAME, one per line (no-store)
//	/cache/reset             forgets every count
//	/cache/font.woff2?...    the font of examples/site/fonts (cachetest's web font), with the same parameters
package main

import (
	"fmt"
	"net/http"
	"os"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"
)

var cacheCounts = struct {
	sync.Mutex
	hits map[string]int
	nm   map[string]int
	last map[string]string
}{hits: map[string]int{}, nm: map[string]int{}, last: map[string]string{}}

func cacheEtagMatches(inm, etag string) bool {
	for _, t := range strings.Split(inm, ",") {
		t = strings.TrimSpace(t)
		if t == "*" || strings.TrimPrefix(t, "W/") == strings.TrimPrefix(etag, "W/") {
			return true
		}
	}
	return false
}

func registerCacheHandlers(mux *http.ServeMux) {
	start := time.Now().UTC().Truncate(time.Second)
	serve := func(w http.ResponseWriter, r *http.Request, name string, body []byte, ctype string) {
		q := r.URL.Query()
		if d, err := strconv.Atoi(q.Get("delay")); err == nil && d > 0 && d <= 60000 {
			select {
			case <-time.After(time.Duration(d) * time.Millisecond):
			case <-r.Context().Done():
				return
			}
		}
		var lines []string
		for k, v := range r.Header {
			lines = append(lines, strings.ToLower(k)+": "+strings.Join(v, ", "))
		}
		sort.Strings(lines)
		cacheCounts.Lock()
		cacheCounts.hits[name]++
		cacheCounts.last[name] = strings.Join(lines, "\n")
		cacheCounts.Unlock()
		h := w.Header()
		if v := q.Get("cc"); v != "" {
			h.Set("Cache-Control", v)
		}
		if v := q.Get("vary"); v != "" {
			h.Set("Vary", v)
		}
		if v := q.Get("age"); v != "" {
			h.Set("Age", v)
		}
		if v := q.Get("cookie"); v != "" {
			h.Set("Set-Cookie", "cachetest="+v+"; Path=/")
		}
		if v := q.Get("acao"); v != "" {
			h.Set("Access-Control-Allow-Origin", v)
		}
		if v, err := strconv.Atoi(q.Get("expires")); err == nil {
			h.Set("Expires", time.Now().UTC().Add(time.Duration(v)*time.Second).Format(http.TimeFormat))
		}
		etag := q.Get("etag")
		if etag != "" {
			h.Set("ETag", `"`+etag+`"`)
		}
		lm := time.Time{}
		if v, err := strconv.Atoi(q.Get("lm")); err == nil {
			lm = start.Add(-time.Duration(v) * time.Second)
			h.Set("Last-Modified", lm.Format(http.TimeFormat))
		}
		h.Set("Date", time.Now().UTC().Format(http.TimeFormat))
		notModified := false
		if inm := r.Header.Get("If-None-Match"); inm != "" && etag != "" {
			notModified = cacheEtagMatches(inm, `"`+etag+`"`)
		} else if ims := r.Header.Get("If-Modified-Since"); ims != "" && !lm.IsZero() {
			if t, err := http.ParseTime(ims); err == nil && !lm.After(t) {
				notModified = true
			}
		}
		if notModified && (r.Method == "GET" || r.Method == "HEAD") {
			cacheCounts.Lock()
			cacheCounts.nm[name]++
			cacheCounts.Unlock()
			w.WriteHeader(http.StatusNotModified)
			return
		}
		if v := q.Get("location"); v != "" {
			h.Set("Location", v)
		}
		h.Set("Content-Type", ctype)
		status := http.StatusOK
		if v, err := strconv.Atoi(q.Get("status")); err == nil {
			status = v
		}
		w.WriteHeader(status)
		w.Write(body)
	}
	mux.HandleFunc("/cache/r/", func(w http.ResponseWriter, r *http.Request) {
		name := r.URL.Path + "?" + r.URL.RawQuery
		q := r.URL.Query()
		body := q.Get("body")
		if body == "" {
			body = fmt.Sprintf("%s %s #%d", r.Method, strings.TrimPrefix(r.URL.Path, "/cache/r/"), time.Now().UnixNano())
		}
		ctype := q.Get("type")
		if ctype == "" {
			ctype = "text/plain; charset=utf-8"
		}
		serve(w, r, name, []byte(body), ctype)
	})
	mux.HandleFunc("/cache/font.woff2", func(w http.ResponseWriter, r *http.Request) {
		b, err := os.ReadFile(sitePath("fonts", "firacode-latin.woff2"))
		if err != nil {
			http.NotFound(w, r)
			return
		}
		serve(w, r, r.URL.Path+"?"+r.URL.RawQuery, b, "font/woff2")
	})
	mux.HandleFunc("/cache/count", func(w http.ResponseWriter, r *http.Request) {
		name := r.URL.Query().Get("name")
		cacheCounts.Lock()
		n, m := cacheCounts.hits[name], cacheCounts.nm[name]
		cacheCounts.Unlock()
		w.Header().Set("Cache-Control", "no-store")
		fmt.Fprintf(w, "%d %d", n, m)
	})
	mux.HandleFunc("/cache/last", func(w http.ResponseWriter, r *http.Request) {
		name := r.URL.Query().Get("name")
		cacheCounts.Lock()
		s := cacheCounts.last[name]
		cacheCounts.Unlock()
		w.Header().Set("Cache-Control", "no-store")
		fmt.Fprint(w, s)
	})
	mux.HandleFunc("/cache/reset", func(w http.ResponseWriter, r *http.Request) {
		cacheCounts.Lock()
		cacheCounts.hits = map[string]int{}
		cacheCounts.nm = map[string]int{}
		cacheCounts.last = map[string]string{}
		cacheCounts.Unlock()
		w.Header().Set("Cache-Control", "no-store")
		fmt.Fprint(w, "ok")
	})
}
