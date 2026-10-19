package main

// Endpoints for the JavaScript web API test (src/tools/jswebtest):
//
//	/jsweb/text?mb=N       N MB of ASCII text (text/plain; charset=utf-8)
//	/jsweb/json            a small JSON document
//	/jsweb/headers         repeated headers (X-Multi twice, Set-Cookie twice) and a Content-Type
//	/jsweb/multipart       a multipart/form-data body: a field and a file
//	/jsweb/urlencoded      an application/x-www-form-urlencoded body
//	/jsweb/latin1          "caf\xe9" as text/plain; charset=iso-8859-1
//	/jsweb/beacon          POST: counted; /jsweb/beacon-log answers "<count>|<last body>|<last Content-Type>"
//	/jsweb/page            an empty HTML page (for documents the test loads by URL)
//	/jsweb/demo            examples/jsweb/demo.html (the server runs from the repository root)

import (
	"fmt"
	"io"
	"net/http"
	"strconv"
	"strings"
	"sync"
)

var beacon struct {
	sync.Mutex
	count int
	body  string
	ctype string
}

func registerJSWebHandlers(mux *http.ServeMux) {
	mux.HandleFunc("/jsweb/text", func(w http.ResponseWriter, r *http.Request) {
		mb, _ := strconv.Atoi(r.URL.Query().Get("mb"))
		w.Header().Set("Content-Type", "text/plain; charset=utf-8")
		w.Header().Set("Content-Length", strconv.Itoa(mb<<20))
		line := []byte(strings.Repeat("abcdefghijklmnopqrstuvwxyz012345", 32)) // 1 KiB
		for i := 0; i < mb<<10; i++ {
			if _, err := w.Write(line); err != nil {
				return
			}
		}
	})
	mux.HandleFunc("/jsweb/json", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		io.WriteString(w, `{"a":1,"b":[true,null],"s":"\u00e9t\u00e9"}`)
	})
	mux.HandleFunc("/jsweb/headers", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/plain; charset=utf-8")
		w.Header().Add("X-Multi", "one")
		w.Header().Add("X-Multi", "two")
		w.Header().Add("Set-Cookie", "a=1")
		w.Header().Add("Set-Cookie", "b=2")
		io.WriteString(w, "headers")
	})
	mux.HandleFunc("/jsweb/multipart", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "multipart/form-data; boundary=XyZ")
		io.WriteString(w, "--XyZ\r\nContent-Disposition: form-data; name=\"field\"\r\n\r\nvalue 1\r\n"+
			"--XyZ\r\nContent-Disposition: form-data; name=\"file\"; filename=\"a.txt\"\r\nContent-Type: text/plain\r\n\r\nfile body\r\n--XyZ--\r\n")
	})
	mux.HandleFunc("/jsweb/urlencoded", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/x-www-form-urlencoded")
		io.WriteString(w, "a=1&b=x+y&a=%C3%A9")
	})
	mux.HandleFunc("/jsweb/latin1", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/plain; charset=iso-8859-1")
		w.Write([]byte{'c', 'a', 'f', 0xe9})
	})
	mux.HandleFunc("/jsweb/beacon", func(w http.ResponseWriter, r *http.Request) {
		b, _ := io.ReadAll(r.Body)
		beacon.Lock()
		beacon.count++
		beacon.body = string(b)
		beacon.ctype = r.Header.Get("Content-Type")
		beacon.Unlock()
		w.WriteHeader(http.StatusNoContent)
	})
	mux.HandleFunc("/jsweb/beacon-log", func(w http.ResponseWriter, r *http.Request) {
		beacon.Lock()
		defer beacon.Unlock()
		w.Header().Set("Access-Control-Allow-Origin", "*")
		fmt.Fprintf(w, "%d|%s|%s", beacon.count, beacon.body, beacon.ctype)
	})
	mux.HandleFunc("/jsweb/demo", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/html; charset=utf-8")
		http.ServeFile(w, r, "examples/jsweb/demo.html")
	})
	mux.HandleFunc("/jsweb/page", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/html; charset=utf-8")
		io.WriteString(w, "<!doctype html><title>page</title>")
	})
}
