package style

import "wb:dom"
import "wb:html"

// What the style tests share: a document parsed, its sheets and its styles.

FIXTURE_PARSE_MAX :: 2_000_000
FIXTURE_JOURNAL :: 1 << 16

Fixture_Options :: struct {
	set:      ^Settings,    // the engine's (nil: the defaults)
	journal:  int,          // entries of the style journal (0: none)
	partial:  bool,         // documents of a few elements restyled in part all the same (inc_max_ratio 1), the DOM journal on
	dark:     Maybe(bool),  // the environment prefers a dark scheme (nil: as the settings say)
	timeline: bool,         // animations and transitions at time 0
}

Fixture :: struct {
	doc: ^dom.Document,
	eng: ^Engine,
	st:  ^Styled,
	tl:  ^Timeline,
}

fixture_load :: proc(src: string, o := Fixture_Options{}) -> ^Fixture {
	f := new(Fixture)
	f.doc = dom.document_create(nil)
	html.parse_into(f.doc, f.doc.root, transmute([]byte)src, FIXTURE_PARSE_MAX)
	if o.set != nil {
		f.eng = engine_make(o.set^)
	} else {
		s := settings_default()
		f.eng = engine_make(s)
		settings_destroy(&s)
	}
	if o.journal > 0 { engine_set_journal(f.eng, o.journal) }
	if o.partial { f.eng.settings.inc_max_ratio = 1 }
	if dark, ok := o.dark.?; ok {
		env := f.eng.env
		env.prefers_dark = dark
		engine_set_environment(f.eng, env)
	}
	sync_document_sheets(f.eng, f.doc, "about:test")
	f.st = compute_styles(f.eng, f.doc, {})
	if o.partial { dom.journal_enable(f.doc, FIXTURE_JOURNAL) }
	if o.timeline {
		f.tl = timeline_make(f.eng)
		timeline_restyled(f.tl, f.doc, nil, f.st, 0)
		timeline_tick(f.tl, f.doc, f.st, 0)
	}
	return f
}

fixture_unload :: proc(f: ^Fixture) {
	if f.tl != nil { timeline_destroy(f.tl, f.st) }
	styled_destroy(f.st)
	engine_destroy(f.eng)
	dom.document_destroy(f.doc)
	free(f)
}
