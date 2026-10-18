package page

import "core:fmt"
import "core:strings"
import "wb:base"
import "wb:fetch"
import "wb:style"
import "wb:webfont"

// Web fonts of a page: the @font-face rules the style engine found (style.engine_font_faces), downloaded through the
// policy layer as fetch destination "font" in CORS mode with same-origin credentials (CSS Fonts 4 §4.9: a cross-origin
// font needs Access-Control-Allow-Origin), decoded by package webfont, and offered to the shell as ready faces.
//
// Only faces whose family some element asks for are fetched (unless style.webfonts.load_unused); sources are tried in
// order, and a source in a format that cannot be decoded (WOFF2, collections, EOT, SVG) or a local() one (system fonts
// are the shell's business) is skipped. Downloads run at most style.webfonts.max_parallel at a time; each file and its
// decoded form are limited to style.webfonts.max_bytes.
//
// The shell polls: when `fonts_generation(p)` changes, the faces in `fonts_ready(p)` are new; it registers them with its
// font engine (family, weight range, italic, sfnt bytes) and lays the page out again.

Font_Load_State :: enum u8 { Queued, Loading, Ready, Failed }

Web_Font_Source :: struct {
	url:       string,              // absolute
	format:    style.Font_Format,
	supported: bool,
}

Web_Font :: struct {
	page:          ^Page,
	key:           string,
	family:        string,
	weight:        [2]u16,
	font_style:    style.Font_Style,
	italic:        bool,            // style is italic or oblique
	stretch:       [2]f32,
	unicode_range: [][2]u32,
	display:       style.Font_Display,
	sources:       []Web_Font_Source,
	next_source:   int,
	state:         Font_Load_State,
	task:          base.Handle,
	bad_status:    bool,
	url:           string,          // the source being loaded or that was loaded (aliases `sources`)
	data:          []byte,          // Ready: the sfnt file (TrueType / OpenType)
	format:        webfont.Format,  // Ready: what the downloaded file was
}

Page_Fonts :: struct {
	faces:      map[string]^Web_Font,   // by face key, for the life of the page
	queue:      [dynamic]^Web_Font,
	loading:    int,
	ready:      [dynamic]^Web_Font,     // in the order they became ready
	generation: u64,                     // changes when a face becomes ready
	rebuilds:   u64,                     // the engine rebuild last looked at
	styled:     u64,                     // the style serial last looked at
}

@(private)
fonts_init :: proc(p: ^Page) {
	p.fonts.faces = make(map[string]^Web_Font)
	p.fonts.queue = make([dynamic]^Web_Font)
	p.fonts.ready = make([dynamic]^Web_Font)
}

@(private)
fonts_destroy :: proc(p: ^Page) {
	for _, f in p.fonts.faces {
		if f.task != base.NIL_HANDLE { fetch.cancel(p.loader, f.task) }
		for s in f.sources { delete(s.url) }
		delete(f.sources)
		delete(f.unicode_range)
		delete(f.key); delete(f.family)
		delete(f.data)
		free(f)
	}
	delete(p.fonts.faces)
	delete(p.fonts.queue)
	delete(p.fonts.ready)
}

// Changes when new faces are ready.
fonts_generation :: proc(p: ^Page) -> u64 { return p.fonts.generation }

// Every face downloaded and decoded so far, oldest first.
fonts_ready :: proc(p: ^Page) -> []^Web_Font { return p.fonts.ready[:] }

// The faces the document declares, whatever their state.
fonts_all :: proc(p: ^Page, allocator := context.temp_allocator) -> []^Web_Font {
	out := make([dynamic]^Web_Font, allocator)
	for _, f in p.fonts.faces { append(&out, f) }
	return out[:]
}

// Looks at the @font-face rules and the families in use after a style pass; starts what has to be loaded.
@(private)
fonts_sync :: proc(p: ^Page) {
	s := &p.settings.style
	if !s.webfonts || p.styled == nil { return }
	e := p.engine
	if e.rebuilds == p.fonts.rebuilds && p.styled.serial == p.fonts.styled { return }
	p.fonts.rebuilds, p.fonts.styled = e.rebuilds, p.styled.serial
	faces := style.engine_font_faces(e)
	if len(faces) == 0 { return }
	used: map[string]bool
	if !s.webfont_load_unused {
		used = make(map[string]bool, context.temp_allocator)
		seen := make(map[rawptr]bool, context.temp_allocator)   // font-family lists are shared by inheritance
		for c in p.styled.by_node {
			if c == nil || len(c.font_family) == 0 { continue }
			if raw_data(c.font_family) in seen { continue }
			seen[raw_data(c.font_family)] = true
			for fam in c.font_family { used[strings.to_lower(fam, context.temp_allocator)] = true }
		}
	}
	for &ff in faces {
		if ff.key in p.fonts.faces { continue }
		if used != nil && strings.to_lower(ff.family, context.temp_allocator) not_in used { continue }
		if len(p.fonts.faces) >= s.webfont_max_faces { log(p, .Warn, fmt.tprintf("@font-face: more than %d faces, the rest is ignored", s.webfont_max_faces)); break }
		f := new(Web_Font)
		f.page = p
		f.key, f.family = strings.clone(ff.key), strings.clone(ff.family)
		f.weight, f.font_style, f.stretch, f.display = ff.weight, ff.style, ff.stretch, ff.display
		f.italic = ff.style != .Normal
		f.unicode_range = make([][2]u32, len(ff.unicode_range))
		copy(f.unicode_range, ff.unicode_range)
		srcs := make([dynamic]Web_Font_Source)
		base_url := ff.base_url != "" ? ff.base_url : p.env.location.href
		for src in ff.sources {
			if src.kind != .Url { continue }   // local(): the shell's font engine knows the installed fonts
			abs, ok := resolve_against(src.url, base_url)
			if !ok { log(p, .Warn, fmt.tprintf("@font-face %q: invalid URL %q", ff.family, src.url)); continue }
			append(&srcs, Web_Font_Source{url = abs, format = src.format, supported = src.supported})
		}
		f.sources = srcs[:]
		p.fonts.faces[f.key] = f
		append(&p.fonts.queue, f)
	}
	fonts_pump(p)
}

@(private)
fonts_pump :: proc(p: ^Page) {
	for p.fonts.loading < max(p.settings.style.webfont_max_parallel, 1) && len(p.fonts.queue) > 0 {
		f := p.fonts.queue[0]
		ordered_remove(&p.fonts.queue, 0)
		if font_start(p, f) { p.fonts.loading += 1 }
	}
}

// Starts the next usable source; false when there is none (the face failed).
@(private)
font_start :: proc(p: ^Page, f: ^Web_Font) -> bool {
	for f.next_source < len(f.sources) {
		src := f.sources[f.next_source]
		f.next_source += 1
		if !src.supported { continue }
		f.url = src.url
		f.bad_status = false
		f.state = .Loading
		f.task = fetch.start(p.loader, {
			request = {
				url = src.url, mode = .Cors, credentials = .Same_Origin, destination = .Font, initiator = &p.env,
				max_body = p.settings.style.webfont_max_bytes,
			},
			on_event = font_event, user = f, scope = p.scope, collect = true,
		})
		return true
	}
	f.state = .Failed
	log(p, .Warn, fmt.tprintf("@font-face %q: no source could be loaded", f.family))
	return false
}

@(private)
font_event :: proc(user: rawptr, task: base.Handle, ev: ^fetch.Event) {
	f := (^Web_Font)(user)
	p := f.page
	switch ev.kind {
	case .Response:
		r := ev.response
		if r.status < 200 || r.status >= 300 {
			f.bad_status = true
			log(p, .Warn, fmt.tprintf("font %s: HTTP %d", f.url, r.status))
		}
	case .Data:
	case .Failed:
		f.task = base.NIL_HANDLE
		log(p, .Warn, fmt.tprintf("font %s: %s", f.url, ev.detail))
		font_retry(p, f)
	case .Done:
		f.task = base.NIL_HANDLE
		if f.bad_status { font_retry(p, f); return }
		sfnt, format, err := webfont.decode(ev.data, p.settings.style.webfont_max_bytes)
		if err != .None {
			log(p, .Warn, fmt.tprintf("font %s: cannot use it (%v, %v)", f.url, format, err))
			font_retry(p, f)
			return
		}
		f.data, f.format, f.state = sfnt, format, .Ready
		append(&p.fonts.ready, f)
		p.fonts.generation += 1
		p.fonts.loading -= 1
		fonts_pump(p)
	}
}

@(private)
font_retry :: proc(p: ^Page, f: ^Web_Font) {
	if !font_start(p, f) {
		p.fonts.loading -= 1
		fonts_pump(p)
	}
}
