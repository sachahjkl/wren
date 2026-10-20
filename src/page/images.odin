package page

// Images of pages: <img> (and <input type=image>) with src, srcset / sizes and <picture> / <source>, loading=lazy, and
// the URLs of CSS background images. Three layers:
//
//   * the process image cache (UI thread only): one Cache_Entry per (top-level site, CORS mode, URL), holding the
//     encoded file, what its header says, and its decoded pixels. Decoding happens on the threads of package images;
//     entries are kept in least-recently-shown order within images.cache.max_bytes: pixels go first (decoded again
//     when shown), then files no page uses. Partitioning by top-level site keeps one site from learning, through an
//     image's size, what another site's cookies fetched;
//   * requests of a page (Img_Request): one per cache key, whatever the number of elements or CSS rules that use it (a
//     page asks the network once per image). Requests go through fetch.start with destination Image (CSP img-src,
//     mixed content, credentials), no-cors unless the element has crossorigin, at most images.max_parallel_loads at a
//     time, nearest the viewport first. A page may take an entry another page already downloaded when its own
//     Content-Security-Policy allows the URL (images.cache.share_between_pages);
//   * elements (Img_Element): the HTML "update the image data" steps, simplified: source selection, the current and
//     pending requests, load / error events as tasks, complete / naturalWidth / currentSrc, decode() promises.
//
// The shell asks for natural sizes (layout), pixels of the current frame (painting) and reports where elements are
// relative to the viewport (lazy loading, priorities). See the "Shell" section at the end.

import "core:fmt"
import "core:slice"
import "core:strconv"
import "core:strings"
import "wb:base"
import "wb:csp"
import "wb:css"
import "wb:dom"
import "wb:fetch"
import "wb:host"
import "wb:http"
import "wb:images"
import "wb:style"
import "wb:url"

////////////////////////////////
// Process image cache

Entry_State :: enum u8 { Probing, Ready, Broken }

Cache_Entry :: struct {
	id:         u64,              // never reused: the painter's texture key
	key:        string,           // owned
	url:        string,           // owned: what was asked for
	final_url:  string,           // owned: after redirects
	redirected: bool,
	opaque:     bool,             // a no-cors cross-origin answer: shown, never readable by scripts
	mime:       string,           // owned: Content-Type essence
	nosniff:    bool,
	blob:       ^images.Blob,     // the encoded file; nil once dropped
	state:      Entry_State,
	info:       images.Info,
	err:        images.Error,
	image:      ^images.Image,    // decoded pixels (maybe at a reduced size); nil when not decoded or dropped
	generation: u64,              // changes whenever `image` changes
	probe:      ^images.Job,
	decode:     ^images.Job,
	decode_w, decode_h: int,      // what the running decode targets (0 = natural size)
	want_full:  bool,             // decode() asked for the natural size
	requests:   [dynamic]^Img_Request,   // the page requests that hold it
	in_map:     bool,             // still the entry of its key (a newer download of the key may replace it)
	last_shown: u64,              // paint epoch it was last drawn in
	anim_start: f64,              // loop ms when its animation started (first shown); < 0 = not started
	accounted:  int,              // bytes counted in the cache's total
	// SVG: no decoded image, rasters at the sizes it is shown at instead (each its own texture), made one at a time
	rasters:    [dynamic]Svg_Raster,
	raster_job: ^images.Job,
	raster_w, raster_h: int,
}

Svg_Raster :: struct {
	id:         u64,              // never reused: the painter's texture key
	w, h:       int,              // device pixels
	image:      ^images.Image,
	last_shown: u64,
}

@(private)
entry_is_svg :: proc(e: ^Cache_Entry) -> bool { return e.state == .Ready && e.info.format == .Svg }

Image_Cache :: struct {
	ready:     bool,
	loop:      ^host.Loop,
	port:      images.Port_Id,
	entries:   map[string]^Cache_Entry,
	by_id:     map[u64]^Cache_Entry,
	next_id:   u64,
	bytes:     int,
	limit:     int,
	epoch:     u64,               // paint epoch: entries shown in the current one are not evicted
	evicted:   [dynamic]u64,      // ids whose pixels were dropped or whose entry died: the painter frees their textures
	settings:  images.Settings,   // the last settings seen (decode options of the cache's own jobs)
}

@(private)
cache: Image_Cache

@(private)
cache_init :: proc(p: ^Page) -> bool {
	if cache.ready { return true }
	if p.worker != nil { return false }
	s := &p.settings.images
	decoder_ensure(s)
	cache.loop = p.loop
	cache.port = images.port_open(p.loop, cache_job_done, nil)
	if cache.port == 0 { return false }
	cache.entries = make(map[string]^Cache_Entry)
	cache.by_id = make(map[u64]^Cache_Entry)
	cache.evicted = make([dynamic]u64)
	cache.settings, cache.limit = p.settings.images, p.settings.images.cache_max_bytes
	cache.ready = true
	return true
}

@(private)
decoder_ensure :: proc(s: ^images.Settings) {
	if images.decoder_running() { return }
	n := s.decode_threads
	if n < 0 { n = clamp(host.processor_count() / 2, 1, 4) }
	images.decoder_start(n, s.decode_stack_bytes > 0 ? s.decode_stack_bytes : images.DECODER_STACK_DEFAULT)
}

// Frees the process cache and stops the decoding threads. Call once every page is closed, before exiting.
images_shutdown :: proc() {
	if cache.ready {
		images.port_close(cache.port)
		for _, e in cache.by_id { entry_free(e) }
		delete(cache.entries)
		delete(cache.by_id)
		delete(cache.evicted)
		cache = {}
	}
	images.decoder_stop()
}

@(private)
entry_free :: proc(e: ^Cache_Entry) {
	if e.probe != nil { images.job_cancel(e.probe) }
	if e.decode != nil { images.job_cancel(e.decode) }
	if e.raster_job != nil { images.job_cancel(e.raster_job) }
	for r in e.rasters { images.image_destroy(r.image) }
	delete(e.rasters)
	images.blob_release(e.blob)
	images.image_destroy(e.image)
	delete(e.key); delete(e.url); delete(e.final_url); delete(e.mime)
	delete(e.requests)
	free(e)
}

@(private)
entry_bytes :: proc(e: ^Cache_Entry) -> int {
	n := 0
	if e.blob != nil { n += len(e.blob.bytes) }
	if e.image != nil { n += e.image.bytes }
	for r in e.rasters { n += r.image.bytes }
	return n
}

@(private)
entry_account :: proc(e: ^Cache_Entry) {
	n := entry_bytes(e)
	cache.bytes += n - e.accounted
	e.accounted = n
}

@(private)
decode_options :: proc(s: ^images.Settings, e: ^Cache_Entry) -> images.Decode_Options {
	return images.Decode_Options{
		limits = s.limits, downscale_below = s.downscale ? s.downscale_below : 0, first_frame_only = !s.animate,
		allow_truncated = s.allow_truncated, mime = e.mime, nosniff = e.nosniff,
	}
}

// Drops the entry from the cache's index; it is freed now if no request holds it, else when the last one lets go.
@(private)
entry_unmap :: proc(e: ^Cache_Entry) {
	if !e.in_map { return }
	e.in_map = false
	if cache.entries[e.key] == e { delete_key(&cache.entries, e.key) }
}

@(private)
entry_release :: proc(e: ^Cache_Entry, r: ^Img_Request) {
	for x, i in e.requests { if x == r { unordered_remove(&e.requests, i); break } }
	if len(e.requests) == 0 && !e.in_map { entry_destroy(e) }
	if len(e.requests) == 0 { cache_enforce() }
}

@(private)
entry_destroy :: proc(e: ^Cache_Entry) {
	cache.bytes -= e.accounted
	delete_key(&cache.by_id, e.id)
	append(&cache.evicted, e.id)
	for r in e.rasters { append(&cache.evicted, r.id) }
	entry_free(e)
}

// Least recently shown first: pixels not shown in the current paint epoch, then files of entries nobody holds.
@(private)
cache_enforce :: proc() {
	if !cache.ready || cache.bytes <= cache.limit { return }
	list := make([dynamic]^Cache_Entry, 0, len(cache.by_id), context.temp_allocator)
	for _, e in cache.by_id { append(&list, e) }
	slice.sort_by(list[:], proc(a, b: ^Cache_Entry) -> bool { return a.last_shown < b.last_shown })
	for e in list {
		if cache.bytes <= cache.limit { return }
		if len(e.rasters) > 0 { svg_drop_rasters(e, true) }
		if e.image == nil || e.last_shown == cache.epoch || e.decode != nil { continue }
		images.image_destroy(e.image)
		e.image = nil
		e.generation += 1
		append(&cache.evicted, e.id)
		entry_account(e)
	}
	for e in list {
		if cache.bytes <= cache.limit { return }
		if len(e.requests) > 0 { continue }
		entry_unmap(e)
		entry_destroy(e)
	}
}

@(private)
cache_job_done :: proc(user: rawptr, j: ^images.Job) {
	e := (^Cache_Entry)(j.user)
	defer images.job_free(j)
	if j.kind == .Probe {
		e.probe = nil
		e.info, e.err = j.info, j.err
		e.state = j.err == .None ? .Ready : .Broken
		entry_notify(e, true)
		return
	}
	if j == e.raster_job {
		e.raster_job = nil
		svg_raster_done(e, j)
		return
	}
	e.decode = nil
	if j.err != .None {
		e.err = j.err
		e.state = .Broken
		entry_notify(e, true)
		return
	}
	images.image_destroy(e.image)
	e.image = j.image
	j.image = nil
	e.generation += 1
	entry_account(e)
	entry_notify(e, false)
	cache_enforce()
}

@(private)
loop_ms :: proc() -> f64 { return cache.loop != nil ? f64(host.now_ns(cache.loop)) / 1e6 : 0 }

// The requests holding `e` (on any page) hear that it settled (`state`) or that pixels arrived.
@(private)
entry_notify :: proc(e: ^Cache_Entry, state: bool) {
	held := slice.clone(e.requests[:], context.temp_allocator)
	for r in held {
		if state { r.state = e.state == .Ready ? .Ready : .Broken }
		if e.state == .Broken && r.error == "" { r.error = strings.clone(images.error_message(e.err)) }
		request_settled(r)
	}
}

// Starts decoding at a size, unless a decode at least that large is running or done.
@(private)
entry_want_pixels :: proc(e: ^Cache_Entry, w, h: int, priority: i32) {
	if e.state != .Ready || e.blob == nil { return }
	s := &cache.settings
	tw, th := w, h
	if e.want_full || e.info.animated || !s.downscale { tw, th = 0, 0 }
	if tw > 0 && th > 0 {
		rw, rh, reduced := images.reduced_size(e.info.width, e.info.height, tw, th, s.downscale_below)
		if !reduced { tw, th = 0, 0 } else { tw, th = rw, rh }
	}
	enough :: proc(have_w, have_h, natural_w, tw, th: int) -> bool {
		if tw == 0 { return have_w >= natural_w }
		return have_w >= tw && have_h >= th
	}
	if e.image != nil && enough(e.image.width, e.image.height, e.info.width, tw, th) { return }
	if e.decode != nil {
		if enough(e.decode_w == 0 ? e.info.width : e.decode_w, e.decode_h == 0 ? e.info.height : e.decode_h, e.info.width, tw, th) {
			images.job_set_priority(e.decode, priority)
			return
		}
		images.job_cancel(e.decode)
		e.decode = nil
	}
	o := decode_options(s, e)
	o.target_w, o.target_h = tw, th
	j := images.job_make(.Decode, e.blob, o, priority, e)
	e.decode, e.decode_w, e.decode_h = j, tw, th
	if !images.submit(cache.port, j) { e.decode = nil }
}

////////////////////////////////
// Requests of a page

Request_State :: enum u8 { Queued, Loading, Probing, Ready, Broken }

Img_Request :: struct {
	page:     ^Page,
	key:      string,          // owned: the cache key
	url:      string,          // owned: absolute
	mode:     fetch.Mode,
	credentials: fetch.Credentials,
	nonce:    string,          // owned
	task:     base.Handle,
	state:    Request_State,
	entry:    ^Cache_Entry,
	refs:     int,             // elements and CSS uses
	error:    string,          // owned
	distance: f32,             // from the viewport, CSS px (priority); max = unknown
	css:      bool,
	bad_status: bool,
	status:   int,
	shared:   bool,            // taken from the cache, not downloaded by this page
	// from the response, for the cache entry made when the body is complete
	final_url:  string,        // owned
	redirected: bool,
	opaque:     bool,
	mime:       string,        // owned
	nosniff:    bool,
}

// What an element shows: a request chosen by source selection, with the density of the candidate.
Img_Element :: struct {
	node:        base.Handle,
	signature:   string,          // owned: what the last selection depended on
	current:     ^Img_Request,
	pending:     ^Img_Request,
	current_url: string,          // owned (currentSrc)
	pending_url: string,          // owned
	density:     f32,
	pending_density: f32,
	lazy_wait:   bool,            // loading=lazy and not near the viewport: the selection waits (lazy_* below)
	lazy_url:    string,          // owned
	lazy_density: f32,
	lazy_mode:   fetch.Mode,
	lazy_cred:   fetch.Credentials,
	broken_empty: bool,           // src="" (or an invalid URL): broken without a request
	notified:    bool,            // the load / error event of the current request is queued
	distance:    f32,             // from the viewport (CSS px), max = unknown
	seen:        u64,             // sync pass that saw it in the tree
	held:        bool,            // a script touched it: kept up to date even outside the tree
	decodes:     [dynamic]u64,    // decode() promises waiting
}

Pending_Image_Event :: struct { node: base.Handle, type: string }

Guest_Decode :: struct { job: ^images.Job, promise: u64, owner: u32 }

Page_Images :: struct {
	ready:      bool,
	doc:        ^dom.Document,          // the tree the element handles belong to
	elements:   map[base.Handle]^Img_Element,
	requests:   map[string]^Img_Request,
	queue:      [dynamic]^Img_Request,  // waiting for a download slot
	loading:    int,
	css_urls:   map[string]^Img_Request,   // CSS image URL as written -> request
	css_bases:  map[string]string,      // URL as written -> the base of the sheet that declares it
	css_rebuilds: u64,
	css_serial: u64,
	mutations:  u64,
	env:        css.Media_Env,          // what the last selection saw
	pass:       u64,
	sizes:      u64,                    // changes when a natural size changes: the layout is stale
	pixels:     u64,                    // changes when pixels of an image of this page arrive: repaint
	events:     [dynamic]Pending_Image_Event,
	event_timer: base.Handle,
	port:       images.Port_Id,         // Image_decode of scripts (on this page's loop: a worker's own)
	guest:      [dynamic]Guest_Decode,
	started:    int,                    // downloads started (statistics, tests)
	shared:     int,                    // entries taken from the cache
	svgs:       map[base.Handle]^Inline_Svg,   // inline <svg> elements drawn so far (inline_svg.odin)
	svg_ids:    map[string]base.Handle, // id -> element, for the references of inline <svg> (rebuilt on mutation)
	svg_ids_at: u64,
}

// A process-unique counter, so that generations of different pages never compare equal by accident.
@(private)
image_serial: u64

@(private)
next_serial :: proc() -> u64 { image_serial += 1; return image_serial }

@(private)
images_init :: proc(p: ^Page) {
	if p.images.ready { return }
	pi := &p.images
	pi.ready = true
	pi.elements = make(map[base.Handle]^Img_Element)
	pi.requests = make(map[string]^Img_Request)
	pi.queue = make([dynamic]^Img_Request)
	pi.css_urls = make(map[string]^Img_Request)
	pi.css_bases = make(map[string]string)
	pi.events = make([dynamic]Pending_Image_Event)
	pi.guest = make([dynamic]Guest_Decode)
	pi.sizes = next_serial()
}

@(private)
images_destroy :: proc(p: ^Page) {
	pi := &p.images
	if !pi.ready { return }
	if pi.port != 0 { images.port_close(pi.port) }   // disposes of the guest decodes still running
	delete(pi.guest)
	inline_svgs_destroy(p)
	// every request is in `requests`: elements and CSS uses only point at them
	for _, el in pi.elements { element_free(p, el, false) }
	delete(pi.elements)
	for k in pi.css_urls { delete(k) }
	delete(pi.css_urls)
	for k, v in pi.css_bases { delete(k); delete(v) }
	delete(pi.css_bases)
	for _, r in pi.requests { request_free(r) }
	delete(pi.requests)
	delete(pi.queue)
	for ev in pi.events { delete(ev.type) }
	delete(pi.events)
	pi^ = {}
}

@(private)
request_free :: proc(r: ^Img_Request) {
	p := r.page
	if r.task != base.NIL_HANDLE { fetch.cancel(p.loader, r.task); r.task = base.NIL_HANDLE }
	if r.entry != nil { entry_release(r.entry, r) }
	delete(r.key); delete(r.url); delete(r.error); delete(r.nonce); delete(r.final_url); delete(r.mime)
	free(r)
}

// One user fewer; the request goes when the last one does (its download is cancelled).
@(private)
request_release :: proc(r: ^Img_Request) {
	if r == nil { return }
	r.refs -= 1
	if r.refs > 0 { return }
	p := r.page
	if r.state == .Loading { p.images.loading -= 1 }
	for x, i in p.images.queue { if x == r { ordered_remove(&p.images.queue, i); break } }
	delete_key(&p.images.requests, r.key)
	request_free(r)
	images_pump(p)
}

@(private)
site_key :: proc(p: ^Page) -> string {
	s := p.env.top_level_site
	if s.opaque { return fmt.tprintf("opaque-%d", s.nonce) }
	return fmt.tprintf("%s://%s", s.scheme, s.domain)
}

@(private)
cache_key :: proc(p: ^Page, abs: string, mode: fetch.Mode, cred: fetch.Credentials) -> string {
	if mode == .Cors {
		o := url.origin_serialize(p.env.origin, context.temp_allocator)
		return fmt.tprintf("%s|%s:%s|%s", site_key(p), cred == .Include ? "u" : "a", o, abs)
	}
	return fmt.tprintf("%s|n|%s", site_key(p), abs)
}

// May this page show an entry another page downloaded, without asking the network? Its own policy decides, as the
// fetch layer would have: CSP img-src for the URL and every redirect target; nothing insecure on a secure page (the
// fetch layer would upgrade or block it); never file: URLs (each document has its own file root).
@(private)
can_share :: proc(p: ^Page, e: ^Cache_Entry) -> bool {
	if !p.settings.images.share_cache || e.state == .Broken { return false }
	u, ok := url.parse_absolute(e.url, context.temp_allocator)
	if !ok { return false }
	switch u.scheme {
	case "https", "data":
	case "http": if p.env.secure_context && !url.is_potentially_trustworthy(u) { return false }
	case: return false
	}
	if len(p.env.policies.policies) > 0 {
		if !csp.check_request(&p.env.policies, .Img_Src, u, p.env.origin).allowed { return false }
		if e.redirected {
			f, fok := url.parse_absolute(e.final_url, context.temp_allocator)
			if !fok || !csp.check_request(&p.env.policies, .Img_Src, f, p.env.origin, true).allowed { return false }
		}
	}
	return true
}

// The page's request for an image, made if needed (deduplicated by cache key). One more user.
@(private)
page_request :: proc(p: ^Page, abs: string, mode: fetch.Mode, cred: fetch.Credentials, css_image: bool, nonce := "") -> ^Img_Request {
	key := cache_key(p, abs, mode, cred)
	if r, ok := p.images.requests[key]; ok { r.refs += 1; return r }
	r := new(Img_Request)
	r.page, r.key, r.url, r.mode, r.credentials, r.css = p, strings.clone(key), strings.clone(abs), mode, cred, css_image
	r.nonce = strings.clone(nonce)
	r.refs = 1
	r.distance = max(f32)
	p.images.requests[r.key] = r
	if !p.settings.images.enabled {
		r.state, r.error = .Broken, strings.clone("images are disabled (images.enabled)")
		return r
	}
	if len(p.images.requests) > p.settings.images.max_per_page {
		r.state, r.error = .Broken, strings.clone("too many images on this page (images.max_per_page)")
		return r
	}
	if !cache_init(p) {
		r.state, r.error = .Broken, strings.clone("the image decoder is unavailable")
		return r
	}
	if e, ok := cache.entries[key]; ok && can_share(p, e) {
		r.entry = e
		append(&e.requests, r)
		r.shared = true
		p.images.shared += 1
		r.state = e.state == .Ready ? .Ready : (e.state == .Broken ? .Broken : .Probing)
		return r
	}
	r.state = .Queued
	append(&p.images.queue, r)
	return r
}

// Starts queued downloads up to the page's limit, nearest the viewport first.
@(private)
images_pump :: proc(p: ^Page) {
	pi := &p.images
	if p.closed { return }
	limit := max(p.settings.images.max_parallel, 1)
	for pi.loading < limit && len(pi.queue) > 0 {
		best := 0
		for r, i in pi.queue { if r.distance < pi.queue[best].distance { best = i } }
		r := pi.queue[best]
		ordered_remove(&pi.queue, best)
		r.state = .Loading
		pi.loading += 1
		pi.started += 1
		r.task = fetch.start(p.loader, {
			request = {
				url = r.url, mode = r.mode, credentials = r.credentials, destination = .Image, initiator = &p.env,
				max_body = p.settings.images.limits.max_encoded_bytes, nonce = r.nonce,
			},
			on_event = image_fetch_event, user = r, scope = p.scope, collect = true,
		})
	}
}

@(private)
image_fetch_event :: proc(user: rawptr, task: base.Handle, ev: ^fetch.Event) {
	r := (^Img_Request)(user)
	p := r.page
	switch ev.kind {
	case .Response:
		resp := ev.response
		r.status = resp.status
		if resp.type != .Opaque && (resp.status < 200 || resp.status >= 300) { r.bad_status = true }
		set_string(&r.final_url, resp.url)
		r.redirected = resp.redirected
		r.opaque = resp.type == .Opaque
		set_string(&r.mime, resp.has_mime ? http.mime_essence(resp.mime) : "")
		if v, ok := http.get_header(resp.headers, "x-content-type-options"); ok {
			r.nosniff = strings.has_prefix(strings.to_lower(strings.trim_space(v), context.temp_allocator), "nosniff")
		}
	case .Data:
	case .Failed:
		r.task = base.NIL_HANDLE
		p.images.loading -= 1
		request_fail(r, ev.detail)
		images_pump(p)
	case .Done:
		r.task = base.NIL_HANDLE
		p.images.loading -= 1
		defer images_pump(p)
		if r.bad_status { request_fail(r, fmt.tprintf("HTTP %d", r.status)); return }
		if len(ev.data) == 0 { request_fail(r, "empty response"); return }
		entry_start(p, r, ev.data)
	}
}

// A cache entry for the encoded bytes of `r` (copied; the response's metadata from `r`), replacing the entry of the
// same key; its header is probed on a decoding thread.
@(private)
entry_start :: proc(p: ^Page, r: ^Img_Request, data: []byte) {
	e := new(Cache_Entry)
	e.anim_start = -1
	e.final_url, e.redirected, e.opaque, e.mime, e.nosniff = strings.clone(r.final_url), r.redirected, r.opaque, strings.clone(r.mime), r.nosniff
	cache.next_id += 1
	e.id = cache.next_id
	e.key, e.url = strings.clone(r.key), strings.clone(r.url)
	e.blob = images.blob_make(slice.clone(data))
	e.state = .Probing
	cache.settings = p.settings.images
	cache.limit = p.settings.images.cache_max_bytes
	if old, ok := cache.entries[e.key]; ok { entry_unmap(old); if len(old.requests) == 0 { entry_destroy(old) } }
	cache.entries[e.key] = e
	cache.by_id[e.id] = e
	e.in_map = true
	append(&e.requests, r)
	r.entry = e
	r.state = .Probing
	entry_account(e)
	e.probe = images.job_make(.Probe, e.blob, decode_options(&cache.settings, e), 1 << 20, e)
	if !images.submit(cache.port, e.probe) {
		e.probe = nil
		e.state, e.err = .Broken, .Platform
		entry_notify(e, true)
	}
	cache_enforce()
}

@(private)
request_fail :: proc(r: ^Img_Request, why: string) {
	r.state = .Broken
	delete(r.error)
	r.error = strings.clone(why)
	log(r.page, .Warn, fmt.tprintf("image %s: %s", r.url, why))
	request_settled(r)
}

// A request changed state (or its pixels arrived): the elements showing it move on.
@(private)
request_settled :: proc(r: ^Img_Request) {
	p := r.page
	if p.closed { return }
	p.images.pixels = next_serial()
	if r.state == .Broken && r.entry != nil && r.error == "" { r.error = strings.clone(images.error_message(r.entry.err)) }
	for _, el in p.images.elements {
		if el.current == r || el.pending == r { element_settle(p, el) }
	}
}

////////////////////////////////
// Elements

@(private)
element_free :: proc(p: ^Page, el: ^Img_Element, live: bool) {
	for pr in el.decodes { if live { promise_reject(p, pr, WEB_ERR_ENCODING, "the image element went away") } }
	delete(el.decodes)
	if live {   // else the page is closing: its requests are freed with its table
		request_release(el.current)
		request_release(el.pending)
	}
	delete(el.signature); delete(el.current_url); delete(el.pending_url); delete(el.lazy_url)
	free(el)
}

@(private)
is_image_element :: proc(d: ^dom.Document, h: base.Handle) -> bool {
	n := dom.get(d, h)
	if n == nil || n.kind != .Element { return false }
	if n.name == "img" { return true }
	if n.name == "input" {
		t, _ := dom.get_attribute(d, h, "type")
		return strings.equal_fold(strings.trim_space(t), "image")
	}
	return false
}

// The element's record, made (and kept up to date even outside the tree) when a script asks about it.
@(private)
image_element :: proc(p: ^Page, h: base.Handle) -> ^Img_Element {
	images_init(p)
	images_adopt_document(p)
	if !is_image_element(p.doc, h) { return nil }
	el, ok := p.images.elements[h]
	if !ok {
		el = new(Img_Element)
		el.node = h
		el.distance = max(f32)
		p.images.elements[h] = el
	}
	el.held = true
	element_update(p, el)
	return el
}

@(private)
images_adopt_document :: proc(p: ^Page) {
	pi := &p.images
	if pi.doc == p.doc { return }
	// a new tree reuses handles of the old one: everything element-related starts over
	for _, el in pi.elements { element_free(p, el, true) }
	clear(&pi.elements)
	for k, r in pi.css_urls { delete(k); request_release(r) }
	clear(&pi.css_urls)
	for ev in pi.events { delete(ev.type) }
	clear(&pi.events)
	inline_svgs_reset(p)
	pi.doc = p.doc
	pi.mutations = 0
	pi.css_serial = 0
	pi.sizes = next_serial()
}

// Finds <img> / <input type=image> elements, runs source selection where something it depends on changed, follows
// CSS image URLs, starts downloads. Cheap when nothing changed. UI thread, from a task (never inside a guest call).
images_sync :: proc(p: ^Page) {
	if p == nil || p.closed || p.worker != nil { return }
	images_init(p)
	images_adopt_document(p)
	if cache.ready { cache.settings, cache.limit = p.settings.images, p.settings.images.cache_max_bytes }
	pi := &p.images
	env := p.engine != nil ? p.engine.env : css.Media_Env{width = 1280, height = 800, dppx = 1}
	env_changed := env.width != pi.env.width || env.dppx != pi.env.dppx || env.height != pi.env.height
	mutated := pi.mutations != p.doc.mutations
	if mutated || env_changed {
		pi.mutations = p.doc.mutations
		pi.env = env
		// the image elements are found again only when the document changed: a new viewport alone (a window being
		// resized) runs source selection on the known ones, without a walk of the whole document at every step
		if mutated { pi.pass += 1 }
		stack := make([dynamic]base.Handle, 0, 64, context.temp_allocator)
		if mutated { append(&stack, p.doc.root) }
		for len(stack) > 0 {
			h := pop(&stack)
			n := dom.get(p.doc, h)
			if n == nil { continue }
			if n.kind == .Element && (n.name == "img" || n.name == "input") && is_image_element(p.doc, h) {
				el, ok := pi.elements[h]
				if !ok {
					el = new(Img_Element)
					el.node = h
					el.distance = max(f32)
					pi.elements[h] = el
				}
				el.seen = pi.pass
			}
			for c := n.last_child; c != base.NIL_HANDLE; c = dom.get(p.doc, c).prev { append(&stack, c) }
			if n.kind == .Element && n.shadow != base.NIL_HANDLE { append(&stack, n.shadow) }   // shadow trees' images too
		}
		gone := make([dynamic]base.Handle, 0, 8, context.temp_allocator)
		for h, el in pi.elements {
			if !is_image_element(p.doc, h) || (el.seen != pi.pass && !el.held) { append(&gone, h); continue }
			element_update(p, el)
		}
		for h in gone {
			el := pi.elements[h]
			delete_key(&pi.elements, h)
			element_free(p, el, true)
		}
		inline_svgs_prune(p)
	}
	css_images_sync(p)
	images_pump(p)
}

@(private)
Candidate :: struct { url: string, density: f32, width: f32, has_w, has_x: bool }

// srcset (HTML §4.8.4.3.3 "parse a srcset attribute"), simplified: URL, then one descriptor (Nw or Nx; h is ignored).
@(private)
parse_srcset :: proc(srcset: string, allocator := context.temp_allocator) -> []Candidate {
	out := make([dynamic]Candidate, allocator)
	s := srcset
	for {
		for len(s) > 0 && (s[0] == ',' || strings.is_space(rune(s[0]))) { s = s[1:] }
		if len(s) == 0 { break }
		end := 0
		for end < len(s) && !strings.is_space(rune(s[end])) { end += 1 }
		u := s[:end]
		s = s[end:]
		desc := ""
		if strings.has_suffix(u, ",") {
			for strings.has_suffix(u, ",") { u = u[:len(u) - 1] }
		} else {
			comma := strings.index_byte(s, ',')
			desc = comma < 0 ? s : s[:comma]
			s = comma < 0 ? "" : s[comma + 1:]
		}
		c := Candidate{url = u, density = 1}
		ok := true
		for d in strings.fields(desc, context.temp_allocator) {
			last := d[len(d) - 1]
			v, vok := strconv.parse_f32(d[:len(d) - 1])
			switch last {
			case 'w':
				if !vok || v <= 0 || c.has_w || c.has_x { ok = false } else { c.width, c.has_w = v, true }
			case 'x':
				if !vok || v <= 0 || c.has_w || c.has_x { ok = false } else { c.density, c.has_x = v, true }
			case 'h':
			case: ok = false
			}
		}
		if ok && u != "" { append(&out, c) }
	}
	return out[:]
}

// sizes: the first entry whose media condition matches, in CSS px; 100vw when none does (or the list is invalid).
@(private)
source_size :: proc(p: ^Page, sizes: string, env: css.Media_Env) -> f32 {
	fallback := f32(env.width)
	if strings.trim_space(sizes) == "" { return fallback }
	vals := css.parse_component_values(sizes, css.Parse_Options{max_nesting_depth = 32, max_rules = 16}, context.temp_allocator)
	lc := css.Length_Context{font_size = 16, root_font_size = 16, vw = env.width, vh = env.height}
	if p.styled != nil && p.styled.root_font_size > 0 { lc.font_size, lc.root_font_size = f64(p.styled.root_font_size), f64(p.styled.root_font_size) }
	for entry in css.split_commas(vals, context.temp_allocator) {
		items := css.trim_values(entry)
		if len(items) == 0 { continue }
		last := items[len(items) - 1]
		cond := css.trim_values(items[:len(items) - 1])
		px: f64 = -1
		if last.kind == .Function {
			if c := css.parse_calc(last, context.temp_allocator); c != nil { px = css.eval_calc(c, lc) }
		} else if last.kind == .Token && last.tok.kind == .Dimension {
			if v, ok := css.length_unit_to_px(last.tok.num, last.tok.text, 0); ok {
				px = v
			} else if u, rok := css.relative_unit(last.tok.text); rok {
				px = css.resolve_unit(last.tok.num, u, lc)
			}
		} else if last.kind == .Token && last.tok.kind == .Number && last.tok.num == 0 {
			px = 0
		} else if last.kind == .Token && last.tok.kind == .Ident && strings.equal_fold(last.tok.text, "auto") {
			px = env.width
		}
		if px < 0 { continue }
		if len(cond) > 0 {
			mq := css.parse_media_query_list(cond, context.temp_allocator)
			if !css.media_matches(mq, env) { continue }
		}
		return f32(px)
	}
	return fallback
}

// Picks the candidate for the device pixel ratio: the smallest density at least the ratio, else the largest.
@(private)
choose_candidate :: proc(cands: []Candidate, size: f32, dppx: f32) -> (Candidate, bool) {
	if len(cands) == 0 { return {}, false }
	best := -1
	best_d: f32
	for c, i in cands {
		d := c.has_w ? c.width / max(size, 1) : c.density
		switch {
		case best < 0: best, best_d = i, d
		case best_d >= dppx: if d >= dppx && d < best_d { best, best_d = i, d }
		case: if d > best_d { best, best_d = i, d }
		}
	}
	c := cands[best]
	c.density = best_d
	return c, true
}

// What source selection gives now: an absolute URL and its density, or nothing.
@(private)
Selection :: struct { url: string, density: f32, has: bool, empty: bool, invalid: bool }

@(private)
select_source :: proc(p: ^Page, el: ^Img_Element, env: css.Media_Env) -> Selection {
	d := p.doc
	h := el.node
	n := dom.get(d, h)
	dppx := f32(env.dppx > 0 ? env.dppx : 1)
	base_url := p.env.location
	resolve :: proc(raw: string, base_url: ^url.URL) -> (string, bool) {
		u, ok := url.parse(strings.trim_space(raw), base_url, context.temp_allocator)
		if !ok { return "", false }
		return u.href, true
	}
	from_set :: proc(p: ^Page, srcset, sizes, src: string, has_src: bool, env: css.Media_Env, dppx: f32) -> (Candidate, bool) {
		cands := make([dynamic]Candidate, context.temp_allocator)
		for c in parse_srcset(srcset) { append(&cands, c) }
		has_1x, has_w := false, false
		for c in cands { if c.has_w { has_w = true }; if !c.has_w && c.density == 1 { has_1x = true } }
		if has_src && strings.trim_space(src) != "" && !has_1x && !has_w { append(&cands, Candidate{url = src, density = 1}) }
		return choose_candidate(cands[:], source_size(p, sizes, env), dppx)
	}
	// <picture>: the first <source> before the img that matches
	if n.parent != base.NIL_HANDLE {
		if parent := dom.get(d, n.parent); parent != nil && parent.kind == .Element && parent.name == "picture" {
			for c := parent.first_child; c != base.NIL_HANDLE && c != h; c = dom.get(d, c).next {
				cn := dom.get(d, c)
				if cn.kind != .Element || cn.name != "source" { continue }
				srcset, has_set := dom.get_attribute(d, c, "srcset")
				if !has_set || strings.trim_space(srcset) == "" { continue }
				if media, has_media := dom.get_attribute(d, c, "media"); has_media && strings.trim_space(media) != "" {
					vals := css.parse_component_values(media, css.Parse_Options{max_nesting_depth = 32, max_rules = 16}, context.temp_allocator)
					if !css.media_matches(css.parse_media_query_list(vals, context.temp_allocator), env) { continue }
				}
				if t, has_type := dom.get_attribute(d, c, "type"); has_type && strings.trim_space(t) != "" {
					essence := strings.to_lower(strings.trim_space(strings.split_n(t, ";", 2, context.temp_allocator)[0]), context.temp_allocator)
					if !images.codec_supported(images.format_of_mime(essence)) { continue }
				}
				sizes, _ := dom.get_attribute(d, c, "sizes")
				if cand, ok := from_set(p, srcset, sizes, "", false, env, dppx); ok {
					abs, aok := resolve(cand.url, &base_url)
					if !aok { return Selection{invalid = true} }
					return Selection{url = abs, density = cand.density, has = true}
				}
			}
		}
	}
	src, has_src := dom.get_attribute(d, h, "src")
	srcset, has_set := dom.get_attribute(d, h, "srcset")
	if has_set && strings.trim_space(srcset) != "" {
		sizes, _ := dom.get_attribute(d, h, "sizes")
		if cand, ok := from_set(p, srcset, sizes, src, has_src, env, dppx); ok {
			abs, aok := resolve(cand.url, &base_url)
			if !aok { return Selection{invalid = true} }
			return Selection{url = abs, density = cand.density, has = true}
		}
	}
	if !has_src { return {} }
	if strings.trim_space(src) == "" { return Selection{empty = true} }
	abs, aok := resolve(src, &base_url)
	if !aok { return Selection{invalid = true} }
	return Selection{url = abs, density = 1, has = true}
}

// Everything selection depends on, as one string: when it is unchanged, nothing is done again.
@(private)
selection_signature :: proc(p: ^Page, el: ^Img_Element, env: css.Media_Env) -> string {
	d := p.doc
	b := strings.builder_make(context.temp_allocator)
	responsive := false
	add :: proc(b: ^strings.Builder, d: ^dom.Document, h: base.Handle, names: []string) -> bool {
		found := false
		for name in names {
			v, ok := dom.get_attribute(d, h, name)
			strings.write_string(b, ok ? "1" : "0")
			strings.write_string(b, v)
			strings.write_byte(b, 0)
			found ||= ok && name != "src" && name != "crossorigin" && name != "loading" && name != "type"
		}
		return found
	}
	responsive ||= add(&b, d, el.node, []string{"src", "srcset", "sizes", "crossorigin", "loading", "type"})
	n := dom.get(d, el.node)
	if parent := dom.get(d, n.parent); parent != nil && parent.kind == .Element && parent.name == "picture" {
		for c := parent.first_child; c != base.NIL_HANDLE && c != el.node; c = dom.get(d, c).next {
			if cn := dom.get(d, c); cn.kind == .Element && cn.name == "source" {
				strings.write_string(&b, "|s")
				responsive ||= add(&b, d, c, []string{"srcset", "sizes", "media", "type"})
			}
		}
	}
	strings.write_string(&b, p.env.location.href)
	if responsive { fmt.sbprintf(&b, "|%v|%v|%v", env.width, env.height, env.dppx) }
	return strings.to_string(b)
}

@(private)
cors_of :: proc(d: ^dom.Document, h: base.Handle) -> (fetch.Mode, fetch.Credentials) {
	v, ok := dom.get_attribute(d, h, "crossorigin")
	if !ok { return .No_Cors, .Include }
	return .Cors, strings.equal_fold(strings.trim_space(v), "use-credentials") ? .Include : .Same_Origin
}

@(private)
is_lazy :: proc(d: ^dom.Document, h: base.Handle) -> bool {
	v, ok := dom.get_attribute(d, h, "loading")
	return ok && strings.equal_fold(strings.trim_space(v), "lazy")
}

@(private)
set_string :: proc(dst: ^string, s: string) {
	delete(dst^)
	dst^ = strings.clone(s)
}

// "Update the image data" when what the element's selection depends on changed.
@(private)
element_update :: proc(p: ^Page, el: ^Img_Element) {
	env := p.images.env
	if env.width == 0 { env = p.engine != nil ? p.engine.env : css.Media_Env{width = 1280, height = 800, dppx = 1} }
	sig := selection_signature(p, el, env)
	if sig == el.signature { return }
	set_string(&el.signature, sig)
	sel := select_source(p, el, env)
	mode, cred := cors_of(p.doc, el.node)
	el.lazy_wait = false
	if !sel.has {
		// no image: src missing (nothing happens) or empty / invalid (broken, error event)
		request_release(el.pending); el.pending = nil
		request_release(el.current); el.current = nil
		set_string(&el.current_url, "")
		el.broken_empty = sel.empty || sel.invalid
		el.notified = false
		element_reject_decodes(p, el, "the image source changed")
		if el.broken_empty { queue_image_event(p, el.node, "error"); el.notified = true }
		p.images.sizes = next_serial()
		return
	}
	el.broken_empty = false
	key := cache_key(p, sel.url, mode, cred)
	if el.current != nil && el.current.key == key && el.pending == nil {
		// the same image again (the "list of available images"): done at once, events again
		el.density = sel.density
		if el.current.state == .Ready || el.current.state == .Broken {
			queue_image_event(p, el.node, el.current.state == .Ready ? "load" : "error")
			el.notified = true
		}
		return
	}
	if is_lazy(p.doc, el.node) && (el.distance > p.settings.images.lazy_margin_px) {
		el.lazy_wait = true
		set_string(&el.lazy_url, sel.url)
		el.lazy_density, el.lazy_mode, el.lazy_cred = sel.density, mode, cred
		return
	}
	element_start(p, el, sel.url, sel.density, mode, cred)
}

@(private)
element_start :: proc(p: ^Page, el: ^Img_Element, abs: string, density: f32, mode: fetch.Mode, cred: fetch.Credentials) {
	nonce, _ := dom.get_attribute(p.doc, el.node, "nonce")
	r := page_request(p, abs, mode, cred, false, nonce)
	r.distance = min(r.distance, el.distance)
	request_release(el.pending)
	el.pending = nil
	if el.current == nil || el.current.state != .Ready {
		// nothing shown yet (or broken): the new request replaces the current one at once
		request_release(el.current)
		el.current = r
		set_string(&el.current_url, abs)
		el.density = density
		el.notified = false
		element_reject_decodes(p, el, "the image source changed")
		p.images.sizes = next_serial()
	} else {
		el.pending = r
		set_string(&el.pending_url, abs)
		el.pending_density = density
	}
	element_settle(p, el)
}

@(private)
element_reject_decodes :: proc(p: ^Page, el: ^Img_Element, why: string) {
	for pr in el.decodes { promise_reject(p, pr, WEB_ERR_ENCODING, why) }
	clear(&el.decodes)
}

// Moves the element on when its requests settled: pending becomes current, events are queued, decode() promises end.
@(private)
element_settle :: proc(p: ^Page, el: ^Img_Element) {
	if r := el.pending; r != nil && (r.state == .Ready || r.state == .Broken) {
		request_release(el.current)
		el.current = r
		el.pending = nil
		set_string(&el.current_url, el.pending_url)
		el.density = el.pending_density
		el.notified = false
		element_reject_decodes(p, el, "the image source changed")
		p.images.sizes = next_serial()
	}
	r := el.current
	if r == nil { return }
	if !el.notified && (r.state == .Ready || r.state == .Broken) {
		el.notified = true
		queue_image_event(p, el.node, r.state == .Ready ? "load" : "error")
		p.images.sizes = next_serial()
	}
	if len(el.decodes) == 0 { return }
	switch r.state {
	case .Broken: element_reject_decodes(p, el, r.error != "" ? r.error : "the image could not be decoded")
	case .Ready:
		e := r.entry
		if e != nil && e.image != nil && !e.image.reduced {
			for pr in el.decodes { promise_resolve(p, pr, 0) }
			clear(&el.decodes)
		} else if e != nil {
			e.want_full = true
			entry_want_pixels(e, 0, 0, 1 << 20)
		}
	case .Queued, .Loading, .Probing:
	}
}

@(private)
queue_image_event :: proc(p: ^Page, node: base.Handle, type: string) {
	append(&p.images.events, Pending_Image_Event{node, strings.clone(type)})
	if p.images.event_timer != base.NIL_HANDLE { return }
	p.images.event_timer = host.set_timer(p.loop, 0, 0, proc(data: rawptr) {
		p := (^Page)(data)
		p.images.event_timer = base.NIL_HANDLE
		evs := slice.clone(p.images.events[:], context.temp_allocator)
		clear(&p.images.events)
		for ev in evs {
			if !p.closed && dom.get(p.doc, ev.node) != nil { dispatch_event(p, ev.node, dom.Event{type = ev.type}) }
			delete(ev.type)
		}
	}, p, p.scope)
}

// The shell reports how far an element is from the viewport (CSS px, 0 = visible; max(f32) = no box): lazy images
// that come near start, downloads and decodes are ordered by it.
images_set_distance :: proc(p: ^Page, node: base.Handle, distance: f32) {
	if !p.images.ready { return }
	el, ok := p.images.elements[node]
	if !ok { return }
	el.distance = distance
	if el.current != nil { el.current.distance = min(el.current.distance, distance) }
	if el.pending != nil { el.pending.distance = min(el.pending.distance, distance) }
	if el.lazy_wait && distance <= p.settings.images.lazy_margin_px {
		el.lazy_wait = false
		element_start(p, el, el.lazy_url, el.lazy_density, el.lazy_mode, el.lazy_cred)
		images_pump(p)
	}
}

// Elements the shell should report distances for: lazy ones waiting, and those whose download has not started.
images_watched :: proc(p: ^Page, allocator := context.temp_allocator) -> []base.Handle {
	out := make([dynamic]base.Handle, allocator)
	if !p.images.ready { return out[:] }
	for h, el in p.images.elements {
		if el.lazy_wait || (el.current != nil && el.current.state == .Queued) || (el.pending != nil && el.pending.state == .Queued) { append(&out, h) }
	}
	return out[:]
}

////////////////////////////////
// CSS images

// The base URL each URL written in a sheet resolves against: the sheet's own (CSS Values 4 §4.5.1.1). The computed
// style keeps URLs as written, so the sheets are searched for them; a URL written identically in sheets with different
// bases resolves against the first.
@(private)
css_bases_rebuild :: proc(p: ^Page) {
	pi := &p.images
	for k, v in pi.css_bases { delete(k); delete(v) }
	clear(&pi.css_bases)
	walk_values :: proc(pi: ^Page_Images, vals: []css.Value, base_url: string) {
		for v in vals {
			switch v.kind {
			case .Token:
				if v.tok.kind == .Url { css_base_note(pi, v.tok.text, base_url) }
			case .Function:
				if strings.equal_fold(v.tok.text, "url") || strings.equal_fold(v.tok.text, "src") {
					for a in v.children { if a.kind == .Token && a.tok.kind == .String { css_base_note(pi, a.tok.text, base_url) } }
				}
				walk_values(pi, v.children, base_url)
			case .Block:
				walk_values(pi, v.children, base_url)
			}
		}
	}
	walk_rules :: proc(pi: ^Page_Images, rules: []^css.Rule, base_url: string) {
		for r in rules {
			for decl in r.declarations { walk_values(pi, decl.value, base_url) }
			walk_rules(pi, r.nested, base_url)
			walk_rules(pi, r.rules, base_url)
		}
	}
	walk_sheet :: proc(pi: ^Page_Images, s: ^style.Sheet) {
		if s == nil { return }
		if s.sheet != nil && s.base_url != "" { walk_rules(pi, s.sheet.rules, s.base_url) }
		for &slot in s.imports { walk_sheet(pi, slot.child) }
	}
	for s in p.engine.sheets { walk_sheet(pi, s) }
}

@(private)
css_base_note :: proc(pi: ^Page_Images, written, base_url: string) {
	if written in pi.css_bases { return }
	pi.css_bases[strings.clone(written)] = strings.clone(base_url)
}

// After a style pass: the URLs of background images in use (on elements that are rendered) get requests; those no
// longer used are released.
@(private)
css_images_sync :: proc(p: ^Page) {
	pi := &p.images
	if p.engine == nil || p.styled == nil { return }
	if p.engine.rebuilds != pi.css_rebuilds { css_bases_rebuild(p); pi.css_rebuilds = p.engine.rebuilds; pi.css_serial = 0 }
	if p.styled.serial == pi.css_serial { return }
	pi.css_serial = p.styled.serial
	used := make(map[string]bool, 16, context.temp_allocator)
	seen := make(map[rawptr]bool, 16, context.temp_allocator)
	note :: proc(c: ^style.Computed, used: ^map[string]bool, seen: ^map[rawptr]bool) {
		if c == nil || c.display == .None { return }
		// background and mask layers (mask-image: MDN's icons)
		for list in ([2][]style.Image{c.background_images, c.mask_images}) {
			if len(list) == 0 || raw_data(list) in seen { continue }
			seen[raw_data(list)] = true
			for im in list { if im.kind == .Url && im.url != "" { used[im.url] = true } }
		}
	}
	for c in p.styled.by_node {
		if c == nil || c.display == .None { continue }
		note(c, &used, &seen)
		// ::before / ::after boxes (an icon after every external link)
		note(c.before, &used, &seen)
		note(c.after, &used, &seen)
	}
	stale := make([dynamic]string, 0, 4, context.temp_allocator)
	for k in pi.css_urls { if k not_in used { append(&stale, k) } }
	for k in stale {
		r := pi.css_urls[k]
		key := k
		delete_key(&pi.css_urls, k)
		delete(key)
		request_release(r)
	}
	for written in used {
		if written in pi.css_urls { continue }
		base_url := pi.css_bases[written] or_else p.env.location.href
		abs, ok := resolve_against(written, base_url)
		if !ok { continue }
		r := page_request(p, abs, .No_Cors, .Include, true)
		delete(abs)
		pi.css_urls[strings.clone(written)] = r
	}
}

////////////////////////////////
// Image_decode for scripts (bindings_images.odin): bytes in, RGBA out, on the decoding threads

@(private)
guest_decode_start :: proc(p: ^Page, bytes: []byte, owner: u32) -> u64 {
	pr := promise_create(p, owner)
	images_init(p)
	decoder_ensure(&p.settings.images)
	if p.images.port == 0 { p.images.port = images.port_open(p.loop, guest_decode_done, p) }
	if p.images.port == 0 { promise_reject(p, pr, WEB_ERR_NOT_SUPPORTED, "the image decoder is unavailable"); return pr }
	s := &p.settings.images
	o := images.Decode_Options{limits = s.limits, first_frame_only = true, allow_truncated = s.allow_truncated}
	o.limits.max_image_bytes = min(o.limits.max_image_bytes, i64(s.guest_max_bytes))
	blob := images.blob_make(slice.clone(bytes))
	j := images.job_make(.Decode, blob, o, 0)
	images.blob_release(blob)
	append(&p.images.guest, Guest_Decode{job = j, promise = pr, owner = owner})
	if !images.submit(p.images.port, j) {
		pop(&p.images.guest)
		promise_reject(p, pr, WEB_ERR_NOT_SUPPORTED, "the image decoder is unavailable")
	}
	return pr
}

@(private)
guest_decode_done :: proc(user: rawptr, j: ^images.Job) {
	p := (^Page)(user)
	defer images.job_free(j)
	g: Guest_Decode
	found := false
	for x, i in p.images.guest { if x.job == j { g, found = x, true; ordered_remove(&p.images.guest, i); break } }
	if !found || p.closed { return }
	if j.err != .None || j.image == nil || len(j.image.frames) == 0 {
		promise_reject(p, g.promise, WEB_ERR_ENCODING, images.error_message(j.err))
		return
	}
	img := j.image
	buf := buffer_create(p, img.frames[0].pixels, g.owner)
	if buf == 0 {
		promise_reject(p, g.promise, WEB_ERR_QUOTA, "the decoded image does not fit in the page's memory (page.max_fetch_bytes)")
		return
	}
	promise_resolve(p, g.promise, i64(buf), fmt.tprintf("%dx%d", img.width, img.height))
}

////////////////////////////////
// SVG rasters: an SVG image is drawn at each size it is shown at (device pixels: CSS size times the screen's scale), so
// it is never a small picture scaled up. Rasters are made on the decoding threads, one at a time per image, from the
// document parsed once (images.Blob); images.svg.max_rasters of them are kept, the least recently shown going first.

// The raster of e for a picture w x h device pixels large: the exact one when it exists, else the nearest (the
// painter scales it meanwhile) and a raster of that size is asked for.
@(private)
svg_raster_for :: proc(e: ^Cache_Entry, want_w, want_h: int, priority: i32) -> ^Svg_Raster {
	w, h := max(want_w, 1), max(want_h, 1)
	best: ^Svg_Raster
	best_d := max(int)
	for &r in e.rasters {
		if r.w == w && r.h == h { r.last_shown = cache.epoch; return &r }
		// nearest by area, a larger one preferred to a smaller one
		d := abs(r.w * r.h - w * h) * (r.w * r.h >= w * h ? 1 : 4)
		if d < best_d { best, best_d = &r, d }
	}
	if e.raster_job != nil {
		if e.raster_w == w && e.raster_h == h {
			images.job_set_priority(e.raster_job, priority)
		}
		// another size is being made: this one is asked for at the next paint after it
	} else if e.blob != nil {
		o := decode_options(&cache.settings, e)
		o.target_w, o.target_h = w, h
		j := images.job_make(.Decode, e.blob, o, priority, e)
		e.raster_job, e.raster_w, e.raster_h = j, w, h
		if !images.submit(cache.port, j) { e.raster_job = nil }
	}
	if best != nil { best.last_shown = cache.epoch }
	return best
}

@(private)
svg_raster_done :: proc(e: ^Cache_Entry, j: ^images.Job) {
	if j.err != .None || j.image == nil {
		// a raster that cannot be made (rendering cost over the limit...): the image is broken
		if len(e.rasters) == 0 {
			e.err = j.err != .None ? j.err : .Internal
			e.state = .Broken
			entry_notify(e, true)
		}
		return
	}
	cache.next_id += 1
	append(&e.rasters, Svg_Raster{id = cache.next_id, w = j.image.width, h = j.image.height, image = j.image, last_shown = cache.epoch})
	j.image = nil
	keep := max(cache.settings.svg_max_rasters, 1)
	for len(e.rasters) > keep {
		oldest := 0
		for r, i in e.rasters { if r.last_shown < e.rasters[oldest].last_shown { oldest = i } }
		append(&cache.evicted, e.rasters[oldest].id)
		images.image_destroy(e.rasters[oldest].image)
		ordered_remove(&e.rasters, oldest)
	}
	e.generation += 1
	entry_account(e)
	entry_notify(e, false)
	cache_enforce()
}

// Drops rasters (those not shown in the current paint epoch when unshown_only).
@(private)
svg_drop_rasters :: proc(e: ^Cache_Entry, unshown_only: bool) {
	for i := 0; i < len(e.rasters); {
		r := e.rasters[i]
		if unshown_only && r.last_shown == cache.epoch { i += 1; continue }
		append(&cache.evicted, r.id)
		images.image_destroy(r.image)
		ordered_remove(&e.rasters, i)
	}
	entry_account(e)
}

// Natural size of an SVG image (CSS Images 3 §5.2, default sizing with the default object size 300 x 150): what the
// document gives, a missing side from the ratio; atio_only: a ratio and no size at all (the layout stretches it).
@(private)
svg_natural :: proc(s: images.Svg_Size) -> (w, h: f32, ratio_only: bool) {
	r := s.ratio
	switch {
	case s.has_w && s.has_h: return s.w, s.h, false
	case s.has_w: return s.w, r > 0 ? s.w / r : 150, false
	case s.has_h: return r > 0 ? s.h * r : 300, s.h, false
	case r > 0:
		// contained in 300 x 150 for those who need a size
		if r >= 2 { return 300, 300 / r, true }
		return 150 * r, 150, true
	}
	return 300, 150, false
}

////////////////////////////////
// Shell: layout, painting, invalidation

Image_State :: enum u8 { None, Loading, Ready, Broken }

// What an element (or a CSS image) shows, for layout and painting.
Image_View :: struct {
	id:          u64,        // cache entry: the key of the painter's texture; 0 = nothing to draw
	state:       Image_State,
	natural:     [2]f32,     // CSS px, density applied
	pixel_size:  [2]int,     // image pixels (orientation applied)
	animated:    bool,
	error:       string,     // Broken: why (valid until the next change)
	svg:         bool,       // vector: drawn at any size; `natural` follows CSS default sizing
	ratio_only:  bool,       // SVG with a natural ratio and no natural size: `natural` is only a fallback
	ratio:       f32,        // natural ratio (width / height), 0 = none
	has_size:    [2]bool,    // SVG: which natural dimensions the document gives
}

@(private)
view_of :: proc(r: ^Img_Request, density: f32) -> Image_View {
	v: Image_View
	if r == nil { return v }
	switch r.state {
	case .Queued, .Loading, .Probing: v.state = .Loading
	case .Ready: v.state = .Ready
	case .Broken: v.state = .Broken
	}
	v.error = r.error
	e := r.entry
	if e == nil || r.state != .Ready { return v }
	v.id = e.id
	v.pixel_size = {e.info.width, e.info.height}
	d := density > 0 ? density : 1
	v.natural = {f32(e.info.width) / d, f32(e.info.height) / d}
	v.animated = e.info.animated && cache.settings.animate
	if e.info.format == .Svg {
		w, h, ratio_only := svg_natural(e.info.svg)
		v.svg, v.ratio_only, v.ratio = true, ratio_only, e.info.svg.ratio
		v.has_size = {e.info.svg.has_w || (e.info.svg.has_h && e.info.svg.ratio > 0), e.info.svg.has_h || (e.info.svg.has_w && e.info.svg.ratio > 0)}
		v.natural = {w / d, h / d}
	} else if v.natural[1] > 0 {
		v.ratio = v.natural[0] / v.natural[1]
		v.has_size = {true, true}
	}
	return v
}

image_view :: proc(p: ^Page, node: base.Handle) -> Image_View {
	if !p.images.ready { return {} }
	el, ok := p.images.elements[node]
	if !ok { return {} }
	if el.broken_empty { return Image_View{state = .Broken, error = "empty or invalid image URL"} }
	if el.current == nil { return Image_View{state = el.lazy_wait ? .Loading : .None} }
	return view_of(el.current, el.density)
}

// A CSS image by its URL as written in the computed style.
css_image_view :: proc(p: ^Page, written: string) -> Image_View {
	if !p.images.ready { return {} }
	r, ok := p.images.css_urls[written]
	if !ok { return {} }
	return view_of(r, 1)
}

// Natural size in CSS px for layout (Replaced_Api.intrinsic): only once known; the element's width / height
// attributes or the placeholder size apply until then.
image_intrinsic :: proc(p: ^Page, node: base.Handle) -> (w, h: f32, ok: bool) {
	v := image_view(p, node)
	if v.state != .Ready { return 0, 0, false }
	return v.natural[0], v.natural[1], true
}

// Changes whenever a natural size of an element of the page appears or changes: the shell lays the page out again
// (these values never repeat across pages).
images_sizes_generation :: proc(p: ^Page) -> u64 { return p.images.ready ? p.images.sizes : 0 }

// Changes whenever pixels or states of the page's images change: something to repaint.
images_pixels_generation :: proc(p: ^Page) -> u64 { return p.images.ready ? p.images.pixels : 0 }

// Pixels of the frame to show now.
Frame_Pixels :: struct {
	pixels:     []u8,     // RGBA8 straight alpha, sRGB; valid until the next call into this package
	width, height, stride: int,
	texture:    u64,      // the painter's texture key: the entry id, or an SVG raster's (one texture per size shown)
	generation: u64,      // changes when the decoded image changes (new size, new decode)
	frame:      int,      // animation frame index
	next_ms:    f64,      // loop ms of the next frame change; < 0 = none (still, ended, or animations off)
	reduced:    bool,     // decoded smaller than its natural size
	ok:         bool,
}

// Starts a paint epoch (once per painted frame): images drawn in it are not evicted while it lasts.
images_paint_begin :: proc() { cache.epoch += 1 }

// The current frame of entry `id`, for a picture drawn `want_w` x `want_h` device pixels large (the decode adapts to
// it). Asks for a decode when there are no pixels yet (or too few); `priority` orders those decodes (higher first).
frame_pixels :: proc(id: u64, now_ms: f64, want_w, want_h: int, priority: i32 = 0) -> Frame_Pixels {
	if !cache.ready { return {} }
	e, ok := cache.by_id[id]
	if !ok { return {} }
	e.last_shown = cache.epoch
	if entry_is_svg(e) {
		r := svg_raster_for(e, want_w, want_h, priority)
		if r == nil || r.image == nil || len(r.image.frames) == 0 { return {} }
		return Frame_Pixels{
			pixels = r.image.frames[0].pixels, width = r.image.width, height = r.image.height, stride = r.image.stride,
			texture = r.id, generation = r.id, ok = true, next_ms = -1,
		}
	}
	entry_want_pixels(e, want_w, want_h, priority)
	img := e.image
	if img == nil || len(img.frames) == 0 { return {} }
	fp := Frame_Pixels{width = img.width, height = img.height, stride = img.stride, texture = e.id, generation = e.generation, reduced = img.reduced, ok = true, next_ms = -1}
	if img.info.animated && cache.settings.animate && len(img.frames) > 1 {
		if e.anim_start < 0 { e.anim_start = now_ms }
		idx, next := images.animation_frame_at(img, now_ms - e.anim_start)
		fp.frame = idx
		if next >= 0 { fp.next_ms = e.anim_start + next }
	}
	fp.pixels = img.frames[fp.frame].pixels
	return fp
}

// Ids whose pixels went away (evicted, or the entry died) since the last call: the painter releases their textures.
images_drain_evicted :: proc(out: ^[dynamic]u64) {
	if !cache.ready { return }
	append(out, ..cache.evicted[:])
	clear(&cache.evicted)
}

// Statistics for about: pages and tests.
Image_Stats :: struct { entries, bytes, limit: int, decoder: images.Decoder_Stats, started, shared, elements, requests: int }

images_stats :: proc(p: ^Page) -> Image_Stats {
	s := Image_Stats{entries = len(cache.by_id), bytes = cache.bytes, limit = cache.limit, decoder = images.decoder_stats()}
	if p != nil && p.images.ready {
		s.started, s.shared = p.images.started, p.images.shared
		s.elements, s.requests = len(p.images.elements), len(p.images.requests)
	}
	return s
}

// The element's complete / naturalWidth / currentSrc (bindings_images.odin).
@(private)
element_complete :: proc(el: ^Img_Element) -> bool {
	if el.lazy_wait { return false }
	if el.pending != nil { return false }
	if el.current == nil { return true }
	return el.current.state == .Ready || el.current.state == .Broken
}

@(private)
element_decode :: proc(p: ^Page, el: ^Img_Element, owner: u32) -> u64 {
	pr := promise_create(p, owner)
	if el.broken_empty || (el.current == nil && !el.lazy_wait) {
		promise_reject(p, pr, WEB_ERR_ENCODING, "the image has no source")
		return pr
	}
	append(&el.decodes, pr)
	element_settle(p, el)
	return pr
}
