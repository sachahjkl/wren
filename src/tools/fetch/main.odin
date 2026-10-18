// Headless network harness: exercises net + host without a window.
//
//   fetch.exe [--collect] [--many N] [--cancel-ms MS] [--slow-ms MS] [--max-body BYTES] URL...
package fetch

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:time"
import "wb:base"
import "wb:host"
import "wb:net"

Stats :: struct {
	url:        string,
	started:    time.Tick,
	bytes:      int,
	unslept:    int,
	chunks:     int,
	peak_queue: int,
	status:     int,
	done:       bool,
}

loop:   host.Loop
client: net.Client
opts:   struct { collect: bool, many: int, cancel_ms: f64, slow_ms: int, max_body: int, print: bool, method, body, headers: string }
pending: int
failures: int

on_event :: proc(user: rawptr, req: base.Handle, ev: ^net.Event) {
	s := (^Stats)(user)
	switch ev.kind {
	case .Headers:
		s.status = ev.status
		fmt.printf("[%s] %d  final=%s\n", s.url, ev.status, ev.final_url)
	case .Data:
		s.bytes += len(ev.data)
		s.chunks += 1
		if ev.job != nil { s.peak_queue = max(s.peak_queue, ev.job.queued) }
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
		fmt.printf("[%s] done: %d bytes in %d chunks, %.0f ms, peak queued %d KB\n", s.url, s.bytes, s.chunks,
			time.duration_milliseconds(time.tick_since(s.started)), s.peak_queue / 1024)
	case .Failed:
		pending -= 1
		failures += 1
		fmt.printf("[%s] FAILED: %s (code %d)\n", s.url, net.error_text(ev.error, ev.secure_flags), ev.error)
	}
}

cancel_task :: proc(data: rawptr) {
	h := (^base.Handle)(data)^
	ok := net.cancel(&client, h)
	fmt.printf("cancel -> %v, in flight now: %d\n", ok, net.in_flight(&client))
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
		case "--header":    i += 1; opts.headers = args[i]
		case:               append(&urls, args[i])
		}
	}
	if len(urls) == 0 { fmt.eprintln("usage: fetch [--collect] [--many N] [--cancel-ms MS] [--slow-ms MS] [--max-body B] URL..."); os.exit(2) }

	host.loop_init(&loop)
	if !net.client_init(&client, &loop) { fmt.eprintln("client_init failed"); os.exit(1) }

	scope := base.scope_make("session")
	handles: [dynamic]base.Handle
	stats: [dynamic]^Stats
	for url in urls {
		for _ in 0 ..< opts.many {
			s := new(Stats)
			s.url = url
			s.started = time.tick_now()
			append(&stats, s)
			h := net.fetch(&client, {
				url = url, method = opts.method, headers = opts.headers, body = transmute([]byte)opts.body,
				on_event = on_event, user = s, collect = opts.collect, max_body = opts.max_body, scope = scope,
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
	fmt.printf("pending=%d in_flight=%d failures=%d\n", pending, net.in_flight(&client), failures)

	// Closing the scope must leave nothing behind, even for requests that are still running.
	base.scope_close(scope)
	fmt.printf("after scope close: in_flight=%d\n", net.in_flight(&client))
	net.client_destroy(&client)
	host.loop_destroy(&loop)
	os.exit(failures > 0 ? 1 : 0)
}
