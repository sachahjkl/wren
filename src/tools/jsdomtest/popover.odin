package jsdomtest

// examples/jsdom/popover.html: the Popover API. The page checks what scripts can do; here the shell's part: a trusted
// click outside an auto popover hides it (light dismiss), one inside or on its invoker does not, Escape hides the
// topmost one.

import "wb:dom"
import "wb:forms"
import "wb:page"

popover_checks :: proc(p: ^page.Page) {
	f := page.page_forms(p)
	click :: proc(f: ^forms.Forms, p: ^page.Page, id: string) { forms.click(f, dom.find_by_id(p.doc, id), forms.Click_Info{trusted = true}) }
	page.js_run(p, transmute([]byte)string(`document.getElementById("a").showPopover(); document.getElementById("nested").showPopover(); document.getElementById("m").showPopover()`), "probe.js")
	click(f, p, "nested")
	probe_checks(p, `eq("a click inside the nested popover keeps both", ["a", "nested"].map((id) => document.getElementById(id).matches(":popover-open")).join(), "true,true")`, "light dismiss inside")
	forms.key_down(f, .Escape, {})
	probe_checks(p, `eq("Escape hides the topmost auto popover", ["a", "nested"].map((id) => document.getElementById(id).matches(":popover-open")).join(), "true,false")`, "close request")
	click(f, p, "outside")
	probe_checks(p, `eq("a click outside hides the auto popovers, not the manual one", ["a", "m"].map((id) => document.getElementById(id).matches(":popover-open")).join(), "false,true")`, "light dismiss outside")
	click(f, p, "btn")
	click(f, p, "btn")
	probe_checks(p, `eq("a trusted click on the invoker toggles it off (not dismissed, then toggled)", document.getElementById("b").matches(":popover-open"), false)`, "invoker")
}
