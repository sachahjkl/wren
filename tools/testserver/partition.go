package main

// Storage partitioning (tools/partition_e2e.ps1):
//
//	/partition/hdr    text: the request's Sec-Fetch-Storage-Access header ("-" when absent), then its Cookie header

import (
	"io"
	"net/http"
)

func registerPartitionHandlers(mux *http.ServeMux) {
	mux.HandleFunc("/partition/hdr", func(w http.ResponseWriter, r *http.Request) {
		sfsa := r.Header.Get("Sec-Fetch-Storage-Access")
		if sfsa == "" {
			sfsa = "-"
		}
		w.Header().Set("Content-Type", "text/plain")
		w.Header().Set("Cache-Control", "no-store")
		io.WriteString(w, sfsa+" "+r.Header.Get("Cookie"))
	})
}
