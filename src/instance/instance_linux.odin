package instance

// Linux: a lock file and a Unix socket in the user's runtime directory ($XDG_RUNTIME_DIR/wren, else /tmp/wren-<uid>,
// mode 0700: only this user's processes reach them). See instance.odin for the whole picture.
//
//   <key>.lock   flock(LOCK_EX) says who owns the profile; the kernel lets go when the process ends, crashed or not
//   <key>.sock   the owner listens there once owner_start has run (before that, and after owner_closing, there is
//                nothing to connect to: the second start tries again, as on Windows when there is no window)
//
// A second start connects, writes the message (a u32 length, little-endian, then encode's bytes) and reads one byte: 1
// taken, 2 another executable, 0 refused (closing). The owner reads its socket in pump_messages, on the thread that
// called owner_start, as the Windows owner gets its WM_COPYDATA in the message pump.

import "core:encoding/endian"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:sys/linux"
import "core:time"

// A message longer than this is not one (the Windows owner takes at most 1 MiB in a WM_COPYDATA too).
@(private = "file") MAX_MESSAGE :: 1 << 20
// How long the owner waits for the bytes of a message once a start has connected (it writes them at once).
@(private = "file") READ_MS :: 1000

Owner :: struct {
	key:     string,        // owned
	exe:     string,        // owned: the executable that owns the profile
	closing: bool,          // set before the socket goes: later messages are refused
	handler: Handler,
	user:    rawptr,
	lock:    linux.Fd,      // the flock'd file (-1: none)
	listen:  linux.Fd,      // the socket (-1: none)
	sock:    string,        // owned: its path
	thread:  int,           // the thread whose pump_messages reads the socket
}

Reply :: enum u8 { No_Window, Accepted, Other_Copy, Refused, Timeout }

// The owners started in this process (pump_messages serves those of the calling thread).
@(private = "file") owners_mu: sync.Mutex
@(private = "file") owners: [dynamic]^Owner

@(private = "file")
runtime_dir :: proc() -> string {
	dir := ""
	if x := os.get_env("XDG_RUNTIME_DIR", context.temp_allocator); x != "" {
		dir = strings.concatenate({x, "/wren"}, context.temp_allocator)
	} else {
		dir = fmt.tprintf("/tmp/wren-%d", linux.getuid())
	}
	linux.mkdir(strings.clone_to_cstring(dir, context.temp_allocator), {.IRUSR, .IWUSR, .IXUSR})
	return dir
}

@(private = "file")
path_of :: proc(key, ext: string) -> string { return strings.concatenate({runtime_dir(), "/", key, ext}, context.temp_allocator) }

@(private = "file")
address_of :: proc(path: string) -> (addr: linux.Sock_Addr_Un, ok: bool) {
	if len(path) >= len(addr.sun_path) { return {}, false }
	addr.sun_family = .UNIX
	copy(addr.sun_path[:], path)
	return addr, true
}

// One attempt to hand `m` to the owner of `key`.
forward_once :: proc(key: string, m: Message, timeout_ms: int) -> Reply {
	addr, ok := address_of(path_of(key, ".sock"))
	if !ok { return .No_Window }
	s, err := linux.socket(.UNIX, .STREAM, {.CLOEXEC}, .HOPOPT)
	if err != .NONE { return .No_Window }
	defer linux.close(s)
	if linux.connect(s, &addr) != .NONE { return .No_Window }   // nobody listens (starting, closing) or no file
	data := encode(m)
	head: [4]u8
	endian.put_u32(head[:], .Little, u32(len(data)))
	if !send_all(s, head[:]) || !send_all(s, data) { return .No_Window }   // it closed while we asked
	fds := []linux.Poll_Fd{{fd = s, events = {.IN}}}
	n, _ := linux.poll(fds, i32(max(timeout_ms, 1)))
	if n <= 0 { return .Timeout }
	answer: [1]u8
	got, rerr := linux.recv(s, answer[:], {})
	if rerr != .NONE || got != 1 { return .No_Window }   // closed without answering: it is going away
	switch answer[0] {
	case 1: return .Accepted
	case 2: return .Other_Copy
	}
	return .Refused
}

@(private = "file")
send_all :: proc(s: linux.Fd, data: []u8) -> bool {
	at := 0
	for at < len(data) {
		n, err := linux.send(s, data[at:], {.NOSIGNAL})
		if err == .EINTR { continue }
		if err != .NONE || n <= 0 { return false }
		at += n
	}
	return true
}

// Takes the profile of `key` or hands `msg` to the one that has it. Tries for up to `wait_ms` while the owner is starting or
// closing; a silent owner ends the wait at once (it is busy or hung: not worth waiting for).
acquire :: proc(key: string, own_exe: string, msg: Message, wait_ms: int) -> (Outcome, Owner) {
	deadline := time.tick_add(time.tick_now(), time.Duration(wait_ms) * time.Millisecond)
	lock_path := strings.clone_to_cstring(path_of(key, ".lock"), context.temp_allocator)
	for {
		fd, err := linux.open(lock_path, {.RDWR, .CREAT, .CLOEXEC}, {.IRUSR, .IWUSR})
		if err != .NONE { return .Unresponsive, {} }   // (no runtime directory: carry on as if it was not asked)
		if linux.flock(fd, {.EX, .NB}) == .NONE {
			return .First, Owner{key = strings.clone(key), exe = strings.clone(own_exe), lock = fd, listen = -1}
		}
		linux.close(fd)
		left := int(time.duration_milliseconds(time.tick_diff(time.tick_now(), deadline)))
		switch forward_once(key, msg, max(left, 200)) {
		case .Accepted:   return .Forwarded, {}
		case .Other_Copy: return .Other_Copy, {}
		case .Timeout:    return .Unresponsive, {}
		case .No_Window, .Refused:
		}
		if left <= 0 { return .Unresponsive, {} }
		time.sleep(40 * time.Millisecond)
	}
}

// Opens the owner's socket (served by pump_messages on this thread) and sets the handler that takes the messages.
owner_start :: proc(o: ^Owner, handler: Handler, user: rawptr) -> bool {
	if o.lock <= 0 { return false }
	o.handler, o.user = handler, user
	path := path_of(o.key, ".sock")
	addr, ok := address_of(path)
	if !ok { return false }
	s, err := linux.socket(.UNIX, .STREAM, {.CLOEXEC, .NONBLOCK}, .HOPOPT)
	if err != .NONE { return false }
	cpath := strings.clone_to_cstring(path, context.temp_allocator)
	linux.unlink(cpath)   // a socket left by an owner that crashed: the lock says it is ours now
	if linux.bind(s, &addr) != .NONE || linux.listen(s, 16) != .NONE { linux.close(s); return false }
	o.listen, o.sock, o.thread = s, strings.clone(path), sync.current_thread_id()
	sync.mutex_lock(&owners_mu)
	append(&owners, o)
	sync.mutex_unlock(&owners_mu)
	return true
}

// Is it an elevated process? (Root: it takes messages from the user's own processes only anyway, the socket is 0700.)
is_elevated :: proc() -> bool { return linux.geteuid() == 0 }

// The owner is ending: later messages are refused and the socket goes. The profile is still its own (the lock is held):
// a start that comes now waits, and takes the profile once owner_stop has released it.
owner_closing :: proc(o: ^Owner) {
	o.closing = true
	if o.listen > 0 {
		sync.mutex_lock(&owners_mu)
		for x, i in owners { if x == o { unordered_remove(&owners, i); break } }
		if len(owners) == 0 { delete(owners); owners = nil }
		sync.mutex_unlock(&owners_mu)
		linux.close(o.listen)
		o.listen = -1
		linux.unlink(strings.clone_to_cstring(o.sock, context.temp_allocator))
	}
	delete(o.sock)
	o.sock = ""
}

// The owner is done with the profile: the lock is released (a start that was waiting becomes the owner).
owner_stop :: proc(o: ^Owner) {
	owner_closing(o)
	if o.lock > 0 { linux.close(o.lock); o.lock = -1 }
	delete(o.key); delete(o.exe)
	o.key, o.exe = "", ""
}

// Raising a window is the shell's (the toolkit's window: xdg-activation on Wayland, _NET_ACTIVE_WINDOW on X11).
focus :: proc(hwnd: rawptr) {}

// Serves the sockets of the owners started on this thread: every waiting start gets its answer.
pump_messages :: proc() {
	me := sync.current_thread_id()
	sync.mutex_lock(&owners_mu)
	mine := make([dynamic]^Owner, context.temp_allocator)
	for o in owners { if o.thread == me { append(&mine, o) } }
	sync.mutex_unlock(&owners_mu)
	for o in mine {
		for {
			c, err := linux.accept(o.listen, cast(^linux.Sock_Addr_Un)nil, {.CLOEXEC})
			if err != .NONE { break }   // EAGAIN: nobody waits
			answer := [1]u8{serve(o, c)}
			send_all(c, answer[:])
			linux.close(c)
		}
	}
}

// Reads one message from `c` and hands it to the handler: the byte to answer.
@(private = "file")
serve :: proc(o: ^Owner, c: linux.Fd) -> u8 {
	if o.closing || o.handler == nil { return 0 }
	head: [4]u8
	if !read_full(c, head[:]) { return 0 }
	n := int(endian.unchecked_get_u32le(head[:]))
	if n == 0 || n > MAX_MESSAGE { return 0 }
	data := make([]u8, n, context.temp_allocator)
	if !read_full(c, data) { return 0 }
	m, ok := decode(data)
	if !ok { return 0 }
	if !same_exe(m.exe, o.exe) { return 2 }
	o.handler(o.user, m)
	return 1
}

@(private = "file")
read_full :: proc(c: linux.Fd, buf: []u8) -> bool {
	at := 0
	deadline := time.tick_add(time.tick_now(), READ_MS * time.Millisecond)
	for at < len(buf) {
		left := time.duration_milliseconds(time.tick_diff(time.tick_now(), deadline))
		if left <= 0 { return false }
		fds := []linux.Poll_Fd{{fd = c, events = {.IN}}}
		if r, _ := linux.poll(fds, i32(left) + 1); r <= 0 { return false }
		got, err := linux.recv(c, buf[at:], {})
		if err == .EINTR || err == .EAGAIN { continue }
		if err != .NONE || got <= 0 { return false }
		at += got
	}
	return true
}
