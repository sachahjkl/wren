// Package instance: one Wren per profile. The first Wren to start with a profile owns it; a second start with the same
// profile (a link opened from another program, a double-clicked .html, `wren.exe https://...` from a terminal) does not
// open a second window on the same cookies, preferences and session: it hands what it was given (addresses, files, the
// request to open Setup) to the first one, lets it come to the front, and ends with exit code 0.
//
// Who is "the same": the channel (release and development builds never meet) and the profile's folder, by a hash of its
// absolute path, so that `--profile X` and every test or tool that has a profile of its own stay independent of one
// another and of the user's Wren. Only the same executable takes the hand-over: a different copy of Wren (an update just
// downloaded, a copy elsewhere) starts as it always did, so that Setup can replace the installed copy while it runs.
//
// How (Windows, instance_windows.odin): a named mutex says who owns the profile; the owner has a message-only window whose
// title is the key; a second start finds it, allows it to take the foreground (AllowSetForegroundWindow) and sends a
// WM_COPYDATA with the message below. The owner answers 1 (taken), 2 (another executable) or 0 (closing).
//
// What can go wrong, and what then: the owner has no window yet (it is starting) or has just closed it (it is closing):
// the second start tries again for a short while, and when the mutex is gone it becomes the owner itself; the owner does
// not answer (a page that keeps it busy, a hung process): after the timeout the second start opens its own window and
// says so, it never waits for ever and never loses its arguments.
package instance

import "core:path/filepath"
import "core:strings"

// What a second start hands over.
Message :: struct {
	exe:       string,     // the sender's executable (absolute): the owner takes the message only from its own
	setup:     bool,       // `--setup`: open the Setup dialog
	addresses: []string,   // what was given to open, one tab each (already addresses: paths made into file: URLs)
}

// What `acquire` came to.
Outcome :: enum u8 {
	First,          // this process owns the profile (Owner is set): carry on and call owner_start once the loop exists
	Forwarded,      // the owner took the message: exit now with code 0
	Other_Copy,     // the owner is another executable: carry on normally, without owning anything
	Unresponsive,   // the owner did not answer in time: carry on normally and say so
}

// The handler of the owner: called on the thread that created the window, inside the pump, with strings that are valid
// only during the call (copy what is kept). It must be quick: the sender waits for it.
Handler :: #type proc(user: rawptr, m: Message)

MAGIC :: 0x5752_4E49   // "WRNI": dwData of the WM_COPYDATA

// "Wren.release.3f2a9c41d07be5a6": the channel, and a hash of the profile folder's absolute path (case and slash direction
// do not matter on Windows). Letters and digits and dots only: it is part of kernel object names.
profile_key :: proc(channel, profile_dir: string, allocator := context.temp_allocator) -> string {
	p := profile_dir
	if abs, err := filepath.abs(profile_dir, context.temp_allocator); err == nil { p = abs }
	p, _ = strings.replace_all(p, "\\", "/", context.temp_allocator)
	p = strings.trim_right(p, "/")
	when ODIN_OS == .Windows { p = strings.to_lower(p, context.temp_allocator) }
	h: u64 = 0xcbf29ce484222325   // FNV-1a
	for c in transmute([]u8)p { h = (h ~ u64(c)) * 0x100000001b3 }
	hex := "0123456789abcdef"
	digits: [16]u8
	for i in 0 ..< 16 { digits[15 - i] = hex[h & 0xf]; h >>= 4 }
	return strings.concatenate({"Wren.", channel, ".", string(digits[:])}, allocator)
}

// The bytes of a message: lines "v1", "exe=<path>", "setup=0|1", then "addr=<address>" for each (an address with a line
// break in it is dropped: it cannot be one).
encode :: proc(m: Message, allocator := context.temp_allocator) -> []byte {
	sb := strings.builder_make(allocator)
	strings.write_string(&sb, "v1\n")
	strings.write_string(&sb, "exe="); strings.write_string(&sb, m.exe); strings.write_string(&sb, "\n")
	strings.write_string(&sb, m.setup ? "setup=1\n" : "setup=0\n")
	for a in m.addresses {
		if a == "" || strings.contains_any(a, "\r\n\x00") { continue }
		strings.write_string(&sb, "addr="); strings.write_string(&sb, a); strings.write_string(&sb, "\n")
	}
	return transmute([]byte)strings.to_string(sb)
}

// The message of those bytes (the strings point into `data`; the addresses slice is in `allocator`). ok = false for anything
// that is not a message of this version.
decode :: proc(data: []byte, allocator := context.temp_allocator) -> (m: Message, ok: bool) {
	text := string(data)
	lines := strings.split_lines(text, context.temp_allocator)
	if len(lines) == 0 || lines[0] != "v1" { return {}, false }
	addresses := make([dynamic]string, allocator)
	seen_exe := false
	for l in lines[1:] {
		switch {
		case strings.has_prefix(l, "exe="):   m.exe = l[len("exe="):]; seen_exe = true
		case l == "setup=1":                  m.setup = true
		case l == "setup=0":
		case strings.has_prefix(l, "addr="):  append(&addresses, l[len("addr="):])
		case l == "":
		case: return {}, false
		}
	}
	if !seen_exe { return {}, false }
	m.addresses = addresses[:]
	return m, true
}

// The same file? (Windows: case and slash direction do not matter.)
same_exe :: proc(a, b: string) -> bool {
	if a == "" || b == "" { return false }
	when ODIN_OS == .Windows {
		x, _ := strings.replace_all(a, "/", "\\", context.temp_allocator)
		y, _ := strings.replace_all(b, "/", "\\", context.temp_allocator)
		return strings.equal_fold(x, y)
	} else {
		return a == b
	}
}
