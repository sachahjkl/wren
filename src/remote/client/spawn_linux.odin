package client

// The processes of spawn.odin on Linux: a child of ours (posix_spawn, waitpid) or, for `stop`, a pid told again by
// /proc/<pid>/stat's start time and /proc/<pid>/exe. A child is reaped by the wait that sees it end (its pid is not given
// to another process before that); a process that is not our child is watched through /proc and signalled.

import "core:os"
import "core:strconv"
import "core:strings"
import "core:sys/posix"
import "core:time"

Process :: struct {
	pid:    posix.pid_t,
	child:  bool,   // ours: waitpid reaps it
	ended:  bool,
	status: i32,
}

this_pid :: proc() -> int { return int(posix.getpid()) }

// The start of process `pid` after boot (clock ticks, /proc/<pid>/stat field 22) and its program (/proc/<pid>/exe).
identity_of_pid :: proc(pid: int, allocator := context.temp_allocator) -> (id: Identity, ok: bool) {
	if pid <= 0 { return {}, false }
	stat, err := os.read_entire_file(strings.concatenate({"/proc/", itoa(pid), "/stat"}, context.temp_allocator), context.temp_allocator)
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
	n := posix.readlink(strings.clone_to_cstring(strings.concatenate({"/proc/", itoa(pid), "/exe"}, context.temp_allocator), context.temp_allocator), &buf[0], len(buf))
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
itoa :: proc(n: int) -> string {
	buf: [24]u8
	return strings.clone(strconv.write_int(buf[:], i64(n), 10), context.temp_allocator)
}

@(private = "file")
gone :: proc(pid: posix.pid_t) -> bool {
	// (a zombie is still there for kill: its state says it ended)
	if posix.kill(pid, .NONE) != .OK { return true }
	stat, err := os.read_entire_file(strings.concatenate({"/proc/", itoa(int(pid)), "/stat"}, context.temp_allocator), context.temp_allocator)
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

// Starts `args` (args[0] the program, a path) with this process's environment. err "": started.
process_start :: proc(args: []string) -> (p: Process, pid: int, err: string) {
	argv := make([]cstring, len(args) + 1, context.temp_allocator)
	for a, i in args { argv[i] = strings.clone_to_cstring(a, context.temp_allocator) }
	child: posix.pid_t
	if e := posix.posix_spawn(&child, argv[0], nil, nil, raw_data(argv), posix.environ); e != .NONE {
		return {}, 0, string(posix.strerror(e))
	}
	return {pid = child, child = true}, int(child), ""
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

process_kill :: proc(p: ^Process) { if !p.ended { posix.kill(p.pid, .SIGKILL) } }

process_release :: proc(p: ^Process) {
	if p.child && !p.ended { process_wait(p, 0) }
	p^ = {}
}

// Lets the process go on alone (a session `wren ctl stop` ends later): when this one exits, init adopts and reaps it.
process_detach :: proc(p: ^Process) { p^ = {} }
