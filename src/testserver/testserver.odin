// The test server (tools/testserver, Go) in the test's own process: build\testserver.dll is loaded on the first call and runs on the
// threads of Go's runtime, beside the test's. There is nothing to start or stop, and no file to read the port from: `start` returns
// once everything listens, with the base port of the block it took, and the server goes with the process. One per process, on the
// block of ports it found free; `start` again gives the same one with nothing kept of the last test's (Go's `Reset`).
// Every origin is an offset from the base port (tools/testserver/ports.go): +0 http on 127.0.0.1 and localhost, +1 https, +2 a second
// http origin, +3 / +4 the web-platform-tests origin, +5 .. +9 the network stack's transport origins.
package testserver

import "core:dynlib"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:sync"

// Where the search for a free block starts: 20000 to 28990 in steps of 10 by the repository's path (as Get-WrenPreferredBasePort in
// tools\test_env.ps1), so that two worktrees rarely try the same one.
PORT_BLOCK_FIRST :: 20000
PORT_BLOCKS :: 900
PORT_BLOCK_STEP :: 10
FNV_OFFSET :: u32(2166136261)
FNV_PRIME :: u32(16777619)
WHY_BYTES :: 512
when ODIN_OS == .Windows { LIBRARY :: "testserver.dll" } else { LIBRARY :: "testserver.so" }
BUILD_IT :: "(test_all builds it: in tools/testserver, go build -buildmode=c-shared -ldflags=\"-s -w\" -o ../../build/testserver.dll ./cdll)"

State :: enum {
	Not_Started,
	Listening,
	Failed,    // once: what stopped it does not get better within a process
}

@(private)
server: struct {
	lock:  sync.Mutex,
	state: State,
	base:  int,
	why:   string,
	reset: proc "c" (),
}

// The repository: a test program is in its build folder (WREN_REPO says otherwise).
@(private)
repo_root :: proc() -> string {
	if r, ok := os.lookup_env("WREN_REPO", context.temp_allocator); ok && r != "" { return r }
	exe, err := os.get_executable_path(context.temp_allocator)
	return err == nil ? filepath.dir(filepath.dir(exe)) : "."
}

@(private)
preferred_base_port :: proc(root: string) -> int {
	h := FNV_OFFSET
	lower := strings.to_lower(strings.trim_right(root, `\/`), context.temp_allocator)
	path, _ := strings.replace_all(lower, "/", `\`, context.temp_allocator)
	for b in transmute([]byte)path { h = (h ~ u32(b)) * FNV_PRIME }
	return PORT_BLOCK_FIRST + int(h % PORT_BLOCKS) * PORT_BLOCK_STEP
}

// The server, listening: its base port, or 0 and why not (kept for the process). What it serves from the disk is under the working
// directory, which is to be the repository.
start :: proc() -> (base: int, why: string) {
	sync.guard(&server.lock)
	switch server.state {
	case .Listening:
		server.reset()
	case .Failed:
	case .Not_Started:
		server.state = .Failed
		allocator := context.allocator
		root := repo_root()
		path := fmt.tprintf("%s/build/%s", root, LIBRARY)
		library, loaded := dynlib.load_library(path)
		if !loaded {
			server.why = fmt.aprintf("cannot load %s: %s %s", path, dynlib.last_error(), BUILD_IT, allocator = allocator)
			break
		}
		start_at, has_start := dynlib.symbol_address(library, "WrenTestServerStart")
		reset_at, has_reset := dynlib.symbol_address(library, "WrenTestServerReset")
		if !has_start || !has_reset {
			server.why = fmt.aprintf("%s is not the test server %s", path, BUILD_IT, allocator = allocator)
			break
		}
		server.reset = auto_cast reset_at
		start_it := cast(proc "c" (base: i32, why: [^]u8, why_bytes: i32) -> i32)start_at
		reason: [WHY_BYTES]u8
		got := start_it(i32(preferred_base_port(root)), &reason[0], WHY_BYTES)
		if got == 0 {
			server.why = fmt.aprintf("the test server could not start: %s", string(cstring(&reason[0])), allocator = allocator)
			break
		}
		server.base, server.state = int(got), .Listening
	}
	return server.base, server.why
}
