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
//   * a job's encoded bytes are a shared, reference-counted Blob, so the cache can let go of them while a decode runs.

import "base:runtime"
import "core:sync"
import win "core:sys/windows"
import "core:time"
import "wb:base"
import "wb:host"

Port_Id :: distinct u64

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
	port:     Port_Id,
	state:    Job_State,
	seq:      u64,
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

@(private)
Decoder :: struct {
	mu:       sync.Mutex,
	cond:     sync.Cond,
	queue:    [dynamic]^Job,
	running:  [dynamic]^Job,
	threads:  [dynamic]^host.Thread,   // live ones and ended ones not joined yet (reap_threads)
	ports:    base.Pool(Port),
	max_threads: int,
	stack_bytes: int,
	idle_ms:  int,    // a thread idle this long ends (0: never); submit starts another when none is idle
	live:     int,    // threads running decoder_thread
	idle:     int,    // ... of them waiting for a job
	stopping: bool,
	held:     bool,   // decoder_hold: the threads take no job (tests queue several jobs before any is taken)
	seq:      u64,
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

@(private)
dec: ^Decoder

@(private)
dec_mu: sync.Mutex   // start / stop

// Optional codecs found on this system (the built-in ones are always there). Probed once, by the first decoding thread.
@(private)
codecs: struct { heif, probed: bool }
@(private)
codecs_ready: sync.Sema

CLSID_WICHeifDecoder := GUID{0xe9a4a80a, 0x44fe, 0x4de4, {0x89, 0x71, 0x71, 0x50, 0xb1, 0x0a, 0x51, 0x99}}

// Can this browser decode `f` here? Everything but HEIF always can (WIC's built-in codecs, and the built-in decoders
// of WebP, AVIF and SVG); HEIF needs the Store's "HEIF Image Extensions" (and HEVC), known once the decoder runs.
codec_supported :: proc(f: Format) -> bool {
	switch f {
	case .Png, .Jpeg, .Gif, .Bmp, .Ico, .Tiff, .Webp, .Avif, .Svg: return true
	case .Heif: return codecs.heif
	case .Unknown: return false
	}
	return false
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

@(private)
probe_codecs :: proc() {
	unk: rawptr
	if succeeded(win.CoCreateInstance(&CLSID_WICHeifDecoder, nil, win.CLSCTX_INPROC_SERVER, win.IUnknown_UUID, &unk)) && unk != nil {
		codecs.heif = true
		com_release(unk)
	}
	codecs.probed = true
}

// Starts the decoding threads (`threads` <= 0: one). Idempotent; the threads use the process heap. `stack_bytes`
// reserved per thread (committed as used): SVG rendering recurses per nesting level (images.svg.max_depth). With
// `idle_ms` > 0 a thread with nothing to do for that long ends (the stack a large decode committed goes back to the
// system: Windows never decommits a thread's stack) and `submit` starts one again when a job finds none idle.
decoder_start :: proc(threads: int, stack_bytes := DECODER_STACK_DEFAULT, idle_ms := 0) {
	sync.mutex_lock(&dec_mu)
	defer sync.mutex_unlock(&dec_mu)
	if dec != nil { return }
	context.allocator = runtime.heap_allocator()
	d := new(Decoder)
	d.allocator = context.allocator
	d.queue = make([dynamic]^Job)
	d.running = make([dynamic]^Job)
	d.threads = make([dynamic]^host.Thread)
	d.max_threads, d.stack_bytes, d.idle_ms = max(threads, 1), stack_bytes, max(idle_ms, 0)
	dec = d
	sync.mutex_lock(&d.mu)
	for _ in 0 ..< d.max_threads { spawn_thread(d) }
	sync.mutex_unlock(&d.mu)
	// <source type> selection needs to know the optional codecs: the first thread looks (a few CoCreateInstance calls)
	if len(d.threads) > 0 && !codecs.probed { _ = sync.sema_wait_with_timeout(&codecs_ready, 2 * time.Second) }
}

decoder_running :: proc() -> bool { return dec != nil }

// Decoding threads running now (fewer than started once idle ones ended).
decoder_threads :: proc() -> int {
	d := dec
	if d == nil { return 0 }
	sync.mutex_lock(&d.mu)
	defer sync.mutex_unlock(&d.mu)
	return d.live
}

// Under d.mu: joins the threads that ended (they returned: joining does not wait), then starts one more.
@(private)
spawn_thread :: proc(d: ^Decoder) {
	reap_threads(d)
	context.allocator = d.allocator
	if t := host.thread_start(decoder_thread, d, d.stack_bytes, .Below_Normal); t != nil {
		append(&d.threads, t)
		d.live += 1
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
// taken in priority order, whatever the threads' scheduling.
@(private)
decoder_hold :: proc(hold: bool) {
	d := dec
	if d == nil { return }
	sync.mutex_lock(&d.mu)
	d.held = hold
	sync.cond_broadcast(&d.cond)
	sync.mutex_unlock(&d.mu)
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
	free(d)
}

// A port delivering on `loop`. 0 when the decoder is not running.
port_open :: proc(loop: ^host.Loop, on_done: Done_Proc, user: rawptr) -> Port_Id {
	d := dec
	if d == nil { return 0 }
	sync.mutex_lock(&d.mu)
	defer sync.mutex_unlock(&d.mu)
	context.allocator = d.allocator
	h, p := base.pool_insert(&d.ports, Port{loop = loop, on_done = on_done, user = user})
	p.done = make([dynamic]^Job)
	return Port_Id(h)
}

// Loop thread of the port. Disposes of every job of the port not yet delivered.
port_close :: proc(id: Port_Id) {
	d := dec
	if d == nil || id == 0 { return }
	sync.mutex_lock(&d.mu)
	defer sync.mutex_unlock(&d.mu)
	context.allocator = d.allocator
	for i := 0; i < len(d.queue); {
		j := d.queue[i]
		if j.port == id { ordered_remove(&d.queue, i); job_free(j) } else { i += 1 }
	}
	for j in d.running { if j.port == id { j.state = .Cancelled } }
	if p, ok := base.pool_remove(&d.ports, base.Handle(id)); ok {
		for j in p.done { job_free(j) }
		delete(p.done)
	}
}

// A job to fill and submit. `data` is retained by the job.
job_make :: proc(kind: Job_Kind, data: ^Blob, opts: Decode_Options, priority: i32 = 0, user: rawptr = nil, tag: u64 = 0) -> ^Job {
	context.allocator = runtime.heap_allocator()
	j := new(Job)
	j.kind, j.data, j.opts, j.priority, j.user, j.tag = kind, blob_retain(data), opts, priority, user, tag
	j.opts.mime = clone_string(opts.mime)
	return j
}

// Frees a job and whatever result it still holds.
job_free :: proc(j: ^Job) {
	if j == nil { return }
	context.allocator = runtime.heap_allocator()
	blob_release(j.data)
	image_destroy(j.image)
	delete(j.opts.mime)
	free(j)
}

// Queues `j` on the port. False (and `j` freed) when the port or the decoder is gone.
submit :: proc(id: Port_Id, j: ^Job) -> bool {
	d := dec
	if d == nil { job_free(j); return false }
	sync.mutex_lock(&d.mu)
	defer sync.mutex_unlock(&d.mu)
	if d.stopping || base.pool_get(&d.ports, base.Handle(id)) == nil {
		job_free(j)
		return false
	}
	d.seq += 1
	j.seq, j.port, j.state = d.seq, id, .Queued
	append(&d.queue, j)
	// every thread is busy (or ended while idle): one more, up to the configured number
	if d.idle < len(d.queue) && d.live < d.max_threads { spawn_thread(d) }
	sync.cond_signal(&d.cond)
	return true
}

// Withdraws a job that was submitted and not delivered yet; the pointer is dead afterwards. Loop thread of its port.
job_cancel :: proc(j: ^Job) {
	d := dec
	if d == nil || j == nil { return }
	sync.mutex_lock(&d.mu)
	defer sync.mutex_unlock(&d.mu)
	switch j.state {
	case .Queued:
		for x, i in d.queue { if x == j { ordered_remove(&d.queue, i); break } }
		job_free(j)
	case .Running:
		j.state = .Cancelled
	case .Finished:
		if p := base.pool_get(&d.ports, base.Handle(j.port)); p != nil {
			for x, i in p.done { if x == j { ordered_remove(&p.done, i); break } }
		}
		job_free(j)
	case .Delivered, .Cancelled:
	}
}

job_set_priority :: proc(j: ^Job, priority: i32) {
	d := dec
	if d == nil || j == nil { return }
	sync.mutex_lock(&d.mu)
	j.priority = priority
	sync.mutex_unlock(&d.mu)
}

@(private)
clone_string :: proc(s: string) -> string {
	if s == "" { return "" }
	b := make([]u8, len(s))
	copy(b, s)
	return string(b)
}

@(private)
decoder_thread :: proc(data: rawptr) {
	d := (^Decoder)(data)
	codec: Codec_Context
	have_codec := codec_init(&codec)
	defer if have_codec { codec_destroy(&codec) }
	sync.mutex_lock(&d.mu)
	first := !codecs.probed
	if first && have_codec { probe_codecs() }
	codecs.probed = true
	sync.mutex_unlock(&d.mu)
	if first { sync.sema_post(&codecs_ready) }
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
		if d.stopping || ended { d.live -= 1; sync.mutex_unlock(&d.mu); return }
		best := 0
		for j, i in d.queue {
			b := d.queue[best]
			if j.priority > b.priority || (j.priority == b.priority && j.seq < b.seq) { best = i }
		}
		j := d.queue[best]
		ordered_remove(&d.queue, best)
		j.state = .Running
		append(&d.running, j)
		sync.mutex_unlock(&d.mu)

		start := time.tick_now()
		{
			context.allocator = runtime.heap_allocator()
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
				host.post(p.loop, port_drain, rawptr(uintptr(j.port)))
			}
		}
		sync.mutex_unlock(&d.mu)
	}
}

// The port's loop: delivers finished jobs one at a time (a callback may close the port).
@(private)
port_drain :: proc(data: rawptr) {
	id := Port_Id(uintptr(data))
	for {
		d := dec
		if d == nil { return }
		sync.mutex_lock(&d.mu)
		p := base.pool_get(&d.ports, base.Handle(id))
		if p == nil { sync.mutex_unlock(&d.mu); return }
		if len(p.done) == 0 { p.posted = false; sync.mutex_unlock(&d.mu); return }
		j := p.done[0]
		ordered_remove(&p.done, 0)
		j.state = .Delivered
		fn, user := p.on_done, p.user
		sync.mutex_unlock(&d.mu)
		fn(user, j)
	}
}
