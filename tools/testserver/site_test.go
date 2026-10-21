package main

import (
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func get(t *testing.T, h http.Handler, target string) *httptest.ResponseRecorder {
	t.Helper()
	w := httptest.NewRecorder()
	h.ServeHTTP(w, httptest.NewRequest("GET", target, nil))
	return w
}

// /site/ as static servers serve it: index.html, folder listings, extensionless pages, Content-Type from the table.
func TestSiteHandler(t *testing.T) {
	root := t.TempDir()
	write := func(rel, text string) {
		p := filepath.Join(root, filepath.FromSlash(rel))
		os.MkdirAll(filepath.Dir(p), 0o755)
		os.WriteFile(p, []byte(text), 0o644)
	}
	write("index.html", "<h1>index</h1>")
	write("grid.html", "<h1>grid</h1>")
	write("app.wasm", "\x00asm")
	write("img/a b#1.png", "png")
	write("img/.hidden", "x")
	write("img/sub/x.avif", "avif")
	write("docs/index.htm", "<h1>htm</h1>")
	h := http.StripPrefix("/site/", siteHandler(root))

	w := get(t, h, "/site/")
	if w.Code != 200 || w.Body.String() != "<h1>index</h1>" || !strings.HasPrefix(w.Header().Get("Content-Type"), "text/html") {
		t.Errorf("/site/ serves index.html: %d %q %q", w.Code, w.Body.String(), w.Header().Get("Content-Type"))
	}
	if w = get(t, h, "/site/grid"); w.Code != 200 || w.Body.String() != "<h1>grid</h1>" || !strings.HasPrefix(w.Header().Get("Content-Type"), "text/html") {
		t.Errorf("/site/grid serves grid.html: %d %q", w.Code, w.Body.String())
	}
	if w = get(t, h, "/site/grid.html"); w.Code != 200 || w.Body.String() != "<h1>grid</h1>" {
		t.Errorf("/site/grid.html: %d", w.Code)
	}
	if w = get(t, h, "/site/nope"); w.Code != 404 {
		t.Errorf("/site/nope is not found: %d", w.Code)
	}
	if w = get(t, h, "/site/app.wasm"); w.Header().Get("Content-Type") != "application/wasm" {
		t.Errorf("wasm type: %q", w.Header().Get("Content-Type"))
	}
	if w = get(t, h, "/site/img/sub/x.avif"); w.Header().Get("Content-Type") != "image/avif" {
		t.Errorf("avif type: %q", w.Header().Get("Content-Type"))
	}
	if w = get(t, h, "/site/img"); w.Code != http.StatusMovedPermanently || w.Header().Get("Location") != "img/" {
		t.Errorf("a folder without '/' is redirected: %d %q", w.Code, w.Header().Get("Location"))
	}
	w = get(t, h, "/site/img/")
	body := w.Body.String()
	if w.Code != 200 || !strings.Contains(body, "<h1>Index of /site/img/</h1>") {
		t.Errorf("a folder without an index lists its files: %d %s", w.Code, body)
	}
	if !strings.Contains(body, `href="a%20b%231.png"`) || !strings.Contains(body, `href="sub/"`) || strings.Contains(body, ".hidden") || !strings.Contains(body, `href="../"`) {
		t.Errorf("listing links: %s", body)
	}
	if strings.Index(body, "sub/") > strings.Index(body, "a b#1.png") {
		t.Errorf("folders first: %s", body)
	}
	if w = get(t, h, "/site/docs/"); w.Body.String() != "<h1>htm</h1>" {
		t.Errorf("index.htm: %q", w.Body.String())
	}
}

// On another block of ports the pages' default ports move with it; binary files and other numbers stay.
func TestPortsRewrite(t *testing.T) {
	saved := basePort
	defer func() { basePort = saved }()
	src := `<img src="http://127.0.0.1:8767/a.png"> ws://localhost:8765/ws https://[::1]:8766/ U+8766 :87650 x:8770`
	basePort = defaultBasePort
	if got := string(portsRewrite([]byte(src))); got != src {
		t.Errorf("default block changed the text: %q", got)
	}
	basePort = 21230
	want := `<img src="http://127.0.0.1:21232/a.png"> ws://localhost:21230/ws https://[::1]:21231/ U+8766 :87650 x:8770`
	if got := string(portsRewrite([]byte(src))); got != want {
		t.Errorf("rewrite: %q", got)
	}
	root := t.TempDir()
	os.WriteFile(filepath.Join(root, "p.html"), []byte(src), 0o644)
	os.WriteFile(filepath.Join(root, "b.png"), []byte("127.0.0.1:8765"), 0o644)
	h := http.StripPrefix("/site/", siteHandler(root))
	if w := get(t, h, "/site/p.html"); w.Body.String() != want {
		t.Errorf("served page: %q", w.Body.String())
	}
	if w := get(t, h, "/site/p"); w.Body.String() != want {
		t.Errorf("served extensionless page: %q", w.Body.String())
	}
	if w := get(t, h, "/site/b.png"); w.Body.String() != "127.0.0.1:8765" {
		t.Errorf("binary file: %q", w.Body.String())
	}
}
