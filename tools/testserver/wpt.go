// The web-platform-tests server (src/tools/wpt, tools/wpt.ps1): the pinned WPT checkout (build/wpt/wpt) served at its
// own origin, http://127.0.0.1:8768/, since WPT paths are absolute (/resources/testharness.js), with the parts of
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
//     the runner.
//   - Python handlers (*.py) do not run: 501. The tests that need them fail, and are counted as failing.
//
// Cross-origin tests: the "www" domains are localhost (the same listener under another host name, so another origin);
// https: 127.0.0.1:8769 with a self-signed certificate. With -wpt-port N the ports are N and N+1; with -wpt-only the
// server serves nothing else (tools\wpt.ps1 runs the whole suite that way, on ports no other test uses).
// The checkout: WREN_WPT_ROOT, else build/wpt/wpt (from the repository root, as the tests run), else next to the
// executable (build\testserver.exe -> build\wpt\wpt). No checkout: the listener answers 503 with how to get one.
package main

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
)

const wptWWWHost = "localhost"

// -wpt-port N: the WPT origin is 127.0.0.1:N (https: N+1). -wpt-only: nothing else is served (tools\wpt.ps1 runs the
// full suite on ports of its own, without holding the shared ones).
var (
	wptHTTPPort  = argInt("-wpt-port", 8768)
	wptHTTPSPort = wptHTTPPort + 1
)

func argInt(name string, def int) int {
	for i, a := range os.Args {
		if a == name && i+1 < len(os.Args) {
			if n, err := strconv.Atoi(os.Args[i+1]); err == nil {
				return n
			}
		}
	}
	return def
}

func wptOnly() bool {
	for _, a := range os.Args {
		if a == "-wpt-only" {
			return true
		}
	}
	return false
}

// The WPT origin alone (-wpt-only).
func serveWPTOnly() {
	registerWPTHandlers(nil)
	log.Printf("web-platform-tests: http://127.0.0.1:%d  https://127.0.0.1:%d (self-signed), checkout %s", wptHTTPPort, wptHTTPSPort, wptRoot)
	select {}
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
)

func registerWPTHandlers(_ *http.ServeMux) {
	h := http.HandlerFunc(serveWPT)
	go func() {
		log.Fatal(http.ListenAndServe(fmt.Sprintf("127.0.0.1:%d", wptHTTPPort), h))
	}()
	go func() {
		srv := &http.Server{Addr: fmt.Sprintf("127.0.0.1:%d", wptHTTPSPort), Handler: h, TLSConfig: &tls.Config{Certificates: []tls.Certificate{selfSigned()}}}
		log.Fatal(srv.ListenAndServeTLS("", ""))
	}()
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
		for _, part := range strings.Split(strings.Trim(sm[2], "[]"), "][") {
			idx = append(idx, strings.Trim(part, `"'`))
		}
		at := func(i int) string {
			if i < len(idx) {
				return idx[i]
			}
			return ""
		}
		switch sm[1] {
		case "host":
			return "127.0.0.1"
		case "domains", "hosts":
			d := at(0)
			if sm[1] == "hosts" {
				d = at(1)
			}
			if d == "" {
				return "127.0.0.1"
			}
			return wptWWWHost
		case "ports":
			switch at(0) {
			case "https", "wss", "h2":
				return strconv.Itoa(wptHTTPSPort)
			default:
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

// The headers of x.headers and of the folder's __dir__.headers ("Name: value" lines).
func sidecarHeaders(w http.ResponseWriter, full string) {
	for _, f := range []string{filepath.Join(filepath.Dir(full), "__dir__.headers"), full + ".headers"} {
		data, err := os.ReadFile(f)
		if err != nil {
			continue
		}
		for _, line := range strings.Split(string(data), "\n") {
			if i := strings.IndexByte(line, ':'); i > 0 {
				w.Header().Add(strings.TrimSpace(line[:i]), strings.TrimSpace(line[i+1:]))
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
		http.Error(w, "no web-platform-tests checkout at "+wptRoot+": run tools\\wpt.ps1 -Fetch", http.StatusServiceUnavailable)
		return
	}
	rel := path.Clean("/" + r.URL.Path)
	// wptserve's alias: the IDL parser idlharness.js loads
	if rel == "/resources/WebIDLParser.js" {
		rel = "/resources/webidl2/lib/webidl2.js"
	}
	if rel == "/resources/testharnessreport.js" {
		data, err := os.ReadFile(wptReport)
		if err != nil {
			http.Error(w, "wpt/testharnessreport.js not found", http.StatusInternalServerError)
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
		w.Write(data)
	}
}

func fileExists(p string) bool {
	st, err := os.Stat(p)
	return err == nil && !st.IsDir()
}
