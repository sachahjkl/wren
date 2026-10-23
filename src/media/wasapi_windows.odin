#+build windows
package media

// WASAPI, shared mode, event driven: a thread fills the device's buffer from a ring the player writes into. The stream is
// float32 stereo at the rate of the media; the audio engine converts it to what the device wants (AUTOCONVERTPCM), so a
// 44.1 kHz stream on a 48 kHz device needs nothing here.
//
// Where playback is: IAudioClock gives the frames the device played (silence included). The thread keeps, for each buffer it
// submitted, how many of its frames were audio and how many silence (the ring ran dry), and turns the device position
// into frames of audible audio: that is what the media clock follows, so an underrun stalls the clock instead of
// letting it run on silence.

import "wb:base"
import "core:sync"
import "core:thread"
import win "core:sys/windows"

foreign import kernel32 "system:kernel32.lib"

@(default_calling_convention = "system")
foreign kernel32 {
	QueryPerformanceCounter :: proc(count: ^i64) -> win.BOOL ---
	QueryPerformanceFrequency :: proc(freq: ^i64) -> win.BOOL ---
}

// Monotonic nanoseconds (the clock of IAudioClock's timestamps too).
mono_ns :: proc "contextless" () -> i64 {
	@(static) freq: i64
	if freq == 0 { QueryPerformanceFrequency(&freq) }
	c: i64
	QueryPerformanceCounter(&c)
	whole, rem := c / freq, c % freq
	return whole * 1_000_000_000 + rem * 1_000_000_000 / freq
}

CLSID_MMDeviceEnumerator := GUID{0xBCDE0395, 0xE52F, 0x467C, {0x8E, 0x3D, 0xC4, 0x57, 0x92, 0x91, 0x69, 0x2E}}
IID_IMMDeviceEnumerator := GUID{0xA95664D2, 0x9614, 0x4F35, {0xA7, 0x46, 0xDE, 0x8D, 0xB6, 0x36, 0x17, 0xE6}}
IID_IAudioClient := GUID{0x1CB9AD4C, 0xDBFA, 0x4c32, {0xB1, 0x78, 0xC2, 0xF5, 0x68, 0xA7, 0x03, 0xB2}}
IID_IAudioRenderClient := GUID{0xF294ACFC, 0x3146, 0x4483, {0xA7, 0xBF, 0xAD, 0xDC, 0xA7, 0xC2, 0x60, 0xE2}}
IID_IAudioClock := GUID{0xCD63314F, 0x3FBA, 0x4a1b, {0x81, 0x2C, 0xEF, 0x96, 0x35, 0x87, 0x28, 0xE7}}

IMMDeviceEnumerator :: struct #raw_union {
	#subtype iunknown: IUnknown,
	using vtable: ^IMMDeviceEnumerator_VTable,
}

IMMDeviceEnumerator_VTable :: struct {
	using iunknown_vtable: IUnknown_VTable,
	EnumAudioEndpoints: rawptr,
	GetDefaultAudioEndpoint: proc "system" (this: ^IMMDeviceEnumerator, flow, role: u32, dev: ^^IMMDevice) -> HRESULT,
	GetDevice: rawptr,
	RegisterEndpointNotificationCallback: rawptr,
	UnregisterEndpointNotificationCallback: rawptr,
}

IMMDevice :: struct #raw_union {
	#subtype iunknown: IUnknown,
	using vtable: ^IMMDevice_VTable,
}

IMMDevice_VTable :: struct {
	using iunknown_vtable: IUnknown_VTable,
	Activate: proc "system" (this: ^IMMDevice, iid: ^GUID, ctx: u32, params: rawptr, out: ^rawptr) -> HRESULT,
	OpenPropertyStore: rawptr,
	GetId: rawptr,
	GetState: rawptr,
}

WAVEFORMATEX_ :: struct #packed {
	wFormatTag:      u16,
	nChannels:       u16,
	nSamplesPerSec:  u32,
	nAvgBytesPerSec: u32,
	nBlockAlign:     u16,
	wBitsPerSample:  u16,
	cbSize:          u16,
}

IAudioClient :: struct #raw_union {
	#subtype iunknown: IUnknown,
	using vtable: ^IAudioClient_VTable,
}

IAudioClient_VTable :: struct {
	using iunknown_vtable: IUnknown_VTable,
	Initialize:        proc "system" (this: ^IAudioClient, mode: u32, flags: u32, duration, period: i64, fmt: ^WAVEFORMATEX_, session: rawptr) -> HRESULT,
	GetBufferSize:     proc "system" (this: ^IAudioClient, frames: ^u32) -> HRESULT,
	GetStreamLatency:  rawptr,
	GetCurrentPadding: proc "system" (this: ^IAudioClient, frames: ^u32) -> HRESULT,
	IsFormatSupported: rawptr,
	GetMixFormat:      rawptr,
	GetDevicePeriod:   rawptr,
	Start:             proc "system" (this: ^IAudioClient) -> HRESULT,
	Stop:              proc "system" (this: ^IAudioClient) -> HRESULT,
	Reset:             proc "system" (this: ^IAudioClient) -> HRESULT,
	SetEventHandle:    proc "system" (this: ^IAudioClient, h: win.HANDLE) -> HRESULT,
	GetService:        proc "system" (this: ^IAudioClient, iid: ^GUID, out: ^rawptr) -> HRESULT,
}

IAudioRenderClient :: struct #raw_union {
	#subtype iunknown: IUnknown,
	using vtable: ^IAudioRenderClient_VTable,
}

IAudioRenderClient_VTable :: struct {
	using iunknown_vtable: IUnknown_VTable,
	GetBuffer:     proc "system" (this: ^IAudioRenderClient, frames: u32, data: ^[^]u8) -> HRESULT,
	ReleaseBuffer: proc "system" (this: ^IAudioRenderClient, frames: u32, flags: u32) -> HRESULT,
}

IAudioClock :: struct #raw_union {
	#subtype iunknown: IUnknown,
	using vtable: ^IAudioClock_VTable,
}

IAudioClock_VTable :: struct {
	using iunknown_vtable: IUnknown_VTable,
	GetFrequency:     proc "system" (this: ^IAudioClock, freq: ^u64) -> HRESULT,
	GetPosition:      proc "system" (this: ^IAudioClock, pos: ^u64, qpc: ^u64) -> HRESULT,
	GetCharacteristics: rawptr,
}

AUDCLNT_STREAMFLAGS_EVENTCALLBACK :: u32(0x00040000)
AUDCLNT_STREAMFLAGS_AUTOCONVERTPCM :: u32(0x80000000)
AUDCLNT_STREAMFLAGS_SRC_DEFAULT_QUALITY :: u32(0x08000000)
AUDCLNT_BUFFERFLAGS_SILENT :: u32(2)
WAVE_FORMAT_IEEE_FLOAT :: u16(3)

@(private)
Submission :: struct {
	total_end: i64,   // device frames submitted up to the end of this buffer
	audio_end: i64,   // of which audible audio
	audio:     i32,   // audio frames in this buffer (they come first, then silence)
}

@(private)
Wasapi :: struct {
	out:        Audio_Output,
	enumerator: ^IMMDeviceEnumerator,
	device:     ^IMMDevice,
	client:     ^IAudioClient,
	render:     ^IAudioRenderClient,
	clock:      ^IAudioClock,
	event:      win.HANDLE,
	buf_frames: u32,
	ring:       []f32,
	ring_frames: int,
	rd, wr:     i64,                // frames, only ever increasing (atomic)
	gain:       u32,                // f32 bits: the gain asked for
	applied:    f32,                // the gain at the end of the last buffer
	start_req, started, quit, failed, flush_req, flush_ack: i32,
	thread:     ^thread.Thread,
	subs:       [256]Submission,
	sub_n:      int,                // submissions made (index of the next)
	total, audio_total: i64,
	// the published position (seqlock)
	pos_seq:    u32,
	pos_frames: i64,
	pos_at:     i64,
	rate:       int,
}

audio_open :: proc(rate: int) -> ^Audio_Output {
	if !mf_startup() { return nil }   // (COM, once)
	w := new(Wasapi, base.process_allocator())
	w.rate = rate
	w.gain = transmute(u32)f32(1)
	w.applied = 1
	ok := false
	defer if !ok { wasapi_free(w) }
	if !hr_ok(win.CoCreateInstance(&CLSID_MMDeviceEnumerator, nil, win.CLSCTX_ALL, &IID_IMMDeviceEnumerator, (^rawptr)(&w.enumerator))) || w.enumerator == nil { return nil }
	if !hr_ok(w.enumerator->GetDefaultAudioEndpoint(0, 0, &w.device)) || w.device == nil { return nil }
	if !hr_ok(w.device->Activate(&IID_IAudioClient, u32(win.CLSCTX_ALL), nil, (^rawptr)(&w.client))) || w.client == nil { return nil }
	f := WAVEFORMATEX_{
		wFormatTag = WAVE_FORMAT_IEEE_FLOAT, nChannels = 2, nSamplesPerSec = u32(rate), nBlockAlign = 8, wBitsPerSample = 32,
		nAvgBytesPerSec = u32(rate) * 8,
	}
	flags := AUDCLNT_STREAMFLAGS_EVENTCALLBACK | AUDCLNT_STREAMFLAGS_AUTOCONVERTPCM | AUDCLNT_STREAMFLAGS_SRC_DEFAULT_QUALITY
	if !hr_ok(w.client->Initialize(0, flags, 600_000, 0, &f, nil)) { return nil }   // shared mode, a 60 ms buffer
	w.event = win.CreateEventW(nil, false, false, nil)
	if w.event == nil || !hr_ok(w.client->SetEventHandle(w.event)) { return nil }
	w.client->GetBufferSize(&w.buf_frames)
	if !hr_ok(w.client->GetService(&IID_IAudioRenderClient, (^rawptr)(&w.render))) || w.render == nil { return nil }
	if !hr_ok(w.client->GetService(&IID_IAudioClock, (^rawptr)(&w.clock))) || w.clock == nil { return nil }
	w.ring_frames = max(rate / 2, 4096)   // half a second
	w.ring = make([]f32, w.ring_frames * 2, base.process_allocator())
	w.thread = thread.create_and_start_with_data(rawptr(w), wasapi_thread, context, .High)   // (the context of the creating thread)
	if w.thread == nil { return nil }
	ok = true
	o := &w.out
	o.impl, o.rate = w, rate
	o.write, o.room, o.queued, o.position = wasapi_write, wasapi_room, wasapi_queued, wasapi_position
	o.start, o.stop, o.flush, o.set_gain, o.failed, o.destroy = wasapi_start, wasapi_stop, wasapi_flush, wasapi_set_gain, wasapi_failed, wasapi_destroy
	return o
}

@(private)
wasapi_free :: proc(w: ^Wasapi) {
	if w.thread != nil {
		sync.atomic_store(&w.quit, 1)
		if w.event != nil { win.SetEvent(w.event) }
		thread.join(w.thread)
		thread.destroy(w.thread)
	}
	if w.client != nil { w.client->Stop() }
	com_release(w.clock); com_release(w.render); com_release(w.client); com_release(w.device); com_release(w.enumerator)
	if w.event != nil { win.CloseHandle(w.event) }
	delete(w.ring, base.process_allocator())
	free(w, base.process_allocator())
}

@(private)
wasapi_destroy :: proc(o: ^Audio_Output) { wasapi_free((^Wasapi)(o.impl)) }

@(private)
wasapi_write :: proc(o: ^Audio_Output, samples: []f32) -> int {
	w := (^Wasapi)(o.impl)
	frames := len(samples) / 2
	rd := sync.atomic_load(&w.rd)
	wr := w.wr   // (this thread is the only writer)
	room := w.ring_frames - int(wr - rd)
	n := min(frames, room)
	for i in 0 ..< n {
		k := int((wr + i64(i)) % i64(w.ring_frames)) * 2
		w.ring[k], w.ring[k + 1] = samples[i * 2], samples[i * 2 + 1]
	}
	sync.atomic_store(&w.wr, wr + i64(n))
	return n
}

@(private)
wasapi_room :: proc(o: ^Audio_Output) -> int {
	w := (^Wasapi)(o.impl)
	return w.ring_frames - int(sync.atomic_load(&w.wr) - sync.atomic_load(&w.rd))
}

@(private)
wasapi_queued :: proc(o: ^Audio_Output) -> int {
	w := (^Wasapi)(o.impl)
	frames, _ := wasapi_position(o)
	return int(sync.atomic_load(&w.wr) - frames)
}

@(private)
wasapi_position :: proc(o: ^Audio_Output) -> (frames: i64, at: i64) {
	w := (^Wasapi)(o.impl)
	for {
		s := sync.atomic_load(&w.pos_seq)
		if s & 1 != 0 { continue }
		frames, at = w.pos_frames, w.pos_at
		if sync.atomic_load(&w.pos_seq) == s { break }
	}
	return
}

@(private)
wasapi_start :: proc(o: ^Audio_Output) { sync.atomic_store(&(^Wasapi)(o.impl).start_req, 1); win.SetEvent((^Wasapi)(o.impl).event) }

@(private)
wasapi_stop :: proc(o: ^Audio_Output) {
	w := (^Wasapi)(o.impl)
	sync.atomic_store(&w.start_req, 0)
	win.SetEvent(w.event)
	// the thread stops the client; wait for it so that the caller may flush right after
	for _ in 0 ..< 100 {
		if sync.atomic_load(&w.started) == 0 { break }
		win.Sleep(1)
	}
}

@(private)
wasapi_flush :: proc(o: ^Audio_Output) {
	w := (^Wasapi)(o.impl)
	sync.atomic_store(&w.flush_ack, 0)
	sync.atomic_store(&w.flush_req, 1)
	win.SetEvent(w.event)
	for _ in 0 ..< 200 {
		if sync.atomic_load(&w.flush_ack) != 0 { break }
		win.Sleep(1)
	}
}

@(private)
wasapi_set_gain :: proc(o: ^Audio_Output, gain: f32) { sync.atomic_store(&(^Wasapi)(o.impl).gain, transmute(u32)clamp(gain, 0, 4)) }

@(private)
wasapi_failed :: proc(o: ^Audio_Output) -> bool { return sync.atomic_load(&(^Wasapi)(o.impl).failed) != 0 }

foreign import avrt "system:Avrt.lib"
@(default_calling_convention = "system", private = "file")
foreign avrt {
	AvSetMmThreadCharacteristicsW :: proc(task: win.LPCWSTR, index: ^u32) -> win.HANDLE ---
	AvRevertMmThreadCharacteristics :: proc(h: win.HANDLE) -> win.BOOL ---
}

@(private)
wasapi_thread :: proc(data: rawptr) {
	name_current_thread("wren-audio-out")
	w := (^Wasapi)(data)
	com_thread_init()
	// the Multimedia Class Scheduler Service: the system keeps CPU for this thread (and boosts it) whatever else is busy, so a
	// page's long script or a style pass on every core does not make the sound glitch
	task_index: u32
	mm := AvSetMmThreadCharacteristicsW(win.L("Pro Audio"), &task_index)
	defer if mm != nil { AvRevertMmThreadCharacteristics(mm) }
	for sync.atomic_load(&w.quit) == 0 {
		win.WaitForSingleObject(w.event, 100)
		if sync.atomic_load(&w.quit) != 0 { break }
		if sync.atomic_load(&w.flush_req) != 0 {
			if w.started != 0 { w.client->Stop(); sync.atomic_store(&w.started, 0) }
			w.client->Reset()
			sync.atomic_store(&w.rd, 0)
			sync.atomic_store(&w.wr, 0)
			w.total, w.audio_total, w.sub_n = 0, 0, 0
			publish(w, 0)
			sync.atomic_store(&w.flush_req, 0)
			sync.atomic_store(&w.flush_ack, 1)
			continue
		}
		want := sync.atomic_load(&w.start_req) != 0
		if !want {
			if w.started != 0 { w.client->Stop(); sync.atomic_store(&w.started, 0) }
			continue
		}
		fill(w)
		if w.started == 0 {
			if hr_ok(w.client->Start()) { sync.atomic_store(&w.started, 1) } else { sync.atomic_store(&w.failed, 1) }
		}
		measure(w)
	}
}

// One buffer's worth: what the ring has (with the gain), then silence.
@(private)
fill :: proc(w: ^Wasapi) {
	padding: u32
	if !hr_ok(w.client->GetCurrentPadding(&padding)) { sync.atomic_store(&w.failed, 1); return }
	avail := w.buf_frames - padding
	if avail == 0 { return }
	data: [^]u8
	if !hr_ok(w.render->GetBuffer(avail, &data)) { sync.atomic_store(&w.failed, 1); return }
	rd := sync.atomic_load(&w.rd)
	have := int(sync.atomic_load(&w.wr) - rd)
	n := min(int(avail), have)
	out := ([^]f32)(data)
	target := transmute(f32)sync.atomic_load(&w.gain)
	from := w.applied
	for i in 0 ..< n {
		k := int((rd + i64(i)) % i64(w.ring_frames)) * 2
		// the gain moves to its new value over this buffer
		g := n > 1 ? from + (target - from) * f32(i) / f32(n - 1) : target
		out[i * 2], out[i * 2 + 1] = w.ring[k] * g, w.ring[k + 1] * g
	}
	w.applied = target
	for i in n ..< int(avail) { out[i * 2], out[i * 2 + 1] = 0, 0 }
	sync.atomic_store(&w.rd, rd + i64(n))
	w.render->ReleaseBuffer(avail, n == 0 ? AUDCLNT_BUFFERFLAGS_SILENT : 0)
	w.total += i64(avail)
	w.audio_total += i64(n)
	w.subs[w.sub_n % len(w.subs)] = Submission{total_end = w.total, audio_end = w.audio_total, audio = i32(n)}
	w.sub_n += 1
}

// The device position as frames of audible audio, published for the readers.
@(private)
measure :: proc(w: ^Wasapi) {
	freq, pos, qpc: u64
	if !hr_ok(w.clock->GetFrequency(&freq)) || !hr_ok(w.clock->GetPosition(&pos, &qpc)) || freq == 0 { return }
	dev := i64(pos * u64(w.rate) / freq)   // frames the device played, silence included
	played: i64
	// the last submissions, newest first: the one the position lies in
	n := min(w.sub_n, len(w.subs))
	for k in 0 ..< n {
		s := w.subs[(w.sub_n - 1 - k) % len(w.subs)]
		if dev >= s.total_end {
			played = s.audio_end
			break
		}
		// the buffer covers device frames [begin, total_end); its audio frames come first
		begin: i64 = 0
		if k + 1 < n { begin = w.subs[(w.sub_n - 2 - k) % len(w.subs)].total_end }
		if dev >= begin {
			played = (s.audio_end - i64(s.audio)) + min(dev - begin, i64(s.audio))
			break
		}
	}
	publish(w, played, i64(qpc) * 100)
}

@(private)
publish :: proc(w: ^Wasapi, frames: i64, at: i64 = 0) {
	sync.atomic_add(&w.pos_seq, 1)
	w.pos_frames = frames
	w.pos_at = at   // (0: no measurement since the flush: the reader does not extrapolate)
	sync.atomic_add(&w.pos_seq, 1)
}
