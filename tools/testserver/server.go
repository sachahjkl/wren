// Local server for exercising the network stack (Go's standard library, plus quic-go for HTTP/3: transport.go), as a
// library: Start listens and serves on goroutines of the process that calls it. What calls it:
//
//	cdll/            build\testserver.dll, what the Odin tests load and start in their own process (src/testserver)
//	cmd/testserver/  build\testserver.exe, a thin main for what is not Odin: the scripts, the demos, the release package
//
//	/                hello
//	/big?mb=N        N MB of incompressible bytes, streamed
//	/gzip            text with Content-Encoding: gzip
//	/redirect?n=K    K redirects, then /
//	/status/NNN      replies NNN
//	/slow            one byte every 100 ms for 10 s
//	/echo            POST: replies with the request body length and the X-Test header
package testserver

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
	"net"
	"net/http"
	"strconv"
	"strings"
	"sync/atomic"
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

// How a server starts.
type Options struct {
	BasePort int    // the first block tried (0: 8765)
	Scan     bool   // a busy block is not an error: the next free one is taken
	WPTOnly  bool   // the WPT origin alone, from WPTPort (or BasePort)
	WPTPort  int    // fixes the WPT origin's first port (0: it moves with the block)
	SiteDir  string // the folder of /site/ ("": examples/site from the working directory, else demos beside the program)
}

// Binds everything, or nothing, then serves on goroutines and returns the base port of the block it took (the WPT origin's
// first port with WPTOnly). One server per process: the origins and what the handlers count are the package's.
func Start(o Options) (int, error) {
	if o.BasePort > 0 {
		basePort = o.BasePort
	}
	siteDir = findSiteDir(o.SiteDir)
	wptRoot = findWPTFile("WREN_WPT_ROOT", "build", "wpt", "wpt")
	wptReport = findWPTFile("WREN_WPT_REPORT", "wpt", "testharnessreport.js")
	if o.WPTOnly {
		return startWPTOnly(o)
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
	registerTransportHandlers(mux)

	// every listener bound before anything is served or announced (ports.go)
	l, err := bindPorts(selfSigned(), o)
	if err != nil {
		return 0, err
	}
	serveWPTOn(l.wpt, l.wptTLS)
	serveTransport(l, mux)
	serve(l.other, mux)
	serve(l.https, mux)
	serve(l.http, mux)
	log.Printf("http://127.0.0.1:%d  https://127.0.0.1:%d (self-signed)  http://127.0.0.1:%d  web-platform-tests http://127.0.0.1:%d, checkout %s",
		basePort, basePort+1, basePort+2, wptHTTPPort, wptRoot)
	return basePort, nil
}

// Serves a listener for as long as the process lives.
func serve(l net.Listener, h http.Handler) {
	go func() { log.Print(http.Serve(l, h)) }()
}

// What the handlers have counted and kept goes, as for a new server: a test that starts one finds nothing of the last test's.
func Reset() {
	cacheCounts.Lock()
	cacheCounts.hits, cacheCounts.nm, cacheCounts.last = map[string]int{}, map[string]int{}, map[string]string{}
	cacheCounts.Unlock()
	imageCounts.Lock()
	imageCounts.m = map[string]int{}
	imageCounts.Unlock()
	jsloadHits.Lock()
	jsloadHits.m = map[string]int{}
	jsloadHits.Unlock()
	beacon.Lock()
	beacon.count, beacon.body, beacon.ctype = 0, "", ""
	beacon.Unlock()
	mediaAccept.Lock()
	mediaAccept.m = map[string]string{}
	mediaAccept.Unlock()
	atomic.StoreInt64(&preflights, 0)
	sseMu.Lock()
	sseHits = map[string]int{}
	sseMu.Unlock()
	swVersion.Store(1)
	proxyTunnels.Store(0)
	proxyForwards.Store(0)
	videoCounts.Lock()
	videoCounts.n, videoCounts.rng = map[string]int{}, map[string]string{}
	videoCounts.Unlock()
	atomic.StoreInt64(&wsHandshakes, 0)
	wsLastClose.Clear()
	httpCacheStash.Lock()
	httpCacheStash.m = map[string][]map[string]any{}
	httpCacheStash.Unlock()
}
