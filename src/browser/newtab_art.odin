package browser

// The artistic new tab: when browser.newtab.art.enabled is on, a new tab shows a public-domain / freely licensed
// painting, filling the window behind the address bar and the start page's shortcuts, with a discreet caption (title,
// artist, date, museum, a link to the record) and two small buttons (another painting, open the record). It follows
// Google Arts & Culture's "art new tab" idea, but every piece runs natively here: the engine renders the page, the
// shell downloads and caches the images.
//
// Nothing reaches the network while the option is off, or while the loader is held offline. With it on, the first listing is asked
// for a moment after the start (ART_WARMUP_MS), so that the first new tab already has a painting; the task stops after
// browser.newtab.art.idle_minutes with no art new tab. From then on a background task keeps a sliding window of about
// browser.newtab.art.window images ready in a dedicated folder of the profile's temporary area, each with a JSON file of
// its metadata. A shown image is replaced by a fresh one, so the window always holds that many unseen paintings; the
// last browser.newtab.art.window picks are remembered so the same painting does not come back at once. The downloader is
// courteous: one request at a time per host, an honest User-Agent (Wren/<version>), exponential backoff on 429 / 403 /
// network error, and it validates every answer (image MIME, a size cap, a decode with the shared decoder, a sane aspect
// ratio and a minimum width for full-screen use) before keeping it. What it keeps is sized for a screen, not for print: the
// decoder reduces the painting to browser.newtab.art.short_side_px and a worker encodes it as JPEG, so showing one costs a
// small read and a decode at its size, in the page's own loader (newtab_art_page.odin); the 8 MB a museum serves cost that
// once, in the background. The disk holds what was not seen yet: a shown painting goes, and the first scan of a session
// (art_scan) takes the rest back, so a first new tab has one at once, and removes everything else in the folder. The task
// stops after a spell with no art new tab open (inactivity) and resumes on the next one.
//
// "Smart": it prefers an image whose orientation suits the window (a tall portrait is avoided on a wide screen, or shown
// over a blurred fill of itself), it pre-fetches the next while the current one is on screen, and it downloads nothing
// on a limited / offline connection.
//
// Sources (browser.newtab.art.sources, a comma list, replaceable): "cleveland" (Cleveland Museum of Art Open Access, CC0
// paintings) and "commons" (Wikimedia Commons, Google Art Project works and featured paintings; only freely licensed
// files, with attribution shown). Google Arts & Culture itself has no public API and is not used. See docs/newtab-art.md.
//
// Privacy: the only requests made are the source's listing API and the image files themselves; nothing about the user is
// sent, no identifier, no referrer to a third party. The images and their metadata live in the profile's temporary
// folder and are cleared with "Clear browsing data".

import "base:runtime"
import "core:encoding/json"
import "core:fmt"
import "core:math/rand"
import "core:os"
import "core:slice"
import "core:strings"
import "core:time"
import "wb:base"
import "wb:config"
import "wb:fetch"
import "wb:host"
import "wb:images"
import "wb:url"

// What a kept painting's JSON says it is: a file of another format (the print-sized originals of before) goes at the scan.
ART_CACHE_FORMAT :: 1
// A painting that needed no reduction and is at most this large is kept as it came: encoding it again would lose more than it saves.
ART_KEEP_AS_IS_BYTES :: 1 << 20
// Behind every image of a page: this work has no one waiting.
ART_DECODE_PRIORITY :: -1

////////////////////////////////
// Preferences

ART_PREFS := [?]config.Def{
	{name = "browser.newtab.art.enabled", kind = .Bool, default = {b = false},
		description = "Show a random public-domain painting on a new tab (the start page's shortcuts and the address bar stay over it). Off by default. No network request is ever made for it until the first art new tab is opened, and none at all while it is off. The images come from the sources named by browser.newtab.art.sources and are kept only in this profile's temporary folder; nothing about you is sent."},
	{name = "browser.newtab.art.sources", kind = .String, default = {s = "cleveland,commons"},
		description = "Where the paintings come from, a comma list tried in turn: cleveland (Cleveland Museum of Art Open Access, CC0 paintings), commons (Wikimedia Commons: Google Art Project works and featured paintings, only freely licensed files, with attribution shown). Google Arts & Culture has no public API and is not used."},
	{name = "browser.newtab.art.window", kind = .Int, default = {i = 20}, bounded = true, min = 1, max = 200,
		description = "How many paintings are kept downloaded and ready ahead of time (a sliding window: a shown one is replaced by a fresh one). Larger means more variety at once and more data downloaded and cached."},
	{name = "browser.newtab.art.max_cache_mb", kind = .Int, default = {i = 128}, bounded = true, min = 8, max = 8192, unit = "MB",
		description = "Most disk the cached paintings and their metadata take in the profile's temporary folder. The oldest files are purged first past this."},
	{name = "browser.newtab.art.refresh_hours", kind = .Float, default = {f = 12}, bounded = true, min = 0, max = 720, unit = "h",
		description = "A kept painting older than this is refreshed (fetched again from its source listing) so the window does not go stale. 0: never refresh on age alone."},
	{name = "browser.newtab.art.show_caption", kind = .Bool, default = {b = true},
		description = "Show the discreet caption at the bottom of the art new tab: the painting's title, artist, date, museum and a link to its record."},
	{name = "browser.newtab.art.offline_fallback", kind = .Bool, default = {b = true},
		description = "When no painting could be downloaded yet (offline, or the sources did not answer), show an elegant gradient with the caption instead of the plain start page, so the art new tab never looks broken."},
	{name = "browser.newtab.art.min_width_px", kind = .Int, default = {i = 1280}, bounded = true, min = 320, max = 16384, unit = "px",
		description = "Smallest width (in image pixels) a painting may have to be kept: below it looks soft filling a screen. Images narrower than this are refused."},
	{name = "browser.newtab.art.max_image_bytes", kind = .Int, default = {i = 8 << 20}, bounded = true, min = 64 << 10, max = 128 << 20, bytes = true, unit = "bytes",
		description = "Largest image file downloaded for one painting. A larger answer is refused."},
	{name = "browser.newtab.art.short_side_px", kind = .Int, default = {i = 1600}, bounded = true, min = 320, max = 16384, unit = "px",
		description = "A painting is kept with its shorter side at most this long, enough to fill a 2560 x 1440 window: a larger one is reduced and encoded as JPEG when it arrives, so that a new tab reads and decodes little. Raise it for a larger screen."},
	{name = "browser.newtab.art.jpeg_quality", kind = .Float, default = {f = 0.82}, bounded = true, min = 0.1, max = 1,
		description = "Quality of the JPEG a painting is kept as when it is reduced, from 0.1 to 1: higher is finer and takes more disk."},
	{name = "browser.newtab.art.idle_minutes", kind = .Float, default = {f = 30}, bounded = true, min = 0, max = 1440, unit = "min",
		description = "The background task stops after this long with no art new tab shown, and resumes at the next one, so an idle window downloads nothing. 0: never stop on its own."},
	{name = "browser.newtab.art.backoff_base_ms", kind = .Int, default = {i = 2000}, bounded = true, min = 100, max = 600_000, unit = "ms",
		description = "First wait after a source or image request fails (429 / 403 / network): it doubles on each further failure up to browser.newtab.art.backoff_max_ms, so a server under load is not hammered."},
	{name = "browser.newtab.art.backoff_max_ms", kind = .Int, default = {i = 300_000}, bounded = true, min = 1000, max = 3_600_000, unit = "ms",
		description = "Longest wait between retries after repeated failures (browser.newtab.art.backoff_base_ms doubles up to here)."},
}

register_newtab_art_prefs :: proc(p: ^config.Prefs) { config.register(p, ART_PREFS[:], "newtab") }

Art_Settings :: struct {
	enabled:         bool,
	sources:         string,   // owned: the comma list
	window:          int,
	max_cache_bytes: i64,
	refresh_ms:      f64,      // 0 = never on age
	show_caption:    bool,
	offline_fallback: bool,
	min_width_px:    int,
	max_image_bytes: int,
	short_side_px:   int,
	jpeg_quality:    f32,
	idle_ms:         f64,      // 0 = never stop
	backoff_base_ms: i64,
	backoff_max_ms:  i64,
}

art_settings_from_prefs :: proc(p: ^config.Prefs) -> Art_Settings {
	return Art_Settings{
		enabled = config.bool_of(p, "browser.newtab.art.enabled"),
		sources = strings.clone(config.string_of(p, "browser.newtab.art.sources")),
		window = int(config.int_of(p, "browser.newtab.art.window")),
		max_cache_bytes = config.int_of(p, "browser.newtab.art.max_cache_mb") * (1 << 20),
		refresh_ms = config.float_of(p, "browser.newtab.art.refresh_hours") * 3_600_000,
		show_caption = config.bool_of(p, "browser.newtab.art.show_caption"),
		offline_fallback = config.bool_of(p, "browser.newtab.art.offline_fallback"),
		min_width_px = int(config.int_of(p, "browser.newtab.art.min_width_px")),
		max_image_bytes = int(config.int_of(p, "browser.newtab.art.max_image_bytes")),
		short_side_px = int(config.int_of(p, "browser.newtab.art.short_side_px")),
		jpeg_quality = f32(config.float_of(p, "browser.newtab.art.jpeg_quality")),
		idle_ms = config.float_of(p, "browser.newtab.art.idle_minutes") * MS_PER_MINUTE,
		backoff_base_ms = config.int_of(p, "browser.newtab.art.backoff_base_ms"),
		backoff_max_ms = config.int_of(p, "browser.newtab.art.backoff_max_ms"),
	}
}

art_settings_destroy :: proc(s: ^Art_Settings) { delete(s.sources) }

////////////////////////////////
// A cached painting

// One painting ready to show: the bytes on disk and the facts the caption needs. Every string is owned. Its JSON file is this
// structure, with the image's name for `file`.
Art_Item :: struct {
	format:    int,      // ART_CACHE_FORMAT
	id:        string,   // stable, source-prefixed ("cleveland:123", "commons:File:x.jpg"): the cache file's stem, dedup key
	file:      string,   // absolute path of the image file in the cache folder
	source:    string,   // "cleveland" / "commons"
	title:     string,
	artist:    string,
	date:      string,   // the work's date ("1889", "c. 1510"), free text
	museum:    string,
	record:    string,   // the web page of the painting's record (opened by "open the record")
	license:   string,   // "CC0", "Public domain", "CC BY-SA 4.0", ...
	width:     int,       // image pixels of the file
	height:    int,
	bytes:     i64,       // size of the file
	fetched:   i64,       // unix seconds when written
}

art_item_destroy :: proc(it: ^Art_Item) {
	delete(it.id); delete(it.file); delete(it.source); delete(it.title); delete(it.artist)
	delete(it.date); delete(it.museum); delete(it.record); delete(it.license)
	it^ = {}
}

////////////////////////////////
// State

Art_Phase :: enum u8 {
	Idle,        // not started, or stopped after inactivity
	Listing,     // fetching a source's listing
	Downloading, // fetching one image
	Validating,  // decoding an image on the decoder threads
	Encoding,    // a worker encodes and writes it (art_encode_work)
	Waiting,     // backing off, or window full: a timer will wake it
}

// The first look at the folder, once a session (art_scan): nothing is written there until it has ended.
Art_Scan :: enum u8 { Not_Yet, Running, Done }

Art :: struct {
	app:        ^App,
	cfg:        Art_Settings,
	watch:      int,
	dir:        string,         // the cache folder (owned); "" until art_ensure_dir

	started:    bool,           // the background task is running (started on the first art new tab)
	phase:      Art_Phase,
	last_shown_ms: f64,         // loop clock when an art new tab was last shown (inactivity)
	warm_timer: base.Handle,    // the first fetch after the start, when the option is on (ART_WARMUP_MS)
	stop_timer: base.Handle,    // the inactivity deadline

	ready:      [dynamic]^Art_Item,   // paintings downloaded and validated, newest last
	recent:     [dynamic]string,      // ids shown lately, oldest first (at most `window`): no immediate repeat
	current:    ^Art_Item,            // what the last art new tab chose (shown): replaced once consumed
	retired:    ^Art_Item,            // the one before it: its page may still be reading the file, which goes at the next pick
	scan:       Art_Scan,
	jobs:       int,                  // on the workers: art_destroy waits for them
	gen:        u32,                  // what a worker was given under another one is dropped when it comes back (art_cancel_io)

	// the listing in hand: candidate image descriptors not yet downloaded
	candidates: [dynamic]Art_Candidate,
	cand_src:   int,            // which source index the candidates came from (round-robins the sources)

	// the download in flight
	task:       base.Handle,
	dl:         Art_Candidate,  // the candidate being downloaded (owned copy)
	dl_active:  bool,

	// validation
	port:       images.Port_Id,
	job:        images.Job_Id,
	blob:       ^images.Blob,

	// courtesy
	fails:      int,            // consecutive failures (backoff)
	wait_timer: base.Handle,
}

// A painting the listing named but that is not downloaded yet.
Art_Candidate :: struct {
	id:       string,   // owned, source-prefixed
	image_url: string,  // owned
	source:   string,   // owned
	title:    string,
	artist:   string,
	date:     string,
	museum:   string,
	record:   string,
	license:  string,
	size:     i64,      // the file's size when the listing says (0: unknown)
}

art_candidate_destroy :: proc(c: ^Art_Candidate) {
	delete(c.id); delete(c.image_url); delete(c.source); delete(c.title); delete(c.artist)
	delete(c.date); delete(c.museum); delete(c.record); delete(c.license)
	c^ = {}
}

art_candidate_clone :: proc(c: Art_Candidate) -> Art_Candidate {
	return Art_Candidate{
		id = strings.clone(c.id), image_url = strings.clone(c.image_url), source = strings.clone(c.source),
		title = strings.clone(c.title), artist = strings.clone(c.artist), date = strings.clone(c.date),
		museum = strings.clone(c.museum), record = strings.clone(c.record), license = strings.clone(c.license), size = c.size,
	}
}


////////////////////////////////
// Lifecycle (the shell starts and ends it, main.odin)

art_init :: proc(app: ^App) {
	app.art.app = app
	app.art.cfg = art_settings_from_prefs(&app.prefs)
	app.art.ready = make([dynamic]^Art_Item, base.process_allocator())
	app.art.recent = make([dynamic]string, base.process_allocator())
	app.art.candidates = make([dynamic]Art_Candidate, base.process_allocator())
	app.art.watch = config.watch(&app.prefs, "browser.newtab.art.", proc(user: rawptr, name: string, p: ^config.Prefs) {
		old := the_app.art.cfg
		the_app.art.cfg = art_settings_from_prefs(p)
		art_settings_destroy(&old)
		// turning the option off while it ran stops it at once and lets the next new tab be the plain start page again
		if !the_app.art.cfg.enabled && the_app.art.started { art_stop() }
		if the_app.art.started { art_pump() }
		// the option was just turned on: the first painting is fetched now, not at the next new tab
		if the_app.art.cfg.enabled && !the_app.art.started && the_app.art.warm_timer == base.NIL_HANDLE { art_warm_up(the_app) }
	}, app)
	// The person turned the art new tab on: the first painting is fetched a moment after the start (the window is up first), so that
	// the first new tab already has one instead of a gradient that waits for a listing and a download. Off: no request, as always.
	if app.art.cfg.enabled { art_warm_up(app) }
}

// How long after the start (or after the option is turned on) the first listing is asked for.
ART_WARMUP_MS :: 2500

@(private = "file")
art_warm_up :: proc(app: ^App) {
	art_scan(app)
	app.art.warm_timer = host.set_timer(&app.loop, ART_WARMUP_MS, 0, proc(data: rawptr) {
		app := (^App)(data)
		app.art.warm_timer = base.NIL_HANDLE
		if app.art.cfg.enabled && !app.art.started { art_seen_new_tab(app) }   // (starts the background task; the idle timer stops it if no art tab comes)
	}, app)
}

art_destroy :: proc(app: ^App) {
	config.unwatch(&app.prefs, app.art.watch)
	art_cancel_io()
	app.art.started = false   // (what comes back from a worker starts nothing)
	for app.art.jobs > 0 { host.blocking_settle(&app.blocking) }
	if app.art.stop_timer != base.NIL_HANDLE { host.clear_timer(&app.loop, app.art.stop_timer) }
	if app.art.warm_timer != base.NIL_HANDLE { host.clear_timer(&app.loop, app.art.warm_timer) }
	if app.art.wait_timer != base.NIL_HANDLE { host.clear_timer(&app.loop, app.art.wait_timer) }
	if app.art.port != 0 { images.port_close(app.art.port) }
	// `current`, if it was consumed, is no longer in `ready`: it was shown, so it leaves the disk too. If it is still in `ready` it is freed with it.
	if app.art.current != nil && !art_in_ready(app.art.current) { art_drop(app.art.current) }
	if app.art.retired != nil { art_drop(app.art.retired) }
	for it in app.art.ready { art_item_destroy(it); free(it) }
	delete(app.art.ready)
	for s in app.art.recent { delete(s) }
	delete(app.art.recent)
	for &c in app.art.candidates { art_candidate_destroy(&c) }
	delete(app.art.candidates)
	art_candidate_destroy(&app.art.dl)
	art_settings_destroy(&app.art.cfg)
	delete(app.art.dir)
	app.art = {}
}

@(private = "file")
art_cancel_io :: proc() {
	the_app.art.gen += 1
	if the_app.art.task != base.NIL_HANDLE { fetch.cancel(&the_app.art.app.loader, the_app.art.task); the_app.art.task = base.NIL_HANDLE }
	the_app.art.dl_active = false
	if the_app.art.job != 0 { images.job_cancel(the_app.art.job); the_app.art.job = 0 }
	if the_app.art.blob != nil { images.blob_release(the_app.art.blob); the_app.art.blob = nil }
}

////////////////////////////////
// The trigger: the first art new tab of the session (newtab_art_page.odin calls this)

// Called when an art new tab is shown. Starts the background task on the very first one, and marks activity so an idle
// window keeps running. Never touches the network itself: art_pump does, and only when the option is on and the loader
// is not held offline.
art_seen_new_tab :: proc(app: ^App) {
	if !app.art.cfg.enabled { return }
	app.art.last_shown_ms = f64(host.now_ns(&app.loop)) / 1e6
	if !app.art.started {
		app.art.started = true
		app.art.phase = .Idle
	}
	art_schedule_stop()
	art_pump()
}

@(private = "file")
art_schedule_stop :: proc() {
	app := the_app.art.app
	if app.art.stop_timer != base.NIL_HANDLE { host.clear_timer(&app.loop, app.art.stop_timer); app.art.stop_timer = base.NIL_HANDLE }
	if app.art.cfg.idle_ms <= 0 { return }
	app.art.stop_timer = host.set_timer(&app.loop, app.art.cfg.idle_ms, 0, proc(data: rawptr) {
		the_app.art.stop_timer = base.NIL_HANDLE
		art_stop()   // inactivity: nothing downloads until the next art new tab
	}, app)
}

@(private = "file")
art_stop :: proc() {
	art_cancel_io()
	if the_app.art.wait_timer != base.NIL_HANDLE { host.clear_timer(&the_app.art.app.loop, the_app.art.wait_timer); the_app.art.wait_timer = base.NIL_HANDLE }
	the_app.art.started = false
	the_app.art.phase = .Idle
}

////////////////////////////////
// The pump: one step of the state machine, re-entered after every async result

// Does one thing and returns: start a listing, download the next candidate, or wait. The network is only ever touched
// here, guarded by the option and the loader's offline hold.

@(private = "file")
art_pump :: proc() {
	app := the_app.art.app
	if !app.art.started || !app.art.cfg.enabled { return }
	if app.art.scan == .Running { return }   // (art_scan_done pumps)
	if app.art.phase == .Listing || app.art.phase == .Downloading || app.art.phase == .Validating || app.art.phase == .Encoding { return }   // a request is in flight
	if app.loader.hold { art_wait(app.art.cfg.backoff_base_ms); return }   // held offline: try again shortly, make no request

	art_purge_over_cap()

	// the window is full: nothing to do until a painting is consumed (a shown new tab calls art_consume, which pumps again)
	if len(app.art.ready) >= app.art.cfg.window {
		app.art.phase = .Idle
		return
	}

	// a candidate in hand: download it. With nothing ready yet the smallest file goes first: the first painting shows
	// as soon as it can, the others follow behind it
	if len(app.art.candidates) > 0 {
		if len(app.art.ready) == 0 {
			best := len(app.art.candidates) - 1
			for c, i in app.art.candidates { if c.size > 0 && (app.art.candidates[best].size <= 0 || c.size < app.art.candidates[best].size) { best = i } }
			c := app.art.candidates[best]
			ordered_remove(&app.art.candidates, best)
			if art_have_id(c.id) { art_candidate_destroy(&c); art_pump(); return }
			art_download(c)
			return
		}
		c := pop(&app.art.candidates)
		if art_have_id(c.id) { art_candidate_destroy(&c); art_pump(); return }   // already cached: skip, no request
		art_download(c)
		return
	}

	// no candidates: fetch a listing from the next source
	art_list_next_source()
}

// Continues the state machine from an answer (a listing, a decode): the request that just ended is no longer in flight.
@(private = "file")
art_continue :: proc() {
	the_app.art.phase = .Idle
	art_pump()
}

@(private = "file")
art_wait :: proc(ms: i64) {
	app := the_app.art.app
	app.art.phase = .Waiting
	if app.art.wait_timer != base.NIL_HANDLE { host.clear_timer(&app.loop, app.art.wait_timer) }
	app.art.wait_timer = host.set_timer(&app.loop, f64(ms), 0, proc(data: rawptr) {
		the_app.art.wait_timer = base.NIL_HANDLE
		art_pump()
	}, app)
}

@(private = "file")
art_backoff_ms :: proc() -> i64 {
	ms := the_app.art.cfg.backoff_base_ms
	for _ in 0 ..< the_app.art.fails { ms *= 2; if ms >= the_app.art.cfg.backoff_max_ms { return the_app.art.cfg.backoff_max_ms } }
	return ms
}

@(private = "file")
art_fail :: proc() {
	the_app.art.fails += 1
	art_wait(art_backoff_ms())
	if the_app.art.fails == 1 { art_empty_failed(the_app.art.app) }   // (once: the page of a tab waiting for its first painting says it is trying again)
}

@(private = "file")
art_ok :: proc() { the_app.art.fails = 0 }

////////////////////////////////
// Listing: ask a source for paintings

@(private = "file")
art_sources_list :: proc() -> []string {
	s := the_app.art.cfg.sources
	out := make([dynamic]string, context.temp_allocator)
	for part in strings.split(s, ",", context.temp_allocator) {
		t := strings.trim_space(part)
		if t == "cleveland" || t == "commons" { append(&out, t) }
	}
	if len(out) == 0 { append(&out, "cleveland") }
	return out[:]
}

@(private = "file")
art_list_next_source :: proc() {
	srcs := art_sources_list()
	if len(srcs) == 0 { art_wait(the_app.art.cfg.backoff_max_ms); return }
	the_app.art.cand_src = (the_app.art.cand_src + 1) % len(srcs)
	src := srcs[the_app.art.cand_src]
	switch src {
	case "cleveland": art_cleveland_list()
	case "commons":   art_commons_list()
	case:             art_wait(the_app.art.cfg.backoff_base_ms)
	}
}

// The listing request shares one shape: a GET with the browser UI as initiator (no page, no cookies, an honest
// User-Agent set by the net layer), its body collected, bounded, on the process scope.
@(private = "file")
art_get :: proc(url: string, max_body: int, on_event: fetch.Event_Proc) {
	the_app.art.task = fetch.start(&the_app.art.app.loader, {
		request = {
			url = url, mode = .Navigate, credentials = .Omit, redirect = .Follow, destination = .Empty,   // the browser's own request: no page, so no CORS
			headers = {{"Accept", "application/json"}}, max_body = max_body,
		},
		on_event = on_event, scope = the_app.art.app.process, collect = true,
	})
}

////////////////////////////////
// Cleveland Museum of Art Open Access (CC0 paintings; no key). The listing is JSON; images.web.url is ~900 px, images.print
// larger when present. We ask for a random page of a few works and keep the ones that pass.

@(private = "file") CLEVELAND_API :: "https://openaccess-api.clevelandart.org/api/artworks/"

@(private = "file")
art_cleveland_list :: proc() {
	the_app.art.phase = .Listing
	// a random slice of the ~3900 CC0 paintings so the window is varied; the fields we need only
	skip := rand.int_max(3800)
	url := fmt.tprintf("%s?cc0=1&type=Painting&has_image=1&limit=%d&skip=%d&fields=id,title,creators,creation_date,images,url,department", CLEVELAND_API, max(the_app.art.cfg.window, 8), skip)
	art_get(url, 4 << 20, art_cleveland_event)
}

@(private = "file")
art_cleveland_event :: proc(user: rawptr, task: base.Handle, ev: ^fetch.Event) {
	if the_app == nil { return }
	the_app.art.task = base.NIL_HANDLE
	#partial switch ev.kind {
	case .Done:
		n := art_cleveland_parse(ev.data)
		if n == 0 { art_fail(); return }
		art_ok()
		art_continue()
	case .Failed:
		art_fail()
	}
}

// Appends candidates from a Cleveland listing. Returns how many were added.
@(private = "file")
art_cleveland_parse :: proc(body: []byte) -> int {
	v, err := json.parse(body, allocator = context.temp_allocator)
	if err != .None { return 0 }
	obj, is_obj := v.(json.Object)
	if !is_obj { return 0 }
	data, has := obj["data"].(json.Array)
	if !has { return 0 }
	added := 0
	for e in data {
		o, ok := e.(json.Object)
		if !ok { continue }
		img, size := art_cleveland_image(o)
		if img == "" || (size > 0 && size > i64(the_app.art.cfg.max_image_bytes)) { continue }   // (too big: it would only fail, and back off)
		id := 0
		if n, h := o["id"].(json.Float); h { id = int(n) }
		c := Art_Candidate{
			id = fmt.aprintf("cleveland:%d", id),
			image_url = strings.clone(img),
			source = strings.clone("cleveland"),
			title = art_json_str(o, "title"),
			artist = art_cleveland_creator(o),
			date = art_json_str(o, "creation_date"),
			museum = strings.clone("Cleveland Museum of Art"),
			record = art_json_str(o, "url"),
			license = strings.clone("CC0"),
			size = size,
		}
		append(&the_app.art.candidates, c)
		added += 1
	}
	return added
}

@(private = "file")
art_cleveland_image :: proc(o: json.Object) -> (url: string, size: i64) {
	images_o, has := o["images"].(json.Object)
	if !has { return }
	// prefer the larger "print" rendition, fall back to "web" (~900 px); both are JPEG
	for key in ([]string{"print", "web"}) {
		if r, h := images_o[key].(json.Object); h {
			if u, hu := r["url"].(json.String); hu && u != "" && art_http_url(string(u)) {
				if n, hn := r["filesize"].(json.Float); hn { size = i64(n) }
				return string(u), size
			}
		}
	}
	return
}

@(private = "file")
art_cleveland_creator :: proc(o: json.Object) -> string {
	arr, has := o["creators"].(json.Array)
	if !has || len(arr) == 0 { return strings.clone("") }
	first, ok := arr[0].(json.Object)
	if !ok { return strings.clone("") }
	// "description" is "Artist (role)"; "Vincent van Gogh (Dutch, 1853–1890)". The name before the first parenthesis reads best.
	if d, h := first["description"].(json.String); h && d != "" {
		s := string(d)
		if i := strings.index_byte(s, '('); i > 0 { s = strings.trim_space(s[:i]) }
		return strings.clone(s)
	}
	return art_json_str(first, "name")
}

////////////////////////////////
// Wikimedia Commons (Google Art Project works and featured paintings). The generator lists files of a category; imageinfo
// gives a scaled URL (iiurlwidth) and extmetadata gives artist, title and licence. Only freely licensed files are kept
// (public domain, CC0, CC-BY(-SA)); the attribution is shown in the caption.

@(private = "file") COMMONS_API :: "https://commons.wikimedia.org/w/api.php"
@(private = "file")
ART_COMMONS_CATEGORIES := [?]string{
	"Category:Google Art Project works by artist",
	"Category:Featured pictures of paintings",
}

@(private = "file")
art_commons_list :: proc() {
	the_app.art.phase = .Listing
	cat := ART_COMMONS_CATEGORIES[rand.int_max(len(ART_COMMONS_CATEGORIES))]
	width := max(1920, the_app.art.cfg.min_width_px)
	// categorymembers as a generator, imageinfo for each: url at a bounded width, the mime, the size, the licence metadata
	url := fmt.tprintf("%s?action=query&format=json&formatversion=2&generator=categorymembers&gcmtype=file&gcmlimit=%d&gcmtitle=%s&prop=imageinfo&iiprop=url|size|mime|extmetadata&iiurlwidth=%d",
		COMMONS_API, max(the_app.art.cfg.window, 8), url.percent_encoded(cat, url.UNRESERVED), width)
	art_get(url, 6 << 20, art_commons_event)
}

@(private = "file")
art_commons_event :: proc(user: rawptr, task: base.Handle, ev: ^fetch.Event) {
	if the_app == nil { return }
	the_app.art.task = base.NIL_HANDLE
	#partial switch ev.kind {
	case .Done:
		n := art_commons_parse(ev.data)
		if n == 0 { art_fail(); return }
		art_ok()
		art_continue()
	case .Failed:
		art_fail()
	}
}

@(private = "file")
art_commons_parse :: proc(body: []byte) -> int {
	v, err := json.parse(body, allocator = context.temp_allocator)
	if err != .None { return 0 }
	obj, is_obj := v.(json.Object)
	if !is_obj { return 0 }
	query, has := obj["query"].(json.Object)
	if !has { return 0 }
	pages, hp := query["pages"].(json.Array)
	if !hp { return 0 }
	added := 0
	for e in pages {
		o, ok := e.(json.Object)
		if !ok { continue }
		title := art_json_str_borrow(o, "title")
		ii, hii := o["imageinfo"].(json.Array)
		if !hii || len(ii) == 0 { continue }
		info, iok := ii[0].(json.Object)
		if !iok { continue }
		mime := art_json_str_borrow(info, "mime")
		if !strings.has_prefix(mime, "image/") { continue }
		img := art_json_str_borrow(info, "thumburl")
		if img == "" { img = art_json_str_borrow(info, "url") }
		if img == "" || !art_http_url(img) { continue }
		meta, hmeta := info["extmetadata"].(json.Object)
		license := hmeta ? art_commons_meta(meta, "LicenseShortName") : ""
		if !art_license_free(license, hmeta ? art_commons_meta(meta, "License") : "") { continue }   // only freely licensed files
		artist := hmeta ? art_commons_strip_html(art_commons_meta(meta, "Artist")) : ""
		date := hmeta ? art_commons_meta(meta, "DateTimeOriginal") : ""
		obj_title := hmeta ? art_commons_strip_html(art_commons_meta(meta, "ObjectName")) : ""
		if obj_title == "" { obj_title = art_commons_file_title(title) }
		c := Art_Candidate{
			id = strings.concatenate({"commons:", title}),
			image_url = strings.clone(img),
			source = strings.clone("commons"),
			title = strings.clone(obj_title),
			artist = strings.clone(artist),
			date = strings.clone(date),
			museum = strings.clone("Wikimedia Commons"),
			record = strings.concatenate({"https://commons.wikimedia.org/wiki/", url.percent_encoded(title, url.UNRESERVED)}),
			license = strings.clone(license == "" ? "Public domain" : license),
		}
		append(&the_app.art.candidates, c)
		added += 1
	}
	return added
}

@(private = "file")
art_commons_meta :: proc(meta: json.Object, key: string) -> string {
	if e, h := meta[key].(json.Object); h {
		if v, hv := e["value"].(json.String); hv { return string(v) }
	}
	return ""
}

// A Commons licence is kept only when it is unambiguously free: public domain, CC0, or a CC-BY / CC-BY-SA. Anything
// non-commercial, no-derivatives, fair-use or unknown is refused.
@(private = "file")
art_license_free :: proc(short, code: string) -> bool {
	s := base.ascii_lower(strings.concatenate({short, " ", code}, context.temp_allocator))
	if strings.contains(s, "non-commercial") || strings.contains(s, "noncommercial") || strings.contains(s, "-nc") { return false }
	if strings.contains(s, "no derivative") || strings.contains(s, "-nd") || strings.contains(s, "fair use") { return false }
	if strings.contains(s, "public domain") || strings.contains(s, "pd-") || strings.contains(s, "cc0") { return true }
	if strings.contains(s, "cc-by") || strings.contains(s, "cc by") { return true }
	return false
}

// extmetadata values may carry HTML (links, <span>); the caption shows plain text, so tags are dropped.
@(private = "file")
art_commons_strip_html :: proc(s: string) -> string {
	if strings.index_byte(s, '<') < 0 { return s }
	sb := strings.builder_make(context.temp_allocator)
	in_tag := false
	for c in s {
		switch c {
		case '<': in_tag = true
		case '>': in_tag = false
		case: if !in_tag { strings.write_rune(&sb, c) }
		}
	}
	return strings.trim_space(strings.to_string(sb))
}

// "File:Vincent van Gogh - Wheatfield.jpg" -> "Wheatfield" (a readable fallback when ObjectName is missing).
@(private = "file")
art_commons_file_title :: proc(title: string) -> string {
	s := strings.trim_prefix(title, "File:")
	if i := strings.last_index_byte(s, '.'); i > 0 { s = s[:i] }
	if i := strings.last_index(s, " - "); i >= 0 { s = s[i + 3:] }
	return s
}

////////////////////////////////
// Downloading one image

art_download :: proc(c: Art_Candidate) {
	the_app.art.phase = .Downloading
	art_candidate_destroy(&the_app.art.dl)
	the_app.art.dl = c   // we own it now
	the_app.art.dl_active = true
	the_app.art.task = fetch.start(&the_app.art.app.loader, {
		request = {
			url = c.image_url, mode = .Navigate, credentials = .Omit, redirect = .Follow, destination = .Empty,   // the browser's own request (a no-cors answer is opaque: its bytes are not ours to read)
			max_body = the_app.art.cfg.max_image_bytes,
		},
		on_event = art_download_event, scope = the_app.art.app.process, collect = true,
	})
}

@(private = "file")
art_download_event :: proc(user: rawptr, task: base.Handle, ev: ^fetch.Event) {
	if the_app == nil || !the_app.art.dl_active { return }
	#partial switch ev.kind {
	case .Response:
		// refuse early what is not an image (the max_body cap enforces size on the body side)
		if ev.response != nil && ev.response.has_mime && ev.response.mime.type != "" && ev.response.mime.type != "image" {
			the_app.art.task = base.NIL_HANDLE; the_app.art.dl_active = false; art_fail(); return
		}
	case .Done:
		the_app.art.task = base.NIL_HANDLE
		the_app.art.dl_active = false
		if len(ev.data) == 0 || i64(len(ev.data)) > i64(the_app.art.cfg.max_image_bytes) { art_fail(); return }
		if images.sniff(ev.data) == .Unknown { art_fail(); return }   // not a decodable image signature
		art_ok()
		art_validate(ev.data)
	case .Failed:
		the_app.art.task = base.NIL_HANDLE
		the_app.art.dl_active = false
		art_fail()
	}
}

////////////////////////////////
// Validation: decode on the decoder threads, at the size it will be kept at (dimensions, ratio, that it decodes)

@(private = "file")
art_validate :: proc(data: []byte) {
	app := the_app.art.app
	if !images.decoder_running() {
		s := &app.page_settings.images
		n := s.decode_threads
		if n < 0 { n = clamp(host.processor_count() / 2, 1, 4) }
		images.decoder_start(n, s.decode_stack_bytes > 0 ? s.decode_stack_bytes : images.DECODER_STACK_DEFAULT, s.decode_idle_ms)
	}
	if app.art.port == 0 { app.art.port = images.port_open(&app.loop, art_validated, nil) }
	if app.art.port == 0 { art_continue(); return }
	bytes := make([]byte, len(data))
	copy(bytes, data)
	app.art.blob = images.blob_make(bytes)
	lim := app.page_settings.images.limits
	lim.max_encoded_bytes = min(lim.max_encoded_bytes, app.art.cfg.max_image_bytes)
	app.art.phase = .Validating
	app.art.job = images.submit(app.art.port, images.job_make(.Decode, app.art.blob, art_decode_options(lim, app.art.cfg.short_side_px), ART_DECODE_PRIORITY))
	if app.art.job == 0 { images.blob_release(app.art.blob); app.art.blob = nil; art_continue() }
}

// The size is the shorter side's: images.reduced_size keeps the larger of the two scales, as a painting that covers a window needs.
art_decode_options :: proc(limits: images.Limits, short_side_px: int) -> images.Decode_Options {
	return {limits = limits, target_w = short_side_px, target_h = short_side_px, downscale_below = 1, first_frame_only = true}
}

@(private = "file")
art_validated :: proc(user: rawptr, j: ^images.Job) {
	defer images.job_free(j)
	the_app.art.job = 0
	blob := the_app.art.blob
	the_app.art.blob = nil
	if j.err != .None || j.image == nil || !art_dimensions_ok(j.info.width, j.info.height) {
		if blob != nil { images.blob_release(blob) }
		art_candidate_destroy(&the_app.art.dl)   // drop this one, do not keep the file
		art_continue()
		return
	}
	img := j.image
	j.image = nil   // the worker's now
	art_encode(blob, img, j.info.width, j.info.height)
}

// A painting is kept only if it is large enough and not an extreme sliver: a minimum width for full screen, and a ratio
// between 1:3 and 3:1 so neither orientation is a letterbox.
@(private = "file")
art_dimensions_ok :: proc(w, h: int) -> bool {
	if w < the_app.art.cfg.min_width_px || h <= 0 { return false }
	r := f64(w) / f64(h)
	return r >= 0.33 && r <= 3.0
}

////////////////////////////////
// Keeping: on a worker, the painting encoded at the size it was decoded at, then the file and its metadata; the loop adds it to the window

// Handed to the worker whole and back at art_encode_done: nothing is shared with the loop meanwhile.
@(private = "file")
Art_Encode_Job :: struct {
	alloc:   runtime.Allocator,   // the loop's: what the item owns is freed there
	gen:     u32,
	dir:     string,
	quality: f32,
	c:       Art_Candidate,
	blob:    ^images.Blob,        // the bytes as they came
	image:   ^images.Image,
	item:    Art_Item,            // the worker's answer
	ok:      bool,
}

@(private = "file")
art_encode :: proc(blob: ^images.Blob, img: ^images.Image, w, h: int) {
	app := the_app.art.app
	if !art_ensure_dir() { images.blob_release(blob); images.image_destroy(img); art_candidate_destroy(&app.art.dl); art_continue(); return }
	j := new(Art_Encode_Job)
	j^ = {alloc = context.allocator, gen = app.art.gen, dir = app.art.dir, quality = app.art.cfg.jpeg_quality, c = app.art.dl, blob = blob, image = img}
	j.item.width, j.item.height = w, h
	app.art.dl = {}   // ownership moved into the job
	app.art.phase = .Encoding
	app.art.jobs += 1
	host.run_blocking(&app.blocking, art_encode_work, art_encode_done, j)
}

// The JPEG to keep instead of `source`, nil when `source` is better kept as it is: it needed no reducing and is small, or the JPEG
// would not be smaller. The result is allocated with `allocator`.
art_reencoded :: proc(source: []byte, img: ^images.Image, quality: f32, allocator := context.allocator) -> []byte {
	if len(img.frames) == 0 || img.stride != img.width * 4 { return nil }
	if !img.reduced && len(source) <= ART_KEEP_AS_IS_BYTES { return nil }
	out, ok := images.encode_rgba(img.frames[0].pixels, img.width, img.height, .Jpeg, quality, false, allocator)
	if !ok { return nil }
	if len(out) >= len(source) { delete(out, allocator); return nil }
	return out
}

@(private = "file")
art_encode_work :: proc(data: rawptr) {
	j := (^Art_Encode_Job)(data)
	context.allocator = j.alloc
	kept := j.blob.bytes
	ext := art_ext(j.c.image_url)
	w, h := j.item.width, j.item.height
	if out := art_reencoded(kept, j.image, j.quality, context.temp_allocator); out != nil {
		kept, ext, w, h = out, ".jpg", j.image.width, j.image.height
	}
	images.image_destroy(j.image)
	j.image = nil
	c := j.c
	j.c = {}   // what it owns goes to the item, but for what the item has no use for
	defer { delete(c.image_url) }
	name := strings.concatenate({art_safe_stem(c.id), ext}, context.temp_allocator)
	j.item = Art_Item{
		format = ART_CACHE_FORMAT, id = c.id, file = name, source = c.source, title = c.title, artist = c.artist, date = c.date, museum = c.museum, record = c.record,
		license = c.license, width = w, height = h, bytes = i64(len(kept)), fetched = i64(time.to_unix_seconds(time.now())),
	}
	meta, merr := json.marshal(j.item, {}, context.temp_allocator)   // (the image's name, not its path: the folder may move with the profile)
	j.item.file = strings.concatenate({j.dir, "/", name})
	if merr != nil { return }
	if os.write_entire_file(j.item.file, kept) != nil { return }
	j.ok = os.write_entire_file(art_meta_path(j.item.file), meta) == nil
}

@(private = "file")
art_encode_done :: proc(data: rawptr) {
	j := (^Art_Encode_Job)(data)
	defer free(j)
	app := the_app.art.app
	app.art.jobs -= 1
	images.blob_release(j.blob)
	if j.gen != app.art.gen || !j.ok {   // cleared, stopped or not written: nothing of it stays
		art_delete_files(&j.item)
		art_item_destroy(&j.item)
		if j.gen == app.art.gen { art_continue() }
		return
	}
	it := new(Art_Item)
	it^ = j.item
	append(&app.art.ready, it)
	art_fill_waiting(app)   // an art new tab that showed no painting yet shows this one
	request_frames(app, 1)
	art_continue()
}

////////////////////////////////
// The scan: what an earlier session left, once, on a worker. The folder then holds what the window shows next and nothing else

@(private = "file")
Art_Scan_Job :: struct {
	alloc:     runtime.Allocator,
	gen:       u32,
	dir:       string,
	window:    int,
	max_bytes: i64,
	items:     [dynamic]^Art_Item,   // the worker's answer
}

@(private = "file")
art_scan :: proc(app: ^App) {
	if app.art.scan != .Not_Yet || !art_ensure_dir() { return }
	j := new(Art_Scan_Job)
	j^ = {alloc = context.allocator, gen = app.art.gen, dir = app.art.dir, window = app.art.cfg.window, max_bytes = app.art.cfg.max_cache_bytes}
	app.art.scan = .Running
	app.art.jobs += 1
	host.run_blocking(&app.blocking, art_scan_work, art_scan_done, j)
}

@(private = "file")
art_scan_work :: proc(data: rawptr) {
	j := (^Art_Scan_Job)(data)
	context.allocator = j.alloc
	entries, err := os.read_directory_by_path(j.dir, -1, context.temp_allocator)
	if err != nil { return }
	found := make([dynamic]^Art_Item, context.temp_allocator)
	for e in entries {
		if e.type == .Directory || !strings.has_suffix(e.name, ".json") { continue }
		if it := art_item_read(j.dir, e.fullpath); it != nil { append(&found, it) }
	}
	slice.sort_by(found[:], proc(a, b: ^Art_Item) -> bool { return a.fetched > b.fetched })   // the newest stay
	total: i64 = 0
	for it in found {
		if len(j.items) < j.window && total + it.bytes <= j.max_bytes {
			total += it.bytes
			append(&j.items, it)
		} else {
			art_item_destroy(it)
			free(it)
		}
	}
	for e in entries { if e.type != .Directory && !art_names_file(j.items[:], e.name) { _ = os.remove(e.fullpath) } }
}

// The painting a JSON file describes, nil when it is of another format or its image is not there.
@(private = "file")
art_item_read :: proc(dir, path: string) -> ^Art_Item {
	text, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil { return nil }
	it := new(Art_Item)
	if json.unmarshal(text, it) == nil && it.format == ART_CACHE_FORMAT && it.id != "" && it.file != "" && strings.index_any(it.file, "/\\") < 0 {
		full := strings.concatenate({dir, "/", it.file})
		delete(it.file)
		it.file = full
		if info, serr := os.stat(full, context.temp_allocator); serr == nil && info.size > 0 {
			it.bytes = info.size
			return it
		}
	}
	art_item_destroy(it)
	free(it)
	return nil
}

// Whether `name` (of a file of the folder) is one of the items' image or JSON file.
@(private = "file")
art_names_file :: proc(items: []^Art_Item, name: string) -> bool {
	stem := art_stem(name)
	for it in items {
		file := it.file[strings.last_index_byte(it.file, '/') + 1:]
		if art_stem(file) == stem { return true }
	}
	return false
}

@(private = "file")
art_scan_done :: proc(data: rawptr) {
	j := (^Art_Scan_Job)(data)
	defer free(j)
	app := the_app.art.app
	app.art.jobs -= 1
	app.art.scan = .Done
	for it in j.items {
		if j.gen != app.art.gen || art_have_id(it.id) { art_item_destroy(it); free(it) } else { append(&app.art.ready, it) }
	}
	has_items := len(j.items) > 0 && j.gen == app.art.gen
	delete(j.items)
	if has_items {
		art_fill_waiting(app)
		request_frames(app, 1)
	}
	art_pump()
}

////////////////////////////////
// The cache folder and its upkeep

// <profile>/tmp/newtab-art: a stable, dedicated subfolder of the profile's temporary area.
@(private = "file")
art_ensure_dir :: proc() -> bool {
	if the_app.art.dir != "" { return true }
	base_dir := strings.concatenate({the_app.art.app.profile_dir, "/tmp/newtab-art"}, context.temp_allocator)
	if os.make_directory_all(base_dir) != nil && !os.is_dir(base_dir) { return false }
	the_app.art.dir = strings.clone(base_dir)
	return true
}

@(private = "file")
art_purge_over_cap :: proc() {
	if the_app.art.dir == "" { return }
	total: i64 = 0
	for it in the_app.art.ready { total += it.bytes }
	// oldest ready items go first until under the cap (never the current pick: it may still be on screen)
	for total > the_app.art.cfg.max_cache_bytes && len(the_app.art.ready) > 1 {
		oldest := -1
		for it, i in the_app.art.ready {
			if the_app.art.current != nil && it.id == the_app.art.current.id { continue }
			if oldest < 0 || the_app.art.ready[i].fetched < the_app.art.ready[oldest].fetched { oldest = i }
		}
		if oldest < 0 { break }
		it := the_app.art.ready[oldest]
		total -= it.bytes
		art_delete_files(it)
		art_item_destroy(it)
		free(it)
		ordered_remove(&the_app.art.ready, oldest)
	}
}

@(private = "file")
art_delete_files :: proc(it: ^Art_Item) {
	if it.file == "" { return }
	_ = os.remove(it.file)
	_ = os.remove(art_meta_path(it.file))
}

// The name without its extension.
@(private = "file")
art_stem :: proc(name: string) -> string {
	i := strings.last_index_byte(name, '.')
	return i >= 0 ? name[:i] : name
}

@(private = "file")
art_meta_path :: proc(file: string) -> string { return strings.concatenate({art_stem(file), ".json"}, context.temp_allocator) }

// The painting and everything of it.
@(private = "file")
art_drop :: proc(it: ^Art_Item) {
	art_delete_files(it)
	art_item_destroy(it)
	free(it)
}

// Cleared with "Clear browsing data" (site_data_ui.odin's cache kind): every cached painting and its metadata go, and the
// window starts over. The task, if running, fills it again.
art_clear_cache :: proc() {
	art_cancel_io()
	if the_app.art.phase == .Encoding { the_app.art.phase = .Idle }   // (it comes back to nothing: art_encode_done)
	if the_app.art.current != nil && !art_in_ready(the_app.art.current) { art_drop(the_app.art.current) }
	the_app.art.current = nil
	if the_app.art.retired != nil { art_drop(the_app.art.retired) }
	the_app.art.retired = nil
	for it in the_app.art.ready { art_drop(it) }
	clear(&the_app.art.ready)
	for s in the_app.art.recent { delete(s) }
	clear(&the_app.art.recent)
	if the_app.art.dir != "" {
		// remove any stray files the folder still holds (a crash between the image and its metadata)
		if entries, rerr := os.read_directory_by_path(the_app.art.dir, -1, context.temp_allocator); rerr == nil {
			for e in entries { if e.type != .Directory { _ = os.remove(e.fullpath) } }
		}
	}
	if the_app.art.started { art_pump() }
}

////////////////////////////////
// What the page asks for: a painting to show now

// Returns a painting for a new tab, or nil when none is ready. "Smart": it prefers one whose orientation suits the
// window (landscape for a wide window, portrait for a tall one), and it avoids the last `window` picks. The chosen one
// becomes the current pick; art_consume replaces it once the tab has drawn.
art_pick :: proc(landscape: bool) -> ^Art_Item {
	if len(the_app.art.ready) == 0 { return nil }
	best: ^Art_Item
	best_score := min(int)
	for it in the_app.art.ready {
		if art_recently_shown(it.id) { continue }
		score := 0
		it_landscape := it.width >= it.height
		if it_landscape == landscape { score += 2 }   // matches the window's orientation
		if best == nil || score > best_score { best, best_score = it, score }
	}
	if best == nil {   // every ready one was shown lately: take the oldest by fetch time anyway
		for it in the_app.art.ready { if best == nil || it.fetched < best.fetched { best = it } }
	}
	// remember the pick so it does not repeat at once; cap the ring at the window size
	append(&the_app.art.recent, strings.clone(best.id))
	for len(the_app.art.recent) > max(the_app.art.cfg.window, 1) { delete(the_app.art.recent[0]); ordered_remove(&the_app.art.recent, 0) }
	// the previous current, if it was consumed (removed from `ready`), was seen: it leaves the disk, one pick later, for a page that has not read it yet
	if the_app.art.current != nil && the_app.art.current != best && !art_in_ready(the_app.art.current) {
		if the_app.art.retired != nil { art_drop(the_app.art.retired) }
		the_app.art.retired = the_app.art.current
	}
	the_app.art.current = best
	return best
}

@(private = "file")
art_recently_shown :: proc(id: string) -> bool {
	for s in the_app.art.recent { if s == id { return true } }
	return false
}

// Called once an art new tab has shown the current painting: it leaves the ready window (it was consumed) and the task
// fetches a replacement so the window stays full of unseen paintings. Its file stays through the next two picks (art_pick), long
// enough for the tab to read it; a new new tab gets a different one.
art_consume :: proc() {
	if the_app.art.current == nil { return }
	// drop the current from `ready` so the window refills with a fresh painting; keep the Art_Item alive as `current`
	for it, i in the_app.art.ready {
		if it == the_app.art.current { ordered_remove(&the_app.art.ready, i); break }
	}
	if the_app.art.started { art_pump() }
}

// True when at least one painting is ready to show (newtab_art_page.odin decides between the art page and the plain start page).
art_ready :: proc() -> bool { return len(the_app.art.ready) > 0 || the_app.art.current != nil }

////////////////////////////////
// Small helpers

@(private = "file")
art_have_id :: proc(id: string) -> bool {
	for it in the_app.art.ready { if it.id == id { return true } }
	if the_app.art.current != nil && the_app.art.current.id == id { return true }
	return false
}

@(private = "file")
art_in_ready :: proc(it: ^Art_Item) -> bool {
	for r in the_app.art.ready { if r == it { return true } }
	return false
}

@(private = "file")
art_json_str :: proc(o: json.Object, key: string) -> string {
	if v, h := o[key].(json.String); h { return strings.clone(string(v)) }
	return strings.clone("")
}

@(private = "file")
art_json_str_borrow :: proc(o: json.Object, key: string) -> string {
	if v, h := o[key].(json.String); h { return string(v) }
	return ""
}

@(private = "file")
art_http_url :: proc(u: string) -> bool {
	return (strings.has_prefix(u, "https://") || strings.has_prefix(u, "http://")) && len(u) <= 4096
}

// The extension of an image URL (".jpg" by default): the cache file keeps a plausible one so an external viewer opens it.
@(private = "file")
art_ext :: proc(u: string) -> string {
	s := u
	if i := strings.index_byte(s, '?'); i >= 0 { s = s[:i] }
	if i := strings.last_index_byte(s, '.'); i >= 0 {
		ext := base.ascii_lower(s[i:])
		switch ext {
		case ".jpg", ".jpeg", ".png", ".webp", ".gif", ".bmp": return strings.clone(ext, context.temp_allocator)
		}
	}
	return ".jpg"
}

// A filesystem-safe stem from a source-prefixed id (no \ / : * ? " < > | and bounded).
@(private = "file")
art_safe_stem :: proc(id: string) -> string {
	sb := strings.builder_make(context.temp_allocator)
	for c in id {
		switch c {
		case 'a' ..= 'z', 'A' ..= 'Z', '0' ..= '9', '-', '_', '.': strings.write_rune(&sb, c)
		case: strings.write_byte(&sb, '_')
		}
		if strings.builder_len(sb) >= 120 { break }
	}
	return strings.to_string(sb)
}
