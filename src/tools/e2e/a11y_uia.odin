#+build windows
package e2e_scenarios

// What a screen reader reads: a Wren of its own, with a real window that is never shown, read and driven through the system's UI Automation (toolkit:tools/uia, a client of
// the COM interface), from this process as a screen reader does from its own. The tree is that of a11y.odin, through AccessKit: the roles and names as they arrive, the patterns
// that act, a page's tree that follows it node by node, each window's own page.

import "core:fmt"
import win "core:sys/windows"
import "core:testing"
import "core:time"
import "../../../ext/gui_toolkit/tools/uia"
import "wb:e2e"
import "wb:remote/api"

@(private = "file") FIND_LIMIT :: 30 * time.Second      // only ends a failing run: an element of a tree rebuilt comes back at once
@(private = "file") REST_FRAMES :: 30                   // frames in which nothing changes: more than the page's tree's interval (accessibility.page.interval_ms)
@(private = "file") SELECT_FROM :: 6
@(private = "file") SELECT_TO :: 12

@(private = "file")
Reader :: struct {
	t:      ^testing.T,
	client: uia.Client,
	hwnd:   rawptr,
}

// `prefix`: the name begins with this. The first one found; nil: none.
@(private = "file")
look :: proc(r: ^Reader, control: uia.Control, name: string, prefix := false) -> ^uia.Element {
	root := uia.from_window(&r.client, r.hwnd)
	if root == nil { return nil }
	defer uia.drop(root)
	all := uia.descendants(&r.client, root, context.temp_allocator)
	found: ^uia.Element
	for e in all {
		n := uia.name(e, context.temp_allocator)
		if found == nil && uia.control(e) == control && (n == name || (prefix && len(n) >= len(name) && n[:len(name)] == name)) { found = e } else { uia.drop(e) }
	}
	return found
}

// Waits for it: what a reader sees comes after what the frames made.
@(private = "file")
wait_element :: proc(r: ^Reader, control: uia.Control, name: string, prefix := false, loc := #caller_location) -> ^uia.Element {
	end := time.tick_add(time.tick_now(), FIND_LIMIT)
	for time.tick_diff(time.tick_now(), end) > 0 {
		if e := look(r, control, name, prefix); e != nil { return e }
	}
	e2e.stop_test(r.t, fmt.tprintf("UI Automation does not show the %v %q", control, name), loc)
}

@(private = "file")
wait_gone :: proc(r: ^Reader, control: uia.Control, name: string, loc := #caller_location) {
	end := time.tick_add(time.tick_now(), FIND_LIMIT)
	for time.tick_diff(time.tick_now(), end) > 0 {
		e := look(r, control, name)
		if e == nil { return }
		uia.drop(e)
	}
	e2e.stop_test(r.t, fmt.tprintf("UI Automation still shows the %v %q", control, name), loc)
}

@(test)
a_screen_reader_reads_a_hidden_window :: proc(t: ^testing.T) {
	p := e2e.launch(t, {hidden = true, prefs = {"accessibility.page.verify=true"}})
	client, opened := uia.open()
	if !testing.expect(t, opened, "the system's UI Automation is there") { return }
	defer uia.close(&client)
	wins, _ := api.windows(p.s)
	first := wins[0]
	testing.expect(t, first.hwnd != 0, "a real window")
	testing.expect(t, !bool(win.IsWindowVisible(win.HWND(uintptr(first.hwnd)))), "never shown")
	r := Reader{t = t, client = client, hwnd = rawptr(uintptr(first.hwnd))}

	// the chrome: the first question makes Wren build its tree
	uia.drop(wait_element(&r, .Button, "Back"))
	for name in ([]string{"Forward", "Reload", "New tab", "Menu"}) { uia.drop(wait_element(&r, .Button, name)) }
	uia.drop(wait_element(&r, .Tab, "Tabs"))   // (a tab list is UI Automation's Tab, its tabs are Tab_Item)
	current := wait_element(&r, .Tab_Item, "", prefix = true)
	testing.expect_value(t, uia.is_selected(current), 1)
	uia.drop(current)

	// its patterns: invoke, value, selection, expand
	new_tab := wait_element(&r, .Button, "New tab")
	testing.expect(t, uia.invoke(new_tab), "invoke New tab")
	uia.drop(new_tab)
	wait_tabs(p, 2)

	address := wait_element(&r, .Edit, "Address and search bar")
	testing.expect(t, uia.set_value(address, "wren a11y"), "set the address bar")
	end := time.tick_add(time.tick_now(), FIND_LIMIT)
	for time.tick_diff(time.tick_now(), end) > 0 {
		if v, ok := uia.value(address, context.temp_allocator); ok && v == "wren a11y" { break }
	}
	v, _ := uia.value(address, context.temp_allocator)
	testing.expect_value(t, v, "wren a11y")
	uia.drop(address)

	menu := wait_element(&r, .Button, "Menu")
	testing.expect(t, uia.expand(menu), "expand Menu")
	uia.drop(wait_element(&r, .Menu_Item, "New tab", prefix = true))
	testing.expect(t, uia.collapse(menu), "collapse Menu")
	uia.drop(menu)
	wait_gone(&r, .Menu_Item, "New tab")

	// a page that changes: its tree follows, node by node, each patch compared with a whole tree (accessibility.page.verify)
	root := e2e.repo_root()
	api.navigate(p.s, e2e.file_url(fmt.tprintf("%s/examples/a11y/dynamic.html", root)))
	uia.drop(wait_element(&r, .Document, "Accessibility updates"))
	uia.drop(wait_element(&r, .Button, "Inside frame"))
	s0, _ := api.stats(p.s)
	api.eval(p.s, "var b = document.createElement('button'); b.id = 'later'; b.textContent = 'Added later'; document.getElementById('host').appendChild(b); 'ok'")
	uia.drop(wait_element(&r, .Button, "Added later"))
	api.eval(p.s, "document.getElementById('later').remove(); 'ok'")
	wait_gone(&r, .Button, "Added later")
	s1, _ := api.stats(p.s)
	testing.expectf(t, s1.a11y.page_builds == s0.a11y.page_builds && s1.a11y.page_patches > s0.a11y.page_patches, "the changes went as patches, not whole trees: builds %d -> %d (%s), patches %d -> %d", s0.a11y.page_builds, s1.a11y.page_builds, s1.a11y.page_fallback, s0.a11y.page_patches, s1.a11y.page_patches)
	testing.expectf(t, s1.a11y.page_verify_failed == 0, "every patch equals a whole tree: %s", s1.a11y.page_verify_diff)
	testing.expect_value(t, s1.a11y.refused + s1.a11y.page_refused, 0)   // no update refused by the adapter
	testing.expect(t, s1.a11y.page_frames >= 1, "the frame's document is in the page's tree")

	// at rest: nothing of the page is built or sent while nothing changes
	api.wait_frames(p.s, REST_FRAMES)
	r0, _ := api.stats(p.s)
	api.wait_frames(p.s, REST_FRAMES)
	r1, _ := api.stats(p.s)
	testing.expectf(t, r1.a11y.page_sends == r0.a11y.page_sends && r1.a11y.page_builds == r0.a11y.page_builds && r1.a11y.page_patches == r0.a11y.page_patches, "nothing built or sent at rest: sends %d -> %d, builds %d -> %d, patches %d -> %d", r0.a11y.page_sends, r1.a11y.page_sends, r0.a11y.page_builds, r1.a11y.page_builds, r0.a11y.page_patches, r1.a11y.page_patches)

	// a frame's button acts in the frame; the text pattern reads a field and selects in it
	inner := wait_element(&r, .Button, "Inside frame")
	testing.expect(t, uia.invoke(inner), "invoke a button of the frame")
	uia.drop(inner)
	api.wait_js(p.s, "window.__msgs.includes('inner-click')")
	api.eval(p.s, "var f = document.getElementById('field'); f.focus(); f.setSelectionRange(0, 5); 'ok'")
	field := wait_element(&r, .Edit, "Field")
	sel := ""
	end = time.tick_add(time.tick_now(), FIND_LIMIT)
	for sel != "Grace" && time.tick_diff(time.tick_now(), end) > 0 { sel, _ = uia.text_selection(field, context.temp_allocator) }
	testing.expect_value(t, sel, "Grace")
	text, _ := uia.document_text(field, context.temp_allocator)
	testing.expect_value(t, text, "Grace Hopper")
	testing.expect(t, uia.select_text(field, SELECT_FROM, SELECT_TO), "select text in the field")
	uia.drop(field)
	api.wait_js(p.s, fmt.tprintf("(f => f.selectionStart == %d && f.selectionEnd == %d)(document.getElementById('field'))", SELECT_FROM, SELECT_TO))

	// a second window: each window shows its own page to the screen readers
	api.run_command(p.s, "window.new")
	api.wait_frames(p.s)
	wins, _ = api.windows(p.s)
	testing.expect_value(t, len(wins), 2)
	second := wins[0].id != first.id ? wins[0] : wins[1]
	testing.expect(t, !bool(win.IsWindowVisible(win.HWND(uintptr(second.hwnd)))), "a new window is never shown either")
	{
		api.in_window(p.s, second.id)
		api.navigate(p.s, e2e.file_url(fmt.tprintf("%s/examples/a11y/page.html", root)))
	}
	r2 := Reader{t = t, client = client, hwnd = rawptr(uintptr(second.hwnd))}
	uia.drop(wait_element(&r2, .Document, "Accessibility sample"))
	uia.drop(wait_element(&r, .Document, "Accessibility updates"))
	shown := look(&r2, .Button, "Inside frame")
	testing.expect(t, shown == nil, "the second window does not show the first one's page")
	if shown != nil { uia.drop(shown) }
}

@(private = "file")
wait_tabs :: proc(p: ^e2e.Wren_Process, n: int) {
	end := time.tick_add(time.tick_now(), FIND_LIMIT)
	for time.tick_diff(time.tick_now(), end) > 0 {
		st, _ := api.stats(p.s)
		if st.tabs == n { return }
		api.wait_frames(p.s)
	}
	testing.expectf(p.t, false, "%d tabs", n)
}
