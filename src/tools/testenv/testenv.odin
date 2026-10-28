// The test server's block of ports for the end-to-end tools (tools/testserver/ports.go): every origin the tests use is
// a fixed offset from one base port, 127.0.0.1:8765 by default (+1 https, +2 a second http origin, +3/+4 the
// web-platform-tests origin). tools\test_all.ps1 gives each run its own block through WREN_TEST_BASE_PORT so that
// several worktrees test side by side; the tools keep writing the default ports and pass every address through url(),
// which moves them to the current block (and changes nothing on the default one).
//
// The port-block logic is the toolkit's testkit (toolkit:testkit), reused with Wren's own environment variable and base
// port; this file is a thin wrapper so the tools keep writing testenv.url / testenv.port unchanged.
package testenv

import tk "toolkit:testkit"

DEFAULT_BASE_PORT :: 8765
BLOCK_PORTS :: 5

@(private)
PORTS := tk.Ports{base_env = "WREN_TEST_BASE_PORT", default_base = DEFAULT_BASE_PORT, span = BLOCK_PORTS}

// The base port of this run: WREN_TEST_BASE_PORT, else 8765.
base_port :: proc() -> int { return tk.base_port(&PORTS) }

// The port `offset` places after the base (0 http, 1 https, 2 the second http origin, 3 / 4 WPT).
port :: proc(offset := 0) -> int { return tk.port(&PORTS, offset) }

// `s` with every default port written after a host (":8765" .. ":8769", not a longer number, not "U+8766") moved to
// the current block. On the default block, `s` itself.
url :: proc(s: string) -> string { return tk.url(&PORTS, s) }
