package page

// The Web Audio API for a page (api/webaudio.widl): a graph of src/webaudio per context, its events brought back to the
// page's thread. A graph is a host object: it goes (its thread joined) with its realm's reference, or with the page.

import "core:mem"
import "core:sync"
import "core:time"
import "wb:base"
import "wb:host"
import "wb:media"
import "wb:webaudio"

Web_Audio_Graph :: struct {
	page:     ^Page,
	self:     u64,
	g:        ^webaudio.Graph,
	callback, user, owner: u32,
	latency:  int,        // frames queued ahead of the device
	offline:  bool,
	wants_run: bool,      // resume() was called, or the context started on its own: it runs as soon as it may
	token:    Web_Audio_Token,
	worklet_realm: u64,   // the Worker object of its AudioWorklet's realm (the engine's wrapper owns it), 0 when none
}

// What the render thread posts to the page's thread: ids, never pointers that may have gone.
Web_Audio_Token :: struct {
	loop:     ^host.Loop,
	page_id:  u64,
	self:     u64,
}

// The buffer of an AudioBuffer in the browser.
Web_Audio_Pcm :: struct {
	pcm: ^webaudio.Pcm,
}

@(private = "file")
graph_vt := Object_VTable{
	name = "AudioGraph",
	destroy = proc(p: ^Page, data: rawptr) {
		a := (^Web_Audio_Graph)(data)
		// (its Worker object lives on until the thread reports its exit; a page closing stops them all: workers_destroy)
		if !p.closed { worklet_realm_stop(p, a) }
		if p.media != nil {
			for o, i in p.media.audio_graphs {
				if o == a { unordered_remove(&p.media.audio_graphs, i); break }
			}
			// the players that send it their sound stop first
			for _, el in p.media.elements {
				if el.capture == nil || el.capture.graph != a.g { continue }
				if el.player != nil { media.player_set_capture(el.player, nil, nil) }
				free(el.capture, base.process_allocator())
				el.capture = nil
			}
		}
		webaudio.graph_destroy(a.g)
		free(a)
	},
}

@(private = "file")
pcm_vt := Object_VTable{
	name = "AudioPcm",
	destroy = proc(p: ^Page, data: rawptr) {
		b := (^Web_Audio_Pcm)(data)
		p.held -= webaudio.pcm_bytes(b.pcm.channels, b.pcm.length)
		webaudio.pcm_release(b.pcm)
		free(b)
	},
}

@(private = "file")
graph_of :: proc(c: ^Call, h: u64) -> ^webaudio.Graph {
	a := (^Web_Audio_Graph)(object_data(c.page, h, &graph_vt))
	return a != nil ? a.g : nil
}

@(private = "file")
pcm_of :: proc(c: ^Call, h: u64) -> ^webaudio.Pcm {
	b := (^Web_Audio_Pcm)(object_data(c.page, h, &pcm_vt))
	return b != nil ? b.pcm : nil
}

@(private = "file")
floats :: proc(b: []u8) -> []f32 { return mem.slice_data_cast([]f32, b) }

// A click or a key press: sound may start. The contexts waiting for it start.
@(private)
web_audio_activated :: proc(p: ^Page) {
	if p.media == nil { return }
	for a in p.media.audio_graphs {
		if a.wants_run { webaudio.graph_resume(a.g, a.latency) }
	}
}

@(private = "file")
allowed_to_start :: proc(p: ^Page) -> bool {
	switch p.settings.media.autoplay {
	case .Allow_All: return true
	case .Allow_Muted, .Block: return media_has_activation(p)
	}
	return false
}

// The tab's mute (the browser's side): the page is not told.
web_audio_set_muted :: proc(p: ^Page, on: bool) {
	if p.media == nil { return }
	for a in p.media.audio_graphs { webaudio.graph_set_muted(a.g, on) }
}

// A context of the page gives sound now (the speaker on its tab).
web_audio_audible :: proc(p: ^Page) -> bool {
	if p.media == nil { return false }
	for a in p.media.audio_graphs {
		if webaudio.graph_audible(a.g) { return true }
	}
	return false
}

// (the render thread, under the graph's lock) Events wait: the page's thread is told once.
@(private = "file")
graph_notify :: proc(user: rawptr) {
	tok := (^Web_Audio_Token)(user)
	t := new_clone(tok^, base.process_allocator())
	host.post(t.loop, graph_pump, t)
}

@(private = "file")
graph_pump :: proc(data: rawptr) {
	t := (^Web_Audio_Token)(data)
	id, self := t.page_id, t.self
	free(t, base.process_allocator())
	p := page_by_id(id)
	if p == nil || p.closed { return }
	a := (^Web_Audio_Graph)(object_data(p, self, &graph_vt))
	if a == nil { return }
	events := webaudio.take_events(a.g, context.temp_allocator)
	callback, user, owner := a.callback, a.user, a.owner
	for e in events {
		// (a listener may close the page or let the graph go)
		if p.closed || object_data(p, self, &graph_vt) == nil { return }
		inst := instance_by_index(p, owner)
		if inst == nil { return }
		argv := [4]u32{user, u32(e.type), u32(e.node), u32(e.value)}
		call_guest(p, inst, callback, argv[:])
	}
}

WebAudio_enabled :: proc(c: ^Call) -> bool { return c.page.settings.webaudio.enabled }
WebAudio_fullyActive :: proc(c: ^Call) -> bool { return !c.page.closed && c.page.web != nil && !c.page.web.frozen }
WebAudio_defaultRate :: proc(c: ^Call) -> f64 { return c.page.settings.webaudio.default_rate }
WebAudio_maxBufferBytes :: proc(c: ^Call) -> f64 { return f64(c.page.settings.webaudio.max_buffer_bytes) }

WebAudio_create :: proc(c: ^Call, rate: f64, channels, offline_frames: u32, latency: f64, notify: u32, user: i32) -> u64 {
	p := c.page
	if !p.settings.webaudio.enabled { return 0 }
	// (the page's script checks all this; a Wasm module of the page calls here directly)
	if !(rate >= webaudio.MIN_SAMPLE_RATE && rate <= webaudio.MAX_SAMPLE_RATE) || channels < 1 || channels > webaudio.MAX_CHANNELS { return 0 }
	if webaudio.pcm_bytes(int(channels), int(offline_frames)) > p.settings.webaudio.max_buffer_bytes { return 0 }
	pm := media_pm(p)
	if offline_frames == 0 && len(pm.audio_graphs) >= p.settings.webaudio.max_contexts { return 0 }
	a := new(Web_Audio_Graph)
	a.page, a.callback, a.user, a.owner = p, notify, u32(user), c.owner
	a.offline = offline_frames > 0
	a.latency = int((latency > 0 ? latency : p.settings.webaudio.latency_ms / 1000) * rate)
	a.g = webaudio.graph_new(rate, int(channels), a.offline)
	a.self = object_create(p, &graph_vt, a, c.owner)
	a.token = Web_Audio_Token{p.loop, page_id(p), a.self}
	a.g.notify, a.g.notify_user = graph_notify, &a.token
	if !a.offline { append(&pm.audio_graphs, a) }
	return a.self
}

WebAudio_resume :: proc(c: ^Call, graph: u64) {
	a := (^Web_Audio_Graph)(object_data(c.page, graph, &graph_vt))
	if a == nil || a.offline { return }
	a.wants_run = true
	if allowed_to_start(c.page) { webaudio.graph_resume(a.g, a.latency) }
}

WebAudio_suspend :: proc(c: ^Call, graph: u64) -> bool {
	a := (^Web_Audio_Graph)(object_data(c.page, graph, &graph_vt))
	if a == nil || a.offline { return false }
	a.wants_run = false
	if webaudio.graph_state(a.g) != .Running { return false }
	webaudio.graph_suspend(a.g)
	return true
}

WebAudio_close :: proc(c: ^Call, graph: u64) {
	a := (^Web_Audio_Graph)(object_data(c.page, graph, &graph_vt))
	if a == nil { return }
	a.wants_run = false
	webaudio.graph_close(a.g)
	// (the place among the running ones is free)
	if c.page.media != nil {
		for o, i in c.page.media.audio_graphs {
			if o == a { unordered_remove(&c.page.media.audio_graphs, i); break }
		}
	}
}

WebAudio_time :: proc(c: ^Call, graph: u64) -> f64 {
	g := graph_of(c, graph)
	return g != nil ? webaudio.graph_time(g) : 0
}

WebAudio_queued :: proc(c: ^Call, graph: u64) -> f64 {
	g := graph_of(c, graph)
	return g != nil ? f64(webaudio.graph_queued(g)) / g.rate : 0
}

WebAudio_render :: proc(c: ^Call, graph: u64, frames: u32) -> bool {
	g := graph_of(c, graph)
	return g != nil && g.offline && frames > 0 && webaudio.pcm_bytes(g.channels, int(frames)) <= c.page.settings.webaudio.max_buffer_bytes && webaudio.offline_start(g, int(frames))
}

WebAudio_takeResult :: proc(c: ^Call, graph: u64) -> u64 {
	g := graph_of(c, graph)
	if g == nil { return 0 }
	pcm := webaudio.offline_take_result(g)
	return pcm != nil ? pcm_object(c.page, pcm, c.owner) : 0
}

// A host object of a buffer (takes the reference). 0, the reference released, past the page's ceiling.
@(private = "file")
pcm_object :: proc(p: ^Page, pcm: ^webaudio.Pcm, owner: u32) -> u64 {
	bytes := webaudio.pcm_bytes(pcm.channels, pcm.length)
	if p.held + bytes > p.settings.max_fetch_bytes {
		webaudio.pcm_release(pcm)
		return 0
	}
	p.held += bytes
	b := new(Web_Audio_Pcm)
	b.pcm = pcm
	return object_create(p, &pcm_vt, b, owner)
}

WebAudio_offlineSuspend :: proc(c: ^Call, graph: u64, frame: f64) -> bool {
	g := graph_of(c, graph)
	return g != nil && webaudio.offline_add_suspend(g, i64(frame))
}

WebAudio_offlineResume :: proc(c: ^Call, graph: u64) {
	if g := graph_of(c, graph); g != nil { webaudio.offline_resume(g) }
}

WebAudio_nodeCreate :: proc(c: ^Call, graph: u64, kind: i32, first, second: f64) -> i32 {
	g := graph_of(c, graph)
	if g == nil || kind < 0 || kind > i32(max(webaudio.Kind)) { return -1 }
	return webaudio.node_create(g, webaudio.Kind(kind), first, second)
}

WebAudio_nodeRelease :: proc(c: ^Call, graph: u64, node: i32) {
	if g := graph_of(c, graph); g != nil { webaudio.node_release(g, node) }
}

WebAudio_connect :: proc(c: ^Call, graph: u64, from, output, to, input: i32, param: bool) -> bool {
	g := graph_of(c, graph)
	if g == nil || output < 0 || input < 0 { return false }
	if param { return webaudio.connect_param(g, from, int(output), to, int(input)) }
	return webaudio.connect(g, from, int(output), to, int(input))
}

WebAudio_disconnect :: proc(c: ^Call, graph: u64, from, output, to, input: i32, param: bool) -> i32 {
	g := graph_of(c, graph)
	return g != nil ? i32(webaudio.disconnect(g, from, int(output), to, int(input), param)) : 0
}

WebAudio_nodeSet :: proc(c: ^Call, graph: u64, node, field: i32, value: f64) {
	g := graph_of(c, graph)
	if g == nil || field < 0 || field > i32(max(webaudio.Field)) { return }
	webaudio.node_set(g, node, webaudio.Field(field), value)
}

WebAudio_nodeGet :: proc(c: ^Call, graph: u64, node, field: i32) -> f64 {
	g := graph_of(c, graph)
	if g == nil || field < 0 || field > i32(max(webaudio.Field)) { return 0 }
	return webaudio.node_get(g, node, webaudio.Field(field))
}

WebAudio_start :: proc(c: ^Call, graph: u64, node: i32, at, offset, duration: f64) {
	if g := graph_of(c, graph); g != nil { webaudio.node_start(g, node, at, offset, duration) }
}

WebAudio_stop :: proc(c: ^Call, graph: u64, node: i32, at: f64) {
	if g := graph_of(c, graph); g != nil { webaudio.node_stop(g, node, at) }
}

WebAudio_setBuffer :: proc(c: ^Call, graph: u64, node: i32, pcm: u64) {
	if g := graph_of(c, graph); g != nil { webaudio.node_set_buffer(g, node, pcm_of(c, pcm)) }
}

WebAudio_setConvolver :: proc(c: ^Call, graph: u64, node: i32, pcm: u64, normalize: bool) {
	if g := graph_of(c, graph); g != nil { webaudio.convolver_set(g, node, pcm_of(c, pcm), normalize, c.page.settings.webaudio.max_convolver_seconds) }
}

WebAudio_setCurve :: proc(c: ^Call, graph: u64, node: i32, curve: []u8) {
	if g := graph_of(c, graph); g != nil { webaudio.shaper_set_curve(g, node, floats(curve)) }
}

WebAudio_setWave :: proc(c: ^Call, graph: u64, node: i32, real, imag: []u8, normalize: bool) {
	if g := graph_of(c, graph); g != nil { webaudio.node_set_wave(g, node, webaudio.wave_new(floats(real), floats(imag), normalize)) }
}

WebAudio_paramGet :: proc(c: ^Call, graph: u64, node, index: i32) -> f64 {
	g := graph_of(c, graph)
	return g != nil ? webaudio.param_get(g, node, int(index)) : 0
}

WebAudio_paramSet :: proc(c: ^Call, graph: u64, node, index: i32, value: f64) -> bool {
	g := graph_of(c, graph)
	return g == nil || webaudio.param_set_value(g, node, int(index), f32(value))
}

WebAudio_paramRate :: proc(c: ^Call, graph: u64, node, index: i32, a_rate: bool) {
	if g := graph_of(c, graph); g != nil { webaudio.param_set_rate(g, node, int(index), a_rate) }
}

WebAudio_paramEvent :: proc(c: ^Call, graph: u64, node, index, kind: i32, time, value, extra: f64, curve: []u8) -> bool {
	g := graph_of(c, graph)
	if g == nil || kind < 0 || kind > i32(max(webaudio.Event_Kind)) { return true }
	return webaudio.param_add_event(g, node, int(index), webaudio.Event_Kind(kind), time, f32(value), extra, floats(curve))
}

WebAudio_paramCancel :: proc(c: ^Call, graph: u64, node, index: i32, time: f64, hold: bool) {
	if g := graph_of(c, graph); g != nil { webaudio.param_cancel_events(g, node, int(index), time, hold) }
}

WebAudio_biquadResponse :: proc(c: ^Call, graph: u64, node: i32, frequencies, magnitude, phase: []u8) {
	g := graph_of(c, graph)
	if g == nil || len(magnitude) < len(frequencies) || len(phase) < len(frequencies) { return }
	webaudio.biquad_frequency_response(g, node, floats(frequencies), floats(magnitude), floats(phase))
}

WebAudio_analyserRead :: proc(c: ^Call, graph: u64, node, what: i32, values: []u8) -> i32 {
	g := graph_of(c, graph)
	if g == nil || what < 0 || what > i32(max(webaudio.Analyser_Read)) { return 0 }
	return i32(webaudio.analyser_read(g, node, webaudio.Analyser_Read(what), values))
}

WebAudio_scriptPull :: proc(c: ^Call, graph: u64, node: i32, values: []u8) {
	if g := graph_of(c, graph); g != nil { webaudio.script_pull(g, node, values) }
}

WebAudio_scriptPush :: proc(c: ^Call, graph: u64, node: i32, values: []u8) {
	if g := graph_of(c, graph); g != nil { webaudio.script_push(g, node, values) }
}

WebAudio_pcmCreate :: proc(c: ^Call, channels, length: u32, rate: f64) -> u64 {
	p := c.page
	if channels == 0 || channels > webaudio.MAX_CHANNELS || length == 0 || !(rate >= webaudio.MIN_SAMPLE_RATE && rate <= webaudio.MAX_SAMPLE_RATE) { return 0 }
	if webaudio.pcm_bytes(int(channels), int(length)) > p.settings.webaudio.max_buffer_bytes { return 0 }
	return pcm_object(p, webaudio.pcm_new(int(channels), int(length), rate), c.owner)
}

// A graph may be playing the samples (it holds a reference): they are copied before they change.
WebAudio_pcmWrite :: proc(c: ^Call, pcm: u64, channel, start: u32, values: []u8) {
	b := (^Web_Audio_Pcm)(object_data(c.page, pcm, &pcm_vt))
	if b == nil || int(channel) >= b.pcm.channels || int(start) >= b.pcm.length { return }
	dst := webaudio.pcm_channel(b.pcm, int(channel))[start:]
	src := floats(values)
	n := min(len(src), len(dst))
	if mem.compare_ptrs(raw_data(dst), raw_data(src), n * size_of(f32)) == 0 { return }
	if webaudio.pcm_shared(b.pcm) {
		copied := webaudio.pcm_new(b.pcm.channels, b.pcm.length, b.pcm.rate)
		copy(copied.samples, b.pcm.samples)
		webaudio.pcm_release(b.pcm)
		b.pcm = copied
		dst = webaudio.pcm_channel(b.pcm, int(channel))[start:]
	}
	copy(dst[:n], src[:n])
}

WebAudio_pcmRead :: proc(c: ^Call, pcm: u64, channel, start: u32, values: []u8) {
	b := pcm_of(c, pcm)
	if b == nil || int(channel) >= b.channels || int(start) >= b.length { return }
	src := webaudio.pcm_channel(b, int(channel))[start:]
	dst := floats(values)
	copy(dst[:min(len(dst), len(src))], src)
}

WebAudio_pcmInfo :: proc(c: ^Call, pcm: u64, which: i32) -> f64 {
	b := pcm_of(c, pcm)
	if b == nil { return 0 }
	switch which {
	case 0: return f64(b.channels)
	case 1: return f64(b.length)
	case 2: return b.rate
	}
	return 0
}

@(private = "file")
Decode_Job :: struct {
	page_id: u64,
	promise: u64,
	owner:   u32,
	data:    []u8,
	rate:    f64,
	result:  ^webaudio.Pcm,
	max_bytes: int,
}

WebAudio_decode :: proc(c: ^Call, data: []u8, rate: f64) -> u64 {
	if !(rate >= webaudio.MIN_SAMPLE_RATE && rate <= webaudio.MAX_SAMPLE_RATE) { return 0 }
	p := c.page
	pr := promise_create(p, c.owner)
	j := new(Decode_Job, base.process_allocator())
	j^ = Decode_Job{page_id = page_id(p), promise = pr, owner = c.owner, rate = rate, max_bytes = p.settings.webaudio.max_buffer_bytes}
	j.data = make([]u8, len(data), base.process_allocator())
	copy(j.data, data)
	work :: proc(d: rawptr) {
		j := (^Decode_Job)(d)
		j.result = webaudio.decode_audio(j.data, j.rate, j.max_bytes)
	}
	if p.loader != nil && p.loader.blocking != nil {
		host.run_blocking(p.loader.blocking, work, proc(d: rawptr) { decode_done((^Decode_Job)(d)) }, j)
	} else {
		// (no pool, a test: the promise still settles from a task)
		work(j)
		post_page_task(p, proc(pg: ^Page, d: rawptr) { decode_done((^Decode_Job)(d)) }, j)
	}
	return pr
}

@(private = "file")
decode_done :: proc(j: ^Decode_Job) {
	defer {
		delete(j.data, base.process_allocator())
		free(j, base.process_allocator())
	}
	p := page_by_id(j.page_id)
	if p == nil || p.closed { webaudio.pcm_release(j.result); return }
	if j.result == nil {
		promise_reject(p, j.promise, i64(Api_Error.Encoding), "EncodingError: unable to decode audio data")
		return
	}
	h := pcm_object(p, j.result, j.owner)
	if h == 0 {
		promise_reject(p, j.promise, i64(Api_Error.Quota), "QuotaExceededError: the decoded audio is too large")
		return
	}
	promise_resolve_object(p, j.promise, h)
}

// createMediaElementSource: the element's player sends what it plays to the node instead of the speakers.
WebAudio_captureElement :: proc(c: ^Call, graph: u64, node: i32, element: Api_Element) -> bool {
	p := c.page
	a := (^Web_Audio_Graph)(object_data(p, graph, &graph_vt))
	if a == nil || p.media == nil { return false }
	el := p.media.elements[base.Handle(element.handle)]
	if el == nil { return false }
	web_audio_capture(el, a, node)
	return true
}

// The tap of a media element into a graph.
Web_Audio_Capture :: struct {
	graph: ^webaudio.Graph,
	node:  i32,
}

@(private = "file")
capture_sink :: proc(user: rawptr, samples: []f32, rate: int) {
	cap := (^Web_Audio_Capture)(user)
	webaudio.element_push(cap.graph, cap.node, samples, f64(rate))
}

@(private)
web_audio_capture :: proc(el: ^Media_Element, a: ^Web_Audio_Graph, node: i32) {
	cap := new(Web_Audio_Capture, base.process_allocator())
	cap^ = Web_Audio_Capture{a.g, node}
	if el.capture != nil { free(el.capture, base.process_allocator()) }
	el.capture = cap
	media_capture_apply(el)
}

@(private)
media_capture_apply :: proc(el: ^Media_Element) {
	if el.player != nil && el.capture != nil { media.player_set_capture(el.player, capture_sink, el.capture) }
}

// ---- AudioWorklet: the page's side of a realm that is a JavaScript worker (js_workers.odin) with its own global scope (the
// engine's web_audio_worklet.js), and of the requests of each quantum (src/webaudio/worklet.odin) ----

@(private = "file")
worklet_realm_stop :: proc(p: ^Page, a: ^Web_Audio_Graph) {
	if a.worklet_realm == 0 { return }
	if h := (^Worker_Host)(object_data(p, a.worklet_realm, &worker_vt)); h != nil { worker_terminate(h) }
	a.worklet_realm = 0
}

@(private = "file")
WORKLET_SCRIPT := []byte{' '}   // (what makes worker_create start at once: web_audio_worklet.js sets the realm up, modules come by messages)

WebAudio_workletStart :: proc(c: ^Call, graph: u64) -> u64 {
	p := c.page
	a := (^Web_Audio_Graph)(object_data(p, graph, &graph_vt))
	if a == nil || a.worklet_realm != 0 { return 0 }
	w := webaudio.worklet_attach(a.g, time.Duration(p.settings.webaudio.worklet_stall_ms) * time.Millisecond)
	if w == nil { return 0 }
	defer webaudio.worklet_release(w)   // (the realm has one of its own)
	a.worklet_realm = worker_create(p, p.env.location.href, "audioworklet", c.owner, javascript = true, image = WORKLET_SCRIPT, worklet = w)
	return a.worklet_realm
}

WebAudio_workletStop :: proc(c: ^Call, graph: u64) {
	a := (^Web_Audio_Graph)(object_data(c.page, graph, &graph_vt))
	if a != nil { worklet_realm_stop(c.page, a) }
}

WebAudio_workletNode :: proc(c: ^Call, graph: u64, inputs, outputs, params, processor: i32, output_channels: []u8) -> i32 {
	g := graph_of(c, graph)
	if g == nil { return -1 }
	return webaudio.worklet_node_create(g, int(inputs), int(outputs), int(params), processor, mem.slice_data_cast([]i32, output_channels))
}

WebAudio_workletParam :: proc(c: ^Call, graph: u64, node, index: i32, default_value, min_value, max_value: f64, a_rate: bool) {
	if g := graph_of(c, graph); g != nil { webaudio.worklet_param_init(g, node, int(index), f32(default_value), f32(min_value), f32(max_value), a_rate) }
}

@(private = "file")
realm_worklet :: proc(c: ^Call) -> ^webaudio.Worklet {
	g := c.page.worker
	return g != nil ? g.worklet : nil
}

AudioWorkletRealm_sampleRate :: proc(c: ^Call) -> f64 {
	w := realm_worklet(c)
	return w != nil ? w.rate : 0
}

AudioWorkletRealm_frame :: proc(c: ^Call) -> f64 {
	w := realm_worklet(c)
	return w != nil ? f64(webaudio.worklet_frame(w)) : 0
}

AudioWorkletRealm_layout :: proc(c: ^Call, layout: []u8) -> i32 {
	w := realm_worklet(c)
	if w == nil { return 0 }
	return i32(webaudio.worklet_layout(w, mem.slice_data_cast([]i32, layout)))
}

AudioWorkletRealm_read :: proc(c: ^Call, at: i32, values: []u8) {
	if w := realm_worklet(c); w != nil { webaudio.worklet_read(w, int(at), floats(values)) }
}

AudioWorkletRealm_write :: proc(c: ^Call, at: i32, values: []u8) {
	if w := realm_worklet(c); w != nil { webaudio.worklet_write(w, int(at), floats(values)) }
}

AudioWorkletRealm_finish :: proc(c: ^Call, status: i32) {
	if w := realm_worklet(c); w != nil && status >= 0 && status < i32(webaudio.Worklet_Status.None) { webaudio.worklet_finish(w, webaudio.Worklet_Status(status)) }
}

AudioWorkletRealm_dropped :: proc(c: ^Call) -> i32 {
	w := realm_worklet(c)
	return w != nil ? webaudio.worklet_take_dropped(w) : -1
}

// The realm's thread: what the render thread asked for, between its other tasks. A quantum goes into the realm's JavaScript
// (wj_worklet_quantum), which calls back for the samples. A trap there ends the realm: its nodes hear of it from the render thread.
worklet_realm_poll :: proc(p: ^Page, g: ^Worker_Global) {
	w := g.worklet
	r := p.js
	if r == nil || r.failed || r.inst == nil || r.inst.dead {
		sync.atomic_store(&g.link.stop, true)
		return
	}
	for {
		// (the specification: the realm's microtasks run once all its processors of a quantum have, before the next quantum)
		if webaudio.worklet_take_checkpoint(w) { microtask_checkpoint(p) }
		if !webaudio.worklet_has_work(w) { return }
		if realm_halted(p) { return }
		webaudio.worklet_take(w)
		// (draining: the checkpoint at the end of this call waits for the end of the quantum)
		p.objects.draining = true
		res := js_call(p, r.inst, "wj_worklet_quantum", nil)
		p.objects.draining = false
		webaudio.worklet_finish(w, .Failed)   // (no answer from JavaScript: it did not get that far)
		if res != .Ok {
			sync.atomic_store(&g.link.stop, true)
			return
		}
		free_all(context.temp_allocator)
	}
}

WebAudio_setIir :: proc(c: ^Call, graph: u64, node: i32, feedforward, feedback: []u8) {
	if g := graph_of(c, graph); g != nil { webaudio.iir_set(g, node, mem.slice_data_cast([]f64, feedforward), mem.slice_data_cast([]f64, feedback)) }
}

WebAudio_iirResponse :: proc(c: ^Call, graph: u64, node: i32, frequencies, magnitude, phase: []u8) {
	g := graph_of(c, graph)
	if g == nil || len(magnitude) < len(frequencies) || len(phase) < len(frequencies) { return }
	webaudio.iir_frequency_response(g, node, floats(frequencies), floats(magnitude), floats(phase))
}

// The nodes of the page's AudioContexts that are in their graphs (for the tests: what a collected object leaves behind).
web_audio_live_nodes :: proc(p: ^Page) -> int {
	if p.media == nil { return 0 }
	n := 0
	for a in p.media.audio_graphs { n += webaudio.live_nodes(a.g) }
	return n
}
