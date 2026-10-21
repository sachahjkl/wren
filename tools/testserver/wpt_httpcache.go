// fetch/http-cache/resources/http-cache.py of web-platform-tests, in Go (wptserve's Python handlers do not run here):
// the server side of the HTTP cache tests. Each request of a test carries the whole test (Test-Requests: base64 JSON
// of the requests); the server answers the n-th request it sees for a uuid with the n-th configuration (response
// headers with "magic" relative dates and locations, status, body), answers 304 when a "validated" request carries the
// validator of the first response, and keeps what it saw for dispatch=state.
package main

import (
	"encoding/base64"
	"encoding/json"
	"fmt"
	"net/http"
	"strings"
	"sync"
	"time"
)

var httpCacheStash = struct {
	sync.Mutex
	m map[string][]map[string]any
}{m: map[string][]map[string]any{}}

func wptHTTPCacheHandler(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()
	dispatch, uuid := q.Get("dispatch"), q.Get("uuid")
	h := w.Header()
	h.Set("Access-Control-Allow-Credentials", "true")
	if r.Method == "OPTIONS" {
		origin := r.Header.Get("Origin")
		if origin == "" {
			origin = "*"
		}
		h.Set("Access-Control-Allow-Origin", origin)
		h.Set("Access-Control-Allow-Methods", "GET")
		reqh := r.Header.Get("Access-Control-Request-Headers")
		if reqh == "" {
			reqh = "*"
		}
		h.Set("Access-Control-Allow-Headers", reqh)
		h.Set("Access-Control-Max-Age", "86400")
		fmt.Fprint(w, "Preflight request")
		return
	}
	plain := func(status int, text string) {
		h.Set("Content-Type", "text/plain")
		w.WriteHeader(status)
		fmt.Fprint(w, text)
	}
	if uuid == "" {
		plain(404, "UUID not found")
		return
	}
	switch dispatch {
	case "state":
		httpCacheStash.Lock()
		st, ok := httpCacheStash.m[uuid]
		delete(httpCacheStash.m, uuid)
		httpCacheStash.Unlock()
		h.Set("Content-Type", "text/plain")
		if !ok {
			fmt.Fprint(w, "null")
			return
		}
		b, _ := json.Marshal(st)
		w.Write(b)
	case "test":
		wptHTTPCacheTest(w, r, uuid)
	default:
		plain(404, "Fallthrough")
	}
}

func wptHTTPDate(t time.Time) string { return t.UTC().Format(http.TimeFormat) }

func wptHTTPCacheTest(w http.ResponseWriter, r *http.Request, uuid string) {
	h := w.Header()
	httpCacheStash.Lock()
	state := httpCacheStash.m[uuid]
	delete(httpCacheStash.m, uuid)
	httpCacheStash.Unlock()
	raw, err := base64.StdEncoding.DecodeString(r.Header.Get("Test-Requests"))
	var requests []map[string]any
	if err == nil {
		err = json.Unmarshal(raw, &requests)
	}
	if err != nil {
		h.Set("Content-Type", "text/plain")
		w.WriteHeader(400)
		fmt.Fprint(w, "No or bad Test-Requests request header")
		return
	}
	if len(state) >= len(requests) || requests[len(state)] == nil {
		h.Set("Content-Type", "text/plain")
		w.WriteHeader(404)
		fmt.Fprint(w, "Config not found")
		return
	}
	config := requests[len(state)]
	now := time.Now()
	scheme := "http"
	if r.TLS != nil {
		scheme = "https"
	}
	requestURL := scheme + "://" + r.Host + r.URL.RequestURI()
	noted := map[string]any{}
	if hdrs, ok := config["response_headers"].([]any); ok {
		for _, x := range hdrs {
			pair, ok := x.([]any)
			if !ok || len(pair) < 2 {
				continue
			}
			name, _ := pair[0].(string)
			lname := strings.ToLower(name)
			value := ""
			switch v := pair[1].(type) {
			case string:
				value = v
				if lname == "location" || lname == "content-location" { // magic locations
					if v != "" {
						value = requestURL + "&target=" + v
					} else {
						value = requestURL
					}
				}
			case float64:
				if lname == "date" || lname == "expires" || lname == "last-modified" { // magic dates
					value = wptHTTPDate(now.Add(time.Duration(v) * time.Second))
				} else {
					value = fmt.Sprint(v)
				}
			default:
				value = fmt.Sprint(v)
			}
			h.Set(name, value)
			if lname == "content-type" || lname == "access-control-allow-origin" || lname == "last-modified" || lname == "etag" {
				noted[lname] = value
			}
		}
	}
	reqHeaders := map[string]string{}
	for k, v := range r.Header {
		reqHeaders[strings.ToLower(k)] = strings.Join(v, ", ")
	}
	reqHeaders["host"] = r.Host
	state = append(state, map[string]any{
		"now": float64(now.UnixNano()) / 1e9, "request_method": r.Method, "request_headers": reqHeaders, "response_headers": noted,
	})
	httpCacheStash.Lock()
	httpCacheStash.m[uuid] = state
	httpCacheStash.Unlock()
	if _, ok := noted["access-control-allow-origin"]; !ok {
		h.Set("Access-Control-Allow-Origin", "*")
	}
	if _, ok := noted["content-type"]; !ok {
		h.Set("Content-Type", "text/plain")
	}
	h.Set("Server-Request-Count", fmt.Sprint(len(state)))
	code := 200
	if st, ok := config["response_status"].([]any); ok && len(st) > 0 {
		if c, ok := st[0].(float64); ok {
			code = int(c)
		}
	}
	if et, _ := config["expected_type"].(string); strings.HasSuffix(et, "validated") {
		ref, _ := state[0]["response_headers"].(map[string]any)
		if lm, ok := ref["last-modified"].(string); ok && lm != "" && r.Header.Get("If-Modified-Since") == lm {
			code = 304
		}
		if et, ok := ref["etag"].(string); ok && et != "" && r.Header.Get("If-None-Match") == et {
			code = 304
		}
		if code != 304 {
			code = 999 // "304 Not Generated"
		}
	}
	w.WriteHeader(code)
	if code == 204 || code == 304 {
		return
	}
	if body, ok := config["response_body"].(string); ok {
		fmt.Fprint(w, body)
	} else {
		fmt.Fprint(w, uuid)
	}
}
