package browser

// The icon of a site wherever the browser lists sites (the address bar's suggestions, the bookmarks bar, the Vault, the
// palette): favicon_of_url and favicon_of_origin. They give the texture when it is ready; otherwise they ask for it once
// and give nothing, and the caller draws its placeholder. The decode's end asks for a frame.
//
//   * A site (Favicon_Site, keyed by its origin "https://example.com") is asked first from the profile, then from the
//     network: the <link rel=icon> a visited page of the site declared (the history keeps it), then /favicon.ico of the
//     origin (browser.tabs.favicon_fallback_ico). These requests are the browser's own: no cookie, no page.
//   * A site that failed is not asked again for FAVICON_RETRY_MS: a list drawn at each frame makes no request per frame.
//   * The profile keeps one file per site in <profile>/favicons: a short text header (origin, the icon's address, when it
//     was fetched) and the icon's bytes as they came. Its name is a hash of the origin; the header's origin is checked
//     when it is read. An icon is stored when it decoded after a request (a tab's page or a site's ask), and again when
//     the site is visited and its copy is older than FAVICON_RESTORE_MS. A copy older than browser.tabs.favicon_disk_days
//     is dropped when it is read and by the prune. After each write the prune keeps the folder under
//     browser.tabs.favicon_disk_max_bytes: the oldest files go first.
//   * Threads: nothing is read at start. A site's file is read by a worker of the blocking pool the first time the site
//     is asked for (or after its texture left the memory cache); its bytes are decoded on the image threads. The writes
//     and the prune are jobs of the blocking pool too, one at a time, through the profile's writer (host.file_put,
//     host.file_drop). Without a pool (unit tests) they run on the calling thread. A Wren that keeps no profile
//     (private browsing, browser.profile.persist off) keeps the icons in memory only.

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:time"
import "toolkit:draw"
import "toolkit:render"
import "toolkit:ui"
import "wb:base"
import "wb:host"
import "wb:url"

// How long a site whose icon failed waits before it is asked for again.
FAVICON_RETRY_MS :: 10 * 60 * 1000
// A visit of a site stores its icon again when its copy in the profile is older than this.
FAVICON_RESTORE_MS :: i64(24 * 60 * 60 * 1000)
FAVICON_DIR :: "favicons"
FAVICON_FILE_EXT :: ".icon"
FAVICON_MAGIC :: "wren-favicon 1"
// Writes that wait for the disk at most: beyond, a new one is dropped (the next visit stores it).
FAVICON_WRITES_WAITING :: 64
// What a site tries from the network, in order: the icon its page declared, /favicon.ico.
FAVICON_CANDIDATES :: 2

Favicon_Site_State :: enum u8 {
	Reading,    // its file in the profile is being read
	Fetching,   // `icon` is its icon: the entry of that address is loading or decoding (or left the memory cache)
	Ready,      // the entry of `icon` is drawn
	Failed,     // nothing came: asked again after FAVICON_RETRY_MS
}

Favicon_Site :: struct {
	origin:    string,   // owned (the key)
	state:     Favicon_Site_State,
	icon:      string,   // owned: the address of its icon, the key of its entry in Favicons.entries ("": none yet)
	hint:      string,   // owned: the <link rel=icon> a visited page of the site declared ("": not known)
	tried:     int,      // the network candidates tried (favicon_candidate)
	failed_ms: f64,      // loop clock: when it failed
	stored_ms: i64,      // wall clock: when its copy in the profile was fetched (0: not known)
}

Favicon_Disk :: struct {
	waiting:     [dynamic]^Favicon_Write,   // writes not handed to the pool yet, oldest first
	writing:     bool,                      // a write is out on the pool
	jobs:        int,                       // reads and writes out on the pool
	reads:       int,                       // files read (unit tests)
	// unit tests
	offline:     bool,   // no request leaves: favicon_fetch counts them in `fetches`
	fetches:     int,
	hold_decode: bool,   // bytes are kept, not decoded (no image threads)
}

////////////////////////////////
// Keys and the file's format (pure: favicon_cache_test.odin)

// The origin whose icon an address shows: "https://example.com" ("" for what has no site: about:, file:, data:...).
favicon_origin :: proc(address: string, allocator := context.allocator) -> string {
	u, ok := url.parse(address, nil, context.temp_allocator)
	if !ok || (u.scheme != "http" && u.scheme != "https") || u.host == "" { return "" }
	return url.origin_serialize(url.origin_of(u, context.temp_allocator), allocator)
}

// The file of a site in the favicons folder: a hash of its origin (an origin can hold any character of a host).
favicon_disk_name :: proc(origin: string, allocator := context.temp_allocator) -> string {
	h: u64 = 0xcbf29ce484222325
	for c in transmute([]u8)origin { h = (h ~ u64(c)) * 0x100000001b3 }
	return fmt.aprintf("%016x%s", h, FAVICON_FILE_EXT, allocator = allocator)
}

// The file of a site: the header's lines, then the icon's bytes.
favicon_disk_encode :: proc(origin, icon: string, fetched_ms: i64, bytes: []byte, allocator := context.allocator) -> []byte {
	head := fmt.tprintf("%s\n%s\n%s\n%d\n", FAVICON_MAGIC, origin, icon, fetched_ms)
	out := make([]byte, len(head) + len(bytes), allocator)
	copy(out, head)
	copy(out[len(head):], bytes)
	return out
}

// A file of the favicons folder (slices of `data`). ok false: not one of ours, or damaged.
favicon_disk_decode :: proc(data: []byte) -> (origin, icon: string, fetched_ms: i64, bytes: []byte, ok: bool) {
	rest := string(data)
	line :: proc(rest: ^string) -> (string, bool) {
		i := strings.index_byte(rest^, '\n')
		if i < 0 { return "", false }
		l := rest^[:i]
		rest^ = rest^[i + 1:]
		return l, true
	}
	magic, at: string
	ok1, ok2, ok3, ok4: bool
	magic, ok1 = line(&rest)
	origin, ok2 = line(&rest)
	icon, ok3 = line(&rest)
	at, ok4 = line(&rest)
	if !ok1 || !ok2 || !ok3 || !ok4 || magic != FAVICON_MAGIC || origin == "" || icon == "" { return "", "", 0, nil, false }
	n, parsed := strconv.parse_i64(at)
	if !parsed || n <= 0 { return "", "", 0, nil, false }
	bytes = data[len(data) - len(rest):]
	if len(bytes) == 0 { return "", "", 0, nil, false }
	return origin, icon, n, bytes, true
}

// Whether a copy fetched at `fetched_ms` is still used at `now_ms`.
favicon_disk_fresh :: proc(fetched_ms, now_ms: i64, days: int) -> bool {
	return now_ms - fetched_ms < i64(days) * 86_400_000
}

Favicon_Disk_File :: struct { name: string, size: i64, modified_ms: i64 }

// The files the prune removes: those too old, then the oldest until the rest holds `max_bytes` at most.
favicon_disk_prune :: proc(files: []Favicon_Disk_File, max_bytes, now_ms: i64, days: int, allocator := context.temp_allocator) -> []string {
	out := make([dynamic]string, allocator)
	kept := make([dynamic]Favicon_Disk_File, context.temp_allocator)
	total: i64 = 0
	for f in files {
		if !strings.has_suffix(f.name, FAVICON_FILE_EXT) { continue }   // (a temporary file of a write: its own)
		if !favicon_disk_fresh(f.modified_ms, now_ms, days) { append(&out, f.name); continue }
		append(&kept, f)
		total += f.size
	}
	slice.sort_by(kept[:], proc(a, b: Favicon_Disk_File) -> bool {
		if a.modified_ms != b.modified_ms { return a.modified_ms < b.modified_ms }
		return a.name < b.name
	})
	for f in kept {
		if total <= max_bytes { break }
		append(&out, f.name)
		total -= f.size
	}
	return out[:]
}

// The `i`-th address a site tries from the network ("": none at that place).
favicon_candidate :: proc(origin, hint: string, i: int, fallback_ico: bool, allocator := context.temp_allocator) -> string {
	ico := strings.concatenate({origin, "/favicon.ico"}, allocator)
	switch i {
	case 0:
		if strings.has_prefix(hint, "https://") || strings.has_prefix(hint, "http://") || strings.has_prefix(hint, "data:") { return hint }
	case 1:
		if fallback_ico && hint != ico { return ico }
	}
	return ""
}

////////////////////////////////
// The one way to an icon

// The icon of the page at `address`: the one its last visit declared when it is in memory, else its site's.
favicon_of_url :: proc(app: ^App, address: string) -> (tex: render.Texture, ok: bool) {
	if !app.favs.cfg.favicons || address == "" { return }
	hint := ""
	if k, found := app.ub.idx.by_url[address]; found && k < len(app.ub.idx.entries) {
		hint = app.ub.idx.entries[k].icon
		if hint != "" {
			if tex, ok = favicon_texture(app, hint); ok { return }
		}
	}
	origin := favicon_origin(address, context.temp_allocator)
	if origin == "" { return }
	return favicon_of_origin(app, origin, hint)
}

// The icon of the site `origin` ("https://example.com"). `hint`: an icon one of its pages declared ("": none known).
favicon_of_origin :: proc(app: ^App, origin: string, hint := "") -> (tex: render.Texture, ok: bool) {
	if !app.favs.cfg.favicons || origin == "" { return }
	s := app.favs.sites[origin]
	if s == nil {
		s = new(Favicon_Site)
		s.origin = strings.clone(origin)
		if hint != "" { s.hint = strings.clone(hint) }
		app.favs.sites[s.origin] = s
		site_read(app, s)
		return
	}
	if s.hint == "" && hint != "" { s.hint = strings.clone(hint) }
	switch s.state {
	case .Reading:
	case .Failed:
		if icon_loop_ms(app) - s.failed_ms < FAVICON_RETRY_MS { return }
		// (its candidates that failed are asked again too: the site may have been down)
		for i in 0 ..< FAVICON_CANDIDATES {
			c := favicon_candidate(s.origin, s.hint, i, app.favs.cfg.fallback_ico)
			if e := app.favs.entries[c]; c != "" && e != nil && e.state == .Failed { favicon_forget(app, e) }
		}
		s.tried = 0
		site_read(app, s)
	case .Fetching, .Ready:
		e := app.favs.entries[s.icon]
		if e == nil {   // (it left the memory cache: the profile has it)
			s.tried = 0
			site_read(app, s)
			return
		}
		switch e.state {
		case .Ready:
			s.state = .Ready
			return favicon_texture(app, s.icon)
		case .Loading, .Decoding:
		case .Failed:
			site_fetch_next(app, s)
		}
	}
	return
}

// A tab's page of the site `origin` names the icon `e` (favicon_request): the site shows it, and a visit stores it
// again when the profile's copy is old.
favicon_site_seen :: proc(app: ^App, origin: string, e: ^Favicon) {
	if origin == "" { return }
	s := app.favs.sites[origin]
	if s == nil {
		s = new(Favicon_Site)
		s.origin = strings.clone(origin)
		app.favs.sites[s.origin] = s
	}
	if s.icon != e.url {
		delete(s.icon)
		s.icon = strings.clone(e.url)
		s.stored_ms = 0   // (the profile's copy is of another icon)
	}
	if s.hint != e.url {
		delete(s.hint)
		s.hint = strings.clone(e.url)
	}
	// (a read out finds the site taken: its answer is dropped)
	if s.state != .Ready { s.state = .Fetching }
	s.tried = 1   // (a failure of the page's icon goes on with /favicon.ico)
	if e.state == .Ready && e.blob != nil && (s.stored_ms == 0 || now_ms() - s.stored_ms > FAVICON_RESTORE_MS) {
		favicon_disk_store(app, origin, e.url, e.blob.bytes)
	}
}

// Draws `tex`, an icon, centred in a box `width` wide and as high as its row, at the size of a tab's icon at most.
favicon_box :: proc(tex: render.Texture, id: string, width: f32) {
	ic := ui.frame_new(Favicon_Draw)
	ic.tex = tex
	ui.next({width = ui.px(width), height = ui.pct(1)})
	ui.custom(id, favicon_box_draw, ic)
}

@(private = "file")
Favicon_Draw :: struct { tex: render.Texture }

@(private = "file")
favicon_box_draw :: proc(b: ^ui.Box, user: rawptr, dc: ^draw.Context) {
	ic := (^Favicon_Draw)(user)
	r := b.rect
	s := min(r.max.x - r.min.x, r.max.y - r.min.y, f32(tab_icon_px(the_app)))
	c := draw.rect_center(r)
	at := draw.Rect{{f32(int(c.x - s * 0.5 + 0.5)), f32(int(c.y - s * 0.5 + 0.5))}, {}}
	at.max = at.min + {s, s}
	draw.image(dc, ic.tex, at)
}

@(private = "file")
icon_loop_ms :: proc(app: ^App) -> f64 { return f64(host.now_ns(&app.loop)) / 1e6 }

// The next network candidate of the site, else it failed.
@(private = "file")
site_fetch_next :: proc(app: ^App, s: ^Favicon_Site) {
	for s.tried < FAVICON_CANDIDATES {
		c := favicon_candidate(s.origin, s.hint, s.tried, app.favs.cfg.fallback_ico)
		s.tried += 1
		if c == "" { continue }
		delete(s.icon)
		s.icon = strings.clone(c)
		s.state = .Fetching
		s.stored_ms = 0
		if e := app.favs.entries[c]; e != nil {
			if e.state == .Failed { continue }
			if e.origin == "" && e.state != .Ready { e.origin = strings.clone(s.origin) }
			return   // (asked already: its answer comes, or it is drawn)
		}
		e := favicon_entry_make(app, c)
		e.origin = strings.clone(s.origin)
		if favicon_fetch(app, e) { return }
		e.state = .Failed
	}
	s.state = .Failed
	s.failed_ms = icon_loop_ms(app)
}

////////////////////////////////
// The profile's folder

@(private = "file")
icon_disk_usable :: proc(app: ^App) -> bool {
	return app.cfg.persist_profile && app.profile_dir != "" && app.favs.cfg.icon_disk_max > 0
}

@(private = "file")
icon_disk_path :: proc(app: ^App, origin: string, allocator := context.allocator) -> string {
	return strings.concatenate({app.profile_dir, "/", FAVICON_DIR, "/", favicon_disk_name(origin)}, allocator)
}

@(private = "file")
Favicon_Read :: struct {
	app:        ^App,
	origin:     string,   // owned (process allocator)
	path:       string,   // owned (process allocator)
	days:       int,
	now_ms:     i64,
	data:       []byte,   // the file (process allocator)
	icon:       string,   // slices of `data`
	bytes:      []byte,
	fetched_ms: i64,
	ok:         bool,
}

// The site's file is read off the interface thread; without one (or no profile) the network is next.
@(private = "file")
site_read :: proc(app: ^App, s: ^Favicon_Site) {
	s.state = .Reading
	if !icon_disk_usable(app) { site_fetch_next(app, s); return }
	pa := base.process_allocator()
	j := new(Favicon_Read, pa)
	j^ = {app = app, origin = strings.clone(s.origin, pa), path = icon_disk_path(app, s.origin, pa), days = app.favs.cfg.icon_disk_days, now_ms = now_ms()}
	app.favs.disk.jobs += 1
	if !profile_pool_ready(app) {
		icon_read_work(j)
		icon_read_done(j)
		return
	}
	host.run_blocking(&app.blocking, icon_read_work, icon_read_done, j, icon_read_discard)
}

@(private = "file")
icon_read_work :: proc(data: rawptr) {
	j := (^Favicon_Read)(data)
	pa := base.process_allocator()
	bytes, err := os.read_entire_file(j.path, pa)
	if err != nil { return }
	j.data = bytes
	origin, icon, at, body, ok := favicon_disk_decode(bytes)
	if !ok || origin != j.origin || !favicon_disk_fresh(at, j.now_ms, j.days) {
		_ = host.file_drop(&j.app.writer, j.path)   // (too old, another site's, or damaged: asked from the site again)
		return
	}
	j.icon, j.bytes, j.fetched_ms, j.ok = icon, body, at, true
}

@(private = "file")
icon_read_free :: proc(j: ^Favicon_Read) {
	pa := base.process_allocator()
	delete(j.origin, pa)
	delete(j.path, pa)
	delete(j.data, pa)
	free(j, pa)
}

// The pool ended before the read: the site is left as it is (the browser ends).
@(private = "file")
icon_read_discard :: proc(data: rawptr) {
	j := (^Favicon_Read)(data)
	j.app.favs.disk.jobs -= 1
	icon_read_free(j)
}

@(private = "file")
icon_read_done :: proc(data: rawptr) {
	j := (^Favicon_Read)(data)
	app := j.app
	defer icon_read_free(j)
	app.favs.disk.jobs -= 1
	app.favs.disk.reads += 1
	host.quiet_note(&app.loop)   // (the disk: the decode's end asks for the frame)
	s := app.favs.sites[j.origin]
	if s == nil || s.state != .Reading { return }   // (a tab gave the site its icon meanwhile)
	if !j.ok { site_fetch_next(app, s); return }
	s.stored_ms = j.fetched_ms
	s.tried = FAVICON_CANDIDATES   // (the copy is the site's icon: a decode that fails asks nothing more until the retry)
	delete(s.icon)
	s.icon = strings.clone(j.icon)
	s.state = .Fetching
	e := app.favs.entries[j.icon]
	if e != nil && e.state != .Failed { return }   // (in memory already: a tab asked for it)
	if e != nil { favicon_forget(app, e) }
	e = favicon_entry_make(app, j.icon)
	favicon_take_bytes(app, e, j.bytes)
}

@(private = "file")
Favicon_Write :: struct {
	app:       ^App,
	dir:       string,   // owned (process allocator)
	path:      string,   // owned (process allocator)
	data:      []byte,   // owned (process allocator): the file
	max_bytes: i64,
	days:      int,
	now_ms:    i64,
}

// Stores the icon of `origin` (its address `icon`, its bytes copied) in the profile, fetched now.
favicon_disk_store :: proc(app: ^App, origin, icon: string, bytes: []byte) {
	if origin == "" || len(bytes) == 0 { return }
	now := now_ms()
	if s := app.favs.sites[origin]; s != nil { s.stored_ms = now }
	if !icon_disk_usable(app) { return }
	pa := base.process_allocator()
	path := icon_disk_path(app, origin, context.temp_allocator)
	// (a newer text of the same file replaces the one that waits)
	for w in app.favs.disk.waiting {
		if w.path == path {
			delete(w.data, pa)
			w.data = favicon_disk_encode(origin, icon, now, bytes, pa)
			w.now_ms = now
			return
		}
	}
	if len(app.favs.disk.waiting) >= FAVICON_WRITES_WAITING { return }
	w := new(Favicon_Write, pa)
	w^ = {app = app, dir = strings.concatenate({app.profile_dir, "/", FAVICON_DIR}, pa), path = strings.clone(path, pa),
		data = favicon_disk_encode(origin, icon, now, bytes, pa), max_bytes = i64(app.favs.cfg.icon_disk_max),
		days = app.favs.cfg.icon_disk_days, now_ms = now}
	if app.favs.disk.waiting == nil { app.favs.disk.waiting = make([dynamic]^Favicon_Write, pa) }
	append(&app.favs.disk.waiting, w)
	icon_disk_kick(app)
}

// Hands the oldest write that waits to the pool, when none is out.
@(private = "file")
icon_disk_kick :: proc(app: ^App) {
	d := &app.favs.disk
	if d.writing || len(d.waiting) == 0 { return }
	w := d.waiting[0]
	ordered_remove(&d.waiting, 0)
	d.writing = true
	d.jobs += 1
	if !profile_pool_ready(app) {
		icon_write_work(w)
		icon_write_done(w)
		return
	}
	host.run_blocking(&app.blocking, icon_write_work, icon_write_done, w, icon_write_discard)
}

@(private = "file")
icon_write_work :: proc(data: rawptr) {
	w := (^Favicon_Write)(data)
	writer := &w.app.writer
	// (a failure is not told: the icon is asked from the site the next time)
	_ = host.file_put(writer, w.path, w.data)
	entries, err := os.read_directory_by_path(w.dir, -1, context.temp_allocator)
	if err != nil { return }
	files := make([]Favicon_Disk_File, len(entries), context.temp_allocator)
	n := 0
	for e in entries {
		if e.type == .Directory { continue }
		files[n] = {name = e.fullpath, size = e.size, modified_ms = time.to_unix_nanoseconds(e.modification_time) / 1e6}
		n += 1
	}
	for name in favicon_disk_prune(files[:n], w.max_bytes, w.now_ms, w.days) { _ = host.file_drop(writer, name) }
}

@(private = "file")
icon_write_free :: proc(w: ^Favicon_Write) {
	pa := base.process_allocator()
	delete(w.dir, pa)
	delete(w.path, pa)
	delete(w.data, pa)
	free(w, pa)
}

@(private = "file")
icon_write_discard :: proc(data: rawptr) {
	w := (^Favicon_Write)(data)
	w.app.favs.disk.jobs -= 1
	w.app.favs.disk.writing = false
	icon_write_free(w)
}

@(private = "file")
icon_write_done :: proc(data: rawptr) {
	w := (^Favicon_Write)(data)
	app := w.app
	icon_write_free(w)
	app.favs.disk.jobs -= 1
	app.favs.disk.writing = false
	host.quiet_note(&app.loop)   // (the disk, not the screen)
	icon_disk_kick(app)
}

// Ends the sites and the disk's jobs (favicons_destroy): the jobs out finish, the writes that wait are dropped (a
// cache: the next visit stores them).
favicon_cache_destroy :: proc(app: ^App) {
	d := &app.favs.disk
	for w in d.waiting { icon_write_free(w) }
	clear(&d.waiting)
	for _ in 0 ..< host.FILE_FLUSH_ROUNDS {
		if d.jobs <= 0 || !profile_pool_ready(app) { break }
		host.blocking_settle(&app.blocking)
	}
	delete(d.waiting)
	d.waiting = nil
	for _, s in app.favs.sites {
		delete(s.origin)
		delete(s.icon)
		delete(s.hint)
		free(s)
	}
	delete(app.favs.sites)
	app.favs.sites = nil
}
