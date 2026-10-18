package main

// Form submission endpoint for the forms end-to-end test: replies with what it received, in a line format the test
// checks (method, Content-Type, query, the raw body, and the body as Go's parsers understand it).
//
//	/forms/echo    any method; GET shows the query, POST parses urlencoded / multipart / text/plain bodies

import (
	"fmt"
	"io"
	"mime"
	"mime/multipart"
	"net/http"
	"net/url"
	"sort"
	"strings"
)

func registerFormHandlers(mux *http.ServeMux) {
	mux.HandleFunc("/forms/echo", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/plain; charset=utf-8")
		w.Header().Set("Access-Control-Allow-Origin", "*")
		var sb strings.Builder
		fmt.Fprintf(&sb, "method=%s\n", r.Method)
		fmt.Fprintf(&sb, "content-type=%s\n", r.Header.Get("Content-Type"))
		fmt.Fprintf(&sb, "query=%s\n", r.URL.RawQuery)
		body, _ := io.ReadAll(io.LimitReader(r.Body, 64<<20))
		fmt.Fprintf(&sb, "raw-length=%d\n", len(body))
		mt, params, _ := mime.ParseMediaType(r.Header.Get("Content-Type"))
		switch mt {
		case "application/x-www-form-urlencoded":
			vals, err := url.ParseQuery(string(body))
			if err != nil {
				fmt.Fprintf(&sb, "error=%v\n", err)
			}
			writeValues(&sb, vals)
		case "multipart/form-data":
			mr := multipart.NewReader(strings.NewReader(string(body)), params["boundary"])
			for {
				p, err := mr.NextPart()
				if err == io.EOF {
					break
				}
				if err != nil {
					fmt.Fprintf(&sb, "error=%v\n", err)
					break
				}
				data, _ := io.ReadAll(p)
				if p.FileName() != "" || strings.Contains(p.Header.Get("Content-Disposition"), "filename=") {
					fmt.Fprintf(&sb, "file %s=%s;%s;%d;%s\n", p.FormName(), p.FileName(), p.Header.Get("Content-Type"), len(data), preview(data))
				} else {
					fmt.Fprintf(&sb, "field %s=%s\n", p.FormName(), strings.ReplaceAll(string(data), "\r\n", "\\r\\n"))
				}
			}
		case "text/plain":
			for _, line := range strings.Split(string(body), "\r\n") {
				if line != "" {
					fmt.Fprintf(&sb, "line %s\n", line)
				}
			}
		}
		if r.Method == http.MethodGet {
			vals, _ := url.ParseQuery(r.URL.RawQuery)
			writeValues(&sb, vals)
		}
		io.WriteString(w, sb.String())
	})
}

func writeValues(sb *strings.Builder, vals url.Values) {
	keys := make([]string, 0, len(vals))
	for k := range vals {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	for _, k := range keys {
		for _, v := range vals[k] {
			fmt.Fprintf(sb, "field %s=%s\n", k, strings.ReplaceAll(v, "\r\n", "\\r\\n"))
		}
	}
}

func preview(b []byte) string {
	if len(b) > 32 {
		b = b[:32]
	}
	return strings.ReplaceAll(strings.ReplaceAll(string(b), "\n", "\\n"), "\r", "\\r")
}
