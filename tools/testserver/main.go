// Local server for exercising the network stack (no dependencies beyond Go's standard library).
//
//	go run ./tools/testserver            # http on :8765, https (self-signed) on :8766, http on :8767, WPT on :8768
//	testserver -base-port N [-scan] [-port-file F] [-parent-pid P]   # another block of ports (ports.go), ending with
//	                                     # process P (tools\test_env.ps1 Start-WrenTestServer starts it that way)
//
//	/                hello
//	/big?mb=N        N MB of incompressible bytes, streamed
//	/gzip            text with Content-Encoding: gzip
//	/redirect?n=K    K redirects, then /
//	/status/NNN      replies NNN
//	/slow            one byte every 100 ms for 10 s
//	/echo            POST: replies with the request body length and the X-Test header
package main

import (
	"compress/gzip"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"fmt"
	"io"
	"log"
	"math/big"
	mrand "math/rand"
	"net/http"
	"strconv"
	"strings"
	"time"
)

func selfSigned() tls.Certificate {
	key, _ := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	tpl := x509.Certificate{
		SerialNumber: big.NewInt(1),
		Subject:      pkix.Name{CommonName: "localhost"},
		NotBefore:    time.Now().Add(-time.Hour),
		NotAfter:     time.Now().Add(24 * time.Hour),
		DNSNames:     []string{"localhost"},
		KeyUsage:     x509.KeyUsageDigitalSignature,
		ExtKeyUsage:  []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth},
	}
	der, _ := x509.CreateCertificate(rand.Reader, &tpl, &tpl, &key.PublicKey, key)
	return tls.Certificate{Certificate: [][]byte{der}, PrivateKey: key}
}

func main() {
	watchParent()
	if wptOnly() {
		serveWPTOnly()
		return
	}
	mux := http.NewServeMux()
	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/" {
			http.NotFound(w, r)
			return
		}
		w.Header().Set("Content-Type", "text/html; charset=utf-8")
		io.WriteString(w, "<!doctype html><title>hello</title><h1>hello</h1>")
	})
	mux.HandleFunc("/big", func(w http.ResponseWriter, r *http.Request) {
		mb, _ := strconv.Atoi(r.URL.Query().Get("mb"))
		w.Header().Set("Content-Length", strconv.Itoa(mb<<20))
		buf := make([]byte, 1<<20)
		mrand.New(mrand.NewSource(1)).Read(buf)
		for i := 0; i < mb; i++ {
			if _, err := w.Write(buf); err != nil {
				return
			}
		}
	})
	mux.HandleFunc("/gzip", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Encoding", "gzip")
		zw := gzip.NewWriter(w)
		io.WriteString(zw, strings.Repeat("compressible ", 10000))
		zw.Close()
	})
	mux.HandleFunc("/redirect", func(w http.ResponseWriter, r *http.Request) {
		n, _ := strconv.Atoi(r.URL.Query().Get("n"))
		if n <= 0 {
			http.Redirect(w, r, "/", http.StatusFound)
			return
		}
		http.Redirect(w, r, fmt.Sprintf("/redirect?n=%d", n-1), http.StatusFound)
	})
	mux.HandleFunc("/status/", func(w http.ResponseWriter, r *http.Request) {
		n, _ := strconv.Atoi(strings.TrimPrefix(r.URL.Path, "/status/"))
		w.WriteHeader(n)
		fmt.Fprintf(w, "status %d", n)
	})
	mux.HandleFunc("/slow", func(w http.ResponseWriter, r *http.Request) {
		fl := w.(http.Flusher)
		for i := 0; i < 100; i++ {
			if _, err := w.Write([]byte{'.'}); err != nil {
				return
			}
			fl.Flush()
			select {
			case <-r.Context().Done():
				return
			case <-time.After(100 * time.Millisecond):
			}
		}
	})
	mux.HandleFunc("/echo", func(w http.ResponseWriter, r *http.Request) {
		n, _ := io.Copy(io.Discard, r.Body)
		fmt.Fprintf(w, "%s %d bytes, X-Test=%q", r.Method, n, r.Header.Get("X-Test"))
	})

	registerPolicyHandlers(mux)
	registerSSEHandlers(mux)
	registerWebSocketHandlers(mux)
	registerWebAPIHandlers(mux)
	registerFormHandlers(mux)
	registerImageHandlers(mux)
	registerMediaHandlers(mux)
	registerVideoHandlers(mux)
	registerFirstPaintHandlers(mux)
	registerJSLoadHandlers(mux)
	registerJSWebHandlers(mux)
	registerDownloadHandlers(mux)
	registerCacheHandlers(mux)
	registerFrameHandlers(mux)
	registerSWHandlers(mux)
	registerPartitionHandlers(mux)

	// every listener bound before anything is served or announced (ports.go)
	l := bindPorts(selfSigned())
	serveWPTOn(l.wpt, l.wptTLS)
	go func() { log.Fatal(http.Serve(l.other, mux)) }()
	go func() { log.Fatal(http.Serve(l.https, mux)) }()
	writePortFile()
	log.Printf("http://127.0.0.1:%d  https://127.0.0.1:%d (self-signed)  http://127.0.0.1:%d  web-platform-tests http://127.0.0.1:%d, checkout %s",
		basePort, basePort+1, basePort+2, wptHTTPPort, wptRoot)
	log.Fatal(http.Serve(l.http, mux))
}
