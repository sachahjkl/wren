package page

// Media Source Extensions in a dedicated worker (Media Source Extensions "MSE-in-Workers"). A media element lives in a
// page, on the interface thread; a worker's MediaSource is on the worker's thread. So:
//   * new MediaSource() in a dedicated worker makes a MediaSource object there (its MediaSource_* functions are the
//     page's: media_source.odin) bound to an Mse_Channel; its source buffers have no parser: they mirror the page's;
//   * mediaSource.handle is a MediaSourceHandle, transferable once (structured clone T_MSE_HANDLE: a token taken here
//     and adopted by the receiving realm); URL.createObjectURL(mediaSource) is refused for a worker's MediaSource;
//   * element.srcObject = handle (in the page) makes the page's side: a MediaSource object of the page, without script,
//     attached to the element as an object URL's would be (ms_attach); its source buffers parse and store what the
//     worker appends, the element plays them;
//   * the worker's calls are checked there (the same functions, on the mirrored state: readyState, duration, updating,
//     buffered) and sent as commands on the worker's link (Mse_Command), done in order by the page's side;
//   * every event of the page's side (sourceopen / sourceended / sourceclose, updatestart / update / updateend / error
//     / abort, addsourcebuffer / removesourcebuffer) goes to the worker (Mse_Event) with a snapshot of the state, applied
//     there before the event fires at the worker's object (the state of a command the page's side has not done yet is
//     the worker's own: command sequence numbers).
// Lifetime: the channel is counted (the worker's MediaSource, each handle, a token in flight, the page's side, an
// element's srcObject); the worker's link it sends on is kept by it.

import "core:math"
import "core:mem"
import "core:strings"
import "core:sync"
import "wb:dom"

Mse_Channel :: struct {
	refs:  i32,                       // atomic
	link:  ^Worker_Link,              // the worker realm's (a reference): the page's side sends its events there
	ui_ms: ^Media_Source_Object,      // interface thread: the page's side (nil: no element plays it)
	w_ms:  ^Media_Source_Object,      // worker thread: the worker's MediaSource (nil once it went)
}

Mse_Handle_Object :: struct {
	ch:       ^Mse_Channel,
	detached: bool,                   // transferred away (or used as a srcObject)
}

mse_handle_vt := Object_VTable{
	name = "MediaSourceHandle",
	destroy = proc(p: ^Page, data: rawptr) {
		h := (^Mse_Handle_Object)(data)
		mse_channel_release(h.ch)
		free(h)
	},
}

lookup_MediaSourceHandle :: proc(c: ^Call, h: u64) -> ^Mse_Handle_Object { return (^Mse_Handle_Object)(object_data(c.page, h, &mse_handle_vt)) }

Mse_Op :: enum u8 { Add, Remove_Buffer, Append, Abort, Remove_Range, Change_Type, Mode, Ts_Offset, Window, Duration, End, Live, Clear_Live }

@(private) MSE_TARGET_SOURCE :: i64(-1)
@(private) MSE_TARGET_ALL    :: i64(-2)
@(private) MSE_TARGET_ACTIVE :: i64(-3)

mse_channel_retain :: proc(ch: ^Mse_Channel) { sync.atomic_add(&ch.refs, 1) }

mse_channel_release :: proc(ch: ^Mse_Channel) {
	if ch == nil || sync.atomic_sub(&ch.refs, 1) != 1 { return }
	link_release(ch.link)
	free(ch)
}

// The worker's MediaSource (the worker's own object, not the page's side).
mse_proxy :: #force_inline proc(ms: ^Media_Source_Object) -> bool { return ms != nil && ms.remote != nil && !ms.remote_ui }

// new MediaSource() in a dedicated worker.
mse_bind_worker :: proc(p: ^Page, ms: ^Media_Source_Object) {
	ch := new(Mse_Channel)
	ch.refs = 1
	ch.link = p.worker.link
	link_retain(ch.link)
	ch.w_ms = ms
	ms.remote = ch
}

// The object goes (ms_free): its side of the channel is let go.
mse_unbind :: proc(ms: ^Media_Source_Object) {
	ch := ms.remote
	if ms.remote_ui { ch.ui_ms = nil } else { ch.w_ms = nil }
	ms.remote = nil
	mse_channel_release(ch)
}

////////////////////////////////
// The worker's side

MediaSource_handle :: proc(c: ^Call, source: Api_MediaSource) -> (u64, Api_Error) {
	ms := source.data
	if c.page.worker == nil || !mse_proxy(ms) { return 0, fail(c, .Not_Supported, "MediaSource.handle is for a MediaSource of a dedicated worker.") }
	if ms.handle_obj == 0 {
		h := new(Mse_Handle_Object)
		h.ch = ms.remote
		mse_channel_retain(h.ch)
		ms.handle_obj = object_create(c.page, &mse_handle_vt, h, ms.owner)
	}
	return ms.handle_obj, .None
}

// A command for the page's side (in order); the worker's state already shows its effect.
mse_command :: proc(ms: ^Media_Source_Object, op: Mse_Op, rid: u32, a: f64 = 0, b: f64 = 0, text := "", data: []byte = nil) {
	p := ms.page
	if p.worker == nil { return }
	ms.seq += 1
	m := new(Worker_Msg)
	m.kind, m.id = .Mse_Command, u64(uintptr(ms.remote))
	mse_channel_retain(ms.remote)   // (the message's: msg_free lets it go)
	m.code = i64(op) | i64(rid) << 8 | i64(ms.seq) << 40
	m.text = strings.clone(text)
	f := [2]f64{a, b}
	m.text2 = strings.clone(string(mem.byte_slice(&f, size_of(f))))
	if len(data) > 0 { m.bytes = make([]byte, len(data)); copy(m.bytes, data) }
	m.size = len(data)
	link_send(p.worker.link, false, m)
}

// An event of the page's side, with its snapshot: the mirror is brought up to date, then the event fires.
mse_worker_event :: proc(p: ^Page, m: ^Worker_Msg) {
	ch := (^Mse_Channel)(uintptr(m.id))
	// (the channel lives while the worker's MediaSource does, and w_ms is nil once it went: then nothing is left to tell;
	// a message that outlives every reference cannot come, the page's side holds one while it sends)
	ms := ch.w_ms
	if ms == nil { return }
	r := Mse_Reader{b = m.bytes}
	seq := r_u32(&r)
	state := MS_State(r_u8(&r))
	duration := r_f64(&r)
	synced := seq == ms.seq   // the page's side has done every command: its state is the state
	if synced { ms.state, ms.duration = state, duration }
	n := int(r_u32(&r))
	seen := make([dynamic]u32, context.temp_allocator)
	for _ in 0 ..< n {
		rid := r_u32(&r)
		updating, mode, init := r_u8(&r) != 0, Append_Mode(r_u8(&r)), r_u8(&r) != 0
		ts := r_f64(&r)
		nr := int(r_u32(&r))
		append(&seen, rid)
		sb: ^Source_Buffer_Object
		for x in ms.buffers { if x.rid == rid { sb = x; break } }
		if sb == nil { for _ in 0 ..< nr { r_f64(&r); r_f64(&r) }; continue }
		clear(&sb.ranges)
		for _ in 0 ..< nr { s := r_f64(&r); e := r_f64(&r); append(&sb.ranges, [2]f64{s, e}) }
		sb.init_received = init
		if synced { sb.updating, sb.mode, sb.ts_offset = updating, mode, ts }
	}
	if synced {
		// buffers the page's side no longer has (its element let go: sourceclose) leave the worker's too
		for i := len(ms.buffers) - 1; i >= 0; i -= 1 {
			found := false
			for rid in seen { if rid == ms.buffers[i].rid { found = true; break } }
			if !found { ms_remove_buffer(ms, i, false) }
		}
	}
	if r.bad { return }
	target: u64
	switch m.code {
	case MSE_TARGET_SOURCE: target = ms.self
	case MSE_TARGET_ALL: target = ms.list_all
	case MSE_TARGET_ACTIVE: target = ms.list_active
	case:
		for x in ms.buffers { if i64(x.rid) == m.code { target = x.self } }
		for x in ms.dead { if i64(x.rid) == m.code { target = x.self } }
	}
	if target != 0 { object_dispatch(p, target, dom.Event{type = m.text}) }
}

@(private)
Mse_Reader :: struct { b: []byte, i: int, bad: bool }

@(private)
r_take :: proc(r: ^Mse_Reader, n: int) -> []byte {
	if r.i + n > len(r.b) { r.bad = true; return nil }
	s := r.b[r.i:r.i + n]
	r.i += n
	return s
}
@(private) r_u8 :: proc(r: ^Mse_Reader) -> u8 { s := r_take(r, 1); return s == nil ? 0 : s[0] }
@(private) r_u32 :: proc(r: ^Mse_Reader) -> u32 { v: u32; if s := r_take(r, 4); s != nil { mem.copy(&v, raw_data(s), 4) }; return v }
@(private) r_f64 :: proc(r: ^Mse_Reader) -> f64 { v: f64; if s := r_take(r, 8); s != nil { mem.copy(&v, raw_data(s), 8) }; return v }

////////////////////////////////
// Transfer (structured clone, runtime/clone.c)

@(private) mse_tokens: [dynamic]^Mse_Channel   // taken, not adopted yet (any thread: under mse_tokens_mu)
@(private) mse_tokens_mu: sync.Mutex

MediaSourceHandle_take :: proc(c: ^Call, h: Api_MediaSourceHandle) -> (u64, Api_Error) {
	o := h.data
	if o.detached { return 0, fail(c, .Data_Clone, "DataCloneError: the MediaSourceHandle was transferred before.") }
	o.detached = true
	mse_channel_retain(o.ch)
	sync.mutex_lock(&mse_tokens_mu)
	append(&mse_tokens, o.ch)
	sync.mutex_unlock(&mse_tokens_mu)
	return u64(uintptr(o.ch)), .None
}

MediaSourceHandle_adopt :: proc(c: ^Call, token: u64) -> (u64, Api_Error) {
	ch := (^Mse_Channel)(uintptr(token))
	found := false
	sync.mutex_lock(&mse_tokens_mu)
	for x, i in mse_tokens { if x == ch { unordered_remove(&mse_tokens, i); found = true; break } }
	sync.mutex_unlock(&mse_tokens_mu)
	if !found { return 0, fail(c, .Data_Clone, "DataCloneError: no such MediaSourceHandle in transfer.") }
	h := new(Mse_Handle_Object)
	h.ch = ch   // (the token's reference)
	return object_create(c.page, &mse_handle_vt, h, c.owner), .None
}

// Process end: the tokens of messages never received.
mse_tokens_shutdown :: proc() {
	sync.mutex_lock(&mse_tokens_mu)
	for ch in mse_tokens { mse_channel_release(ch) }
	delete(mse_tokens)
	mse_tokens = nil
	sync.mutex_unlock(&mse_tokens_mu)
}

////////////////////////////////
// The page's side

// element.srcObject = handle (0: null).
HTMLMediaElement_setSourceHandle :: proc(c: ^Call, element: Api_HTMLMediaElement, handle: u64) -> Api_Error {
	el := element.data
	var_h: ^Mse_Handle_Object
	if handle != 0 {
		var_h = (^Mse_Handle_Object)(object_data(c.page, handle, &mse_handle_vt))
		if var_h == nil { return fail(c, .Type, "srcObject: only a MediaSourceHandle (or null) is supported.") }
		if var_h.detached { return fail(c, .Invalid_State, "InvalidStateError: this MediaSourceHandle was transferred or used already.") }
	}
	if el.src_channel != nil { mse_channel_release(el.src_channel); el.src_channel = nil }
	if var_h != nil {
		var_h.detached = true   // (a handle serves one element: it cannot be transferred any more)
		el.src_channel = var_h.ch
		mse_channel_retain(el.src_channel)
	}
	media_load(el)
	return .None
}

// The element's load found its srcObject: the page's side of the worker's MediaSource is made and attached.
mse_attach_channel :: proc(el: ^Media_Element) {
	ch := el.src_channel
	p := el.page
	if ch.ui_ms != nil {
		media_failed(el, MEDIA_ERR_SRC_NOT_SUPPORTED, "the MediaSource is already attached")
		return
	}
	ms := new(Media_Source_Object)
	ms.page = p
	ms.duration = math.nan_f64()
	ms.remote, ms.remote_ui = ch, true
	mse_channel_retain(ch)
	ch.ui_ms = ms
	ms.self = object_create(p, &media_source_vt, ms, 0)
	ms.list_all = object_create(p, &source_buffer_list_vt, new_clone(Source_Buffer_List_Object{ms = ms}), 0)
	ms.list_active = object_create(p, &source_buffer_list_vt, new_clone(Source_Buffer_List_Object{ms = ms, active = true}), 0)
	ms_attach(el, ms)
}

// mse_fire's hook: an event of the page's side goes to the worker with the state (true: it was one of those).
mse_forward :: proc(p: ^Page, handle: u64, type: string) -> bool {
	ms: ^Media_Source_Object
	target: i64
	if x := (^Media_Source_Object)(object_data(p, handle, &media_source_vt)); x != nil {
		ms, target = x, MSE_TARGET_SOURCE
	} else if l := (^Source_Buffer_List_Object)(object_data(p, handle, &source_buffer_list_vt)); l != nil {
		ms, target = l.ms, l.active ? MSE_TARGET_ACTIVE : MSE_TARGET_ALL
	} else if sb := (^Source_Buffer_Object)(object_data(p, handle, &source_buffer_vt)); sb != nil {
		ms, target = sb.ms, i64(sb.rid)
	}
	if ms == nil || !ms.remote_ui || ms.remote == nil { return false }
	b := make([dynamic]byte, context.temp_allocator)
	w_u32(&b, ms.seq)
	append(&b, u8(ms.state))
	w_f64(&b, ms.duration)
	w_u32(&b, u32(len(ms.buffers)))
	for sb in ms.buffers {
		w_u32(&b, sb.rid)
		append(&b, u8(sb.updating), u8(sb.mode), u8(sb.init_received))
		w_f64(&b, sb.ts_offset)
		rs := sb_ranges(sb)
		w_u32(&b, u32(len(rs)))
		for r in rs { w_f64(&b, r[0]); w_f64(&b, r[1]) }
	}
	m := new(Worker_Msg)
	m.kind, m.id, m.code = .Mse_Event, u64(uintptr(ms.remote)), target
	mse_channel_retain(ms.remote)   // (the message's: msg_free lets it go)
	m.text = strings.clone(type)
	m.bytes = make([]byte, len(b))
	copy(m.bytes, b[:])
	link_send(ms.remote.link, true, m)
	return true
}

@(private) w_u32 :: proc(b: ^[dynamic]byte, v: u32) { x := v; append(b, ..mem.byte_slice(&x, 4)) }
@(private) w_f64 :: proc(b: ^[dynamic]byte, v: f64) { x := v; append(b, ..mem.byte_slice(&x, 8)) }

// A command of the worker (interface thread, from the worker's link).
mse_ui_command :: proc(m: ^Worker_Msg) {
	ch := (^Mse_Channel)(uintptr(m.id))
	ms := ch.ui_ms   // (the channel lives: the worker's MediaSource holds it while it sends)
	op := Mse_Op(m.code & 0xFF)
	rid := u32((m.code >> 8) & 0xFFFF_FFFF)
	seq := u32(m.code >> 40)
	if ms == nil { return }   // no element plays it (the worker checked the state: it went meanwhile)
	ms.seq = seq   // (done from here on: the snapshots of the events it causes say so)
	f: [2]f64
	if len(m.text2) == size_of(f) { mem.copy(&f, raw_data(m.text2), size_of(f)) }
	c := Call{page = ms.page}
	src := Api_MediaSource{handle = ms.self, data = ms}
	sb: ^Source_Buffer_Object
	for x in ms.buffers { if x.rid == rid { sb = x; break } }
	b := Api_SourceBuffer{handle = sb != nil ? sb.self : 0, data = sb}
	if op != .Add && op != .Duration && op != .End && op != .Live && op != .Clear_Live && sb == nil { return }
	switch op {
	case .Add:
		ms.next_rid = rid   // (MediaSource_addSourceBuffer gives it to the new buffer)
		MediaSource_addSourceBuffer(&c, src, m.text)
	case .Remove_Buffer: MediaSource_removeSourceBuffer(&c, src, b)
	case .Append:
		if SourceBuffer_appendBuffer(&c, b, m.bytes) != .None {
			// (refused here, a full buffer: the worker hears of it as a failed append)
			mse_fire(ms.page, sb.self, "error")
			mse_fire(ms.page, sb.self, "updateend")
		}
	case .Abort: SourceBuffer_abort(&c, b)
	case .Remove_Range: SourceBuffer_remove(&c, b, f[0], f[1])
	case .Change_Type: SourceBuffer_changeType(&c, b, m.text)
	case .Mode: SourceBuffer_set_mode(&c, b, m.text)
	case .Ts_Offset: SourceBuffer_set_timestampOffset(&c, b, f[0])
	case .Window:
		sb.win_start, sb.win_end = 0, math.inf_f64(1)
		SourceBuffer_set_appendWindowEnd(&c, b, f[1])
		SourceBuffer_set_appendWindowStart(&c, b, f[0])
	case .Duration: MediaSource_set_duration(&c, src, f[0])
	case .End: MediaSource_endOfStream(&c, src, m.text)
	case .Live: MediaSource_setLiveSeekableRange(&c, src, f[0], f[1])
	case .Clear_Live: MediaSource_clearLiveSeekableRange(&c, src)
	}
}
