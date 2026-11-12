package vault

// The helper as a child process with two anonymous pipes: its standard input carries the requests, its standard output
// the answers (no socket, no named pipe: no other process can connect). Its standard error goes nowhere.
//
// Two threads per helper, so the loop thread never waits on it:
//   - the reader starts the process, then reads frames, decodes each into an Answer and posts it; at the end of the
//     output it waits for the process and posts Exited;
//   - the writer writes the queued frames in order, zeroes each, and closes the helper's input when the transport closes.

import "core:mem"
import "core:os"
import "core:strings"
import "core:sync"
import "wb:base"
import "wb:host"

@(private)
Proc_Transport :: struct {
	using tr:  Transport,   // (first: a ^Transport is a ^Proc_Transport)
	path:      string,          // owned
	mu:        sync.Mutex,
	cond:      sync.Cond,
	queue:     [dynamic][]u8,   // frames to write, owned
	closing:   bool,            // close asked: write what is queued, then close the input
	started:   bool,            // the start of the process is decided (`failed`: it did not start)
	failed:    bool,
	reaping:   bool,            // the reader waits for the process from now on: nobody kills it any more (its pid may be reused)
	input:     ^os.File,        // the write end of the helper's standard input (the writer's)
	process:   os.Process,
	reader, writer: ^host.Thread,
}

// Spawn_Proc of the real helper.
process_spawn :: proc(v: ^Vault, path: string) -> ^Transport {
	p := new(Proc_Transport, base.process_allocator())
	p.send, p.close, p.destroy = process_send, process_close, process_destroy
	p.vault, p.loop = v, v.loop
	p.path = strings.clone(path, base.process_allocator())
	p.queue = make([dynamic][]u8, base.process_allocator())
	p.reader = host.thread_start(process_reader, p, name = "wren-vault-read")
	p.writer = host.thread_start(process_writer, p, name = "wren-vault-write")
	return &p.tr
}

@(private = "file")
process_send :: proc(t: ^Transport, frame: []u8) {
	p := (^Proc_Transport)(t)
	sync.mutex_lock(&p.mu)
	if p.closing || p.failed {
		sync.mutex_unlock(&p.mu)
		frame_free(frame)
		return
	}
	append(&p.queue, frame)
	sync.cond_broadcast(&p.cond)
	sync.mutex_unlock(&p.mu)
}

@(private = "file")
process_close :: proc(t: ^Transport) {
	p := (^Proc_Transport)(t)
	sync.mutex_lock(&p.mu)
	p.closing = true
	sync.cond_broadcast(&p.cond)
	sync.mutex_unlock(&p.mu)
}

// Any thread. After Exited (on the blocking pool), or when the Vault ends while the helper still works on a request: it
// is killed then (it holds keys; it must not outlive the browser). Both threads are joined: nothing is posted after this.
@(private = "file")
process_destroy :: proc(t: ^Transport) {
	p := (^Proc_Transport)(t)
	sync.mutex_lock(&p.mu)
	p.closing = true
	sync.cond_broadcast(&p.cond)
	if p.started && !p.failed && !p.reaping { _ = os.process_kill(p.process) }   // (under the lock: not reaped yet)
	sync.mutex_unlock(&p.mu)
	if p.writer != nil { host.thread_join(p.writer) }
	if p.reader != nil { host.thread_join(p.reader) }
	for f in p.queue { frame_free(f) }
	delete(p.queue)
	delete(p.path, base.process_allocator())
	free(p, base.process_allocator())
}

@(private = "file")
process_reader :: proc(data: rawptr) {
	p := (^Proc_Transport)(data)
	context.allocator = base.process_allocator()
	in_r, in_w, err1 := os.pipe()
	out_r, out_w, err2 := os.pipe()
	process: os.Process
	start_err: os.Error = err1 != nil ? err1 : err2
	if start_err == nil {
		process, start_err = os.process_start({command = {p.path}, stdin = in_r, stdout = out_w, stderr = nil})
	}
	// (the child has its ends now; ours of them go, so that its exit closes our read end)
	if in_r != nil { _ = os.close(in_r) }
	if out_w != nil { _ = os.close(out_w) }
	sync.mutex_lock(&p.mu)
	p.started = true
	p.failed = start_err != nil
	p.process = process
	if p.failed { p.closing = true } else { p.input = in_w }
	sync.cond_broadcast(&p.cond)
	sync.mutex_unlock(&p.mu)
	if start_err != nil {
		if in_w != nil { _ = os.close(in_w) }
		if out_r != nil { _ = os.close(out_r) }
		transport_post(&p.tr, nil, exited = true)
		return
	}
	broken := false
	for {
		head: [FRAME_HEAD]u8
		if n, e := os.read_full(out_r, head[:]); e != nil || n != FRAME_HEAD { break }
		size, size_ok := frame_length(head)
		if !size_ok { broken = true; break }
		body := make([]u8, size)
		n, e := os.read_full(out_r, body)
		if e != nil || n != size {
			mem.zero_explicit(raw_data(body), len(body))
			delete(body)
			break
		}
		answer, ok := answer_decode(body)
		mem.zero_explicit(raw_data(body), len(body))
		delete(body)
		if !ok { broken = true; break }
		transport_post(&p.tr, answer)
	}
	_ = os.close(out_r)
	sync.mutex_lock(&p.mu)
	if broken { _ = os.process_kill(process) }   // (a helper that breaks the protocol is not trusted to exit)
	p.reaping = true
	p.closing = true   // (the writer stops too)
	sync.cond_broadcast(&p.cond)
	sync.mutex_unlock(&p.mu)
	_, _ = os.process_wait(process)
	transport_post(&p.tr, nil, exited = true, broken = broken)
}

@(private = "file")
process_writer :: proc(data: rawptr) {
	p := (^Proc_Transport)(data)
	context.allocator = base.process_allocator()
	writer_thread_signals()
	sync.mutex_lock(&p.mu)
	for !p.started { sync.cond_wait(&p.cond, &p.mu) }
	input := p.input
	for {
		for len(p.queue) == 0 && !p.closing { sync.cond_wait(&p.cond, &p.mu) }
		if len(p.queue) == 0 { break }   // closing, all written
		frame := p.queue[0]
		ordered_remove(&p.queue, 0)
		sync.mutex_unlock(&p.mu)
		written := 0
		for input != nil && written < len(frame) {
			n, e := os.write(input, frame[written:])
			if e != nil || n <= 0 { break }
			written += n
		}
		frame_free(frame)
		sync.mutex_lock(&p.mu)
	}
	sync.mutex_unlock(&p.mu)
	// the helper reads the end of its input and exits: lock is the exit of the process
	if input != nil { _ = os.close(input) }
}
