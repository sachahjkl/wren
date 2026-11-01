package webaudio

// The threads. A running AudioContext has one: it keeps the output's queue at the latency asked for, a quantum at a time,
// so that the device's clock paces the rendering (and so currentTime). Suspending ends the thread and closes the stream.
// An OfflineAudioContext has one until its rendering is over, as fast as it goes.

import "core:sync"
import "core:time"
import "wb:host"
import "wb:media"

// How long the thread sleeps when the queue is full enough.
RENDER_WAIT :: 2 * time.Millisecond
// The stack of the render threads (the graph is ordered with a walk of its own, not by recursion).
RENDER_STACK_BYTES :: 256 * 1024

Render_Thread :: struct {
	th:       ^host.Thread,
	quit:     bool,            // atomic
	muted:    bool,            // atomic: the tab is muted
	latency:  int,             // frames kept queued
	written:  i64,             // frames given to the output
	queued:   i64,             // atomic: frames in the output's queue at the last look
	audible:  bool,            // atomic: the last block the output got was not silent
	open:     proc(rate: int) -> ^media.Audio_Output,   // nil: the platform's output (a test gives its own)
	// offline
	total:    int,             // frames to render
	result:   ^Pcm,
	wake:     sync.Cond,
	suspends: [dynamic]i64,    // frames where the rendering waits for the page (sorted)
	waiting:  bool,
}

// (the lock not held) Makes the context run. A closed context stays closed.
graph_resume :: proc(g: ^Graph, latency_frames: int) {
	context.allocator = alloc()
	sync.lock(&g.mu)
	defer sync.unlock(&g.mu)
	if g.state != .Suspended || g.thread.th != nil { return }
	g.thread.latency = max(latency_frames, RENDER_QUANTUM)
	sync.atomic_store(&g.thread.quit, false)
	g.thread.th = host.thread_start(online_main, g, RENDER_STACK_BYTES, name = "wren-webaudio")
	if g.thread.th != nil {
		g.state = .Running
		post_event(g, .State_Changed, 0, i32(Graph_State.Running))
	}
}

// (the lock not held) Stops rendering and the thread. No event.
thread_stop :: proc(g: ^Graph) {
	context.allocator = alloc()
	sync.lock(&g.mu)
	th := g.thread.th
	g.thread.th = nil
	sync.atomic_store(&g.thread.quit, true)
	sync.cond_broadcast(&g.thread.wake)
	worklet_interrupt(g)
	sync.unlock(&g.mu)
	if th != nil { host.thread_join(th) }
	if g.thread.result != nil { pcm_release(g.thread.result); g.thread.result = nil }
	delete(g.thread.suspends)
	g.thread.suspends = nil
}

graph_suspend :: proc(g: ^Graph) {
	sync.lock(&g.mu)
	running := g.state == .Running
	sync.unlock(&g.mu)
	if !running { return }
	thread_stop(g)
	sync.guard(&g.mu)
	g.state = .Suspended
	post_event(g, .State_Changed, 0, i32(Graph_State.Suspended))
}

graph_close :: proc(g: ^Graph) {
	sync.lock(&g.mu)
	closed := g.state == .Closed
	sync.unlock(&g.mu)
	if closed { return }
	thread_stop(g)
	sync.guard(&g.mu)
	g.state = .Closed
	post_event(g, .State_Changed, 0, i32(Graph_State.Closed))
}

graph_set_muted :: proc(g: ^Graph, muted: bool) { sync.atomic_store(&g.thread.muted, muted) }

// Reads for the page.
graph_time :: proc(g: ^Graph) -> f64 {
	sync.guard(&g.mu)
	return f64(g.frame) / g.rate
}

graph_state :: proc(g: ^Graph) -> Graph_State {
	sync.guard(&g.mu)
	return g.state
}

// Frames in the output's queue: what outputLatency says.
graph_queued :: proc(g: ^Graph) -> i64 { return sync.atomic_load(&g.thread.queued) }

// The stereo block of the destination, interleaved in `out`.
@(private = "file")
interleave :: proc(g: ^Graph, stereo: ^Bus, out: []f32) {
	bus_clear(stereo, OUTPUT_CHANNELS)
	bus_sum(stereo, &g.output, .Speakers)
	l, r := bus_ch(stereo, 0), bus_ch(stereo, 1)
	for i in 0 ..< RENDER_QUANTUM {
		out[i * 2], out[i * 2 + 1] = l[i], r[i]
	}
}

@(private = "file")
online_main :: proc(data: rawptr) {
	context.allocator = alloc()
	g := (^Graph)(data)
	t := &g.thread
	open := t.open != nil ? t.open : media.backend_audio_output
	out := open(int(g.rate))
	if out == nil { return }
	defer out.destroy(out)
	stereo: Bus
	defer bus_destroy(&stereo)
	block: [RENDER_QUANTUM * OUTPUT_CHANNELS]f32
	started, was_muted := false, false
	out.set_gain(out, 1)
	for !sync.atomic_load(&t.quit) {
		// the device went away (unplugged, its format changed): another stream, the default device or silence
		if out.failed(out) {
			if started { out.stop(out) }
			out.destroy(out)
			out = open(int(g.rate))
			if out == nil { return }
			started = false
			out.set_gain(out, was_muted ? 0 : 1)
		}
		muted := sync.atomic_load(&t.muted)
		if muted != was_muted {
			out.set_gain(out, muted ? 0 : 1)
			was_muted = muted
		}
		queued := out.queued(out)
		sync.atomic_store(&t.queued, i64(queued))
		if queued >= t.latency || out.room(out) < RENDER_QUANTUM {
			if !started && queued > 0 { out.start(out); started = true }
			time.sleep(RENDER_WAIT)
			continue
		}
		sync.lock(&g.mu)
		render_quantum(g)
		interleave(g, &stereo, block[:])
		sync.atomic_store(&t.audible, !g.output.silent)
		sync.unlock(&g.mu)
		rest := block[:]
		for len(rest) > 0 && !sync.atomic_load(&t.quit) {
			n := out.write(out, rest)
			if n <= 0 { time.sleep(RENDER_WAIT); continue }
			rest = rest[n * OUTPUT_CHANNELS:]
			t.written += i64(n)
		}
	}
	sync.atomic_store(&t.audible, false)
	if started { out.stop(out) }
}

// The rendering of an OfflineAudioContext of `frames` frames, on a thread of its own. Ends with a State_Changed event to
// Closed; the page then takes the result with offline_take_result.
offline_start :: proc(g: ^Graph, frames: int) -> bool {
	context.allocator = alloc()
	sync.guard(&g.mu)
	if g.thread.th != nil { return false }
	g.thread.total = frames
	g.thread.result = pcm_new(g.channels, frames, g.rate)
	g.state = .Running
	post_event(g, .State_Changed, 0, i32(Graph_State.Running))
	g.thread.th = host.thread_start(offline_main, g, RENDER_STACK_BYTES, .Below_Normal, "wren-webaudio-offline")
	return g.thread.th != nil
}

// Renders `frames` frames into `result` (planar), under the lock a quantum at a time. false: stopped before the end.
offline_render :: proc(g: ^Graph, result: ^Pcm) -> bool {
	context.allocator = alloc()
	t := &g.thread
	frames := result.length
	mixed: Bus
	defer bus_destroy(&mixed)
	at := 0
	for at < frames {
		sync.lock(&g.mu)
		if sync.atomic_load(&t.quit) { sync.unlock(&g.mu); return false }
		// a suspend() that comes due
		for len(t.suspends) > 0 && t.suspends[0] <= g.frame {
			pop_front(&t.suspends)
			t.waiting = true
			g.state = .Suspended
			post_event(g, .Offline_Suspended, 0, i32(g.frame / RENDER_QUANTUM))
			for t.waiting && !sync.atomic_load(&t.quit) { sync.cond_wait(&t.wake, &g.mu) }
			if sync.atomic_load(&t.quit) { sync.unlock(&g.mu); return false }
			g.state = .Running
			post_event(g, .State_Changed, 0, i32(Graph_State.Running))
		}
		render_quantum(g)
		count := min(RENDER_QUANTUM, frames - at)
		bus_clear(&mixed, result.channels)
		bus_sum(&mixed, &g.output, .Speakers)
		for c in 0 ..< result.channels {
			copy(pcm_channel(result, c)[at:][:count], bus_ch(&mixed, c)[:count])
		}
		sync.unlock(&g.mu)
		at += count
	}
	return true
}

@(private = "file")
offline_main :: proc(data: rawptr) {
	context.allocator = alloc()
	g := (^Graph)(data)
	if !offline_render(g, g.thread.result) { return }
	sync.guard(&g.mu)
	g.state = .Closed
	post_event(g, .State_Changed, 0, i32(Graph_State.Closed))
}

// The page takes the finished rendering (one reference, nil when it is not there).
offline_take_result :: proc(g: ^Graph) -> ^Pcm {
	sync.guard(&g.mu)
	if g.state != .Closed { return nil }
	r := g.thread.result
	g.thread.result = nil
	return r
}

// OfflineAudioContext.suspend(when): the frame, rounded up to a quantum. false: there is one there already, or past.
offline_add_suspend :: proc(g: ^Graph, frame: i64) -> bool {
	context.allocator = alloc()
	sync.guard(&g.mu)
	t := &g.thread
	f := (frame + RENDER_QUANTUM - 1) / RENDER_QUANTUM * RENDER_QUANTUM
	if f <= g.frame && g.state == .Running { return false }
	at := len(t.suspends)
	for s, i in t.suspends {
		if s == f { return false }
		if s > f { at = i; break }
	}
	inject_at(&t.suspends, at, f)
	return true
}

offline_resume :: proc(g: ^Graph) {
	sync.guard(&g.mu)
	g.thread.waiting = false
	sync.cond_broadcast(&g.thread.wake)
}

// Frames of a buffer: what the allocator would have to give.
pcm_bytes :: proc(channels, length: int) -> int { return channels * length * size_of(f32) }


// Sound came out of the destination in the last moments (what the tab's speaker shows).
graph_audible :: proc(g: ^Graph) -> bool {
	return sync.atomic_load(&g.thread.audible)
}
