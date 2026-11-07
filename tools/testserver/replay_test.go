package testserver

import (
	"crypto/tls"
	"crypto/x509"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"testing"
)

func writeRecording(t *testing.T, files ...string) string {
	t.Helper()
	dir := t.TempDir()
	for i, text := range files {
		if err := os.WriteFile(filepath.Join(dir, fmt.Sprintf("%06d.http", i)), []byte(text), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	return dir
}

func recorded(method, address, body string) string {
	return method + " " + address + "\nHTTP/2 200 OK\r\ncontent-type: text/plain\r\nalt-svc: h3=\":443\"\r\ncontent-length: 999\r\nset-cookie: a=1\r\nset-cookie: b=2\r\n\r\n" + body
}

// A client as the browser is: every name goes to the replay's port, the test authority is trusted.
func replayClient(port int) *http.Client {
	roots := x509.NewCertPool()
	roots.AppendCertsFromPEM(TestAuthorityPEM())
	dial := func(network, _ string) (net.Conn, error) { return net.Dial(network, fmt.Sprintf("127.0.0.1:%d", port)) }
	return &http.Client{Transport: &http.Transport{
		Dial:              dial,
		TLSClientConfig:   &tls.Config{RootCAs: roots},
		ForceAttemptHTTP2: true,
	}}
}

func replayGet(t *testing.T, c *http.Client, address string) (*http.Response, string) {
	t.Helper()
	r, err := c.Get(address)
	if err != nil {
		t.Fatal(err)
	}
	defer r.Body.Close()
	body, _ := io.ReadAll(r.Body)
	return r, string(body)
}

func TestReplayAnswersByOrderThenNearThenNothing(t *testing.T) {
	r, err := LoadReplay(writeRecording(t,
		recorded("GET", "https://a.example/x?v=1", "first"),
		recorded("GET", "https://a.example/x?v=1", "second"),
		recorded("GET", "http://b.example/y#frag", "plain")))
	if err != nil {
		t.Fatal(err)
	}
	port, l, err := r.Serve()
	if err != nil {
		t.Fatal(err)
	}
	defer l.Close()
	c := replayClient(port)
	for _, want := range []string{"first", "second", "second"} {
		if res, body := replayGet(t, c, "https://a.example/x?v=1"); body != want || res.ProtoMajor != 2 {
			t.Errorf("got %q on %s, want %q on HTTP/2", body, res.Proto, want)
		}
	}
	if _, body := replayGet(t, c, "https://a.example/x?v=2"); body != "first" {
		t.Errorf("another query: %q", body)
	}
	if _, body := replayGet(t, c, "http://b.example/y"); body != "plain" {
		t.Errorf("plain http on the same port, no fragment: %q", body)
	}
	res, body := replayGet(t, c, "https://never.example/z")
	if res.StatusCode != http.StatusNotFound || body != "" {
		t.Errorf("unknown: %d %q", res.StatusCode, body)
	}
	counts, missed := r.Counts()
	if counts != [3]int{4, 1, 1} || len(missed) != 1 || missed[0] != "GET https://never.example/z" {
		t.Errorf("counts %v, missed %v", counts, missed)
	}
	r.Rewind()
	if _, body := replayGet(t, c, "https://a.example/x?v=1"); body != "first" {
		t.Errorf("after a rewind: %q", body)
	}
}

func TestReplayServesTheHeadItWasGivenLessWhatIsOfTheHop(t *testing.T) {
	r, err := LoadReplay(writeRecording(t, recorded("GET", "https://a.example/", "body")))
	if err != nil {
		t.Fatal(err)
	}
	port, l, err := r.Serve()
	if err != nil {
		t.Fatal(err)
	}
	defer l.Close()
	res, _ := replayGet(t, replayClient(port), "https://a.example/")
	if res.Header.Get("Alt-Svc") != "" {
		t.Error("Alt-Svc would send the browser elsewhere")
	}
	if res.ContentLength != 4 {
		t.Errorf("Content-Length %d: the recorded one was the coded body's", res.ContentLength)
	}
	if len(res.Header["Set-Cookie"]) != 2 {
		t.Errorf("both cookies: %v", res.Header["Set-Cookie"])
	}
}

func TestReplayRefusesWhatIsNoRecording(t *testing.T) {
	if _, err := LoadReplay(t.TempDir()); err == nil {
		t.Error("an empty folder")
	}
	if _, err := LoadReplay(writeRecording(t, "GET https://a.example/\nno head")); err == nil {
		t.Error("a file with no head")
	}
}
