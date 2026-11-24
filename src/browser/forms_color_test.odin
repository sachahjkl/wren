package browser

import "base:runtime"
import "core:fmt"
import "core:strings"
import "core:testing"
import "toolkit:ui"
import "wb:base"
import "wb:dom"
import "wb:fetch"
import "wb:forms"
import "wb:host"
import "wb:page"

// <input type="color"> toolkit colour picker popover (forms_shell.odin / forms_shell_other.odin):
// opens with the input's hex value, applies live changes with "input", commits with "change", and reverts on Escape.
@(test)
forms_color_popover_updates_commits_and_reverts :: proc(t: ^testing.T) {
	app := test_app(t)
	context.allocator = runtime.heap_allocator()
	loop: host.Loop
	host.loop_init(&loop)
	defer host.loop_destroy(&loop)
	loader := fetch.Loader{loop = &loop}
	settings := page.settings_default()
	defer page.settings_destroy(&settings)
	settings.threads.parse_html = false
	scope := base.scope_make("test")
	defer base.scope_close(scope)

	p := page.page_create(&loop, &loader, &settings, scope, "https://example.test/color.html")
	defer page.page_close(p)
	page.load_html(p, transmute([]byte)string(`<!doctype html><body><input id="c" type="color" value="#336699"></body>`))
	el := dom.find_by_id(p.doc, "c")
	testing.expect(t, el != base.NIL_HANDLE, "color input exists")
	f := page.page_forms(p)
	testing.expect_value(t, forms.value(f, el), "#336699")

	// Formatting helper round-trips sRGB to lowercase #rrggbb.
	testing.expect_value(t, forms_hex_of_srgba(ui.Srgba{1, 0, 0.5, 0.25}), "#ff0080")
	testing.expect_value(t, forms_hex_of_srgba(ui.Srgba{0, 0, 0, 1}), "#000000")

	// Record DOM "input" and "change" events dispatched onto the colour input.
	Rec :: struct {
		p:   ^page.Page,
		el:  base.Handle,
		log: [dynamic]string,
	}
	rec := Rec{p = p, el = el}
	defer {
		for s in rec.log { delete(s) }
		delete(rec.log)
	}
	p.dp.invoke = proc(user: rawptr, l: dom.Listener, event: base.Handle) -> bool {
		r := (^Rec)(user)
		ty := dom.event_type(&r.p.dp, event)
		val := forms.value(page.page_forms(r.p), r.el)
		append(&r.log, fmt.aprintf("%s:%s", ty, val))
		return true
	}
	p.dp.user = rawptr(&rec)
	_, _ = dom.add_listener(p.doc, el, "input", 1, 1, false, false, false)
	_, _ = dom.add_listener(p.doc, el, "change", 2, 2, false, false, false)

	// Open, live-update, and commit: sets value, fires "input" then "change".
	forms_color_popover_open(app, p, el)
	fv := forms_view(app)
	testing.expect(t, fv.color_pop.open, "popover opened")
	testing.expect_value(t, fv.color_pop.initial, "#336699")
	testing.expect_value(t, forms_hex_of_srgba(ui.color_pick_rgba(&fv.color_pop.pick)), "#336699")

	forms_color_popover_apply(app, "#ff8800")
	testing.expect_value(t, forms.value(f, el), "#ff8800")

	forms_color_popover_close(app, commit = true)
	testing.expect(t, !fv.color_pop.open, "popover closed after commit")
	testing.expect_value(t, forms.value(f, el), "#ff8800")

	// Open, live-update, then Escape (revert): restores "#ff8800", fires "input" for revert, no "change".
	forms_color_popover_open(app, p, el)
	forms_color_popover_apply(app, "#112233")
	testing.expect_value(t, forms.value(f, el), "#112233")
	forms_color_popover_close(app, commit = false, revert = true)
	testing.expect(t, !fv.color_pop.open, "popover closed after revert")
	testing.expect_value(t, forms.value(f, el), "#ff8800")

	testing.expect_value(t, strings.join(rec.log[:], ",", context.temp_allocator), "input:#ff8800,change:#ff8800,input:#112233,input:#ff8800")

	// Closing the page while the popover is open clears it via scope cleanup so later apply/close never touch freed memory.
	p2 := page.page_create(&loop, &loader, &settings, scope, "https://example.test/color2.html")
	page.load_html(p2, transmute([]byte)string(`<!doctype html><body><input id="c2" type="color" value="#123456"></body>`))
	el2 := dom.find_by_id(p2.doc, "c2")
	testing.expect(t, el2 != base.NIL_HANDLE, "second color input exists")
	forms_color_popover_open(app, p2, el2)
	testing.expect(t, fv.color_pop.open && fv.color_pop.page == p2, "popover opened on p2")
	page.page_close(p2)
	testing.expect(t, !fv.color_pop.open && fv.color_pop.page == nil, "page_close detached popover")
	forms_color_popover_apply(app, "#abcdef")
	forms_color_popover_close(app, commit = true)
	testing.expect(t, !fv.color_pop.open, "subsequent apply/close are no-ops")
}
