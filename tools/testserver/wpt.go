// The web-platform-tests server (src/tools/wpt, src/tools/wpt): the pinned WPT checkout (build/wpt/wpt) served at its
// own origin, http://127.0.0.1:8768/ on the default block of ports (ports.go), since WPT paths are absolute (/resources/testharness.js), with the parts of
// wptserve the measured folders need:
//
//   - generated test pages: x.any.js -> x.any.html (window), x.any.worker.html + x.any.worker.js (dedicated worker);
//     x.window.js -> x.window.html; x.worker.js -> x.worker.html. "// META: script=, title=, timeout=" are honored
//     (the query of the page, its variant, passes to the worker).
//   - substitutions in *.sub.* files and with ?pipe=sub: {{host}}, {{domains[..]}}, {{hosts[..][..]}}, {{ports[..][..]}},
//     {{location[..]}}, {{GET[..]}}, {{uuid()}}, {{header_or_default(..)}}.
//   - pipes: ?pipe=header(name,value[,True])|status(code)|sub (others are ignored).
//   - x.headers and __dir__.headers files: extra response headers.
//   - /resources/WebIDLParser.js is resources/webidl2/lib/webidl2.js, as wptserve routes it.
//   - /resources/testharnessreport.js is Wren's (wpt/testharnessreport.js of the repository): it hands the results to
//     the runner. /resources/testdriver-vendor.js too (wpt/testdriver-vendor.js): test_driver's input goes to the runner.
//   - Python handlers (*.py) do not run: 501, but for a few ported to Go (wpt_httpcache.go, wpt_handlers.go). The tests
//     that need the others fail, and are counted as failing.
//
// Cross-origin tests: the names of wptserve's configuration, all on this listener: web-platform.test ({{host}}), its subdomains
// www, www1, www2, xn--n8j6ds53lwwkrqhv28a and xn--lve-6lad ({{domains[..]}}), not-web-platform.test and its subdomains ({{hosts[alt][..]}}).
// The browser resolves them itself (network.hosts: web-platform.test=127.0.0.1 not-web-platform.test=127.0.0.1), never the system nor
// a hosts file; https: 127.0.0.1:8769 (the next port) with a self-signed certificate for those names; a second http port, 8767 (the block's
// second origin, answering the WPT names as this one: wptOrSite). With -wpt-port N the ports are N and N+1 (and N-1 with -wpt-only); with -wpt-only the
// server serves nothing else (src\tools\wpt runs the whole suite that way, on ports no other test uses).
// The checkout: WREN_WPT_ROOT, else build/wpt/wpt (from the repository root, as the tests run), else next to the
// executable (build\testserver.exe -> build\wpt\wpt). No checkout: the listener answers 503 with how to get one.
package testserver

import (
	"crypto/rand"
	"crypto/tls"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"os"
	"path"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"time"
)

// wptserve's names (its config.json: browser_host, alternate_hosts, subdomains; the two IDNA ones in their ASCII form).
const (
	wptHost    = "web-platform.test"
	wptAltHost = "not-web-platform.test"
)

var wptSubdomains = map[string]string{"www": "www", "www1": "www1", "www2": "www2", "天気の良い日": "xn--n8j6ds53lwwkrqhv28a", "élève": "xn--lve-6lad"}

// WPTHostsPref is what a browser under test resolves itself (Wren's network.hosts): every name the substitutions give.
const WPTHostsPref = wptHost + "=127.0.0.1 " + wptAltHost + "=127.0.0.1"

// The certificate of the WPT https origin: the test authority's (a browser under test trusts it through network.tls.extra_ca_file, as wptrunner
// hands its browsers WPT's own authority), for every name of the substitutions.
func wptCert() tls.Certificate {
	return testCA.leaf([]string{wptHost, "*." + wptHost, wptAltHost, "*." + wptAltHost, "127.0.0.1"}, time.Now().Add(-time.Hour), time.Now().Add(7*24*time.Hour))
}

// {{domains[sub]}}, {{hosts[alt][sub]}}: sub."host" ("" : the host itself); a subdomain wptserve does not know is left as it is.
func wptName(alt bool, sub string) string {
	host := wptHost
	if alt {
		host = wptAltHost
	}
	if sub == "" {
		return host
	}
	if s, ok := wptSubdomains[sub]; ok {
		return s + "." + host
	}
	return sub + "." + host
}

// The WPT origin is 127.0.0.1:N (https: N+1): by default the fourth and fifth ports of the block (ports.go: 8768 / 8769 on the
// default block), or Options.WPTPort. Options.WPTOnly: nothing else is served (src\tools\wpt runs the full suite on ports of
// its own); there Options.Scan takes the next free pair (N+10...).
var (
	wptHTTPPort  = defaultBasePort + 3
	wptHTTPSPort = wptHTTPPort + 1
	// {{ports[http][1]}}, wptserve's second http port (another origin of the same names): the block's second http origin (base+2), whose
	// listener answers requests to the WPT names as the WPT origin does (wptOrSite); with -wpt-only the port before the pair. 0: none.
	wptHTTPPort2 = 0
)

// Whether a request names the WPT origin: one of wptserve's names or a subdomain of them.
func wptNamed(r *http.Request) bool {
	host, _, err := net.SplitHostPort(r.Host)
	if err != nil {
		host = r.Host
	}
	for _, h := range []string{wptHost, wptAltHost} {
		if host == h || strings.HasSuffix(host, "."+h) {
			return true
		}
	}
	return false
}

// The second http origin of the block: the WPT origin's second port for requests to the WPT names, the site's for the others.
func wptOrSite(site http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if wptNamed(r) {
			serveWPT(w, r)
			return
		}
		site.ServeHTTP(w, r)
	})
}

// The WPT origin alone: returns its first port.
func startWPTOnly(o Options) (int, error) {
	tries := 1
	if o.Scan {
		tries = scanTries
	}
	first := o.WPTPort
	if first == 0 {
		first = basePort + 3
	}
	var plain, secure, second net.Listener
	var err error
	for i := 0; i < tries; i++ {
		wptHTTPPort = first + i*scanStep
		wptHTTPSPort = wptHTTPPort + 1
		wptHTTPPort2 = wptHTTPPort - 1   // (where the block has its second origin: base+2)
		if plain, err = net.Listen("tcp", fmt.Sprintf("127.0.0.1:%d", wptHTTPPort)); err != nil {
			continue
		}
		if secure, err = net.Listen("tcp", fmt.Sprintf("127.0.0.1:%d", wptHTTPSPort)); err != nil {
			plain.Close()
			continue
		}
		if second, err = net.Listen("tcp", fmt.Sprintf("127.0.0.1:%d", wptHTTPPort2)); err != nil {
			plain.Close()
			secure.Close()
			continue
		}
		break
	}
	if err != nil {
		return 0, fmt.Errorf("no free ports for web-platform-tests from %d: %w", first, err)
	}
	log.Printf("web-platform-tests: http://127.0.0.1:%d  https://127.0.0.1:%d (self-signed)  http://127.0.0.1:%d, checkout %s", wptHTTPPort, wptHTTPSPort, wptHTTPPort2, wptRoot)
	serveWPTOn(plain, tls.NewListener(secure, &tls.Config{Certificates: []tls.Certificate{wptCert()}}))
	serve(second, http.HandlerFunc(serveWPT))
	return wptHTTPPort, nil
}

func findWPTFile(env string, rel ...string) string {
	if v := os.Getenv(env); v != "" {
		return v
	}
	cands := []string{filepath.Join(rel...)}
	if exe, err := os.Executable(); err == nil {
		dir := filepath.Dir(exe)
		cands = append(cands, filepath.Join(append([]string{dir, ".."}, rel...)...), filepath.Join(append([]string{dir}, rel[1:]...)...))
	}
	for _, c := range cands {
		if _, err := os.Stat(c); err == nil {
			return c
		}
	}
	return cands[0]
}

var (
	wptRoot   = findWPTFile("WREN_WPT_ROOT", "build", "wpt", "wpt")
	wptReport = findWPTFile("WREN_WPT_REPORT", "wpt", "testharnessreport.js")
	wptVendor = findWPTFile("WREN_WPT_VENDOR", "wpt", "testdriver-vendor.js")
)

// The WPT origin on its two listeners (the TLS one already wrapped), each served from its own goroutine.
func serveWPTOn(plain, secure net.Listener) {
	h := http.HandlerFunc(serveWPT)
	serve(plain, h)
	serve(secure, h)
}

var wptTypes = map[string]string{
	".html": "text/html", ".htm": "text/html", ".xhtml": "application/xhtml+xml", ".xht": "application/xhtml+xml",
	".xml": "application/xml", ".svg": "image/svg+xml", ".js": "text/javascript", ".mjs": "text/javascript",
	".json": "application/json", ".css": "text/css", ".txt": "text/plain", ".png": "image/png", ".gif": "image/gif",
	".jpg": "image/jpeg", ".jpeg": "image/jpeg", ".webp": "image/webp", ".ico": "image/x-icon", ".wasm": "application/wasm",
	".woff": "font/woff", ".woff2": "font/woff2", ".ttf": "font/ttf", ".otf": "font/otf", ".mp4": "video/mp4",
	".webm": "video/webm", ".ogg": "application/ogg", ".wav": "audio/wav", ".mp3": "audio/mpeg", ".pdf": "application/pdf",
	".bmp": "image/bmp", ".zip": "application/zip", ".gz": "application/gzip", ".csv": "text/csv", ".vtt": "text/vtt",
}

func wptType(name string) string {
	if t, ok := wptTypes[strings.ToLower(path.Ext(name))]; ok {
		return t
	}
	return "application/octet-stream"
}

// "// META: key=value" lines at the top of a .any.js / .window.js / .worker.js test.
type wptMeta struct{ key, value string }

func readMeta(src []byte) []wptMeta {
	var out []wptMeta
	for _, line := range strings.Split(string(src), "\n") {
		l := strings.TrimSpace(line)
		if !strings.HasPrefix(l, "//") {
			if l == "" {
				continue
			}
			break
		}
		l = strings.TrimSpace(strings.TrimPrefix(l, "//"))
		if !strings.HasPrefix(l, "META:") {
			continue
		}
		kv := strings.TrimSpace(strings.TrimPrefix(l, "META:"))
		if i := strings.IndexByte(kv, '='); i > 0 {
			out = append(out, wptMeta{strings.TrimSpace(kv[:i]), strings.TrimSpace(kv[i+1:])})
		}
	}
	return out
}

func htmlEscape(s string) string {
	return strings.NewReplacer("&", "&amp;", "<", "&lt;", ">", "&gt;", `"`, "&quot;").Replace(s)
}

func jsString(s string) string { return strconv.Quote(s) }

func metaHead(meta []wptMeta) string {
	var b strings.Builder
	for _, m := range meta {
		switch m.key {
		case "title":
			fmt.Fprintf(&b, "<title>%s</title>\n", htmlEscape(m.value))
		case "timeout":
			if m.value == "long" {
				b.WriteString("<meta name=\"timeout\" content=\"long\">\n")
			}
		}
	}
	return b.String()
}

const wptGlobalWindow = "<script>\nself.GLOBAL = {\n  isWindow: function() { return true; },\n  isWorker: function() { return false; },\n  isShadowRealm: function() { return false; },\n};\n</script>\n"

// The generated pages of wptserve. `src` is the test's script, `base` its URL path without the generated suffix.
func wptWrapper(kind string, src []byte, scriptPath, query string) (string, string) {
	meta := readMeta(src)
	var scripts strings.Builder
	var imports strings.Builder
	for _, m := range meta {
		if m.key == "script" {
			fmt.Fprintf(&scripts, "<script src=\"%s\"></script>\n", htmlEscape(m.value))
			fmt.Fprintf(&imports, "importScripts(%s);\n", jsString(m.value))
		}
	}
	head := "<!doctype html>\n<meta charset=utf-8>\n" + metaHead(meta)
	harness := "<script src=\"/resources/testharness.js\"></script>\n<script src=\"/resources/testharnessreport.js\"></script>\n"
	switch kind {
	case "any.html", "window.html":
		return "text/html; charset=utf-8", head + wptGlobalWindow + harness + scripts.String() + "<div id=log></div>\n" +
			fmt.Sprintf("<script src=\"%s\"></script>\n", htmlEscape(scriptPath))
	case "any.worker.html":
		worker := strings.TrimSuffix(scriptPath, ".js") + ".worker.js" + query
		return "text/html; charset=utf-8", head + harness + "<div id=log></div>\n<script>\nfetch_tests_from_worker(new Worker(" + jsString(worker) + "));\n</script>\n"
	case "worker.html":
		return "text/html; charset=utf-8", head + harness + "<div id=log></div>\n<script>\nfetch_tests_from_worker(new Worker(" + jsString(scriptPath+query) + "));\n</script>\n"
	case "any.worker.js":
		return "text/javascript; charset=utf-8", "self.GLOBAL = {\n  isWindow: function() { return false; },\n  isWorker: function() { return true; },\n  isShadowRealm: function() { return false; },\n};\n" +
			"importScripts(\"/resources/testharness.js\");\n" + imports.String() + "importScripts(" + jsString(scriptPath) + ");\ndone();\n"
	}
	return "", ""
}

var subPattern = regexp.MustCompile(`\{\{\s*([^{}]+?)\s*\}\}`)
var subIndex = regexp.MustCompile(`^(\w+)((?:\[[^\]]*\])*)$`)
var subIndexPart = regexp.MustCompile(`\[([^\]]*)\]`)

func newUUID() string {
	b := make([]byte, 16)
	rand.Read(b)
	b[6] = b[6]&0x0f | 0x40
	b[8] = b[8]&0x3f | 0x80
	return fmt.Sprintf("%x-%x-%x-%x-%x", b[0:4], b[4:6], b[6:8], b[8:10], b[10:16])
}

// wptserve's substitutions, for what the measured tests use; anything else is left as it is.
func substitute(text string, r *http.Request) string {
	host, port, err := net.SplitHostPort(r.Host)
	if err != nil {
		host, port = r.Host, strconv.Itoa(wptHTTPPort)
	}
	scheme := "http"
	if r.TLS != nil {
		scheme = "https"
	}
	return subPattern.ReplaceAllStringFunc(text, func(m string) string {
		expr := strings.TrimSpace(m[2 : len(m)-2])
		if expr == "uuid()" {
			return newUUID()
		}
		if strings.HasPrefix(expr, "header_or_default(") && strings.HasSuffix(expr, ")") {
			args := strings.SplitN(expr[len("header_or_default("):len(expr)-1], ",", 2)
			if len(args) == 2 {
				name := strings.Trim(strings.TrimSpace(args[0]), `"'`)
				if v := r.Header.Get(name); v != "" {
					return v
				}
				return strings.Trim(strings.TrimSpace(args[1]), `"'`)
			}
		}
		sm := subIndex.FindStringSubmatch(expr)
		if sm == nil {
			return m
		}
		var idx []string
		for _, part := range subIndexPart.FindAllStringSubmatch(sm[2], -1) {
			idx = append(idx, strings.Trim(part[1], `"'`))
		}
		at := func(i int) string {
			if i < len(idx) {
				return idx[i]
			}
			return ""
		}
		switch sm[1] {
		case "host":
			return wptHost
		case "domains":
			return wptName(false, at(0))
		case "hosts":
			return wptName(at(0) == "alt", at(1))
		case "ports":
			switch at(0) {
			case "https", "wss", "h2":
				return strconv.Itoa(wptHTTPSPort)
			default:
				if at(1) == "1" && wptHTTPPort2 != 0 {
					return strconv.Itoa(wptHTTPPort2)
				}
				return strconv.Itoa(wptHTTPPort)
			}
		case "location":
			switch at(0) {
			case "scheme":
				return scheme
			case "host":
				return r.Host
			case "hostname":
				return host
			case "port":
				return port
			case "path", "pathname":
				return r.URL.Path
			case "query":
				if r.URL.RawQuery == "" {
					return ""
				}
				return "?" + r.URL.RawQuery
			case "server":
				return scheme + "://" + r.Host
			}
		case "GET":
			return r.URL.Query().Get(at(0))
		}
		return m
	})
}

// The headers of x.headers and of the folder's __dir__.headers ("Name: value" lines). As wptserve does, a header they
// name replaces the server's own (Content-Type by extension); several lines of one name all go.
func sidecarHeaders(w http.ResponseWriter, full string) {
	seen := map[string]bool{}
	for _, f := range []string{filepath.Join(filepath.Dir(full), "__dir__.headers"), full + ".headers"} {
		data, err := os.ReadFile(f)
		if err != nil {
			continue
		}
		for _, line := range strings.Split(string(data), "\n") {
			if i := strings.IndexByte(line, ':'); i > 0 {
				name := http.CanonicalHeaderKey(strings.TrimSpace(line[:i]))
				if !seen[name] {
					w.Header().Del(name)
					seen[name] = true
				}
				w.Header().Add(name, strings.TrimSpace(line[i+1:]))
			}
		}
	}
}

// ?pipe=a(..)|b(..): what applies to the response; sub is returned for the caller to apply to the body.
func applyPipes(w http.ResponseWriter, pipe string) (status int, sub bool) {
	status = http.StatusOK
	for _, p := range splitPipes(pipe) {
		name, args := p, ""
		if i := strings.IndexByte(p, '('); i >= 0 && strings.HasSuffix(p, ")") {
			name, args = p[:i], p[i+1:len(p)-1]
		}
		switch name {
		case "sub":
			sub = true
		case "status":
			if n, err := strconv.Atoi(strings.TrimSpace(args)); err == nil {
				status = n
			}
		case "header":
			parts := splitArgs(args)
			if len(parts) >= 2 {
				if len(parts) >= 3 && strings.EqualFold(parts[2], "True") {
					w.Header().Add(parts[0], parts[1])
				} else {
					w.Header().Set(parts[0], parts[1])
				}
			}
		}
	}
	return
}

func splitPipes(s string) []string {
	var out []string
	depth, start := 0, 0
	for i := 0; i < len(s); i++ {
		switch s[i] {
		case '(':
			depth++
		case ')':
			depth--
		case '|':
			if depth == 0 {
				out = append(out, s[start:i])
				start = i + 1
			}
		}
	}
	if start < len(s) {
		out = append(out, s[start:])
	}
	return out
}

// Arguments of a pipe: comma separated, "\," escapes a comma.
func splitArgs(s string) []string {
	var out []string
	var cur strings.Builder
	for i := 0; i < len(s); i++ {
		if s[i] == '\\' && i+1 < len(s) {
			cur.WriteByte(s[i+1])
			i++
			continue
		}
		if s[i] == ',' {
			out = append(out, strings.TrimSpace(cur.String()))
			cur.Reset()
			continue
		}
		cur.WriteByte(s[i])
	}
	return append(out, strings.TrimSpace(cur.String()))
}

func serveWPT(w http.ResponseWriter, r *http.Request) {
	if _, err := os.Stat(wptRoot); err != nil {
		http.Error(w, "no web-platform-tests checkout at "+wptRoot+": run build\\wpt.exe -fetch", http.StatusServiceUnavailable)
		return
	}
	rel := path.Clean("/" + r.URL.Path)
	// wptserve's alias: the IDL parser idlharness.js loads
	if rel == "/resources/WebIDLParser.js" {
		rel = "/resources/webidl2/lib/webidl2.js"
	}
	if own, ok := map[string]string{"/resources/testharnessreport.js": wptReport, "/resources/testdriver-vendor.js": wptVendor}[rel]; ok {
		data, err := os.ReadFile(own)
		if err != nil {
			http.Error(w, "wpt"+rel[len("/resources"):]+" not found", http.StatusInternalServerError)
			return
		}
		w.Header().Set("Content-Type", "text/javascript; charset=utf-8")
		w.Header().Set("Cache-Control", "no-store")
		w.Write(data)
		return
	}
	full := filepath.Join(wptRoot, filepath.FromSlash(strings.TrimPrefix(rel, "/")))
	query := ""
	if r.URL.RawQuery != "" {
		query = "?" + r.URL.RawQuery
	}
	// generated pages
	for _, g := range []struct{ suffix, kind, script string }{
		{".any.worker.html", "any.worker.html", ".any.js"}, {".any.html", "any.html", ".any.js"},
		{".any.worker.js", "any.worker.js", ".any.js"}, {".window.html", "window.html", ".window.js"},
		{".worker.html", "worker.html", ".worker.js"},
	} {
		if !strings.HasSuffix(rel, g.suffix) {
			continue
		}
		if _, err := os.Stat(full); err == nil {
			break // a real file of that name
		}
		scriptRel := strings.TrimSuffix(rel, g.suffix) + g.script
		src, err := os.ReadFile(filepath.Join(wptRoot, filepath.FromSlash(strings.TrimPrefix(scriptRel, "/"))))
		if err != nil {
			continue
		}
		ctype, body := wptWrapper(g.kind, src, path.Base(scriptRel), query)
		w.Header().Set("Content-Type", ctype)
		w.Header().Set("Cache-Control", "no-store")
		io.WriteString(w, body)
		return
	}
	if rel == "/fetch/http-cache/resources/http-cache.py" {
		wptHTTPCacheHandler(w, r) // ported to Go (wpt_httpcache.go)
		return
	}
	if h, ok := wptPyHandlers[rel]; ok {
		h(w, r) // ported to Go (wpt_handlers.go)
		return
	}
	if strings.HasSuffix(rel, ".py") {
		http.Error(w, "wptserve Python handlers do not run on Wren's test server", http.StatusNotImplemented)
		return
	}
	st, err := os.Stat(full)
	if err != nil {
		http.NotFound(w, r)
		return
	}
	if st.IsDir() {
		if idx := filepath.Join(full, "index.html"); fileExists(idx) {
			full = idx
		} else {
			http.Error(w, "a folder", http.StatusForbidden)
			return
		}
	}
	data, err := os.ReadFile(full)
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	w.Header().Set("Content-Type", wptType(full))
	w.Header().Set("Cache-Control", "no-store")
	sidecarHeaders(w, full)
	status, sub := applyPipes(w, r.URL.Query().Get("pipe"))
	if sub || strings.Contains(path.Base(full), ".sub.") {
		data = []byte(substitute(string(data), r))
	}
	w.WriteHeader(status)
	if r.Method != http.MethodHead {
		writeTrickled(w, data, r.URL.Query().Get("pipe"))
	}
}

// The body as ?pipe=trickle(..) says: dN waits N seconds, a number sends that many bytes, rN repeats the N tokens before it
// until the bytes are gone, and what is left goes at the end. Without that pipe, all at once.
func writeTrickled(w http.ResponseWriter, data []byte, pipe string) {
	var tokens []string
	for _, p := range splitPipes(pipe) {
		if strings.HasPrefix(p, "trickle(") && strings.HasSuffix(p, ")") {
			tokens = strings.Split(p[len("trickle("):len(p)-1], ":")
		}
	}
	flush := func() {
		if f, ok := w.(http.Flusher); ok {
			f.Flush()
		}
	}
	var run func(list []string, depth int)
	run = func(list []string, depth int) {
		for i, t := range list {
			switch {
			case t == "":
			case t[0] == 'd':
				if s, err := strconv.ParseFloat(t[1:], 64); err == nil {
					flush()
					time.Sleep(time.Duration(s * float64(time.Second)))
				}
			case t[0] == 'r':
				n, err := strconv.Atoi(t[1:])
				if err != nil || n > i || depth > 0 {
					continue
				}
				for k := 0; len(data) > 0 && k < 100000; k++ {
					run(list[i-n:i], depth+1)
				}
			default:
				if n, err := strconv.Atoi(t); err == nil {
					n = min(n, len(data))
					w.Write(data[:n])
					data = data[n:]
					flush()
				}
			}
		}
	}
	run(tokens, 0)
	w.Write(data)
}

func fileExists(p string) bool {
	st, err := os.Stat(p)
	return err == nil && !st.IsDir()
}
