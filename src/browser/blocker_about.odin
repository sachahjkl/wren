package browser

import "core:fmt"
import "toolkit:ui"
import "wb:i18n"

// The About tab of about:blocker: how the blocker works, the filter syntax it understands, and where its tools are. Each
// sentence is a row of its own (a translation reorders and resizes sentences, not rows).

@(private = "file")
Syntax_Row :: struct { syntax, meaning: string }

@(private = "file")
sentence :: proc(text, id: string, i: int, font_scale: f32 = 1) {
	em := ui.font_size()
	ui.next({width = ui.fill(), height = ui.px(ui.dense(em * 1.6))})
	if ui.row(.Center) {
		ui.spacer(ui.px(em * 0.9))
		ui.next({width = ui.fill(), height = ui.pct(1), font_size = em * font_scale})
		ui.label(fmt.aprintf("%s###%s%d", text, id, i, allocator = ui.frame_allocator()))
	}
}

tab_about :: proc(app: ^App, t: ^Tab) {
	em := ui.font_size()
	ui.next({width = ui.fill(), height = ui.fill()})
	if ui.scroll_y("###ab_scroll") {
		section(i18n.tr("How it works"), "how")
		how := []string{
			i18n.tr("Every request of a page is judged before it leaves the machine, in a few microseconds."),
			i18n.tr("The URL is cut into tokens, each filter is filed under its rarest token, and only the few filters that share a token with the URL are tried."),
			i18n.tr("The lists are compiled once, on a background thread, into a compact index kept in the profile: start-up loads it in a few milliseconds."),
			i18n.tr("Blocked requests cost nothing: no DNS lookup, no connection, no script to download or run."),
			i18n.tr("Element hiding is in force at the first paint (no flash of ads); scriptlets run before the page's own scripts."),
			i18n.tr("Nothing is ever sent anywhere."),
		}
		for l, i in how { sentence(l, "ab1_", i) }

		section(i18n.tr("Filter syntax understood"), "syntax")
		rows := []Syntax_Row{
			{"||example.com^  |http://  *  ^  /regex/", i18n.tr("network filters: anchors, wildcards, separators, regular expressions")},
			{"$third-party  $script,image,stylesheet,xmlhttprequest,subdocument,media,font,websocket,ping,other,document,popup", i18n.tr("options: party and request types")},
			{"$domain=a.com|~b.com  $to=  $denyallow=  $method=  $important  $match-case  $badfilter  $all", i18n.tr("options: domains, method, priority")},
			{"$redirect=  $redirect-rule=  $removeparam=  $csp=  $header=  $generichide  $elemhide  $specifichide", i18n.tr("options: stand-ins, parameters, headers, page exceptions")},
			{"@@...", i18n.tr("exceptions")},
			{"example.com##.banner   ~example.com##.ad   google.*##.x   ##.generic", i18n.tr("element hiding, with exclusions and entities")},
			{":has()  :has-text()  :contains()  :matches-css()  :matches-attr()  :matches-path()  :min-text-length()  :not()  :upward()", i18n.tr("procedural selectors")},
			{":nth-ancestor()  :remove()  :style()  :-abp-contains()  :-abp-has()", i18n.tr("more procedural selectors")},
			{"example.com##+js(set-constant, name, value)", i18n.tr("scriptlets: set-constant, json-prune, abort-on-property-read, abort-current-script, no-fetch-if, click-element, and more")},
			{"!#if  !#else  !#endif  !#include", i18n.tr("conditional blocks and includes of the lists")},
			{"0.0.0.0 host", i18n.tr("hosts files")},
		}
		for r, i in rows {
			ui.next({width = ui.fill(), height = ui.px(ui.dense(em * 1.35))})
			if ui.row(.Center) {
				ui.spacer(ui.px(em * 0.9))
				cell(r.meaning, fmt.tprintf("ab2m_%d", i), em * 100, true)
			}
			ui.next({width = ui.fill(), height = ui.px(ui.dense(em * 1.5))})
			if ui.row(.Center) {
				ui.spacer(ui.px(em * 1.6))
				cell(r.syntax, fmt.tprintf("ab2s_%d", i), em * 100)
			}
		}

		section(i18n.tr("Panel and shortcuts"), "keys")
		keys := []string{
			i18n.tr("The shield at the end of the address bar opens the panel: power button for the site, switches, matrix, element picker, log."),
			i18n.tr("Matrix: a click on a cell blocks, allows, then resets that host and kind for this site; Shift+click does the same for every site."),
			i18n.tr("The context menu of a page has Block element… and Block this resource."),
			i18n.tr("Ctrl+Shift+K starts the element picker; the command palette lists every Blocker command."),
		}
		for l, i in keys { sentence(l, "ab3_", i) }
	}
}
