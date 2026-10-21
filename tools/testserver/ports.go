// The block of ports the server listens on. Every origin of the tests is a fixed offset from one base port, so a run
// moves as a whole and the relations between origins (same site, cross-origin, https) stay what the tests expect:
//
//	base+0  http   127.0.0.1 and localhost (two sites, one listener)
//	base+1  https  self-signed
//	base+2  http   a second origin of the same hosts
//	base+3  http   the web-platform-tests origin (wpt.go)
//	base+4  https  the web-platform-tests origin, self-signed
//
// The base: -base-port N, else WREN_TEST_BASE_PORT, else 8765 (the demos, demo.bat and the release package use the
// default; tools\test_all.ps1 gives each run a block of its own so that several worktrees test side by side).
// -scan: a busy block is not an error, the next free one (base+10, base+20...) is taken. -port-file F: once every
// listener is bound, the base actually used is written to F (what the caller waits for, instead of probing ports).
//
// The pages and scripts of the repository write the default ports (http://127.0.0.1:8765/...); on another block the
// text files of /site/ are served with those ports moved (portsRewrite), as the test tools move theirs
// (src/tools/testenv).
package main

import (
	"crypto/tls"
	"fmt"
	"net"
	"os"
	"regexp"
	"strconv"
)

const defaultBasePort = 8765

// Number of ports of a block and the step between candidate blocks of -scan.
const (
	portBlock = 5
	scanStep  = 10
	scanTries = 200
)

var basePort = argInt("-base-port", envInt("WREN_TEST_BASE_PORT", defaultBasePort))

func envInt(name string, def int) int {
	if n, err := strconv.Atoi(os.Getenv(name)); err == nil && n > 0 {
		return n
	}
	return def
}

func hasArg(name string) bool {
	for _, a := range os.Args {
		if a == name {
			return true
		}
	}
	return false
}

func argString(name string) string {
	for i, a := range os.Args {
		if a == name && i+1 < len(os.Args) {
			return os.Args[i+1]
		}
	}
	return ""
}

// ":8765" .. ":8769" after a host name or address (not "U+8766", not a longer number).
var defaultPortRe = regexp.MustCompile(`([A-Za-z0-9\]]):876([5-9])\b`)

// The text with the default block's ports moved to the current block (unchanged on the default block).
func portsRewrite(b []byte) []byte {
	if basePort == defaultBasePort {
		return b
	}
	return defaultPortRe.ReplaceAllFunc(b, func(m []byte) []byte {
		off := int(m[len(m)-1] - '5')
		return []byte(fmt.Sprintf("%c:%d", m[0], basePort+off))
	})
}

// The listeners of a block: plain TCP for base+0 and base+2, TLS for base+1 (and the WPT pair when wanted). All of
// them or none: a block half bound is closed again.
type portListeners struct {
	http, https, other, wpt, wptTLS net.Listener
}

func (l *portListeners) close() {
	for _, x := range []net.Listener{l.http, l.https, l.other, l.wpt, l.wptTLS} {
		if x != nil {
			x.Close()
		}
	}
}

func listenBlock(base int, withWPT bool, cert tls.Certificate) (*portListeners, error) {
	l := &portListeners{}
	var err error
	listen := func(port int) net.Listener {
		if err != nil {
			return nil
		}
		var x net.Listener
		x, err = net.Listen("tcp", fmt.Sprintf("127.0.0.1:%d", port))
		return x
	}
	l.http = listen(base)
	l.https = listen(base + 1)
	l.other = listen(base + 2)
	if withWPT {
		l.wpt = listen(wptHTTPPort)
		l.wptTLS = listen(wptHTTPSPort)
	}
	if err != nil {
		l.close()
		return nil, err
	}
	l.https = tls.NewListener(l.https, &tls.Config{Certificates: []tls.Certificate{cert}})
	if l.wptTLS != nil {
		l.wptTLS = tls.NewListener(l.wptTLS, &tls.Config{Certificates: []tls.Certificate{cert}})
	}
	return l, nil
}

// Binds the block (the next free one with -scan), moving the WPT ports along unless -wpt-port fixed them.
func bindPorts(cert tls.Certificate) *portListeners {
	scan := hasArg("-scan")
	fixedWPT := argString("-wpt-port") != ""
	tries := 1
	if scan {
		tries = scanTries
	}
	var lastErr error
	for i := 0; i < tries; i++ {
		base := basePort + i*scanStep
		if base+portBlock > 65535 {
			break
		}
		if !fixedWPT {
			wptHTTPPort, wptHTTPSPort = base+3, base+4
		}
		l, err := listenBlock(base, true, cert)
		if err == nil {
			basePort = base
			return l
		}
		lastErr = err
	}
	fmt.Fprintf(os.Stderr, "testserver: no free block of ports from %d: %v\n", basePort, lastErr)
	os.Exit(1)
	return nil
}

// -port-file F: the base port, written once everything listens (written then renamed: a reader never sees half of it).
func writePortFile() {
	f := argString("-port-file")
	if f == "" {
		return
	}
	tmp := f + ".tmp"
	if err := os.WriteFile(tmp, []byte(strconv.Itoa(basePort)), 0o644); err == nil {
		os.Rename(tmp, f)
	}
}
