// What a Python handler of web-platform-tests sees and answers, as wptserve gives it: a request with its raw headers, a stash,
// and a response written byte for byte (the reason phrase of a status line, a header's case, order and repetition, an empty
// value, a 204 with a body: net/http keeps none of them), and x.asis files, whole responses on disk. The handlers
// themselves: wpt_xhr.go, wpt_fetch.go.
package testserver

import (
	"bytes"
	"context"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"os"
	"strconv"
	"strings"
	"sync"
	"time"
)

// What a connection keeps of what it read while no request's head is taken, and what is left of it past that.
const (
	rawHeadKeepBytes = 1 << 20
	rawHeadTailBytes = 1 << 16
	wptServerName    = "BaseHTTP/0.6 Python/3" // what wptserve says it is
)

// rawConn remembers the bytes of a plain connection's requests, for the raw headers net/http canonicalizes. (Not a TLS
// connection: net/http must see the *tls.Conn; a handler there sees the canonical names.)
type rawConn struct {
	net.Conn
	mu   sync.Mutex
	seen []byte
}

func (c *rawConn) Read(b []byte) (int, error) {
	n, err := c.Conn.Read(b)
	c.mu.Lock()
	c.seen = append(c.seen, b[:n]...)
	if len(c.seen) > rawHeadKeepBytes {
		c.seen = append(c.seen[:0], c.seen[len(c.seen)-rawHeadTailBytes:]...)
	}
	c.mu.Unlock()
	return n, err
}

// The header lines of the request that starts with `line`, the latest one read; what came before them goes.
func (c *rawConn) head(line string) []string {
	c.mu.Lock()
	defer c.mu.Unlock()
	i := bytes.LastIndex(c.seen, []byte(line+"\r\n"))
	if i < 0 {
		return nil
	}
	rest := c.seen[i+len(line)+2:]
	end := bytes.Index(rest, []byte("\r\n\r\n"))
	if end < 0 {
		return nil
	}
	lines := strings.Split(string(rest[:end]), "\r\n")
	c.seen = append(c.seen[:0], rest[end+4:]...)
	return lines
}

type rawListener struct{ net.Listener }

func (l rawListener) Accept() (net.Conn, error) {
	c, err := l.Listener.Accept()
	if err != nil {
		return nil, err
	}
	return &rawConn{Conn: c}, nil
}

type rawConnKey struct{}

// Serves a plain listener whose handlers can ask for a request's raw headers.
func serveRaw(l net.Listener, h http.Handler) {
	s := &http.Server{Handler: h, ConnContext: func(ctx context.Context, c net.Conn) context.Context {
		return context.WithValue(ctx, rawConnKey{}, c)
	}}
	go s.Serve(rawListener{l})
}

// The header pairs of a request as the client wrote them; on a connection that kept none, net/http's.
func rawHeaders(r *http.Request) [][2]string {
	var out [][2]string
	if c, ok := r.Context().Value(rawConnKey{}).(*rawConn); ok {
		for _, line := range c.head(fmt.Sprintf("%s %s %s", r.Method, r.RequestURI, r.Proto)) {
			if name, value, found := strings.Cut(line, ":"); found {
				out = append(out, [2]string{name, strings.Trim(value, " \t")})
			}
		}
	}
	if out == nil {
		for name, values := range r.Header {
			for _, v := range values {
				out = append(out, [2]string{name, v})
			}
		}
	}
	return out
}

// pyRequest: wptserve's request.
type pyRequest struct {
	r    *http.Request
	body []byte
	q    url.Values
	raw  [][2]string
}

func (q *pyRequest) has(name string) bool { return q.q.Has(name) }

// request.GET.first(name, fallback)
func (q *pyRequest) first(name, fallback string) string {
	if q.q.Has(name) {
		return q.q.Get(name)
	}
	return fallback
}

func (q *pyRequest) firstInt(name string, fallback int) int {
	if n, err := strconv.Atoi(q.q.Get(name)); err == nil {
		return n
	}
	return fallback
}

// A number of milliseconds of the query.
func (q *pyRequest) firstMs(name string, fallback int) time.Duration {
	if f, err := strconv.ParseFloat(q.q.Get(name), 64); err == nil {
		return time.Duration(f * float64(time.Millisecond))
	}
	return time.Duration(fallback) * time.Millisecond
}

func (q *pyRequest) hasHeader(name string) bool {
	_, ok := q.r.Header[http.CanonicalHeaderKey(name)]
	return ok || strings.EqualFold(name, "Host")
}

// request.headers.get(name, fallback)
func (q *pyRequest) header(name, fallback string) string {
	if strings.EqualFold(name, "Host") {
		return q.r.Host
	}
	if q.hasHeader(name) {
		return q.r.Header.Get(name)
	}
	return fallback
}

func (q *pyRequest) origin() string { return q.header("Origin", "") }

func (q *pyRequest) scheme() string {
	if q.r.TLS != nil {
		return "https"
	}
	return "http"
}

// request.POST: the fields of a form body, urlencoded or multipart.
func (q *pyRequest) post() (*http.Request, error) {
	form := q.r.Clone(q.r.Context())
	form.Body = io.NopCloser(bytes.NewReader(q.body))
	form.URL = &url.URL{Path: q.r.URL.Path}
	if strings.HasPrefix(q.r.Header.Get("Content-Type"), "multipart/") {
		return form, form.ParseMultipartForm(int64(len(q.body)) + 1)
	}
	return form, form.ParseForm()
}

// pyResponse: wptserve's response. No code: 200; no text: the code's own reason phrase.
type pyResponse struct {
	code    int
	text    string
	headers [][2]string
	body    []byte
	conn    net.Conn // once out of net/http's hands
	req     *pyRequest
	w       http.ResponseWriter
}

func (p *pyResponse) add(name, value string) { p.headers = append(p.headers, [2]string{name, value}) }

// response.headers.set: one value in place of those of that name.
func (p *pyResponse) set(name, value string) {
	kept := p.headers[:0]
	for _, h := range p.headers {
		if !strings.EqualFold(h[0], name) {
			kept = append(kept, h)
		}
	}
	p.headers = append(kept, [2]string{name, value})
}

func (p *pyResponse) has(name string) bool {
	for _, h := range p.headers {
		if strings.EqualFold(h[0], name) {
			return true
		}
	}
	return false
}

func (p *pyResponse) status(code int) { p.code, p.text = code, "" }

func (p *pyResponse) cookie(name, value string, expires time.Time, attributes string) {
	c := name + "=" + value + "; Path=/" + attributes
	if !expires.IsZero() {
		c += "; Expires=" + expires.UTC().Format(http.TimeFormat)
	}
	p.add("Set-Cookie", c)
}

func (p *pyResponse) head() []byte {
	code, text := p.code, p.text
	if code == 0 {
		code = http.StatusOK
	}
	if text == "" {
		text = http.StatusText(code)
	}
	var b bytes.Buffer
	fmt.Fprintf(&b, "HTTP/1.1 %d %s\r\n", code, text)
	for _, h := range p.headers {
		fmt.Fprintf(&b, "%s: %s\r\n", h[0], h[1])
	}
	// (the end of the socket ends the exchange: a client must not keep the connection for its next request)
	if !p.has("Connection") {
		b.WriteString("Connection: close\r\n")
	}
	if !p.has("Server") {
		fmt.Fprintf(&b, "Server: %s\r\n", wptServerName)
	}
	if !p.has("Date") {
		fmt.Fprintf(&b, "Date: %s\r\n", time.Now().UTC().Format(http.TimeFormat))
	}
	b.WriteString("\r\n")
	return b.Bytes()
}

// The connection, out of net/http's hands (closed at the end of the handler, which ends a body without a length).
func (p *pyResponse) takeConn() bool {
	if p.conn != nil {
		return true
	}
	h, ok := p.w.(http.Hijacker)
	if !ok {
		return false
	}
	c, _, err := h.Hijack()
	if err != nil {
		return false
	}
	p.conn = c
	return true
}

// response.write_status_headers: the handler goes on with write and its sleeps.
func (p *pyResponse) start() {
	if p.takeConn() {
		p.conn.Write(p.head())
	}
}

func (p *pyResponse) write(data []byte) {
	if p.conn != nil {
		p.conn.Write(data)
	}
}

func (p *pyResponse) finish() {
	if p.conn == nil {
		if !p.has("Content-Length") {
			p.add("Content-Length", strconv.Itoa(len(p.body)))
		}
		p.start()
		if p.req.r.Method != http.MethodHead {
			p.write(p.body)
		}
	}
	if p.conn != nil {
		p.conn.Close()
	}
}

// A Python handler in Go.
func wptPy(main func(q *pyRequest, p *pyResponse)) func(w http.ResponseWriter, r *http.Request) {
	return func(w http.ResponseWriter, r *http.Request) {
		body, _ := io.ReadAll(r.Body)
		q := &pyRequest{r: r, body: body, q: r.URL.Query(), raw: rawHeaders(r)}
		p := &pyResponse{req: q, w: w}
		main(q, p)
		p.finish()
	}
}

// wptserve's x.asis: the file is the whole response.
func serveAsIs(w http.ResponseWriter, full string) {
	data, err := os.ReadFile(full)
	if err != nil {
		http.Error(w, err.Error(), http.StatusNotFound)
		return
	}
	if h, ok := w.(http.Hijacker); ok {
		if c, _, err := h.Hijack(); err == nil {
			c.Write(data)
			// (wptserve leaves a file that stops after its last header as it is: the end of the socket closes the head
			// for the other browsers, and an incomplete message for hyper. What these files test is what the headers say.)
			if !bytes.HasSuffix(data, []byte("\n\n")) && !bytes.Contains(data, []byte("\n\n")) && !bytes.Contains(data, []byte("\r\n\r\n")) {
				c.Write([]byte("\n"))
			}
			c.Close()
		}
	}
}

// The stash of wptserve: a key's value, taken once. A scope (a handler, or the folder it names) has its own keys.
var pyStash = struct {
	sync.Mutex
	m map[[2]string]any
}{m: map[[2]string]any{}}

func wptStashReset() {
	pyStash.Lock()
	pyStash.m = map[[2]string]any{}
	pyStash.Unlock()
}

func stashPut(scope, key string, value any) {
	pyStash.Lock()
	pyStash.m[[2]string{scope, key}] = value
	pyStash.Unlock()
}

func stashTake(scope, key string) (any, bool) {
	pyStash.Lock()
	defer pyStash.Unlock()
	v, ok := pyStash.m[[2]string{scope, key}]
	delete(pyStash.m, [2]string{scope, key})
	return v, ok
}

// A handler's state kept as a string: "Uninitialized" when there is none, or an empty one.
func stashState(scope, key string) string {
	if v, ok := stashTake(scope, key); ok {
		if s, _ := v.(string); s != "" {
			return s
		}
	}
	return "Uninitialized"
}
