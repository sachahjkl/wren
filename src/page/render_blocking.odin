package page

import "core:fmt"
import "core:strings"
import "wb:base"
import "wb:css"
import "wb:dom"
import "wb:host"
import "wb:style"

// What the first paint of a document waits for (HTML "render-blocking"; CSS Fonts 4 font-display), so that it is not
// shown unstyled or with the wrong fonts and then re-shown:
//   * the stylesheets of the document as parsed: <link rel=stylesheet> wherever they are (the body's ones too: this
//     browser lays the document out at once, so "block the content after them" is "block the first paint"), the
//     @imports of those and of <style> elements; a sheet whose media does not match does not block; a <link> or
//     <style> a script adds blocks only with blocking="render";
//   * web fonts used by the page while in their block period (auto / block: style.webfonts.block_period_ms; fallback /
//     optional: style.webfonts.short_block_period_ms). Text is not drawn invisible in place: the first paint waits.
// Stylesheets block at most style.render_blocking.timeout_ms. Parsing itself is not blocked. The shell asks
// `first_paint_state` before painting a new document and says `first_paint_done` once it has.

Render_Block :: struct {
	adopted:    bool,   // the document is there (parsed and adopted, or built by the shell)
	adopted_ms: f64,    // ... since (the loop's clock)
	collecting: bool,   // between adoption and the first paint: sheets and imports found now are the parser's
	painted:    bool,   // the shell painted the document once
}

First_Paint_State :: enum u8 {
	No_Document,   // still the blank document of a page whose own one has not arrived
	Blocked,       // render-blocking resources are pending
	Ready,
}

@(private)
now_ms :: proc(p: ^Page) -> f64 { return f64(host.now_ns(p.loop)) / 1e6 }

// The document of the page is complete from the shell's point of view (called by adopt_document; the shell calls it
// for documents it builds itself: text, a module). Starts loading its stylesheets at once.
render_begin :: proc(p: ^Page) {
	p.render = Render_Block{adopted = true, adopted_ms = now_ms(p), collecting = true}
	if p.engine != nil && p.doc != nil { sync_styles(p) }
}

// The shell painted the document: later sheets and fonts no longer hold anything back.
first_paint_done :: proc(p: ^Page) {
	if p.render.painted { return }
	p.render.painted = true
	p.render.collecting = false
}

// Whether `owner` (<link> or <style>) may block the first paint: a parser's element before that paint, or any element
// with blocking="render".
@(private)
render_blocking_candidate :: proc(p: ^Page, owner: base.Handle) -> bool {
	if v, ok := dom.get_attribute(p.doc, owner, "blocking"); ok {
		rest := v
		for tok in strings.fields_iterator(&rest) { if strings.equal_fold(tok, "render") { return true } }
	}
	return p.render.collecting && !p.render.painted
}

@(private)
media_text_matches :: proc(e: ^style.Engine, media: string) -> bool {
	if strings.trim_space(media) == "" { return true }
	toks := css.parse_component_values(media, style.parse_options(&e.settings), context.temp_allocator)
	list := css.parse_media_query_list(toks, context.temp_allocator)
	return css.media_matches(list, e.env)
}

// The top-level sheet that holds (or imports) the sheet `id`.
@(private)
top_sheet_of :: proc(e: ^style.Engine, id: u64) -> ^style.Sheet {
	holds :: proc(s: ^style.Sheet, id: u64) -> bool {
		if s.id == id { return true }
		for &slot in s.imports { if slot.child != nil && holds(slot.child, id) { return true } }
		return false
	}
	for s in e.sheets { if holds(s, id) { return s } }
	return nil
}

// A render-blocking stylesheet is still on its way: the reason, else "".
@(private)
pending_blocking_sheet :: proc(p: ^Page) -> string {
	e := p.engine
	if e == nil { return "" }
	for owner, l in p.link_loads {
		if !l.parser || l.failed { continue }
		if !media_text_matches(e, l.media) { continue }
		if l.task == base.NIL_HANDLE && style.engine_sheet_of_owner(e, owner) != nil { continue }
		return l.url
	}
	for l in p.import_loads {
		if !l.parser || l.failed { continue }
		parent := style.engine_find_sheet(e, l.sheet_id)
		if parent == nil || l.slot < 0 || l.slot >= len(parent.imports) { continue }   // the importing sheet went away
		slot := parent.imports[l.slot]
		if slot.child != nil || slot.failed { continue }
		if top := top_sheet_of(e, l.sheet_id); top != nil && len(top.media) > 0 && !css.media_matches(top.media, e.env) { continue }
		if len(slot.rule.media) > 0 && !css.media_matches(slot.rule.media, e.env) { continue }
		return l.url
	}
	return ""
}

// A web font used by the page in its block period: its family, else "".
@(private)
pending_blocking_font :: proc(p: ^Page, now: f64) -> string {
	s := &p.settings.style
	for _, f in p.fonts.faces {
		if f.state != .Queued && f.state != .Loading { continue }
		block: f64
		switch f.display {
		case .Auto, .Block: block = s.webfont_block_ms
		case .Fallback, .Optional: block = s.webfont_short_block_ms
		case .Swap: block = 0
		}
		if now - f.started_ms < block { return f.family }
	}
	return ""
}

// Whether the document can be painted for the first time: it is there, and nothing that blocks rendering is pending
// (or the waits are over). `why`: what is waited for (diagnostics).
first_paint_state :: proc(p: ^Page) -> (state: First_Paint_State, why: string) {
	if !p.render.adopted { return .No_Document, "document" }
	if p.render.painted { return .Ready, "" }
	now := now_ms(p)
	if now - p.render.adopted_ms < p.settings.style.render_block_ms {
		if u := pending_blocking_sheet(p); u != "" { return .Blocked, u }
	}
	if f := pending_blocking_font(p, now); f != "" { return .Blocked, fmt.tprintf("font %q", f) }
	return .Ready, ""
}

// How long (ms) until the next wait of a blocked first paint runs out whatever happens (the shell wakes up then);
// -1 when nothing is waited for.
first_paint_next_deadline_ms :: proc(p: ^Page) -> f64 {
	if !p.render.adopted || p.render.painted { return -1 }
	now := now_ms(p)
	s := &p.settings.style
	best := -1.0
	consider :: proc(best: ^f64, at, now: f64) { if at > now && (best^ < 0 || at - now < best^) { best^ = at - now } }
	consider(&best, p.render.adopted_ms + s.render_block_ms, now)
	for _, f in p.fonts.faces {
		if f.state != .Queued && f.state != .Loading { continue }
		block := f.display == .Auto || f.display == .Block ? s.webfont_block_ms : (f.display == .Swap ? 0 : s.webfont_short_block_ms)
		consider(&best, f.started_ms + block, now)
	}
	return best
}
