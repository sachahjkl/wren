#+build linux
package tooling

import "core:strings"
import "core:sync"
import "core:time"
import "core:os"
import "core:sys/linux"
import "core:sys/posix"

// A process in a process group of its own: what it starts stays in the group unless it asks otherwise, and a signal to the group stops the tree. Its CPU is
// what wait4 reports: its own and that of the children it waited for.

@(private = "file") MICROS_PER_SECOND :: 1_000_000
@(private = "file") BYTES_PER_KILOBYTE :: 1024
@(private = "file") SEARCH_FAILED_EXIT :: 127
@(private = "file") FILE_MODE :: 0o644

Platform_Process :: struct {
	pid:    linux.Pid,
	ended:  bool,
	code:   int,
	rusage: linux.RUsage,
}

// The path of a program, from the PATH (found before the fork: in the child nothing may allocate).
@(private = "file")
find_program :: proc(name: string) -> string {
	if strings.contains_rune(name, '/') { return name }
	path, _ := os.lookup_env("PATH", context.temp_allocator)
	for dir in strings.split(path, ":", context.temp_allocator) {
		full := strings.concatenate({dir, "/", name}, context.temp_allocator)
		if os.exists(full) { return full }
	}
	return ""
}

@(private = "file")
c_strings :: proc(list: []string) -> [^]cstring {
	out := make([]cstring, len(list) + 1, context.temp_allocator)
	for s, i in list { out[i] = strings.clone_to_cstring(s, context.temp_allocator) }
	return raw_data(out)
}

spawn :: proc(d: Spawn) -> (p: Process, why: string) {
	sync.guard(&spawn_lock)
	program := find_program(exe_argument(d.command[0]))
	if program == "" { return p, "it is not on the PATH" }
	program_c := strings.clone_to_cstring(program, context.temp_allocator)
	argv := c_strings(d.command)
	envp := c_strings(merged_env(d.env))
	dir_c := strings.clone_to_cstring(d.dir, context.temp_allocator)
	log_c := strings.clone_to_cstring(d.log, context.temp_allocator)
	pid := posix.fork()
	if pid < 0 { return p, "fork failed" }
	if pid == 0 {
		posix.setpgid(0, 0)
		if d.log != "" {
			fd := posix.open(log_c, {.WRONLY, .CREAT, .APPEND}, transmute(posix.mode_t)posix._mode_t(FILE_MODE))
			if fd >= 0 { posix.dup2(fd, 1); posix.dup2(fd, 2); posix.close(fd) }
		}
		null_in := posix.open("/dev/null", {})
		if null_in >= 0 { posix.dup2(null_in, 0); posix.close(null_in) }
		if d.dir != "" { posix.chdir(dir_c) }
		posix.execve(program_c, argv, envp)
		posix._exit(SEARCH_FAILED_EXIT)
	}
	posix.setpgid(pid, pid)   // (both sides: whichever runs first)
	p.pid = linux.Pid(pid)
	p.began = time.tick_now()
	return p, ""
}

poll :: proc(p: ^Process) -> (done: bool, code: int) {
	if p.ended { return true, p.code }
	if p.pid == 0 { return true, -1 }
	status: u32
	got, err := linux.wait4(p.pid, &status, {.WNOHANG}, &p.rusage)
	if err != nil || got == 0 { return err != nil && err != .EINTR ? true : false, -1 }
	p.ended = true
	p.code = linux.WIFEXITED(status) ? int(linux.WEXITSTATUS(status)) : -int(linux.WTERMSIG(status))
	return true, p.code
}

kill_tree :: proc(p: ^Process) {
	if p.pid != 0 { _ = linux.kill(-p.pid, .SIGKILL) }
}

usage :: proc(p: ^Process) -> (u: Usage) {
	tv :: proc(t: linux.Time_Val) -> f64 { return f64(t.seconds) + f64(t.microseconds) / MICROS_PER_SECOND }
	u.cpu_seconds = tv(p.rusage.utime) + tv(p.rusage.stime)
	u.processes = 1
	u.peak_bytes = u64(p.rusage.maxrss_word) * BYTES_PER_KILOBYTE
	return
}

tree_pids :: proc(p: ^Process, allocator := context.temp_allocator) -> []int {
	out := make([]int, 1, allocator)
	out[0] = int(p.pid)
	return out
}

// How many of the group still run: all that can be told is whether any does.
tree_active :: proc(p: ^Process) -> int {
	if p.pid == 0 { return 0 }
	return linux.kill(-p.pid, linux.Signal(0)) == nil ? 1 : 0
}

release :: proc(p: ^Process) {
	if p.pid == 0 { return }
	kill_tree(p)
	if !p.ended {
		for {
			if done, _ := poll(p); done { break }
			time.sleep(WAIT_SLICE)
		}
	}
	p.pid = 0
}

// What /STACK is on Windows: Wasm calls run on the calling thread (the JavaScript engine's pre-initialization, the browser's window
// thread). The soft limit of this process's stack, which every child inherits (no more than the hard limit).
raise_stack :: proc() {
	limit: linux.RLimit
	if linux.getrlimit(.STACK, &limit) != nil { return }
	limit.cur = min(JS_THREAD_STACK_BYTES, limit.max)
	_ = linux.setrlimit(.STACK, &limit)
}
