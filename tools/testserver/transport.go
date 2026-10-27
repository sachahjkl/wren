// Transport origins for the network stack's own tests (src/tools/nettest), on the upper half of the block (ports.go):
//
//	base+5  https, HTTP/2 and HTTP/1.1, certificate of the test authority; HTTP/3 on UDP base+5, announced by Alt-Svc
//	base+6  https, TLS 1.3 only; announces HTTP/3 on UDP base+6 where nothing listens (QUIC never gets through: the
//	        client must fall back to TCP, the odin-lang.org case)
//	base+7  https, an expired certificate of the test authority
//	base+8  https, a certificate of the test authority for another name
//	base+9  an HTTP proxy: CONNECT tunnels and absolute-form requests (answers carry X-Test-Proxy: 1)
//
// The test authority is made at start; /testca.pem gives it (a client trusts it through network.tls.extra_ca_file).
// Handlers on every origin: /stall (headers after 3 s), /cut (a body cut short), /garbage (not HTTP),
// /proxystats (what the proxy carried).
package main

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/pem"
	"fmt"
	"io"
	"log"
	"math/big"
	"net"
	"net/http"
	"strings"
	"sync/atomic"
	"time"

	"github.com/quic-go/quic-go/http3"
)

type testAuthority struct {
	cert *x509.Certificate
	key  *ecdsa.PrivateKey
	pem  []byte
}

var (
	testCA        = newTestAuthority()
	proxyTunnels  atomic.Int64
	proxyForwards atomic.Int64
)

func newTestAuthority() *testAuthority {
	key, _ := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	tpl := x509.Certificate{
		SerialNumber:          big.NewInt(time.Now().UnixNano()),
		Subject:               pkix.Name{CommonName: "Wren test authority"},
		NotBefore:             time.Now().Add(-time.Hour),
		NotAfter:              time.Now().Add(7 * 24 * time.Hour),
		IsCA:                  true,
		BasicConstraintsValid: true,
		KeyUsage:              x509.KeyUsageCertSign | x509.KeyUsageDigitalSignature,
	}
	der, _ := x509.CreateCertificate(rand.Reader, &tpl, &tpl, &key.PublicKey, key)
	cert, _ := x509.ParseCertificate(der)
	return &testAuthority{cert: cert, key: key, pem: pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der})}
}

// A leaf of the test authority for these names, valid from..until.
func (ca *testAuthority) leaf(names []string, from, until time.Time) tls.Certificate {
	key, _ := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	tpl := x509.Certificate{
		SerialNumber: big.NewInt(time.Now().UnixNano()),
		Subject:      pkix.Name{CommonName: names[0]},
		NotBefore:    from,
		NotAfter:     until,
		KeyUsage:     x509.KeyUsageDigitalSignature,
		ExtKeyUsage:  []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth},
	}
	for _, n := range names {
		if ip := net.ParseIP(n); ip != nil {
			tpl.IPAddresses = append(tpl.IPAddresses, ip)
		} else {
			tpl.DNSNames = append(tpl.DNSNames, n)
		}
	}
	der, _ := x509.CreateCertificate(rand.Reader, &tpl, ca.cert, &key.PublicKey, ca.key)
	return tls.Certificate{Certificate: [][]byte{der}, PrivateKey: key} // as real servers do: not the root
}

func registerTransportHandlers(mux *http.ServeMux) {
	mux.HandleFunc("/testca.pem", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/x-pem-file")
		w.Write(testCA.pem)
	})
	mux.HandleFunc("/stall", func(w http.ResponseWriter, r *http.Request) {
		select {
		case <-r.Context().Done():
			return
		case <-time.After(3 * time.Second):
		}
		io.WriteString(w, "late")
	})
	mux.HandleFunc("/cut", func(w http.ResponseWriter, r *http.Request) {
		hj, ok := w.(http.Hijacker)
		if !ok {
			http.Error(w, "no hijack on this protocol", http.StatusNotImplemented)
			return
		}
		c, buf, err := hj.Hijack()
		if err != nil {
			return
		}
		buf.WriteString("HTTP/1.1 200 OK\r\nContent-Length: 100000\r\nContent-Type: text/plain\r\n\r\n")
		buf.WriteString(strings.Repeat("x", 1000))
		buf.Flush()
		c.Close()
	})
	mux.HandleFunc("/garbage", func(w http.ResponseWriter, r *http.Request) {
		hj, ok := w.(http.Hijacker)
		if !ok {
			http.Error(w, "no hijack on this protocol", http.StatusNotImplemented)
			return
		}
		c, buf, err := hj.Hijack()
		if err != nil {
			return
		}
		buf.WriteString("THIS IS NOT HTTP AT ALL\r\n\r\n")
		buf.Flush()
		c.Close()
	})
	mux.HandleFunc("/proxystats", func(w http.ResponseWriter, r *http.Request) {
		fmt.Fprintf(w, "tunnels=%d forwards=%d", proxyTunnels.Load(), proxyForwards.Load())
	})
}

// Adds Alt-Svc to every answer.
func withAltSvc(h http.Handler, port int) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Alt-Svc", fmt.Sprintf(`h3=":%d"; ma=600`, port))
		h.ServeHTTP(w, r)
	})
}

func proxyHandler(w http.ResponseWriter, r *http.Request) {
	if r.Method == http.MethodConnect {
		dst, err := net.DialTimeout("tcp", r.Host, 5*time.Second)
		if err != nil {
			http.Error(w, err.Error(), http.StatusBadGateway)
			return
		}
		proxyTunnels.Add(1)
		c, buf, err := w.(http.Hijacker).Hijack()
		if err != nil {
			dst.Close()
			return
		}
		c.Write([]byte("HTTP/1.1 200 Connection established\r\n\r\n"))
		go func() {
			io.Copy(dst, buf.Reader)
			dst.(*net.TCPConn).CloseWrite()
		}()
		io.Copy(c, dst)
		c.Close()
		dst.Close()
		return
	}
	if !r.URL.IsAbs() {
		http.Error(w, "a proxy wants absolute URLs", http.StatusBadRequest)
		return
	}
	proxyForwards.Add(1)
	out := r.Clone(r.Context())
	out.RequestURI = ""
	resp, err := http.DefaultTransport.RoundTrip(out)
	if err != nil {
		http.Error(w, err.Error(), http.StatusBadGateway)
		return
	}
	defer resp.Body.Close()
	for k, v := range resp.Header {
		w.Header()[k] = v
	}
	w.Header().Set("X-Test-Proxy", "1")
	w.WriteHeader(resp.StatusCode)
	io.Copy(w, resp.Body)
}

// Serves the transport origins on the listeners bound by bindPorts.
func serveTransport(l *portListeners, mux http.Handler) {
	names := []string{"localhost", "127.0.0.1", "::1"}
	now := time.Now()
	good := testCA.leaf(names, now.Add(-time.Hour), now.Add(24*time.Hour))
	expired := testCA.leaf(names, now.Add(-48*time.Hour), now.Add(-24*time.Hour))
	wrong := testCA.leaf([]string{"other.invalid"}, now.Add(-time.Hour), now.Add(24*time.Hour))

	serveTLS := func(ln net.Listener, cfg *tls.Config, h http.Handler) {
		srv := &http.Server{Handler: h, TLSConfig: cfg, ErrorLog: log.New(io.Discard, "", 0)}
		go func() { log.Fatal(srv.ServeTLS(ln, "", "")) }()
	}
	serveTLS(l.h2, &tls.Config{Certificates: []tls.Certificate{good}}, withAltSvc(mux, basePort+5))
	serveTLS(l.tls13, &tls.Config{Certificates: []tls.Certificate{good}, MinVersion: tls.VersionTLS13}, withAltSvc(mux, basePort+6))
	serveTLS(l.expired, &tls.Config{Certificates: []tls.Certificate{expired}}, mux)
	serveTLS(l.wrongName, &tls.Config{Certificates: []tls.Certificate{wrong}}, mux)
	go func() { log.Fatal(http.Serve(l.proxy, http.HandlerFunc(proxyHandler))) }()

	h3 := &http3.Server{Handler: withAltSvc(mux, basePort+5), TLSConfig: http3.ConfigureTLSConfig(&tls.Config{Certificates: []tls.Certificate{good}})}
	go func() { log.Fatal(h3.Serve(l.h3)) }()
}
