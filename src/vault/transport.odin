package vault

// A connection to one helper. The Vault makes one when it needs the helper (a login, an unlock) and closes it to lock:
// lock is the exit of the helper (docs/bitwarden.md 3.2). The real one is a process with two pipes (process.odin); the
// tests use an in-process one that answers from a table (fake_test.odin).
//
// Every call is on the loop thread and returns at once: what blocks (starting the process, the pipes) runs on the
// transport's own threads. What comes back (an answer, the end of the helper) is posted to the loop, where
// transport_deliver hands it to the Vault.

import "wb:base"
import "wb:host"

Transport :: struct {
	// Queues one frame (from request_end); the transport owns it from here on and zeroes it once written.
	send:    proc(t: ^Transport, frame: []u8),
	// Ends the helper: its input closes, it exits. An Exited event follows (the transport is freed after it).
	close:   proc(t: ^Transport),
	// After Exited, or when the Vault ends: stops what still runs and frees the transport.
	destroy: proc(t: ^Transport),
	vault:   ^Vault,
	loop:    ^host.Loop,
	exited:  bool,   // its Exited event was delivered
}

// Makes a transport for the helper at `path`; returns at once. A helper that cannot start delivers Exited.
Spawn_Proc :: proc(v: ^Vault, path: string) -> ^Transport

// What a transport posts to the loop.
@(private)
Posted :: struct {
	t:      ^Transport,
	answer: ^Answer,   // nil with `exited`
	exited: bool,
	broken: bool,      // the helper sent what is not a frame of the protocol
}

// Any thread. Hands an answer (owned by the loop from here on) or the end of the helper to the loop.
transport_post :: proc(t: ^Transport, answer: ^Answer, exited := false, broken := false) {
	p := new(Posted, base.process_allocator())
	p^ = {t = t, answer = answer, exited = exited, broken = broken}
	host.post(t.loop, transport_posted, p)
}

@(private)
transport_posted :: proc(data: rawptr) {
	p := (^Posted)(data)
	defer free(p, base.process_allocator())
	vault_deliver(p.t.vault, p.t, p.answer, p.exited, p.broken)
}

// What the loop never ran (the Vault ends): the answers are zeroed.
@(private)
transport_discard :: proc(data: rawptr) {
	p := (^Posted)(data)
	answer_free(p.answer)
	free(p, base.process_allocator())
}
