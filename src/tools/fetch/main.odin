// Headless network harness for the whole stack (net + fetch policy layer + host loop), no window.
//
//   fetch.exe [--collect] [--many N] [--cancel-ms MS] [--slow-ms MS] [--max-body BYTES] [--print]
//             [--method M] [--body TEXT] [--header "Name: value"] URL...
//
// Requests are browser-initiated navigations (cookies on, redirects followed), the way the address bar behaves.
package fetch_tool

import _ "wb:tools/crashtrace"   // a crash prints its symbolized stack

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:time"
import "wb:base"
import "wb:fetch"
import "wb:host"
import "wb:net"

Stats :: struct {
	url:     string,
	started: time.Tick,
	bytes:   int,
	unslept: int,
	chunks:  int,
	status:  int,
	done:    bool,
}

loop:     host.Loop
client:   net.Client
blocking: host.Blocking_Pool
profile:  fetch.Profile
loader:   fetch.Loader
opts:     struct { collect: bool, many: int, cancel_ms: f64, slow_ms: int, max_body: int, print: bool, method, body, header: string }
pending:  int
failures: int

on_event :: proc(user: rawptr, task: base.Handle, ev: ^fetch.Event) {
	s := (^Stats)(user)
	switch ev.kind {
	case .Response:
		s.status = ev.response.status
		fmt.printf("[%s] %d  final=%s\n", s.url, ev.response.status, ev.response.url)
	case .Data:
		s.bytes += len(ev.data)
		s.chunks += 1
		// slow consumer: one pause of slow_ms per 256 KB handled, whatever the chunk size WinHTTP produces
		s.unslept += len(ev.data)
		if opts.slow_ms > 0 && s.unslept >= 256 << 10 {
			s.unslept = 0
			time.sleep(time.Duration(opts.slow_ms) * time.Millisecond)
		}
	case .Done:
		if opts.collect { s.bytes = len(ev.data) }
		if opts.print { fmt.printf("%s\n", string(ev.data[:min(len(ev.data), 300)])) }
		s.done = true
		pending -= 1
		fmt.printf("[%s] done: %d bytes in %d chunks, %.0f ms\n", s.url, s.bytes, s.chunks, time.duration_milliseconds(time.tick_since(s.started)))
	case .Failed:
		pending -= 1
		failures += 1
		fmt.printf("[%s] FAILED: %s (%v)\n", s.url, ev.detail, ev.error)
	}
}

cancel_task :: proc(data: rawptr) {
	h := (^base.Handle)(data)^
	ok := fetch.cancel(&loader, h)
	fmt.printf("cancel -> %v, in flight now: %d\n", ok, fetch.in_flight(&loader))
	if ok { pending -= 1 }
}

main :: proc() {
	urls: [dynamic]string
	opts.many = 1
	args := os.args[1:]
	for i := 0; i < len(args); i += 1 {
		switch args[i] {
		case "--collect":   opts.collect = true
		case "--many":      i += 1; opts.many, _ = strconv.parse_int(args[i])
		case "--cancel-ms": i += 1; opts.cancel_ms, _ = strconv.parse_f64(args[i])
		case "--slow-ms":   i += 1; opts.slow_ms, _ = strconv.parse_int(args[i])
		case "--max-body":  i += 1; opts.max_body, _ = strconv.parse_int(args[i])
		case "--print":     opts.print = true; opts.collect = true
		case "--method":    i += 1; opts.method = args[i]
		case "--body":      i += 1; opts.body = args[i]
		case "--header":    i += 1; opts.header = args[i]
		case:               append(&urls, args[i])
		}
	}
	if len(urls) == 0 { fmt.eprintln("usage: fetch [--collect] [--many N] [--cancel-ms MS] [--slow-ms MS] [--max-body B] [--print] [--method M] [--body T] [--header \"N: v\"] URL..."); os.exit(2) }

	host.loop_init(&loop)
	if !net.client_init(&client, &loop) { fmt.eprintln("client_init failed"); os.exit(1) }
	host.blocking_init(&blocking, &loop, 2)
	profile = fetch.profile_make()
	fetch.loader_init(&loader, &loop, &client, &blocking, &profile)

	pairs: [dynamic]fetch.Header_Pair
	if opts.header != "" {
		if colon := strings.index_byte(opts.header, ':'); colon > 0 {
			append(&pairs, fetch.Header_Pair{strings.trim_space(opts.header[:colon]), strings.trim_space(opts.header[colon + 1:])})
		}
	}

	scope := base.scope_make("session")
	handles: [dynamic]base.Handle
	for u in urls {
		for _ in 0 ..< opts.many {
			s := new(Stats)
			s.url = u
			s.started = time.tick_now()
			h := fetch.start(&loader, {
				request = {
					url = u, method = opts.method, headers = pairs[:], body = transmute([]byte)opts.body,
					mode = .Navigate, credentials = .Include, destination = .Document, max_body = opts.max_body,
				},
				on_event = on_event, user = s, collect = opts.collect, scope = scope,
			})
			append(&handles, h)
			pending += 1
		}
	}
	if opts.cancel_ms > 0 {
		for &h in handles { host.set_timer(&loop, opts.cancel_ms, 0, cancel_task, &h) }
	}

	deadline := time.tick_now()
	for pending > 0 && time.duration_seconds(time.tick_since(deadline)) < 120 { host.loop_wait(&loop, 100) }
	fmt.printf("pending=%d in_flight=%d failures=%d\n", pending, fetch.in_flight(&loader), failures)

	// Closing the scope must leave nothing behind, even for requests that are still running.
	base.scope_close(scope)
	fmt.printf("after scope close: in_flight=%d\n", fetch.in_flight(&loader))
	fetch.loader_destroy(&loader)
	host.blocking_destroy(&blocking)
	net.client_destroy(&client)
	fetch.profile_destroy(&profile)
	host.loop_destroy(&loop)
	os.exit(failures > 0 ? 1 : 0)
}
