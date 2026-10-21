// The test server's block of ports for the end-to-end tools (tools/testserver/ports.go): every origin the tests use is
// a fixed offset from one base port, 127.0.0.1:8765 by default (+1 https, +2 a second http origin, +3/+4 the
// web-platform-tests origin). tools\test_all.ps1 gives each run its own block through WREN_TEST_BASE_PORT so that
// several worktrees test side by side; the tools keep writing the default ports and pass every address through url(),
// which moves them to the current block (and changes nothing on the default one).
package testenv

import "core:os"
import "core:strconv"
import "core:strings"
import "core:sync"
import "wb:base"

DEFAULT_BASE_PORT :: 8765
BLOCK_PORTS :: 5

@(private) cached: int
@(private) lock: sync.Mutex
// url() results, kept for the life of the process on the heap allocator (outside any tracking allocator a tool
// checks for leaks): an address can be handed to anything that keeps it.
@(private) interned: map[string]string

// The base port of this run: WREN_TEST_BASE_PORT, else 8765.
base_port :: proc() -> int {
	if cached != 0 { return cached }
	b := DEFAULT_BASE_PORT
	if v := os.get_env("WREN_TEST_BASE_PORT", context.temp_allocator); v != "" {
		if n, ok := strconv.parse_int(v, 10); ok && n > 0 && n + BLOCK_PORTS <= 65536 { b = n }
	}
	cached = b
	return b
}

// The port `offset` places after the base (0 http, 1 https, 2 the second http origin, 3 / 4 WPT).
port :: proc(offset := 0) -> int { return base_port() + offset }

// `s` with every default port written after a host (":8765" .. ":8769", not a longer number, not "U+8766") moved to
// the current block. On the default block, `s` itself.
url :: proc(s: string) -> string {
	b := base_port()
	if b == DEFAULT_BASE_PORT || !strings.contains(s, ":876") { return s }
	sync.guard(&lock)
	if r, ok := interned[s]; ok { return r }
	context.allocator = base.process_allocator()
	if interned == nil { interned = make(map[string]string) }
	r := rewrite(s, b)
	interned[strings.clone(s)] = r
	return r
}

@(private)
rewrite :: proc(s: string, b: int) -> string {
	out := strings.builder_make(0, len(s) + 16)
	for i := 0; i < len(s); {
		if is_default_port_at(s, i) {
			strings.write_byte(&out, ':')
			strings.write_int(&out, b + int(s[i + 4] - '5'))
			i += 5
			continue
		}
		strings.write_byte(&out, s[i])
		i += 1
	}
	return strings.to_string(out)
}

// ":876d" at i, d in 5..9, after a host character and not followed by another digit.
@(private)
is_default_port_at :: proc(s: string, i: int) -> bool {
	if i == 0 || i + 5 > len(s) || s[i:i + 4] != ":876" { return false }
	d := s[i + 4]
	if d < '5' || d > '9' { return false }
	if i + 5 < len(s) && s[i + 5] >= '0' && s[i + 5] <= '9' { return false }
	c := s[i - 1]
	return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == ']'
}
