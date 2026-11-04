package testserver

import (
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// A status line, a header's case and an empty value go as the handler wrote them, and a request's headers reach it as the client wrote them.
func TestWPTPythonHandlers(t *testing.T) {
	l, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer l.Close()
	saved := wptRoot
	wptRoot = t.TempDir()
	defer func() { wptRoot = saved }()
	serveRaw(l, http.HandlerFunc(serveWPT))
	exchange := func(request string) string {
		c, err := net.Dial("tcp", l.Addr().String())
		if err != nil {
			t.Fatal(err)
		}
		defer c.Close()
		io.WriteString(c, request)
		answer, _ := io.ReadAll(c)
		return string(answer)
	}
	status := exchange("GET /xhr/resources/status.py?code=299&text=Nice&type= HTTP/1.1\r\nHost: x\r\n\r\n")
	if !strings.HasPrefix(status, "HTTP/1.1 299 Nice\r\nContent-Type: \r\nX-Request-Method: GET\r\n") {
		t.Errorf("status.py: %q", status)
	}
	echoed := exchange("POST /xhr/resources/inspect-headers.py?filter_name=x-TEST HTTP/1.1\r\nHost: x\r\nX-teST: a\r\nContent-Length: 0\r\n\r\n")
	if !strings.HasSuffix(echoed, "\r\n\r\nX-teST: a\n") {
		t.Errorf("inspect-headers.py: %q", echoed)
	}
	head := exchange("HEAD /xhr/resources/content.py?content=abc HTTP/1.1\r\nHost: x\r\n\r\n")
	if !strings.Contains(head, "Content-Length: 3\r\n") || !strings.HasSuffix(head, "\r\n\r\n") {
		t.Errorf("a HEAD of content.py: %q", head)
	}
}

func TestWPTStash(t *testing.T) {
	defer wptStashReset()
	stashPut("scope", "key", "1")
	if state := stashState("other", "key"); state != "Uninitialized" {
		t.Errorf("another scope's key: %q", state)
	}
	if state := stashState("scope", "key"); state != "1" {
		t.Errorf("a key put: %q", state)
	}
	if state := stashState("scope", "key"); state != "Uninitialized" {
		t.Errorf("a key taken twice: %q", state)
	}
}

func TestWPTAsIs(t *testing.T) {
	dir := t.TempDir()
	os.WriteFile(filepath.Join(dir, "x.asis"), []byte("HTTP/1.1 280 HELLO\nfoo-test: 1\n\n"), 0o644)
	saved := wptRoot
	wptRoot = dir
	defer func() { wptRoot = saved }()
	s := httptest.NewServer(http.HandlerFunc(serveWPT))
	defer s.Close()
	r, err := http.Get(s.URL + "/x.asis")
	if err != nil {
		t.Fatal(err)
	}
	defer r.Body.Close()
	if r.Status != "280 HELLO" || r.Header.Get("foo-test") != "1" {
		t.Errorf("x.asis: %s %v", r.Status, r.Header)
	}
}
