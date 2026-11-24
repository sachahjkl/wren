package images

// The decoding threads, shared by the whole process. Work is submitted as Jobs through a Port; a port belongs to one
// event loop (the UI thread, or a worker's thread) and results come back on that loop, in completion order, to the
// port's `on_done`. The highest priority job runs first (ties: oldest first), so images in the viewport decode before
// those far below it; priorities can change while a job waits.
//
// Lifetimes, without anything ever touching freed memory or a dead loop:
//   * the posted wake-up of a port carries the port's generational id, not a pointer: if the port closed meanwhile (its
//     page went away, its loop may be gone too) the drain finds nothing and does nothing;
//   * closing a port disposes of its queued and finished jobs at once and marks running ones, which their thread frees
//     when it is done with them; `on_done` is never called after `port_close`;
//   * a job's encoded bytes are a shared, reference-counted Blob, so the cache can let go of them while a decode runs;
//   * a job has one owner at each moment, and whoever submitted it holds a Job_Id, never a pointer to be used later:
//       before submit               the caller ("job_make")
//       Queued, Running, Finished   the decoder: the queue, a thread, the port's list of finished jobs. The id is in Decoder.live.
//       Delivered                   the receiver ("on_done" frees it with job_free); the id left live just before the call
//       Cancelled                   the thread that runs it, which frees it when it is done (the id left live at the cancel)
//     job_cancel and job_set_priority take the id and look it up under the decoder's lock: an id that is not live (delivered, cancelled,
//     its port closed) is not the caller's job any more, and nothing is touched. Every move between those states is made under the lock.

import "core:strings"
import "base:runtime"
import "core:sync"
import "core:time"
import "wb:base"
import "wb:host"

// How long asking for an optional codec waits for the first thread to look at them (<source type> selection).
CODECS_PROBE_WAIT :: 2 * time.Second

Port_Id :: distinct u64
Job_Id :: distinct u64   // 0: none (a job refused by submit, or one not submitted)

// Encoded bytes shared between their owner and the jobs reading them. An SVG document is parsed once, by the first job
// that needs it, and kept here for every later raster of it (native.odin).
Blob :: struct {
	bytes:     []byte,
	refs:      i32,   // atomic
	allocator: runtime.Allocator,
	svg_doc:   rawptr,        // atomic: the parsed document (library handle), nil until parsed
	svg_info:  Info,
	svg_err:   u8,            // atomic: Error of a parse that failed
	svg_mu:    sync.Mutex,
}

// Takes ownership of `bytes` (allocated with context.allocator).
blob_make :: proc(bytes: []byte) -> ^Blob {
	b := new(Blob)
	b.bytes, b.refs, b.allocator = bytes, 1, context.allocator
	return b
}

blob_retain :: proc(b: ^Blob) -> ^Blob {
	if b != nil { sync.atomic_add(&b.refs, 1) }
	return b
}

blob_release :: proc(b: ^Blob) {
	if b == nil { return }
	if sync.atomic_sub(&b.refs, 1) == 1 {
		context.allocator = b.allocator
		svg_doc_free(b)
		delete(b.bytes)
		free(b)
	}
}

Job_Kind :: enum u8 { Probe, Decode }

@(private)
Job_State :: enum u8 { Queued, Running, Finished, Delivered, Cancelled }

Job :: struct {
	kind:     Job_Kind,
	data:     ^Blob,            // a reference of the job's own
	opts:     Decode_Options,   // `mime` is copied
	priority: i32,
	user:     rawptr,           // the submitter's; untouched here
	tag:      u64,
	// results, for on_done
	info:     Info,
	image:    ^Image,           // Decode: the receiver takes it (image_destroy) or leaves it to job_free
	err:      Error,
	ms:       f64,              // time spent decoding
	// internal
	id:       Job_Id,           // set by submit (the caller's handle for cancelling and for telling its jobs apart in on_done)
	port:     Port_Id,
	state:    Job_State,
	seq:      u64,
	heap_idx: i32,              // index in Decoder.queue binary max-heap (-1 when not queued)
}

// Runs on the port's loop thread. The receiver owns `j` and calls job_free.
Done_Proc :: #type proc(user: rawptr, j: ^Job)

@(private)
Port :: struct {
	loop:    ^host.Loop,
	on_done: Done_Proc,
	user:    rawptr,
	done:    [dynamic]^Job,
	posted:  bool,
}

// Stack-owned state registered in Decoder.drains under d.mu while port_drain delivers a batch without holding d.mu.
// Holds only value job ids and atomic flags so job_cancel and port_close never dereference ^Job or a reallocated ^Port.
@(private)
Drain_State :: struct {
	port:      Port_Id,
	ids:       [dynamic]Job_Id,
	cancelled: [dynamic]bool,   // atomic per-slot cancel flags parallel to batch
	closed:    bool,            // atomic: set true by port_close under d.mu
}

@(private)
Decoder :: struct {
	mu:       sync.Mutex,
	cond:     sync.Cond,
	queue:    [dynamic]^Job,
	running:  [dynamic]^Job,
	threads:  [dynamic]^host.Thread,   // live ones and ended ones not joined yet (reap_threads)
	ports:    base.Pool(Port),
	drains:   [dynamic]^Drain_State,   // active port_drain batches (protected by mu)
	max_threads: int,
	stack_bytes: int,
	idle_ms:  int,    // a thread idle this long ends (0: never); submit starts another when none is idle
	threads_live: int,   // threads running decoder_thread
	idle:     int,    // ... of them waiting for a job
	stopping: bool,
	held:     bool,   // decoder_hold: the threads take no job (tests queue several jobs before any is taken)
	seq:      u64,
	live:     map[Job_Id]^Job,   // the jobs a caller may still cancel: submitted and neither delivered, cancelled nor dropped with their port
	allocator: runtime.Allocator,
	stats:    Decoder_Stats,
}

Decoder_Stats :: struct {
	jobs:        u64,
	decoded:     u64,
	failed:      u64,
	busy_ms:     f64,
	longest_ms:  f64,
}

// Tests: while set, every decoding thread stops after it took a job (entered is posted) until elease is.
@(private)
Gate :: struct { entered, release: sync.Sema }
@(private)
decode_gate: ^Gate
@(private)
probe_gate: ^Gate   // ... and the first thread before it probes the optional codecs

@(private)
dec: ^Decoder

@(private)
dec_mu: sync.Mutex   // start / stop

// Optional codecs found on this system (the built-in ones are always there). Probed once, by the first decoding thread;
// codecs_ready is posted then, and again by each one that waited for it.
@(private)
codecs: struct { heif, claimed, probed: bool }
@(private)
codecs_ready: sync.Sema

// Can this browser decode `f` here? Everything but HEIF always can (WIC's built-in codecs, and the built-in decoders
// of WebP, AVIF and SVG); HEIF needs the Store's "HEIF Image Extensions" (and HEVC), known once the decoder runs.
codec_supported :: proc(f: Format) -> bool {
	switch f {
	case .Png, .Jpeg, .Gif, .Bmp, .Ico, .Tiff, .Webp, .Avif, .Svg: return true
	case .Heif: codecs_wait(); return codecs.heif
	case .Unknown: return false
	}
	return false
}

// Until the first decoding thread probed the optional codecs, when the pool started one (its start does not wait: the
// probe's COM and imaging factory took 12 ms of the window thread at a page's first image).
@(private)
codecs_wait :: proc() {
	if d := dec; sync.atomic_load(&codecs.probed) || d == nil || d.threads_live == 0 { return }
	// (a post can be an earlier pool's: the probe is looked at again)
	posted := false
	for !sync.atomic_load(&codecs.probed) && sync.sema_wait_with_timeout(&codecs_ready, CODECS_PROBE_WAIT) { posted = true }
	if posted { sync.sema_post(&codecs_ready) }
}

// The format a MIME type names (for <source type>), Unknown when it is not an image type this browser knows.
format_of_mime :: proc(mime: string) -> Format {
	switch mime {
	case "image/png", "image/apng": return .Png
	case "image/jpeg", "image/jpg", "image/pjpeg": return .Jpeg
	case "image/gif": return .Gif
	case "image/bmp", "image/x-bmp", "image/x-ms-bmp": return .Bmp
	case "image/x-icon", "image/vnd.microsoft.icon": return .Ico
	case "image/tiff", "image/tiff-fx": return .Tiff
	case "image/webp": return .Webp
	case "image/avif": return .Avif
	case "image/heif", "image/heic", "image/heif-sequence", "image/heic-sequence": return .Heif
	case "image/svg+xml": return .Svg
	}
	return .Unknown
}

// Starts the decoding threads (`threads` <= 0: one). Idempotent; the threads use the process heap. `stack_bytes`
// reserved per thread (committed as used): SVG rendering recurses per nesting level (images.svg.max_depth). With
// `idle_ms` > 0 a thread with nothing to do for that long ends (the stack a large decode committed goes back to the
// system: Windows never decommits a thread's stack) and `submit` starts one again when a job finds none idle.
decoder_start :: proc(threads: int, stack_bytes := DECODER_STACK_DEFAULT, idle_ms := 0) {
	sync.mutex_lock(&dec_mu)
	defer sync.mutex_unlock(&dec_mu)
	if dec != nil { return }
	context.allocator = base.process_allocator()
	d := new(Decoder)
	d.allocator = context.allocator
	d.queue = make([dynamic]^Job)
	d.running = make([dynamic]^Job)
	d.threads = make([dynamic]^host.Thread)
	d.drains = make([dynamic]^Drain_State)
	d.live = make(map[Job_Id]^Job)
	d.max_threads, d.stack_bytes, d.idle_ms = max(threads, 1), stack_bytes, max(idle_ms, 0)
	dec = d
	sync.mutex_lock(&d.mu)
	for _ in 0 ..< d.max_threads { spawn_thread(d) }
	sync.mutex_unlock(&d.mu)
}

decoder_running :: proc() -> bool { return dec != nil }

// Decoding threads running now (fewer than started once idle ones ended).
decoder_threads :: proc() -> int {
	d := dec
	if d == nil { return 0 }
	sync.mutex_lock(&d.mu)
	defer sync.mutex_unlock(&d.mu)
	return d.threads_live
}

// Under d.mu: joins the threads that ended (they returned: joining does not wait), then starts one more.
@(private)
spawn_thread :: proc(d: ^Decoder) {
	reap_threads(d)
	context.allocator = d.allocator
	if t := host.thread_start(decoder_thread, d, d.stack_bytes, .Below_Normal, "wren-image-decode"); t != nil {
		append(&d.threads, t)
		d.threads_live += 1
	}
}

@(private)
reap_threads :: proc(d: ^Decoder) {
	context.allocator = d.allocator
	for i := 0; i < len(d.threads); {
		if host.thread_finished(d.threads[i]) { host.thread_join(d.threads[i]); unordered_remove(&d.threads, i) } else { i += 1 }
	}
}

decoder_stats :: proc() -> Decoder_Stats {
	if dec == nil { return {} }
	sync.mutex_lock(&dec.mu)
	defer sync.mutex_unlock(&dec.mu)
	return dec.stats
}

// While held, the decoding threads take no job (they finish the one they run): what is queued meanwhile is then
// taken in priority order, whatever the threads' scheduling. (Tests: a frame drawn while a picture is being made.)
decoder_hold :: proc(hold: bool) {
	d := dec
	if d == nil { return }
	sync.mutex_lock(&d.mu)
	d.held = hold
	sync.cond_broadcast(&d.cond)
	sync.mutex_unlock(&d.mu)
}

// Waits until no thread runs a cancelled job: such a job holds its Blob until its thread is done with it, after the page
// that made it is gone. False at the bound. (Tests: what a test allocated is freed before its memory is counted.)
decoder_settle :: proc(bound: time.Duration) -> bool {
	d := dec
	if d == nil { return true }
	start := time.tick_now()
	for {
		sync.mutex_lock(&d.mu)
		busy := false
		for j in d.running { if j.state == .Cancelled { busy = true; break } }
		sync.mutex_unlock(&d.mu)
		if !busy { return true }
		if time.tick_since(start) > bound { return false }
		time.sleep(time.Millisecond)
	}
}

// Joins the threads; queued and finished jobs are dropped. Every port is closed. Call at shutdown.
decoder_stop :: proc() {
	sync.mutex_lock(&dec_mu)
	defer sync.mutex_unlock(&dec_mu)
	d := dec
	if d == nil { return }
	sync.mutex_lock(&d.mu)
	d.stopping = true
	sync.cond_broadcast(&d.cond)
	sync.mutex_unlock(&d.mu)
	context.allocator = d.allocator
	for t in d.threads { host.thread_join(t) }
	dec = nil
	for j in d.queue { job_free(j) }
	it: u32
	for _, p in base.pool_next(&d.ports, &it) {
		for j in p.done { job_free(j) }
		delete(p.done)
	}
	base.pool_destroy(&d.ports)
	delete(d.queue)
	delete(d.running)
	delete(d.threads)
	delete(d.drains)
	delete(d.live)
	free(d)
}

// A port delivering on `loop`. 0 when the decoder is not running.
port_open :: proc(loop: ^host.Loop, on_done: Done_Proc, user: rawptr) -> Port_Id {
	d := dec
	if d == nil { return 0 }
	sync.mutex_lock(&d.mu)
	defer sync.mutex_unlock(&d.mu)
	context.allocator = d.allocator
	// the loop is the caller's, kept until port_close (rawptr: on purpose)
	h, p := base.pool_insert(&d.ports, Port{loop = (^host.Loop)(rawptr(loop)), on_done = on_done, user = user})
	p.done = make([dynamic]^Job)
	return Port_Id(h)
}

// Binary max-heap helpers for Decoder.queue (highest priority first, ties broken by oldest seq). Caller holds d.mu.
@(private)
job_higher :: #force_inline proc(a, b: ^Job) -> bool {
	return a.priority > b.priority || (a.priority == b.priority && a.seq < b.seq)
}

@(private)
queue_swap :: #force_inline proc(d: ^Decoder, i, j: int) {
	a, b := d.queue[i], d.queue[j]
	d.queue[i], d.queue[j] = b, a
	b.heap_idx, a.heap_idx = i32(i), i32(j)
}

@(private)
queue_sift_up :: proc(d: ^Decoder, idx: int) {
	i := idx
	for i > 0 {
		p := (i - 1) / 2
		if !job_higher(d.queue[i], d.queue[p]) { break }
		queue_swap(d, i, p)
		i = p
	}
}

@(private)
queue_sift_down :: proc(d: ^Decoder, idx: int) {
	n := len(d.queue)
	i := idx
	for {
		best := i
		l := 2 * i + 1
		r := l + 1
		if l < n && job_higher(d.queue[l], d.queue[best]) { best = l }
		if r < n && job_higher(d.queue[r], d.queue[best]) { best = r }
		if best == i { break }
		queue_swap(d, i, best)
		i = best
	}
}

@(private)
queue_push :: proc(d: ^Decoder, j: ^Job) {
	j.heap_idx = i32(len(d.queue))
	append(&d.queue, j)
	queue_sift_up(d, len(d.queue) - 1)
}

@(private)
queue_remove_at :: proc(d: ^Decoder, idx: int) -> ^Job {
	j := d.queue[idx]
	j.heap_idx = -1
	last := len(d.queue) - 1
	if idx != last {
		d.queue[idx] = d.queue[last]
		d.queue[idx].heap_idx = i32(idx)
	}
	pop(&d.queue)
	if idx < len(d.queue) {
		queue_sift_up(d, idx)
		queue_sift_down(d, idx)
	}
	return j
}

@(private)
queue_pop :: #force_inline proc(d: ^Decoder) -> ^Job {
	return queue_remove_at(d, 0)
}

@(private)
queue_heapify :: proc(d: ^Decoder) {
	for i := len(d.queue) / 2 - 1; i >= 0; i -= 1 { queue_sift_down(d, i) }
}

// Loop thread of the port. Disposes of every job of the port not yet delivered.
port_close :: proc(id: Port_Id) {
	d := dec
	if d == nil || id == 0 { return }
	sync.mutex_lock(&d.mu)
	defer sync.mutex_unlock(&d.mu)
	context.allocator = d.allocator
	w := 0
	for j in d.queue {
		if j.port == id {
			j.heap_idx = -1
			delete_key(&d.live, j.id)
			job_free(j)
		} else {
			j.heap_idx = i32(w)
			d.queue[w] = j
			w += 1
		}
	}
	if w != len(d.queue) {
		resize(&d.queue, w)
		queue_heapify(d)
	}
	for j in d.running { if j.port == id { j.state = .Cancelled; delete_key(&d.live, j.id) } }
	for ds in d.drains {
		if ds.port == id { sync.atomic_store(&ds.closed, true) }
	}
	if p, ok := base.pool_remove(&d.ports, base.Handle(id)); ok {
		for j in p.done { delete_key(&d.live, j.id); job_free(j) }
		delete(p.done)
	}
}

// A job to fill and submit. `data` is retained by the job.
job_make :: proc(kind: Job_Kind, data: ^Blob, opts: Decode_Options, priority: i32 = 0, user: rawptr = nil, tag: u64 = 0) -> ^Job {
	context.allocator = base.process_allocator()
	j := new(Job)
	j.kind, j.data, j.opts, j.priority, j.user, j.tag, j.heap_idx = kind, blob_retain(data), opts, priority, user, tag, -1
	j.opts.mime = strings.clone(opts.mime)
	return j
}

// Frees a job and whatever result it still holds.
job_free :: proc(j: ^Job) {
	if j == nil { return }
	context.allocator = base.process_allocator()
	blob_release(j.data)
	image_destroy(j.image)
	delete(j.opts.mime)
	free(j)
}

// Queues `j` on the port and returns its id; from now on the decoder owns the job until it is delivered, cancelled or its port closes
// (the top of this file). 0, and `j` freed, when the port or the decoder is gone.
submit :: proc(id: Port_Id, j: ^Job) -> Job_Id {
	d := dec
	if d == nil { job_free(j); return 0 }
	sync.mutex_lock(&d.mu)
	defer sync.mutex_unlock(&d.mu)
	if d.stopping || base.pool_get(&d.ports, base.Handle(id)) == nil {
		job_free(j)
		return 0
	}
	d.seq += 1
	j.seq, j.port, j.state = d.seq, id, .Queued
	j.id = Job_Id(d.seq)
	d.live[j.id] = j
	context.allocator = d.allocator
	queue_push(d, j)
	// every thread is busy (or ended while idle): one more, up to the configured number
	if d.idle < len(d.queue) && d.threads_live < d.max_threads { spawn_thread(d) }
	sync.cond_signal(&d.cond)
	return j.id
}

// Withdraws a job that was submitted and not delivered yet. Loop thread of its port. A job that is not live any more (delivered, already
// cancelled, its port closed) is not the caller's: nothing happens.
job_cancel :: proc(id: Job_Id) {
	d := dec
	if d == nil || id == 0 { return }
	sync.mutex_lock(&d.mu)
	defer sync.mutex_unlock(&d.mu)
	j, ok := d.live[id]
	if !ok {
		// a job already swapped into a port_drain batch: match by value Job_Id without touching ^Job
		for ds in d.drains {
			for jid, k in ds.ids {
				if jid == id {
					sync.atomic_store(&ds.cancelled[k], true)
					return
				}
			}
		}
		return
	}
	delete_key(&d.live, id)
	context.allocator = d.allocator
	switch j.state {
	case .Queued:
		if j.heap_idx >= 0 { queue_remove_at(d, int(j.heap_idx)) }
		job_free(j)
	case .Running:
		j.state = .Cancelled   // the thread that runs it frees it
	case .Finished:
		if p := base.pool_get(&d.ports, base.Handle(j.port)); p != nil {
			for x, i in p.done { if x == j { ordered_remove(&p.done, i); break } }
		}
		job_free(j)
	case .Delivered, .Cancelled:   // (not live: unreachable)
	}
}

job_set_priority :: proc(id: Job_Id, priority: i32) {
	d := dec
	if d == nil || id == 0 { return }
	sync.mutex_lock(&d.mu)
	defer sync.mutex_unlock(&d.mu)
	if j, ok := d.live[id]; ok {
		if j.priority == priority { return }
		j.priority = priority
		if j.state == .Queued && j.heap_idx >= 0 {
			queue_sift_up(d, int(j.heap_idx))
			queue_sift_down(d, int(j.heap_idx))
		}
	}
}
@(private)
decoder_thread :: proc(data: rawptr) {
	d := (^Decoder)(data)
	codec: Codec_Context
	have_codec := codec_init(&codec)
	defer if have_codec { codec_destroy(&codec) }
	// the first thread probes, holding nothing: under d.mu a submit waited for it, the window thread 18 to 21 ms at a page's
	// first image
	if !sync.atomic_exchange(&codecs.claimed, true) {
		if g := sync.atomic_load(&probe_gate); g != nil { sync.sema_post(&g.entered); sync.sema_wait(&g.release) }   // (tests: a probe held)
		if have_codec { probe_codecs() }
		sync.atomic_store(&codecs.probed, true)
		sync.sema_post(&codecs_ready)
	}
	for {
		sync.mutex_lock(&d.mu)
		ended := false
		for (len(d.queue) == 0 || d.held) && !d.stopping {
			d.idle += 1
			woken := true
			if d.idle_ms > 0 { woken = sync.cond_wait_with_timeout(&d.cond, &d.mu, time.Duration(d.idle_ms) * time.Millisecond) } else { sync.cond_wait(&d.cond, &d.mu) }
			d.idle -= 1
			// idle for idle_ms: this thread ends (another starts at the next submit)
			if !woken && len(d.queue) == 0 && !d.stopping { ended = true; break }
		}
		if d.stopping || ended { d.threads_live -= 1; sync.mutex_unlock(&d.mu); return }
		j := queue_pop(d)
		j.state = .Running
		append(&d.running, j)
		sync.mutex_unlock(&d.mu)

		if g := sync.atomic_load(&decode_gate); g != nil { sync.sema_post(&g.entered); sync.sema_wait(&g.release) }   // (tests: a job held while it runs)
		start := time.tick_now()
		{
			context.allocator = base.process_allocator()
			// without WIC (no COM on this thread) the built-in formats still decode
			j.image, j.info, j.err = run_blob(have_codec ? &codec : nil, j.data, j.opts, j.kind == .Probe)
		}
		j.ms = time.duration_milliseconds(time.tick_since(start))
		free_all(context.temp_allocator)

		sync.mutex_lock(&d.mu)
		for x, i in d.running { if x == j { unordered_remove(&d.running, i); break } }
		d.stats.jobs += 1
		if j.err == .None { d.stats.decoded += 1 } else { d.stats.failed += 1 }
		d.stats.busy_ms += j.ms
		d.stats.longest_ms = max(d.stats.longest_ms, j.ms)
		p := base.pool_get(&d.ports, base.Handle(j.port))
		if j.state == .Cancelled || p == nil || d.stopping {
			job_free(j)
		} else {
			j.state = .Finished
			append(&p.done, j)
			if !p.posted {
				p.posted = true
				host.post(p.loop, port_drain, rawptr(uintptr(j.port)), .Arrival)
			}
		}
		sync.mutex_unlock(&d.mu)
	}
}

@(private = "file")
drain_unregister :: proc(d: ^Decoder, ds: ^Drain_State) {
	for x, i in d.drains {
		if x == ds {
			unordered_remove(&d.drains, i)
			return
		}
	}
}

// The port's loop: swap-drains p.done under a single lock and delivers each finished job (callbacks may open/close
// ports or cancel remaining jobs in the batch without racing on ^Port or ^Job).
@(private)
port_drain :: proc(data: rawptr) {
	id := Port_Id(uintptr(data))
	d := dec
	if d == nil { return }
	batch := make([dynamic]^Job, 0, 0, d.allocator)
	ds := Drain_State{
		port      = id,
		ids       = make([dynamic]Job_Id, 0, 0, d.allocator),
		cancelled = make([dynamic]bool, 0, 0, d.allocator),
	}
	registered := false
	finished := false
	defer {
		if !finished {
			if d2 := dec; d2 != nil {
				sync.mutex_lock(&d2.mu)
				if registered {
					drain_unregister(d2, (^Drain_State)(rawptr(&ds)))
					registered = false
				}
				if !sync.atomic_load(&ds.closed) {
					if p := base.pool_get(&d2.ports, base.Handle(id)); p != nil {
						if len(p.done) == 0 {
							clear(&batch)
							p.done, batch = batch, p.done
						}
						p.posted = false
					}
				}
				sync.mutex_unlock(&d2.mu)
			}
		}
		delete(batch)
		delete(ds.ids)
		delete(ds.cancelled)
	}
	for {
		d = dec
		if d == nil { return }
		sync.mutex_lock(&d.mu)
		if registered {
			drain_unregister(d, (^Drain_State)(rawptr(&ds)))
			registered = false
		}
		p := base.pool_get(&d.ports, base.Handle(id))
		if p == nil || sync.atomic_load(&ds.closed) {
			finished = true
			sync.mutex_unlock(&d.mu)
			return
		}
		if len(p.done) == 0 {
			clear(&batch)
			p.done, batch = batch, p.done
			p.posted = false
			finished = true
			sync.mutex_unlock(&d.mu)
			return
		}
		clear(&batch)
		p.done, batch = batch, p.done
		clear(&ds.ids)
		clear(&ds.cancelled)
		reserve(&ds.ids, len(batch))
		reserve(&ds.cancelled, len(batch))
		for j in batch {
			j.state = .Delivered
			delete_key(&d.live, j.id)   // the receiver's now
			append(&ds.ids, j.id)
			append(&ds.cancelled, false)
		}
		sync.atomic_store(&ds.closed, false)
		// Unregistered under d.mu before loop re-entry or return on every exit path.
		context.allocator = d.allocator
		append(&d.drains, (^Drain_State)(rawptr(&ds)))
		registered = true
		fn, user := p.on_done, p.user
		sync.mutex_unlock(&d.mu)

		for j, i in batch {
			if sync.atomic_load(&ds.closed) {
				for rem in batch[i:] { job_free(rem) }
				if d2 := dec; d2 != nil {
					sync.mutex_lock(&d2.mu)
					drain_unregister(d2, (^Drain_State)(rawptr(&ds)))
					registered = false
					sync.mutex_unlock(&d2.mu)
				}
				finished = true
				return
			}
			if sync.atomic_load(&ds.cancelled[i]) {
				job_free(j)
				continue
			}
			fn(user, j)
		}
	}
}
