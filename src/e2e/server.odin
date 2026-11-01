package e2e

// The test server (tools/testserver): a process of its own on a block of ports of its own, gone at the end of the test. Every
// origin is an offset from one base port (tools/testserver/ports.go): +0 http on 127.0.0.1 and localhost, +1 https, +2 a second http origin.

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:testing"
import "core:time"
import "wb:base"
import "wb:remote/api"

// Where the search for a free block starts: 20000 to 28990 in steps of 10 by the repository's path (as Get-WrenPreferredBasePort in
// tools\test_env.ps1), so that two worktrees rarely try the same one.
PORT_BLOCK_FIRST :: 20000
PORT_BLOCKS :: 900
PORT_BLOCK_STEP :: 10
FNV_OFFSET :: u32(2166136261)
FNV_PRIME :: u32(16777619)
// How long it may take to listen (it writes its port in a file once it does), how often that is looked at.
SERVER_START_LIMIT :: 60 * time.Second
SERVER_POLL :: 5 * time.Millisecond
// How long it may take to end once ended.
SERVER_STOP_WAIT_MS :: 5000

Server :: struct {
	process: api.Process,
	base:    int,
	origin:  string,    // http://127.0.0.1:<base>
}

@(private)
preferred_base_port :: proc() -> int {
	h := FNV_OFFSET
	root := strings.to_lower(strings.trim_right(repo_root(), `\/`), context.temp_allocator)
	path, _ := strings.replace_all(root, "/", `\`, context.temp_allocator)
	for b in transmute([]byte)path { h = (h ~ u32(b)) * FNV_PRIME }
	return PORT_BLOCK_FIRST + int(h % PORT_BLOCKS) * PORT_BLOCK_STEP
}

// A test server for this test: it listens when this returns, and ends with the test (or with this process, however it ends).
test_server :: proc(t: ^testing.T, loc := #caller_location) -> ^Server {
	exe := fmt.tprintf("%s/build/testserver%s", repo_root(), ODIN_OS == .Windows ? ".exe" : "")
	if !os.exists(exe) { stop_test(t, fmt.tprintf("%s is missing (go build in tools/testserver; test_all builds it)", exe), loc) }
	port_file := fmt.tprintf("%s/wren-e2e-port-%s", base.temp_dir(context.temp_allocator), base.unique_name(context.temp_allocator))
	p, _, err := api.process_start({exe, "-base-port", fmt.tprintf("%d", preferred_base_port()), "-scan", "-port-file", port_file, "-parent-pid", fmt.tprintf("%d", api.this_pid())})
	if err != "" { stop_test(t, fmt.tprintf("cannot start the test server: %s", err), loc) }
	s := new(Server)
	s.process = p
	testing.cleanup(t, proc(ptr: rawptr) {
		s := (^Server)(ptr)
		api.process_kill(&s.process)
		api.process_wait(&s.process, SERVER_STOP_WAIT_MS)
		api.process_release(&s.process)
		delete(s.origin)
		free(s)
	}, s)
	defer os.remove(port_file)
	end := time.tick_add(time.tick_now(), SERVER_START_LIMIT)
	for s.base <= 0 {
		if !api.process_alive(&s.process) { stop_test(t, "the test server stopped at once (no free block of ports?)", loc) }
		if time.tick_diff(time.tick_now(), end) <= 0 { stop_test(t, "the test server did not listen in time", loc) }
		// (the file is there before the server has finished writing it)
		if data, rerr := os.read_entire_file(port_file, context.temp_allocator); rerr == nil { s.base, _ = strconv.parse_int(strings.trim_space(string(data))) }
		if s.base <= 0 { time.sleep(SERVER_POLL) }   // (another process: nothing to run meanwhile)
	}
	s.origin = fmt.aprintf("http://127.0.0.1:%d", s.base)
	return s
}

// An address of the test server: `path` from its root.
url :: proc(s: ^Server, path: string) -> string { return fmt.tprintf("%s%s", s.origin, path) }

