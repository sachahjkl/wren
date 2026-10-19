package page

// matchMedia and screen for JavaScript (api/js_web.widl, module media).
//
// A MediaQueryList is a host object (an EventTarget) holding its query parsed once, in an arena of its own, and the
// result it last reported. The page's style computation calls media_queries_update with the environment it styles
// for (viewport, resolution, color scheme...): when that environment changed, every list of the page is evaluated
// again and those whose result changed get their "change" event from a task of their own (never in the middle of a
// style computation), as CSSOM View's "evaluate media queries and report changes" says.

import "core:mem/virtual"
import "core:strings"
import win "core:sys/windows"
import "wb:base"
import "wb:css"
import "wb:dom"
import "wb:style"

Media_Query_List :: struct {
	page:    ^Page,
	self:    u64,
	media:   string,               // owned: the query as serialized for mql.media
	arena:   virtual.Arena,
	list:    css.Media_Query_List, // in `arena`
	invalid: bool,                 // did not parse: "not all"
	matches: bool,                 // the result last reported
}

@(private)
Media_Page :: struct {
	lists:   [dynamic]u64,
	env:     css.Media_Env,
	has_env: bool,
}

@(private)
media_pages: map[^Page]^Media_Page

mql_vt := Object_VTable{
	name = "MediaQueryList",
	destroy = proc(p: ^Page, data: rawptr) {
		m := (^Media_Query_List)(data)
		if mp, ok := media_pages[p]; ok {
			for h, i in mp.lists { if h == m.self { unordered_remove(&mp.lists, i); break } }
		}
		virtual.arena_destroy(&m.arena)
		delete(m.media)
		free(m)
	},
}

mql_get :: proc(p: ^Page, h: u64) -> ^Media_Query_List { return (^Media_Query_List)(object_data(p, h, &mql_vt)) }
lookup_MediaQueryList :: proc(c: ^Call, h: u64) -> ^Media_Query_List { return mql_get(c.page, h) }

@(private)
media_page :: proc(p: ^Page) -> ^Media_Page {
	if mp, ok := media_pages[p]; ok { return mp }
	mp := new(Media_Page)
	media_pages[p] = mp
	cleanup :: proc(data: rawptr) {
		pg := (^Page)(data)
		if mp, ok := media_pages[pg]; ok {
			delete(mp.lists)
			free(mp)
			delete_key(&media_pages, pg)
		}
	}
	// runs before page_cleanup destroys the objects (registered after it): the destructor tolerates the missing entry
	base.on_close(p.scope, cleanup, p)
	return mp
}

// The environment media queries are evaluated in: the page's last style computation, or a default before it had one.
@(private)
media_env :: proc(p: ^Page) -> css.Media_Env {
	if mp, ok := media_pages[p]; ok && mp.has_env { return mp.env }
	if p.engine != nil && p.engine.env.width > 0 { return p.engine.env }
	return style.media_env_from(&p.engine.settings, 0, 0, 1, style.os_appearance().dark) if p.engine != nil else css.Media_Env{type = .Screen, dppx = 1, color_bits = 24}
}

@(private)
mql_eval :: proc(m: ^Media_Query_List, env: css.Media_Env) -> bool {
	if m.invalid { return false }
	return css.media_matches(m.list, env)
}

// "change" for every list whose result differs in `env` (called by the page's style computation: styles.odin).
media_queries_update :: proc(p: ^Page, env: css.Media_Env) {
	mp, ok := media_pages[p]
	if !ok { return }
	if mp.has_env && mp.env == env { return }
	mp.env, mp.has_env = env, true
	changed := false
	for h in mp.lists {
		m := mql_get(p, h)
		if m != nil && mql_eval(m, env) != m.matches { changed = true; break }
	}
	if !changed { return }
	post_page_task(p, proc(pg: ^Page, data: rawptr) {
		if pg == nil { return }
		mp, ok := media_pages[pg]
		if !ok { return }
		// the lists in creation order, each one reporting its new result
		lists := make([]u64, len(mp.lists), context.temp_allocator)
		copy(lists, mp.lists[:])
		for h in lists {
			m := mql_get(pg, h)
			if m == nil { continue }
			now := mql_eval(m, mp.env)
			if now == m.matches { continue }
			m.matches = now
			object_dispatch(pg, h, dom.Event{type = "change", code = now ? 1 : 0, data = m.media})
			if pg.closed { return }
		}
	}, nil)
}

// What mql.media shows: the query trimmed, its white space collapsed, in lower case outside of nothing else (an
// approximation of CSSOM's media query serialization); "not all" when it does not parse.
@(private)
media_text :: proc(query: string, invalid: bool) -> string {
	if invalid { return strings.clone("not all") }
	b := strings.builder_make()
	space := false
	for r in strings.trim_space(query) {
		if strings.is_space(r) { space = true; continue }
		if space && strings.builder_len(b) > 0 { strings.write_byte(&b, ' ') }
		space = false
		strings.write_rune(&b, r >= 'A' && r <= 'Z' ? r + 32 : r)
	}
	return strings.to_string(b)
}

MediaQueryList_create :: proc(c: ^Call, query: string) -> u64 {
	p := c.page
	m := new(Media_Query_List)
	m.page = p
	alloc := virtual.arena_allocator(&m.arena)
	opt := p.engine != nil ? style.parse_options(&p.engine.settings) : css.Parse_Options{}
	vals := css.parse_component_values(query, opt, alloc)
	if strings.trim_space(query) == "" {
		m.list = nil   // an empty list matches everything
	} else {
		m.list = css.parse_media_query_list(vals, alloc)
		m.invalid = len(m.list) == 0
	}
	m.media = media_text(query, m.invalid)
	m.matches = mql_eval(m, media_env(p))
	m.self = object_create(p, &mql_vt, m, c.owner)
	mp := media_page(p)
	append(&mp.lists, m.self)
	return m.self
}

MediaQueryList_media :: proc(c: ^Call, list: Api_MediaQueryList) -> string { return list.data.media }

MediaQueryList_matches :: proc(c: ^Call, list: Api_MediaQueryList) -> bool {
	// the current answer (matches is live: it does not wait for the change event)
	return mql_eval(list.data, media_env(c.page))
}

// The screen of the page: the primary monitor (the page does not know which monitor shows its tab), in CSS pixels.
Screen_get :: proc(c: ^Call, field: Api_ScreenField) -> i32 {
	dppx := media_env(c.page).dppx
	if dppx <= 0 { dppx = 1 }
	work: win.RECT
	switch field {
	case .Width: return i32(f64(win.GetSystemMetrics(win.SM_CXSCREEN)) / dppx)
	case .Height: return i32(f64(win.GetSystemMetrics(win.SM_CYSCREEN)) / dppx)
	case .Avail_Width, .Avail_Height, .Avail_Left, .Avail_Top:
		if win.SystemParametersInfoW(win.SPI_GETWORKAREA, 0, &work, 0) == win.FALSE {
			work = {0, 0, win.GetSystemMetrics(win.SM_CXSCREEN), win.GetSystemMetrics(win.SM_CYSCREEN)}
		}
		#partial switch field {
		case .Avail_Width: return i32(f64(work.right - work.left) / dppx)
		case .Avail_Height: return i32(f64(work.bottom - work.top) / dppx)
		case .Avail_Left: return i32(f64(work.left) / dppx)
		case .Avail_Top: return i32(f64(work.top) / dppx)
		}
	case .Color_Depth:
		bits := media_env(c.page).color_bits
		return i32(bits > 0 ? bits : 24)
	}
	return 0
}
