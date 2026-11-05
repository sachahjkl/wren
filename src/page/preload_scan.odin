package page

// The preload scanner: what a document's bytes name goes out while they arrive. The parser takes the whole document (off the
// window thread), so a page of megabytes asked for nothing before they were all in and parsed. The bytes are read as they
// come, on the window thread: reading is a matter of milliseconds for the largest documents (html.scan_feed), and a request can
// only be made there; a thread of its own would add a hop to what it gains nothing on.
//
// A request made here is the one the element makes (fetch/speculative.odin): this file asks what the element would ask,
// mode, credentials and destination included, and only that (the element's own code decides on integrity, MIME types and the
// rest, on what it gets). What it asks is the best guess of a reader that has no tree: a wrong guess costs a request that
// nobody takes (a <noscript> of a page whose scripts are off, an image a script removes), never a wrong page. So it is careful
// about what would be wasted:
//
//   * <base href>: what follows resolves against it, in the head, as the document's base URL does;
//   * media attributes (<link>, <source>): what does not apply now is left to the element;
//   * a Content-Security-Policy in a <meta>: the scan stops there, what follows is for the parser with the policy in force. The
//     response's own policy applies as to any request, silently: what is refused reports when its element is reached;
//   * <meta name=referrer> applies as it is read (apply_meta does the same again once the document is adopted);
//   * loading=lazy and images the page's image cache holds are left alone; images count against html.preload.max_images: the
//     first of a document are the likely ones on screen, what is further down waits for its turn in the page's own order;
//   * a value it cannot decode exactly (a named character reference other than markup's, non-ASCII in another encoding than
//     UTF-8) is left to the element.

import "core:strings"
import "wb:base"
import "wb:css"

import "wb:fetch"
import "wb:html"

import "wb:style"
import "wb:url"

@(private)
Preload_Scan :: struct {
	page:    ^Page,
	tokens:  html.Preload_Scanner,
	base:    url.URL,      // the <base> met, owned; else the document's URL
	has_base: bool,
	utf8:    bool,         // the document is in UTF-8, as far as anything said
	env:     css.Media_Env,
	scripts: bool,
	images:  int,          // images asked
	in_picture: bool,
	picture_url: string,   // the <source> of the <picture> in hand that applies (owned), "" none
	picture_seen: bool,    // ... found: the next ones do not count
	started: bool,         // the first bytes were looked at
}

// Encodings that do not keep ASCII in place: their bytes are not read.
@(private = "file")
scan_reads_encoding :: proc(name: string) -> bool {
	return !strings.has_prefix(name, "UTF-16") && name != "ISO-2022-JP" && name != "replacement"
}

// A document's response came. `charset`: of its Content-Type; `mime`: its type.
preload_scan_begin :: proc(p: ^Page, charset: string, mime: string) {
	if p.scan != nil || !p.settings.html.preload_scanner || p.loader == nil { return }
	if mime != "" && mime != "text/html" { return }
	name := charset != "" ? html.canonical_encoding(charset) : ""
	if !scan_reads_encoding(name) { return }
	s := new(Preload_Scan)
	s.page = p
	s.utf8 = name == "UTF-8"
	s.env = media_env(p)
	if s.env.width == 0 { s.env.width, s.env.height = style.DEFAULT_VIEWPORT_W, style.DEFAULT_VIEWPORT_H }
	s.scripts = js_enabled(p)
	s.tokens.scripting = s.scripts
	s.tokens.on_tag = scan_tag
	s.tokens.user = s
	p.scan = s
	if p.speculation == nil { p.speculation = fetch.speculation_make(p.loader, &p.env, p.scope) }
}

// All the document's bytes so far.
preload_scan_feed :: proc(p: ^Page, data: []byte) {
	s := p.scan
	if s == nil { return }
	if !s.started {
		if len(data) < html.BOM_MAX_BYTES { return }
		s.started = true
		switch {
		case data[0] == 0xFE && data[1] == 0xFF, data[0] == 0xFF && data[1] == 0xFE: html.scan_stop(&s.tokens)
		case data[0] == 0xEF && data[1] == 0xBB && data[2] == 0xBF: s.utf8 = true
		}
	}
	html.scan_feed(&s.tokens, data)
}

// The document is complete, or failed: the parser takes over.
preload_scan_end :: proc(p: ^Page) {
	s := p.scan
	if s == nil { return }
	p.scan = nil
	html.scan_destroy(&s.tokens)
	if s.has_base { url.destroy(&s.base) }
	delete(s.picture_url)
	free(s)
}

@(private = "file")
scan_base :: proc(s: ^Preload_Scan) -> ^url.URL { return s.has_base ? &s.base : &s.page.env.location }

// The absolute URL of a value of the document. "" when it is not one to ask for.
@(private = "file")
scan_url :: proc(s: ^Preload_Scan, value: string) -> string {
	v := strings.trim_space(value)
	if v == "" { return "" }
	if !s.utf8 { for i in 0 ..< len(v) { if v[i] >= 0x80 { return "" } } }
	u, ok := url.parse(v, scan_base(s), context.temp_allocator)
	if !ok { return "" }
	switch u.scheme {
	case "http", "https": return u.href
	}
	return ""   // (data:, blob:, about: cost no request worth starting early)
}

@(private = "file")
scan_applies :: proc(s: ^Preload_Scan, t: ^html.Scan_Tag) -> bool {
	media, ok := html.scan_attr(t, "media")
	return !ok || media_attr_matches(media, s.env)
}

@(private = "file")
scan_cors :: proc(t: ^html.Scan_Tag) -> (fetch.Mode, fetch.Credentials) {
	if !html.scan_has_attr(t, "crossorigin") { return .No_Cors, .Include }
	v, _ := html.scan_attr(t, "crossorigin")
	return .Cors, base.ascii_equal_fold(strings.trim_space(v), "use-credentials") ? .Include : .Same_Origin
}

@(private = "file")
scan_referrer :: proc(t: ^html.Scan_Tag) -> fetch.Referrer_Policy {
	v, ok := html.scan_attr(t, "referrerpolicy")
	return ok ? fetch.parse_referrer_policy(v) : .Default
}

// Asks, if the document has any room left for it.
@(private = "file")
scan_ask :: proc(s: ^Preload_Scan, r: fetch.Request_Desc, link := false) -> bool {
	p := s.page
	if p.speculation.made >= p.settings.html.preload_max_requests { return false }
	return fetch.speculate(p.speculation, r, link)
}

@(private = "file")
scan_image :: proc(s: ^Preload_Scan, u: string, t: ^html.Scan_Tag) {
	p := s.page
	if u == "" || !p.settings.images.enabled || s.images >= p.settings.html.preload_max_images { return }
	mode, cred := scan_cors(t)
	if image_cached(p, u, mode, cred) { return }
	nonce, _ := html.scan_attr(t, "nonce")
	if scan_ask(s, {url = u, mode = mode, credentials = cred, destination = .Image, referrer_policy = scan_referrer(t), nonce = nonce,
		max_body = p.settings.images.limits.max_encoded_bytes}) {
		s.images += 1
	}
}

@(private = "file")
scan_img :: proc(s: ^Preload_Scan, t: ^html.Scan_Tag) {
	p := s.page
	if v, ok := html.scan_attr(t, "loading"); ok && base.ascii_equal_fold(strings.trim_space(v), "lazy") { return }
	if s.picture_seen {
		// (the <picture>'s <source> asks with the <img>'s attributes, as the element does)
		scan_image(s, s.picture_url, t)
		return
	}
	src, has_src := html.scan_attr(t, "src")
	srcset, has_set := html.scan_attr(t, "srcset")
	if has_set && strings.trim_space(srcset) != "" {
		sizes, _ := html.scan_attr(t, "sizes")
		if c, ok := srcset_choose(p, srcset, sizes, src, has_src, s.env); ok {
			scan_image(s, scan_url(s, c.url), t)
			return
		}
	}
	if has_src { scan_image(s, scan_url(s, src), t) }
}

@(private = "file")
scan_source :: proc(s: ^Preload_Scan, t: ^html.Scan_Tag) {
	if !s.in_picture || s.picture_seen { return }
	srcset, has_set := html.scan_attr(t, "srcset")
	if !has_set || strings.trim_space(srcset) == "" || !scan_applies(s, t) { return }
	if v, ok := html.scan_attr(t, "type"); ok && !type_attr_supported(v) { return }
	sizes, _ := html.scan_attr(t, "sizes")
	if c, ok := srcset_choose(s.page, srcset, sizes, "", false, s.env); ok {
		s.picture_seen = true
		delete(s.picture_url)
		s.picture_url = strings.clone(scan_url(s, c.url))
	}
}

@(private = "file")
scan_script :: proc(s: ^Preload_Scan, t: ^html.Scan_Tag) {
	if !s.scripts { return }
	src, has_src := html.scan_attr(t, "src")
	if !has_src { return }
	u := scan_url(s, src)
	if u == "" { return }
	ty, _ := html.scan_attr(t, "type")
	lang, _ := html.scan_attr(t, "language")
	kind, ok := script_kind_of_text(ty, html.scan_has_attr(t, "type"), lang)
	if !ok || kind == .Import_Map { return }
	nonce, _ := html.scan_attr(t, "nonce")
	mode, cred := scan_cors(t)
	if kind == .Module {
		// (js_load_modules.odin module_fetch)
		if mode == .No_Cors { mode, cred = .Cors, .Same_Origin }
		scan_ask(s, {url = u, mode = mode, credentials = cred, destination = .Script, script = .Module, nonce = nonce, referrer_policy = scan_referrer(t)})
		return
	}
	if html.scan_has_attr(t, "nomodule") { return }
	scan_ask(s, {url = u, mode = mode, credentials = cred, destination = .Script, script = .Classic, nonce = nonce,
		referrer_policy = scan_referrer(t), parser_inserted = true})
}

@(private = "file")
scan_link :: proc(s: ^Preload_Scan, t: ^html.Scan_Tag) {
	p := s.page
	rel, _ := html.scan_attr(t, "rel")
	href, has_href := html.scan_attr(t, "href")
	if !has_href { return }
	u := scan_url(s, href)
	if u == "" || !scan_applies(s, t) { return }
	if link_preconnect(p, rel, u) { return }
	nonce, _ := html.scan_attr(t, "nonce")
	if style.has_token(rel, "stylesheet") {
		if style.has_token(rel, "alternate") || html.scan_has_attr(t, "disabled") { return }
		if ty, ok := html.scan_attr(t, "type"); ok && strings.trim_space(ty) != "" && !base.ascii_equal_fold(strings.trim_space(ty), "text/css") { return }
		if p.engine == nil || !p.engine.settings.author_stylesheets { return }
		mode, cred := scan_cors(t)
		scan_ask(s, {url = u, mode = mode, credentials = cred, destination = .Style, nonce = nonce, referrer_policy = scan_referrer(t)})
		return
	}
	module := style.has_token(rel, "modulepreload")
	if !module && !style.has_token(rel, "preload") { return }
	as, _ := html.scan_attr(t, "as")
	co, _ := html.scan_attr(t, "crossorigin")
	r := link_preload_request(u, as, module, html.scan_has_attr(t, "crossorigin"), co)
	if r.destination == .Empty { return }   // (fetch(), which says more of its request than this, and what `as` does not name)
	#partial switch r.destination {
	case .Script: if !s.scripts { return }
	case .Image:  if !p.settings.images.enabled { return }
	case .Audio, .Video: return
	}
	r.nonce = nonce
	r.referrer_policy = scan_referrer(t)
	scan_ask(s, r, link = true)
}

@(private = "file")
scan_meta :: proc(s: ^Preload_Scan, t: ^html.Scan_Tag) {
	p := s.page
	if html.scan_has_attr(t, "charset") {
		v, _ := html.scan_attr(t, "charset")
		name := html.canonical_encoding(v)
		s.utf8 = name == "UTF-8"
		if !scan_reads_encoding(name) { html.scan_stop(&s.tokens) }
		return
	}
	content, _ := html.scan_attr(t, "content")
	if he, ok := html.scan_attr(t, "http-equiv"); ok {
		if base.ascii_equal_fold(he, "content-security-policy") && t.in_head && csp_on(p) { html.scan_stop(&s.tokens) }
		return
	}
	if name, ok := html.scan_attr(t, "name"); ok && base.ascii_equal_fold(name, "referrer") {
		if rp := fetch.parse_referrer_policy(content); rp != .Default { p.env.referrer_policy = rp }
	}
}

@(private = "file")
scan_tag :: proc(user: rawptr, t: ^html.Scan_Tag) {
	s := (^Preload_Scan)(user)
	switch t.name {
	case "base":
		if s.has_base || !t.in_head { return }
		href, ok := html.scan_attr(t, "href")
		if !ok { return }
		if u, parsed := url.parse(href, &s.page.env.location, context.temp_allocator); parsed {
			s.base = url.clone(u)
			s.has_base = true
		}
	case "img": scan_img(s, t)
	case "link": scan_link(s, t)
	case "meta": scan_meta(s, t)
	case "picture":
		s.in_picture = !t.closing
		s.picture_seen = false
	case "script": scan_script(s, t)
	case "source": scan_source(s, t)
	}
}

