// What `wrentool replay` serves: the answers a load was given (src/net/record.odin wrote them, one <number>.http a piece), again, with no latency of its own, on one
// port for every name: the browser sends every connection there (network.hosts "*=127.0.0.1:port") and the first byte says TLS or plain http. A certificate
// for a name comes from the test authority when the name is first seen, so neither the hosts file nor the machine's trust store is touched.
//
// Which answer: the n-th ask of a method and URL gets the n-th answer recorded for them, then the last again. A URL never recorded gets the first answer of
// its method and path, whatever its query (a cache buster the server wrote into a script). Anything else is a 404 with nothing in it: a deterministic answer,
// counted, so that a load that left its recording shows.
package testserver

import (
	"bufio"
	"bytes"
	"crypto/tls"
	"fmt"
	"net"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"
)

const (
	replayTLSRecord = 0x16 // the first byte of a TLS handshake
	replayCertDays  = 7
)

// What goes between one hop and the next, or would send the browser away from this server.
var replayHeadersLeftOut = map[string]bool{"connection": true, "keep-alive": true, "transfer-encoding": true, "content-length": true, "alt-svc": true, "upgrade": true}

// How an ask was answered.
type ReplayKind int

const (
	ReplayExact ReplayKind = iota
	ReplayNear
	ReplayUnknown
	replayKinds
)

type replayAnswer struct {
	status int
	header http.Header
	body   []byte
}

// A recording, and where the load being replayed is in it.
type Replay struct {
	exact  map[string][]*replayAnswer // "METHOD url"
	near   map[string]*replayAnswer   // "METHOD url without its query"
	mu     sync.Mutex
	asked  map[string]int
	counts [replayKinds]int
	missed []string
	certs  sync.Map // name -> *tls.Certificate
}

func replayNearKey(method, address string) string {
	if q := strings.IndexByte(address, '?'); q >= 0 {
		address = address[:q]
	}
	return method + " " + address
}

// One <number>.http: "METHOD URL\n", the head, an empty line, the body.
func parseReplayFile(data []byte) (method, address string, a *replayAnswer, err error) {
	line, rest, found := bytes.Cut(data, []byte("\n"))
	if !found {
		return "", "", nil, fmt.Errorf("no first line")
	}
	first := strings.SplitN(string(line), " ", 2)
	if len(first) != 2 {
		return "", "", nil, fmt.Errorf("no method and URL")
	}
	head, body, found := bytes.Cut(rest, []byte("\r\n\r\n"))
	if !found {
		return "", "", nil, fmt.Errorf("no end of head")
	}
	lines := strings.Split(string(head), "\r\n")
	status := strings.Fields(lines[0])
	if len(status) < 2 {
		return "", "", nil, fmt.Errorf("no status line")
	}
	code, err := strconv.Atoi(status[1])
	if err != nil {
		return "", "", nil, err
	}
	a = &replayAnswer{status: code, header: http.Header{}, body: body}
	for _, l := range lines[1:] {
		name, value, ok := strings.Cut(l, ": ")
		if ok && !replayHeadersLeftOut[strings.ToLower(name)] {
			a.header.Add(name, value)
		}
	}
	address, _, _ = strings.Cut(first[1], "#")
	return first[0], address, a, nil
}

// LoadReplay reads a recording's folder, in the order it was written.
func LoadReplay(dir string) (*Replay, error) {
	names, err := filepath.Glob(filepath.Join(dir, "*.http"))
	if err != nil {
		return nil, err
	}
	if len(names) == 0 {
		return nil, fmt.Errorf("%s holds no recording", dir)
	}
	sort.Strings(names)
	r := &Replay{exact: map[string][]*replayAnswer{}, near: map[string]*replayAnswer{}, asked: map[string]int{}}
	for _, name := range names {
		data, err := os.ReadFile(name)
		if err != nil {
			return nil, err
		}
		method, address, a, err := parseReplayFile(data)
		if err != nil {
			return nil, fmt.Errorf("%s: %w", name, err)
		}
		key := method + " " + address
		r.exact[key] = append(r.exact[key], a)
		if near := replayNearKey(method, address); r.near[near] == nil {
			r.near[near] = a
		}
	}
	return r, nil
}

// Rewind puts the recording back at its start: the next load is asked as the first was.
func (r *Replay) Rewind() {
	r.mu.Lock()
	defer r.mu.Unlock()
	clear(r.asked)
	r.counts = [replayKinds]int{}
	r.missed = nil
}

// Counts says how the asks since the last Rewind were answered, and which were unknown.
func (r *Replay) Counts() (counts [3]int, missed []string) {
	r.mu.Lock()
	defer r.mu.Unlock()
	return r.counts, append([]string(nil), r.missed...)
}

func (r *Replay) answer(method, address string) *replayAnswer {
	r.mu.Lock()
	defer r.mu.Unlock()
	key := method + " " + address
	if list := r.exact[key]; len(list) > 0 {
		n := min(r.asked[key], len(list)-1)
		r.asked[key]++
		r.counts[ReplayExact]++
		return list[n]
	}
	if a := r.near[replayNearKey(method, address)]; a != nil {
		r.counts[ReplayNear]++
		return a
	}
	r.counts[ReplayUnknown]++
	r.missed = append(r.missed, key)
	return nil
}

func (r *Replay) ServeHTTP(w http.ResponseWriter, q *http.Request) {
	scheme := "http"
	if q.TLS != nil {
		scheme = "https"
	}
	a := r.answer(q.Method, (&url.URL{Scheme: scheme, Host: q.Host}).String()+q.RequestURI)
	if a == nil {
		w.WriteHeader(http.StatusNotFound)
		return
	}
	for name, values := range a.header {
		w.Header()[name] = values
	}
	if a.status >= 200 && a.status != http.StatusNoContent && a.status != http.StatusNotModified {
		w.Header().Set("Content-Length", strconv.Itoa(len(a.body)))
	}
	w.WriteHeader(a.status)
	if q.Method != http.MethodHead {
		w.Write(a.body)
	}
}

func (r *Replay) certificate(hello *tls.ClientHelloInfo) (*tls.Certificate, error) {
	name := hello.ServerName
	if name == "" {
		name = "localhost" // (an address in the URL: no name to show)
	}
	if c, ok := r.certs.Load(name); ok {
		return c.(*tls.Certificate), nil
	}
	now := time.Now()
	c := testCA.leaf([]string{name}, now.Add(-time.Hour), now.Add(replayCertDays*24*time.Hour))
	got, _ := r.certs.LoadOrStore(name, &c)
	return got.(*tls.Certificate), nil
}

// The connection whose first byte was looked at.
type replayConn struct {
	net.Conn
	r *bufio.Reader
}

func (c *replayConn) Read(b []byte) (int, error) { return c.r.Read(b) }

// What http.Server takes connections from: those of the real listener, TLS or not by their first byte.
type replayListener struct {
	net.Listener
	conns chan net.Conn
}

func (l *replayListener) Accept() (net.Conn, error) {
	c, ok := <-l.conns
	if !ok {
		return nil, net.ErrClosed
	}
	return c, nil
}

func (l *replayListener) sort(config *tls.Config) {
	defer close(l.conns)
	for {
		c, err := l.Listener.Accept()
		if err != nil {
			return
		}
		go func() {
			rc := &replayConn{c, bufio.NewReader(c)}
			first, err := rc.r.Peek(1)
			if err != nil {
				c.Close()
				return
			}
			if first[0] == replayTLSRecord {
				l.conns <- tls.Server(rc, config)
			} else {
				l.conns <- rc
			}
		}()
	}
}

// Serve listens on a free port of 127.0.0.1 and serves on goroutines until the listener closes: its port.
func (r *Replay) Serve() (int, net.Listener, error) {
	inner, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		return 0, nil, err
	}
	config := &tls.Config{GetCertificate: r.certificate, NextProtos: []string{"h2", "http/1.1"}}
	l := &replayListener{inner, make(chan net.Conn)}
	go l.sort(config)
	go (&http.Server{Handler: r, TLSConfig: config}).Serve(l)
	return inner.Addr().(*net.TCPAddr).Port, inner, nil
}
