package browser

// The artistic new tab: when browser.newtab.art.enabled is on, a new tab shows a public-domain / freely licensed
// painting, filling the window behind the address bar and the start page's shortcuts, with a discreet caption (title,
// artist, date, museum, a link to the record) and two small buttons (another painting, open the record). It follows
// Google Arts & Culture's "art new tab" idea, but every piece runs natively here: the engine renders the page, the
// shell downloads and caches the images.
//
// Nothing reaches the network before the first art new tab of the session is shown (never at start-up, never when the
// option is off, never while the loader is held offline). From then on a background task keeps a sliding window of about
// browser.newtab.art.window images ready in a dedicated folder of the profile's temporary area, each with a JSON file of
// its metadata. A shown image is replaced by a fresh one, so the window always holds that many unseen paintings; the
// last browser.newtab.art.window picks are remembered so the same painting does not come back at once. The downloader is
// courteous: one request at a time per host, an honest User-Agent (Wren/<version>), exponential backoff on 429 / 403 /
// network error, and it validates every answer (image MIME, a size cap, a probe decode with the shared decoder, a sane
// aspect ratio and a minimum width for full-screen use) before keeping it. Files beyond the cache cap are purged oldest
// first. The task stops after a spell with no art new tab open (inactivity) and resumes on the next one.
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

import "core:encoding/json"
import "core:fmt"
import "core:math/rand"
import "core:os"
import "core:strings"
import "core:time"
import "wb:base"
import "wb:config"
import "wb:fetch"
import "wb:host"
import "wb:images"

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
		idle_ms = config.float_of(p, "browser.newtab.art.idle_minutes") * 60_000,
		backoff_base_ms = config.int_of(p, "browser.newtab.art.backoff_base_ms"),
		backoff_max_ms = config.int_of(p, "browser.newtab.art.backoff_max_ms"),
	}
}

art_settings_destroy :: proc(s: ^Art_Settings) { delete(s.sources) }

////////////////////////////////
// A cached painting

// One painting ready to show: the bytes on disk and the facts the caption needs. Every string is owned.
Art_Item :: struct {
	id:        string,   // stable, source-prefixed ("cleveland:123", "commons:File:x.jpg"): the cache file's stem, dedup key
	file:      string,   // absolute path of the image file in the cache folder
	source:    string,   // "cleveland" / "commons"
	title:     string,
	artist:    string,
	date:      string,   // the work's date ("1889", "c. 1510"), free text
	museum:    string,
	record:    string,   // the web page of the painting's record (opened by "open the record")
	license:   string,   // "CC0", "Public domain", "CC BY-SA 4.0", ...
	width:     int,       // image pixels (probed)
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
	Validating,  // probing an image on the decoder threads
	Waiting,     // backing off, or window full: a timer will wake it
}

Art :: struct {
	app:        ^App,
	cfg:        Art_Settings,
	watch:      int,
	dir:        string,         // the cache folder (owned); "" until art_ensure_dir

	started:    bool,           // the background task is running (started on the first art new tab)
	phase:      Art_Phase,
	last_shown_ms: f64,         // loop clock when an art new tab was last shown (inactivity)
	stop_timer: base.Handle,    // the inactivity deadline

	ready:      [dynamic]^Art_Item,   // paintings downloaded and validated, newest last
	recent:     [dynamic]string,      // ids shown lately, oldest first (at most `window`): no immediate repeat
	current:    ^Art_Item,            // what the last art new tab chose (shown): replaced once consumed

	// the listing in hand: candidate image descriptors not yet downloaded
	candidates: [dynamic]Art_Candidate,
	cand_src:   int,            // which source index the candidates came from (round-robins the sources)

	// the download in flight
	task:       base.Handle,
	dl_bytes:   [dynamic]byte,
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
		museum = strings.clone(c.museum), record = strings.clone(c.record), license = strings.clone(c.license),
	}
}

art: Art

////////////////////////////////
// Lifecycle (the shell starts and ends it, main.odin)

art_init :: proc(app: ^App) {
	art.app = app
	art.cfg = art_settings_from_prefs(&app.prefs)
	art.ready = make([dynamic]^Art_Item, base.process_allocator())
	art.recent = make([dynamic]string, base.process_allocator())
	art.candidates = make([dynamic]Art_Candidate, base.process_allocator())
	art.dl_bytes = make([dynamic]byte, base.process_allocator())
	art.watch = config.watch(&app.prefs, "browser.newtab.art.", proc(user: rawptr, name: string, p: ^config.Prefs) {
		old := art.cfg
		art.cfg = art_settings_from_prefs(p)
		art_settings_destroy(&old)
		// turning the option off while it ran stops it at once and lets the next new tab be the plain start page again
		if !art.cfg.enabled && art.started { art_stop() }
		if art.started { art_pump() }
	}, app)
}

art_destroy :: proc(app: ^App) {
	config.unwatch(&app.prefs, art.watch)
	art_cancel_io()
	if art.stop_timer != base.NIL_HANDLE { host.clear_timer(&app.loop, art.stop_timer) }
	if art.wait_timer != base.NIL_HANDLE { host.clear_timer(&app.loop, art.wait_timer) }
	if art.port != 0 { images.port_close(art.port) }
	// `current`, if it was consumed, is no longer in `ready`: free it separately. If it is still in `ready` it is freed with it.
	if art.current != nil && !art_in_ready(art.current) { art_item_destroy(art.current); free(art.current) }
	for it in art.ready { art_item_destroy(it); free(it) }
	delete(art.ready)
	for s in art.recent { delete(s) }
	delete(art.recent)
	for &c in art.candidates { art_candidate_destroy(&c) }
	delete(art.candidates)
	art_candidate_destroy(&art.dl)
	delete(art.dl_bytes)
	art_settings_destroy(&art.cfg)
	delete(art.dir)
	art = {}
}

@(private = "file")
art_cancel_io :: proc() {
	if art.task != base.NIL_HANDLE { fetch.cancel(&art.app.loader, art.task); art.task = base.NIL_HANDLE }
	art.dl_active = false
	if art.job != 0 { images.job_cancel(art.job); art.job = 0 }
	if art.blob != nil { images.blob_release(art.blob); art.blob = nil }
}

////////////////////////////////
// The trigger: the first art new tab of the session (newtab_art_page.odin calls this)

// Called when an art new tab is shown. Starts the background task on the very first one, and marks activity so an idle
// window keeps running. Never touches the network itself: art_pump does, and only when the option is on and the loader
// is not held offline.
art_seen_new_tab :: proc(app: ^App) {
	if !art.cfg.enabled { return }
	art.last_shown_ms = f64(host.now_ns(&app.loop)) / 1e6
	if !art.started {
		art.started = true
		art.phase = .Idle
	}
	art_schedule_stop()
	art_pump()
}

@(private = "file")
art_schedule_stop :: proc() {
	app := art.app
	if art.stop_timer != base.NIL_HANDLE { host.clear_timer(&app.loop, art.stop_timer); art.stop_timer = base.NIL_HANDLE }
	if art.cfg.idle_ms <= 0 { return }
	art.stop_timer = host.set_timer(&app.loop, art.cfg.idle_ms, 0, proc(data: rawptr) {
		art.stop_timer = base.NIL_HANDLE
		art_stop()   // inactivity: nothing downloads until the next art new tab
	}, app)
}

@(private = "file")
art_stop :: proc() {
	art_cancel_io()
	if art.wait_timer != base.NIL_HANDLE { host.clear_timer(&art.app.loop, art.wait_timer); art.wait_timer = base.NIL_HANDLE }
	art.started = false
	art.phase = .Idle
}

////////////////////////////////
// The pump: one step of the state machine, re-entered after every async result

// Does one thing and returns: start a listing, download the next candidate, or wait. The network is only ever touched
// here, guarded by the option and the loader's offline hold.

@(private = "file")
art_pump :: proc() {
	app := art.app
	if !art.started || !art.cfg.enabled { return }
	if art.phase == .Listing || art.phase == .Downloading || art.phase == .Validating { return }   // a request is in flight
	if app.loader.hold { art_wait(art.cfg.backoff_base_ms); return }   // held offline: try again shortly, make no request

	art_purge_over_cap()

	// the window is full: nothing to do until a painting is consumed (a shown new tab calls art_consume, which pumps again)
	if len(art.ready) >= art.cfg.window {
		art.phase = .Idle
		return
	}

	// a candidate in hand: download it
	if len(art.candidates) > 0 {
		c := pop(&art.candidates)
		if art_have_id(c.id) { art_candidate_destroy(&c); art_pump(); return }   // already cached: skip, no request
		art_download(c)
		return
	}

	// no candidates: fetch a listing from the next source
	art_list_next_source()
}

// Continues the state machine from an answer (a listing, a probe): the request that just ended is no longer in flight.
@(private = "file")
art_continue :: proc() {
	art.phase = .Idle
	art_pump()
}

@(private = "file")
art_wait :: proc(ms: i64) {
	app := art.app
	art.phase = .Waiting
	if art.wait_timer != base.NIL_HANDLE { host.clear_timer(&app.loop, art.wait_timer) }
	art.wait_timer = host.set_timer(&app.loop, f64(ms), 0, proc(data: rawptr) {
		art.wait_timer = base.NIL_HANDLE
		art_pump()
	}, app)
}

@(private = "file")
art_backoff_ms :: proc() -> i64 {
	ms := art.cfg.backoff_base_ms
	for _ in 0 ..< art.fails { ms *= 2; if ms >= art.cfg.backoff_max_ms { return art.cfg.backoff_max_ms } }
	return ms
}

@(private = "file")
art_fail :: proc() {
	art.fails += 1
	art_wait(art_backoff_ms())
}

@(private = "file")
art_ok :: proc() { art.fails = 0 }

////////////////////////////////
// Listing: ask a source for paintings

@(private = "file")
art_sources_list :: proc() -> []string {
	s := art.cfg.sources
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
	if len(srcs) == 0 { art_wait(art.cfg.backoff_max_ms); return }
	art.cand_src = (art.cand_src + 1) % len(srcs)
	src := srcs[art.cand_src]
	switch src {
	case "cleveland": art_cleveland_list()
	case "commons":   art_commons_list()
	case:             art_wait(art.cfg.backoff_base_ms)
	}
}

// The listing request shares one shape: a GET with the browser UI as initiator (no page, no cookies, an honest
// User-Agent set by the net layer), its body collected, bounded, on the process scope.
@(private = "file")
art_get :: proc(url: string, max_body: int, on_event: fetch.Event_Proc) {
	art.task = fetch.start(&art.app.loader, {
		request = {
			url = url, mode = .Navigate, credentials = .Omit, redirect = .Follow, destination = .Empty,   // the browser's own request: no page, so no CORS
			headers = {{"Accept", "application/json"}}, max_body = max_body,
		},
		on_event = on_event, scope = art.app.process, collect = true,
	})
}

////////////////////////////////
// Cleveland Museum of Art Open Access (CC0 paintings; no key). The listing is JSON; images.web.url is ~900 px, images.print
// larger when present. We ask for a random page of a few works and keep the ones that pass.

@(private = "file") CLEVELAND_API :: "https://openaccess-api.clevelandart.org/api/artworks/"

@(private = "file")
art_cleveland_list :: proc() {
	art.phase = .Listing
	// a random slice of the ~3900 CC0 paintings so the window is varied; the fields we need only
	skip := rand.int_max(3800)
	url := fmt.tprintf("%s?cc0=1&type=Painting&has_image=1&limit=%d&skip=%d&fields=id,title,creators,creation_date,images,url,department", CLEVELAND_API, max(art.cfg.window, 8), skip)
	art_get(url, 4 << 20, art_cleveland_event)
}

@(private = "file")
art_cleveland_event :: proc(user: rawptr, task: base.Handle, ev: ^fetch.Event) {
	if the_app == nil { return }
	art.task = base.NIL_HANDLE
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
		img := art_cleveland_image(o)
		if img == "" { continue }
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
		}
		append(&art.candidates, c)
		added += 1
	}
	return added
}

@(private = "file")
art_cleveland_image :: proc(o: json.Object) -> string {
	images_o, has := o["images"].(json.Object)
	if !has { return "" }
	// prefer the larger "print" rendition, fall back to "web" (~900 px); both are JPEG
	for key in ([]string{"print", "web"}) {
		if r, h := images_o[key].(json.Object); h {
			if u, hu := r["url"].(json.String); hu && u != "" && art_http_url(string(u)) { return string(u) }
		}
	}
	return ""
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
	art.phase = .Listing
	cat := ART_COMMONS_CATEGORIES[rand.int_max(len(ART_COMMONS_CATEGORIES))]
	width := max(1920, art.cfg.min_width_px)
	// categorymembers as a generator, imageinfo for each: url at a bounded width, the mime, the size, the licence metadata
	url := fmt.tprintf("%s?action=query&format=json&formatversion=2&generator=categorymembers&gcmtype=file&gcmlimit=%d&gcmtitle=%s&prop=imageinfo&iiprop=url|size|mime|extmetadata&iiurlwidth=%d",
		COMMONS_API, max(art.cfg.window, 8), art_url_encode(cat), width)
	art_get(url, 6 << 20, art_commons_event)
}

@(private = "file")
art_commons_event :: proc(user: rawptr, task: base.Handle, ev: ^fetch.Event) {
	if the_app == nil { return }
	art.task = base.NIL_HANDLE
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
			record = strings.concatenate({"https://commons.wikimedia.org/wiki/", art_url_encode(title)}),
			license = strings.clone(license == "" ? "Public domain" : license),
		}
		append(&art.candidates, c)
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
	s := strings.to_lower(strings.concatenate({short, " ", code}, context.temp_allocator), context.temp_allocator)
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

@(private = "file")
art_download :: proc(c: Art_Candidate) {
	art.phase = .Downloading
	art_candidate_destroy(&art.dl)
	art.dl = c   // we own it now
	art.dl_active = true
	clear(&art.dl_bytes)
	art.task = fetch.start(&art.app.loader, {
		request = {
			url = c.image_url, mode = .Navigate, credentials = .Omit, redirect = .Follow, destination = .Empty,   // the browser's own request (a no-cors answer is opaque: its bytes are not ours to read)
			max_body = art.cfg.max_image_bytes,
		},
		on_event = art_download_event, scope = art.app.process, collect = true,
	})
}

@(private = "file")
art_download_event :: proc(user: rawptr, task: base.Handle, ev: ^fetch.Event) {
	if the_app == nil || !art.dl_active { return }
	#partial switch ev.kind {
	case .Response:
		// refuse early what is not an image (the max_body cap enforces size on the body side)
		if ev.response != nil && ev.response.has_mime && ev.response.mime.type != "" && ev.response.mime.type != "image" {
			art.task = base.NIL_HANDLE; art.dl_active = false; art_fail(); return
		}
	case .Done:
		art.task = base.NIL_HANDLE
		art.dl_active = false
		if len(ev.data) == 0 || i64(len(ev.data)) > i64(art.cfg.max_image_bytes) { art_fail(); return }
		if images.sniff(ev.data) == .Unknown { art_fail(); return }   // not a decodable image signature
		art_ok()
		// keep the bytes while the probe runs: art_keep writes them to disk once the image passes
		clear(&art.dl_bytes)
		append(&art.dl_bytes, ..ev.data)
		art_validate(art.dl_bytes[:])
	case .Failed:
		art.task = base.NIL_HANDLE
		art.dl_active = false
		art_fail()
	}
}

////////////////////////////////
// Validation: probe the bytes on the decoder threads (dimensions, ratio, that it decodes)

@(private = "file")
art_validate :: proc(data: []byte) {
	app := art.app
	if !images.decoder_running() {
		s := &app.page_settings.images
		n := s.decode_threads
		if n < 0 { n = clamp(host.processor_count() / 2, 1, 4) }
		images.decoder_start(n, s.decode_stack_bytes > 0 ? s.decode_stack_bytes : images.DECODER_STACK_DEFAULT, s.decode_idle_ms)
	}
	if art.port == 0 { art.port = images.port_open(&app.loop, art_validated, nil) }
	if art.port == 0 { art_continue(); return }
	bytes := make([]byte, len(data))
	copy(bytes, data)
	art.blob = images.blob_make(bytes)
	lim := app.page_settings.images.limits
	lim.max_encoded_bytes = min(lim.max_encoded_bytes, art.cfg.max_image_bytes)
	opts := images.Decode_Options{limits = lim}
	art.phase = .Validating
	art.job = images.submit(art.port, images.job_make(.Probe, art.blob, opts))
	if art.job == 0 { images.blob_release(art.blob); art.blob = nil; art_continue() }
}

@(private = "file")
art_validated :: proc(user: rawptr, j: ^images.Job) {
	defer images.job_free(j)
	art.job = 0
	if art.blob != nil { images.blob_release(art.blob); art.blob = nil }
	ok := j.err == .None && art_dimensions_ok(j.info.width, j.info.height)
	if !ok {
		art_candidate_destroy(&art.dl)   // drop this one, do not keep the file
		art_continue()
		return
	}
	art_keep(art.dl, j.info.width, j.info.height)
	art.dl = {}   // ownership moved into the Art_Item
	art_continue()
}

// A painting is kept only if it is large enough and not an extreme sliver: a minimum width for full screen, and a ratio
// between 1:3 and 3:1 so neither orientation is a letterbox.
@(private = "file")
art_dimensions_ok :: proc(w, h: int) -> bool {
	if w < art.cfg.min_width_px || h <= 0 { return false }
	r := f64(w) / f64(h)
	return r >= 0.33 && r <= 3.0
}

////////////////////////////////
// Keeping: write the image and its metadata to the cache folder, add to the ready window

@(private = "file")
art_keep :: proc(c: Art_Candidate, w, h: int) {
	if !art_ensure_dir() { art_candidate_destroy_copy(c); return }
	stem := art_safe_stem(c.id)
	img_path := strings.concatenate({art.dir, "/", stem, art_ext(c.image_url)}, context.temp_allocator)
	if os.write_entire_file(img_path, art_last_bytes()) != nil { art_candidate_destroy_copy(c); return }
	it := new(Art_Item)
	it^ = Art_Item{
		id = strings.clone(c.id), file = strings.clone(img_path), source = strings.clone(c.source),
		title = strings.clone(c.title), artist = strings.clone(c.artist), date = strings.clone(c.date),
		museum = strings.clone(c.museum), record = strings.clone(c.record), license = strings.clone(c.license),
		width = w, height = h, bytes = i64(len(art_last_bytes())), fetched = i64(time.to_unix_seconds(time.now())),
	}
	meta_path := strings.concatenate({art.dir, "/", stem, ".json"}, context.temp_allocator)
	_ = os.write_entire_file(meta_path, transmute([]byte)art_meta_json(it^))
	append(&art.ready, it)
	art_candidate_destroy_copy(c)
	art_fill_waiting(art.app)   // an art new tab that showed no painting yet shows this one
	request_frames(art.app, 1)
}

// The bytes of the download in hand still live in art.blob until it is released; art_keep runs after the probe, which
// released the blob. We therefore keep a copy of the download bytes alongside the candidate while it is in flight.
@(private = "file")
art_last_bytes :: proc() -> []byte { return art.dl_bytes[:] }

@(private = "file")
art_candidate_destroy_copy :: proc(c: Art_Candidate) { cc := c; art_candidate_destroy(&cc) }

@(private = "file")
art_meta_json :: proc(it: Art_Item) -> string {
	return fmt.aprintf(
		`{{"id":%q,"source":%q,"title":%q,"artist":%q,"date":%q,"museum":%q,"record":%q,"license":%q,"width":%d,"height":%d,"bytes":%d,"fetched":%d}}`,
		it.id, it.source, it.title, it.artist, it.date, it.museum, it.record, it.license, it.width, it.height, it.bytes, it.fetched,
		allocator = context.temp_allocator)
}

////////////////////////////////
// The cache folder and its upkeep

// <profile>/tmp/newtab-art: a stable, dedicated subfolder of the profile's temporary area.
@(private = "file")
art_ensure_dir :: proc() -> bool {
	if art.dir != "" { return true }
	base_dir := strings.concatenate({art.app.profile_dir, "/tmp/newtab-art"}, context.temp_allocator)
	if os.make_directory_all(base_dir) != nil && !os.is_dir(base_dir) { return false }
	art.dir = strings.clone(base_dir)
	return true
}

@(private = "file")
art_purge_over_cap :: proc() {
	if art.dir == "" { return }
	total: i64 = 0
	for it in art.ready { total += it.bytes }
	// oldest ready items go first until under the cap (never the current pick: it may still be on screen)
	for total > art.cfg.max_cache_bytes && len(art.ready) > 1 {
		oldest := -1
		for it, i in art.ready {
			if art.current != nil && it.id == art.current.id { continue }
			if oldest < 0 || art.ready[i].fetched < art.ready[oldest].fetched { oldest = i }
		}
		if oldest < 0 { break }
		it := art.ready[oldest]
		total -= it.bytes
		art_delete_files(it)
		art_item_destroy(it)
		free(it)
		ordered_remove(&art.ready, oldest)
	}
}

@(private = "file")
art_delete_files :: proc(it: ^Art_Item) {
	if it.file != "" { _ = os.remove(it.file) }
	stem := it.file
	if i := strings.last_index_byte(stem, '.'); i >= 0 { stem = stem[:i] }
	_ = os.remove(strings.concatenate({stem, ".json"}, context.temp_allocator))
}

// Cleared with "Clear browsing data" (site_data_ui.odin's cache kind): every cached painting and its metadata go, and the
// window starts over. The task, if running, fills it again.
art_clear_cache :: proc() {
	art_cancel_io()
	if art.current != nil && !art_in_ready(art.current) { art_delete_files(art.current); art_item_destroy(art.current); free(art.current) }
	art.current = nil
	for it in art.ready { art_delete_files(it); art_item_destroy(it); free(it) }
	clear(&art.ready)
	for s in art.recent { delete(s) }
	clear(&art.recent)
	if art.dir != "" {
		// remove any stray files the folder still holds (a crash between the image and its metadata)
		if entries, rerr := os.read_directory_by_path(art.dir, -1, context.temp_allocator); rerr == nil {
			for e in entries { if e.type != .Directory { _ = os.remove(e.fullpath) } }
		}
	}
	if art.started { art_pump() }
}

////////////////////////////////
// What the page asks for: a painting to show now

// Returns a painting for a new tab, or nil when none is ready. "Smart": it prefers one whose orientation suits the
// window (landscape for a wide window, portrait for a tall one), and it avoids the last `window` picks. The chosen one
// becomes the current pick; art_consume replaces it once the tab has drawn.
art_pick :: proc(landscape: bool) -> ^Art_Item {
	if len(art.ready) == 0 { return nil }
	best: ^Art_Item
	best_score := min(int)
	for it in art.ready {
		if art_recently_shown(it.id) { continue }
		score := 0
		it_landscape := it.width >= it.height
		if it_landscape == landscape { score += 2 }   // matches the window's orientation
		if best == nil || score > best_score { best, best_score = it, score }
	}
	if best == nil {   // every ready one was shown lately: take the oldest by fetch time anyway
		for it in art.ready { if best == nil || it.fetched < best.fetched { best = it } }
	}
	// remember the pick so it does not repeat at once; cap the ring at the window size
	append(&art.recent, strings.clone(best.id))
	for len(art.recent) > max(art.cfg.window, 1) { delete(art.recent[0]); ordered_remove(&art.recent, 0) }
	// the previous current, if it was consumed (removed from `ready`), is no longer referenced: free it so it does not leak
	if art.current != nil && art.current != best && !art_in_ready(art.current) {
		art_delete_files(art.current)
		art_item_destroy(art.current)
		free(art.current)
	}
	art.current = best
	return best
}

@(private = "file")
art_recently_shown :: proc(id: string) -> bool {
	for s in art.recent { if s == id { return true } }
	return false
}

// Called once an art new tab has shown the current painting: it leaves the ready window (it was consumed) and the task
// fetches a replacement so the window stays full of unseen paintings. The file stays on disk until purged, so the same
// tab can keep showing it; a new new tab gets a different one.
art_consume :: proc() {
	if art.current == nil { return }
	// drop the current from `ready` so the window refills with a fresh painting; keep the Art_Item alive as `current`
	for it, i in art.ready {
		if it == art.current { ordered_remove(&art.ready, i); break }
	}
	if art.started { art_pump() }
}

// True when at least one painting is ready to show (newtab_art_page.odin decides between the art page and the plain start page).
art_ready :: proc() -> bool { return len(art.ready) > 0 || art.current != nil }

////////////////////////////////
// Small helpers

@(private = "file")
art_have_id :: proc(id: string) -> bool {
	for it in art.ready { if it.id == id { return true } }
	if art.current != nil && art.current.id == id { return true }
	return false
}

@(private = "file")
art_in_ready :: proc(it: ^Art_Item) -> bool {
	for r in art.ready { if r == it { return true } }
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
		ext := strings.to_lower(s[i:], context.temp_allocator)
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

// Percent-encode what a query / path segment may not carry literally (spaces, the reserved set). Enough for the API
// titles and category names we build URLs from.
@(private = "file")
art_url_encode :: proc(s: string) -> string {
	sb := strings.builder_make(context.temp_allocator)
	for c in transmute([]u8)s {
		switch c {
		case 'a' ..= 'z', 'A' ..= 'Z', '0' ..= '9', '-', '_', '.', '~': strings.write_byte(&sb, c)
		case: fmt.sbprintf(&sb, "%%%2X", c)
		}
	}
	return strings.to_string(sb)
}
