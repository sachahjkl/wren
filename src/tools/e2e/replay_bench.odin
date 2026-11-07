package e2e_scenarios

// What `wrentool replay` stands on (docs/testing.md, the replay bench): any name reaches the recording's server with its certificate from the test authority, the page's
// random and clock are the test world's, what compares with the recording's dates goes by them, and a load is recorded as the host was given it.

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "wb:base"
import "wb:e2e"
import "wb:net"
import "wb:testserver"

@(private = "file") SEED_ONE :: 7
@(private = "file") SEED_TWO :: 8
// 2001-09-09T01:46:40Z, long before any run of this test: what the recording's dates are near.
@(private = "file") RECORDED_MS :: 1_000_000_000_000.0
@(private = "file") PAGE_URL :: "https://news.example/front?x=1"
// The cookie runs out an hour after the recording: for the real clock, years ago.
@(private = "file") RECORDED_PAGE :: "GET " + PAGE_URL + "\nHTTP/2 200 OK\r\ncontent-type: text/html\r\nset-cookie: kept=1; Expires=Sun, 09 Sep 2001 02:46:40 GMT; Path=/\r\n\r\n" +
	`<!doctype html><script src="https://cdn.example/never.js"></script><body>recorded`

@(private = "file")
replay_prefs :: proc(t: ^testing.T, folder: string) -> []string {
	port, why := testserver.replay_start(folder)
	testing.expect(t, port != 0, why)
	ca := fmt.tprintf("%s/ca.pem", folder)
	testing.expect(t, os.write_entire_file(ca, testserver.ca_pem(context.temp_allocator)) == nil)
	prefs := make([dynamic]string, context.temp_allocator)
	append(&prefs, fmt.tprintf("network.hosts=*=127.0.0.1:%d", port), fmt.tprintf("network.tls.extra_ca_file=%s", ca), "network.loopback_only=true", "network.http3.enabled=false")
	return prefs[:]
}

// A load in a new browser, after `s` if there was one, under the seed: what the page drew from its world.
@(private = "file")
one_load :: proc(t: ^testing.T, s: ^e2e.Session, seed: u64, prefs: []string) -> (next: ^e2e.Session, seen: string) {
	if s != nil { e2e.stop(s) }
	base.test_world_set(seed, RECORDED_MS)
	testserver.replay_rewind()
	next = s != nil ? e2e.restart(s, {prefs = prefs}) : e2e.start(t, {prefs = prefs})
	e2e.navigate(next, PAGE_URL)
	testing.expect_value(t, e2e.eval(next, "document.body.textContent"), "recorded")
	testing.expect_value(t, e2e.eval(next, "document.cookie"), "kept=1")
	testing.expect(t, e2e.eval_f64(next, "new Date().getFullYear()") == 2001, "the page's year is the recording's")
	moved := e2e.eval_f64(next, "(() => { const a = performance.now(); return performance.now() - a })()")
	testing.expect(t, moved > 0 && moved < 1, "the clock moves by its reads")
	return next, strings.clone(e2e.eval(next, "[Math.random(), crypto.getRandomValues(new Uint32Array(2)).join(), crypto.randomUUID()].join(' ')"), context.temp_allocator)
}

@(test)
replay_serves_any_name_and_the_world_makes_two_loads_one :: proc(t: ^testing.T) {
	_ = e2e.test_server(t)
	defer base.test_world_clear()
	folder := e2e.temp_folder(t)
	testing.expect(t, os.write_entire_file(fmt.tprintf("%s/000000.http", folder), RECORDED_PAGE) == nil)
	prefs := replay_prefs(t, folder)
	s, a := one_load(t, nil, SEED_ONE, prefs)
	exact, _, unknown, missed := testserver.replay_counts(context.temp_allocator)
	testing.expect(t, exact >= 1)
	testing.expect(t, unknown >= 1)
	testing.expect(t, strings.contains(missed, "GET https://cdn.example/never.js"), missed)
	again, b := one_load(t, s, SEED_ONE, prefs)
	testing.expect_value(t, b, a)
	_, c := one_load(t, again, SEED_TWO, prefs)
	testing.expect(t, c != a, "another seed, other numbers")
}

@(test)
a_load_is_recorded_as_the_host_was_given_it :: proc(t: ^testing.T) {
	server := e2e.test_server(t)
	folder := e2e.temp_folder(t)
	net.record_to(folder)
	defer net.record_stop()
	s := e2e.start(t)
	defer e2e.stop(s)
	address := e2e.url(server, "/gzip")
	e2e.navigate(s, address)
	found := false
	entries, _ := os.read_all_directory_by_path(folder, context.temp_allocator)
	for entry in entries {
		data, err := os.read_entire_file(entry.fullpath, context.temp_allocator)
		testing.expect(t, err == nil)
		text := string(data)
		if !strings.has_prefix(text, fmt.tprintf("GET %s\n", address)) { continue }
		found = true
		testing.expect(t, !strings.contains(text, "ontent-encoding"), "the head of the decoded body")
		testing.expect(t, strings.contains(text, "compressible compressible"), "the body, decoded")
	}
	testing.expect(t, found, "the page's answer is among the files")
}
