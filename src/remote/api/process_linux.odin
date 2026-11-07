package api

// The processes of session.odin on Linux: a child of ours (posix_spawn, waitpid) or, for `stop`, a pid told again by
// /proc/<pid>/stat's start time and /proc/<pid>/exe. A child is reaped by the wait that sees it end (its pid is not given
// to another process before that); a process that is not our child is watched through /proc and signalled.

import "base:runtime"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:sys/posix"
import "core:time"
import "wb:base"

Process :: struct {
	pid:      posix.pid_t,
	child:    bool,   // ours: waitpid reaps it
	ended:    bool,
	status:   i32,
	out, err: Maybe(posix.FD),   // the read ends of the pipes it writes to, those it was given (Start_Options)
}

// What a pipe of Output holds before the program writing to it waits (a program that writes more waits for process_output), as on Windows.
OUTPUT_PIPE_BYTES :: 1 << 20
// Linux's fcntl that sets a pipe's size (F_SETPIPE_SZ; core:sys/posix has not got it).
@(private = "file") FCNTL_SETPIPE_SZ :: posix.FCNTL_Cmd(1031)
@(private = "file") NULL_DEVICE :: cstring("/dev/null")
@(private = "file") OUTPUT_FILE_MODE :: posix.mode_t{.IRUSR, .IWUSR}
// What process_output reads at a time.
@(private = "file") OUTPUT_CHUNK_BYTES :: 64 << 10

// posix_spawn's list of what to do in the child (core:sys/posix has the call, not these): an opaque block, 80 bytes in glibc.
@(private = "file") Spawn_Actions :: [128]u8

foreign import libc "system:c"

@(private = "file", default_calling_convention = "c")
foreign libc {
	posix_spawn_file_actions_init      :: proc(actions: ^Spawn_Actions) -> posix.Errno ---
	posix_spawn_file_actions_destroy   :: proc(actions: ^Spawn_Actions) -> posix.Errno ---
	posix_spawn_file_actions_adddup2   :: proc(actions: ^Spawn_Actions, fd, to: posix.FD) -> posix.Errno ---
	posix_spawn_file_actions_addchdir_np :: proc(actions: ^Spawn_Actions, path: cstring) -> posix.Errno ---   // glibc 2.29
}

this_pid :: proc() -> int { return int(posix.getpid()) }

// The start of process `pid` after boot (clock ticks, /proc/<pid>/stat field 22) and its program (/proc/<pid>/exe).
identity_of_pid :: proc(pid: int, allocator := context.temp_allocator) -> (id: Identity, ok: bool) {
	if pid <= 0 { return {}, false }
	stat, err := os.read_entire_file(strings.concatenate({"/proc/", base.itoa(pid), "/stat"}, context.temp_allocator), context.temp_allocator)
	if err != nil { return {}, false }
	// the name (field 2) is in parentheses and may hold anything: the fields after its last ')' start at field 3
	s := string(stat)
	close := strings.last_index_byte(s, ')')
	if close < 0 { return {}, false }
	fields := strings.fields(s[close + 1:], context.temp_allocator)
	if len(fields) < 20 { return {}, false }
	start, good := strconv.parse_u64(fields[19])
	if !good || start == 0 { return {}, false }
	buf: [4096]u8
	n := posix.readlink(strings.clone_to_cstring(strings.concatenate({"/proc/", base.itoa(pid), "/exe"}, context.temp_allocator), context.temp_allocator), &buf[0], len(buf))
	if n <= 0 || int(n) >= len(buf) { return {}, false }
	return {created = start, image = strings.clone(string(buf[:n]), allocator)}, true
}

identity_of :: proc(p: ^Process, allocator := context.temp_allocator) -> (id: Identity, ok: bool) { return identity_of_pid(int(p.pid), allocator) }

// Same start, same program (paths are compared as they are: case matters here). A record with no start time or no
// program names nobody.
same_process :: proc(recorded, now: Identity) -> bool {
	return recorded.created != 0 && recorded.image != "" && recorded.created == now.created && recorded.image == now.image
}

@(private = "file")
gone :: proc(pid: posix.pid_t) -> bool {
	// (a zombie is still there for kill: its state says it ended)
	if posix.kill(pid, .NONE) != .OK { return true }
	stat, err := os.read_entire_file(strings.concatenate({"/proc/", base.itoa(int(pid)), "/stat"}, context.temp_allocator), context.temp_allocator)
	if err != nil { return true }
	s := string(stat)
	close := strings.last_index_byte(s, ')')
	return close >= 0 && close + 2 < len(s) && (s[close + 2] == 'Z' || s[close + 2] == 'X')
}

// Waits for process `pid` (not a child of ours: `wren ctl quit` of a Wren started elsewhere) to end. `ended` false: still
// running after `ms`. Its exit code is its parent's to read: 0 here.
wait_process_exit :: proc(pid: int, ms: int) -> (code: int, ended: bool) {
	if pid <= 0 { return 0, true }
	deadline := time.tick_add(time.tick_now(), time.Duration(ms) * time.Millisecond)
	for !gone(posix.pid_t(pid)) {
		if time.tick_diff(time.tick_now(), deadline) <= 0 { return 0, false }
		time.sleep(10 * time.Millisecond)
	}
	return 0, true
}

// (Windows only for now: gdb -p does it here.)
process_stacks :: proc(pid: int, minidump := "") -> (text: string, ok: bool) { return "reading another process's stacks is not written for this system", false }

// Starts `args` (args[0] the program, a path) with this process's environment and `o.env` over it, in `o.cwd`, its outputs
// where `o` says (as on Windows: an output left out of a redirected start goes nowhere). err "": started.
process_start :: proc(args: []string, o := Start_Options{}) -> (p: Process, pid: int, err: string) {
	argv := make([]cstring, len(args) + 1, context.temp_allocator)
	for a, i in args { argv[i] = strings.clone_to_cstring(a, context.temp_allocator) }
	redirected := o.stdout != {} || o.stderr != {} || o.merged
	actions: Spawn_Actions
	posix_spawn_file_actions_init(&actions)
	defer posix_spawn_file_actions_destroy(&actions)
	if o.cwd != "" { posix_spawn_file_actions_addchdir_np(&actions, strings.clone_to_cstring(o.cwd, context.temp_allocator)) }
	// the ends the child writes to, closed here once it has them
	given: [2]posix.FD = {-1, -1}
	defer for fd in given { if fd >= 0 { posix.close(fd) } }
	if redirected {
		out_fd, out_read, ok := output_for_child(o.stdout)
		if !ok { return {}, 0, "its output could not be made" }
		given[0] = out_fd
		if out_read >= 0 { p.out = out_read }
		posix_spawn_file_actions_adddup2(&actions, out_fd, posix.STDOUT_FILENO)
		if o.merged {
			posix_spawn_file_actions_adddup2(&actions, out_fd, posix.STDERR_FILENO)
		} else {
			err_fd, err_read, ok2 := output_for_child(o.stderr)
			if !ok2 { process_release(&p); return {}, 0, "its error output could not be made" }
			given[1] = err_fd
			if err_read >= 0 { p.err = err_read }
			posix_spawn_file_actions_adddup2(&actions, err_fd, posix.STDERR_FILENO)
		}
	}
	child: posix.pid_t
	if e := posix.posix_spawn(&child, argv[0], &actions, nil, raw_data(argv), environment_with(o.env)); e != .NONE {
		process_release(&p)
		return {}, 0, string(posix.strerror(e))
	}
	p.pid, p.child = child, true
	return p, int(child), ""
}

// The descriptor a child writes one of its outputs to (closed on exec here: the child gets it by dup2) and, for a pipe, the read end
// this process keeps, which never blocks (process_output). Neither pipe nor file: /dev/null.
@(private = "file")
output_for_child :: proc(o: Output) -> (write, read: posix.FD, ok: bool) {
	read = -1
	if o.file != "" {
		write = posix.open(strings.clone_to_cstring(o.file, context.temp_allocator), {.WRONLY, .CREAT, .TRUNC, .CLOEXEC}, OUTPUT_FILE_MODE)
		return write, -1, write >= 0
	}
	if !o.pipe {
		write = posix.open(NULL_DEVICE, {.WRONLY, .CLOEXEC})
		return write, -1, write >= 0
	}
	fds: [2]posix.FD
	if posix.pipe(&fds) != .OK { return -1, -1, false }
	for fd in fds { posix.fcntl(fd, .SETFD, i32(posix.FD_CLOEXEC)) }
	posix.fcntl(fds[0], .SETFL, i32(posix.O_NONBLOCK))
	posix.fcntl(fds[1], FCNTL_SETPIPE_SZ, i32(OUTPUT_PIPE_BYTES))   // (as on Windows: what a program writes before it waits for process_output)
	return fds[1], fds[0], true
}

// This process's environment with `over` ("NAME=value" sets it, "NAME=" leaves it out), nil-terminated.
@(private = "file")
environment_with :: proc(over: []string) -> [^]cstring {
	if len(over) == 0 { return posix.environ }
	name_of :: proc(entry: string) -> string { k := strings.index_byte(entry, '='); return k < 0 ? entry : entry[:k] }
	out := make([dynamic]cstring, context.temp_allocator)
	for i := 0; posix.environ[i] != nil; i += 1 {
		entry := string(posix.environ[i])
		replaced := false
		for e in over { if name_of(e) == name_of(entry) { replaced = true; break } }
		if !replaced { append(&out, posix.environ[i]) }
	}
	for e in over { if !strings.has_suffix(e, "=") { append(&out, strings.clone_to_cstring(e, context.temp_allocator)) } }
	append(&out, nil)
	return raw_data(out)
}

// Process `pid`, to wait for it and end it (false: it is gone).
process_open :: proc(pid: int) -> (Process, bool) {
	if pid <= 0 || gone(posix.pid_t(pid)) { return {}, false }
	return {pid = posix.pid_t(pid)}, true
}

@(private = "file")
reap :: proc(p: ^Process, block: bool) -> bool {
	if p.ended { return true }
	if !p.child { p.ended = gone(p.pid); return p.ended }
	st: i32
	r := posix.waitpid(p.pid, &st, block ? {} : {.NOHANG})
	if r == p.pid { p.ended, p.status = true, st; return true }
	if r < 0 && posix.errno() == .ECHILD { p.ended = true; return true }
	return false
}

process_alive :: proc(p: ^Process) -> bool { return !reap(p, false) }

// True once it has ended (within `ms`).
process_wait :: proc(p: ^Process, ms: int) -> bool {
	deadline := time.tick_add(time.tick_now(), time.Duration(ms) * time.Millisecond)
	for !reap(p, false) {
		if time.tick_diff(time.tick_now(), deadline) <= 0 { return false }
		time.sleep(5 * time.Millisecond)
	}
	return true
}

// Has it been ended?
process_ended :: proc(p: ^Process) -> bool { return !process_alive(p) }

// What the program wrote to its pipes since the last look, without waiting (the program may go on, and what it started may hold the pipes for ever).
process_output :: proc(p: ^Process, allocator := context.temp_allocator) -> (out, err: string) {
	drain :: proc(pipe: Maybe(posix.FD), allocator: runtime.Allocator) -> string {
		fd, open := pipe.?
		if !open { return "" }
		b := strings.builder_make(allocator)
		chunk: [OUTPUT_CHUNK_BYTES]u8
		for {
			n := posix.read(fd, &chunk[0], len(chunk))
			if n <= 0 { break }   // nothing more now (EAGAIN), or the end
			strings.write_bytes(&b, chunk[:n])
		}
		return strings.to_string(b)
	}
	return drain(p.out, allocator), drain(p.err, allocator)
}

// The time it has spent on the processors (ms): not read here.
process_cpu_ms :: proc(p: ^Process) -> f64 { return 0 }

process_kill :: proc(p: ^Process) { if !p.ended { posix.kill(p.pid, .SIGKILL) } }

process_release :: proc(p: ^Process) {
	if p.child && !p.ended { process_wait(p, 0) }
	process_detach(p)
}

// Lets the process go on alone (a session `wren ctl stop` ends later): when this one exits, init adopts and reaps it.
// (closes the read ends of its pipes: what it writes after goes nowhere)
process_detach :: proc(p: ^Process) {
	if fd, open := p.out.?; open { posix.close(fd) }
	if fd, open := p.err.?; open { posix.close(fd) }
	p^ = {}
}

// The exit code of a process that has ended (process_wait said so): that of a child of ours; -1 when a signal ended it, or it is not our child.
process_exit_code :: proc(p: ^Process) -> int {
	if !p.child || !p.ended || !posix.WIFEXITED(p.status) { return -1 }
	return int(posix.WEXITSTATUS(p.status))
}
