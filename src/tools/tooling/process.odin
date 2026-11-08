// Package tooling: what the programs of the test tooling share (test_all, wpt, test262, buildjs, endurance): a process with everything it
// starts held together, so that a step can be measured and stopped whole; a file of the repository, its hash, the pinned download; the JavaScript engine's build.
package tooling

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:sync"
import "core:time"

// How often a blocking wait looks at the process.
WAIT_SLICE :: 10 * time.Millisecond

// The console of what starts (Windows). In a process that has one, the start and the end of every thread call the console's host while they hold the loader lock (KERNELBASE, DLL_THREAD_ATTACH and
// DETACH; measured with a graphics driver's dozens of threads per device, every core busy: a thread started or joined in 15 s, 3 teardowns in 150 forced to their end; 0 without one, the same tests in 20 s instead of 50).
// A console shared by the whole of a run is one thread of a process at normal priority that all of them queue for.
Console_Use :: enum {
	Inherited,   // this process's
	Own,         // a hidden one for this process and what it starts
	None,        // none: it writes to files. (A console program it starts makes a console of its own)
}

// What to start. `env`: KEY=VALUE on top of this process's environment. `log`: the file standard output and error are appended to; "": this process's own.
Spawn :: struct {
	command: []string,
	env:     []string,
	dir:     string,
	log:     string,
	console: Console_Use,
	// (Windows, the profiler of test_all: the completion port the process tree's births and ends are told to, with this key)
	port:     rawptr,
	port_key: uintptr,
}

// What a process and all it started used.
Usage :: struct {
	cpu_seconds: f64,    // user and kernel, of the whole tree
	processes:   int,    // how many the tree counted
	peak_bytes:  u64,    // the highest working set of the process itself
}

Process :: struct {
	using platform: Platform_Process,
	began: time.Tick,
}

// (One at a time: a file handle made inheritable for one child must not reach another.)
@(private) spawn_lock: sync.Mutex

// The arguments of what is started: what is not a path is left to the system's search.
@(private)
exe_argument :: proc(path: string, allocator := context.temp_allocator) -> string {
	if !strings.contains_any(path, "/\\") { return path }
	full, _ := filepath.abs(path, allocator)
	when ODIN_OS == .Windows {
		slashes, _ := strings.replace_all(full, "/", "\\", allocator)
		return slashes
	} else {
		return full
	}
}

// Blocks until it ends: its exit code. `limit` 0: no limit; past it the tree is killed and `timed_out` true.
wait :: proc(p: ^Process, limit := time.Duration(0)) -> (code: int, timed_out: bool) {
	for {
		if done, c := poll(p); done { return c, false }
		if limit > 0 && time.tick_since(p.began) > limit {
			kill_tree(p)
			for {
				if done, c := poll(p); done { return c, true }
				time.sleep(WAIT_SLICE)
			}
		}
		time.sleep(WAIT_SLICE)
	}
}

// A thread that works for one step adds what its processes used here.
@(thread_local) task_usage: ^Usage
// ... and what it starts tells the profiler's port, as a command of a step does.
@(thread_local) task_port: rawptr

count_usage :: proc(p: ^Process) {
	if task_usage == nil { return }
	u := usage(p)
	task_usage.cpu_seconds += u.cpu_seconds
	task_usage.processes += u.processes
}

// Starts, waits, lets go. -1: it could not start (said in the log, or on standard error).
run :: proc(d: Spawn, limit := time.Duration(0)) -> int {
	p, why := spawn(d)
	if why != "" {
		text := fmt.tprintfln("%s cannot start: %s", d.command[0], why)
		if d.log != "" { append_text(d.log, text) } else { fmt.eprint(text) }
		return -1
	}
	code, _ := wait(&p, limit)
	count_usage(&p)
	release(&p)
	return code
}

// What a command prints, both streams, and its exit code. In `dir` when it says so.
capture :: proc(command: []string, dir := "", allocator := context.allocator) -> (text: string, code: int) {
	@(static) serial: int
	n := sync.atomic_add(&serial, 1)
	name := fmt.tprintf("wren_capture_%d_%d.txt", os.get_pid(), n)
	temp, _ := os.temp_directory(context.temp_allocator)
	path, _ := filepath.join({temp, name}, context.temp_allocator)
	code = run({command = command, dir = dir, log = path})
	data, err := os.read_entire_file(path, allocator)
	_ = os.remove(path)
	if err == nil { text = string(data) }
	return
}

append_text :: proc(path, text: string) {
	f, err := os.open(path, os.O_WRONLY + os.O_CREATE + os.O_APPEND)
	if err != nil { return }
	defer os.close(f)
	_, _ = os.write_string(f, text)
}
