package e2e_scenarios

// Accessibility: what a window tells a screen reader, and what a screen reader's requests do. The tree read here is the one the adapter is handed; what the system's
// UI Automation makes of it is the last test of this file, on a real window, read as a screen reader reads it. examples/a11y/page.html: a form, a list, a table, a
// dialog, live regions; examples/a11y/dynamic.html: a page that changes, a frame, a text field.

import "core:fmt"
import "core:strings"
import "core:testing"
import "toolkit:platform"
import "wb:e2e"

@(private = "file") A11Y_SIZE :: [2]int{1100, 760}
@(private = "file") Role :: platform.A11y_Role
@(private = "file") Entry :: e2e.A11y_Entry

@(private = "file")
find :: proc(tree: []Entry, role: Role, name: string, prefix := false) -> (Entry, bool) {
	for e in tree { if e.role == role && (prefix ? strings.has_prefix(e.name, name) : e.name == name) { return e, true } }
	return {}, false
}

@(private = "file")
named :: proc(tree: []Entry, name: string) -> (Entry, bool) {
	for e in tree { if e.name == name { return e, true } }
	return {}, false
}

@(private = "file")
count_role :: proc(tree: []Entry, role: Role) -> (n: int) {
	for e in tree { if e.role == role { n += 1 } }
	return
}

// What a barrier waits for: this node is told to a screen reader.
@(private = "file") Wanted :: struct { role: Role, name: string, prefix: bool }

@(private = "file")
wait_node :: proc(s: ^e2e.Session, role: Role, name: string, prefix := false, loc := #caller_location) -> Entry {
	e2e.wait_until(s, Wanted{role, name, prefix}, proc(s: ^e2e.Session, w: Wanted) -> bool { _, ok := find(e2e.a11y_tree(s), w.role, w.name, w.prefix); return ok }, fmt.tprintf("the node %v %q", role, name), loc = loc)
	e, _ := find(e2e.a11y_tree(s, loc), role, name, prefix)
	return e
}

@(private = "file")
wait_no_node :: proc(s: ^e2e.Session, role: Role, name: string, loc := #caller_location) {
	e2e.wait_until(s, Wanted{role, name, false}, proc(s: ^e2e.Session, w: Wanted) -> bool { _, ok := find(e2e.a11y_tree(s), w.role, w.name); return !ok }, fmt.tprintf("the node %v %q to go", role, name), loc = loc)
}

@(private = "file")
expect_node :: proc(t: ^testing.T, tree: []Entry, role: Role, name: string, loc := #caller_location) {
	_, ok := find(tree, role, name)
	testing.expectf(t, ok, "%v %q is told to a screen reader", role, name, loc = loc)
}

@(private = "file")
expect_no_name :: proc(t: ^testing.T, tree: []Entry, name: string, loc := #caller_location) {
	_, ok := named(tree, name)
	testing.expectf(t, !ok, "%q is left out", name, loc = loc)
}

// The chrome: its roles, names, states; invoking, setting a value, selecting, expanding.
@(test)
a11y_of_the_chrome :: proc(t: ^testing.T) {
	s := e2e.start(t, {size = A11Y_SIZE})
	e2e.a11y_capture(s)
	wait_node(s, .Button, "Back")
	tree := e2e.a11y_tree(s)
	for name in ([]string{"Back", "Forward", "Reload", "New tab", "Menu"}) { expect_node(t, tree, .Button, name) }
	expect_node(t, tree, .Tab_List, "Tabs")
	for e in tree { if e.role == .Tab { testing.expect(t, .Selected in e.flags, "the current tab is selected") } }
	for e in tree { if e.role == .Button { testing.expectf(t, len(e.name) != 1, "an icon font's glyph is no name: %q", e.name) } }
	address := wait_node(s, .Text_Input, "Address and search bar")

	new_tab, _ := find(tree, .Button, "New tab")
	e2e.a11y_act(s, new_tab, {action = .Click})
	e2e.wait_until(s, proc(s: ^e2e.Session) -> bool { return count_role(e2e.a11y_tree(s), .Tab) == 2 }, "a second tab")

	e2e.a11y_act(s, address, {action = .Set_Value, data = .Value, value = "wren a11y"})
	e2e.wait_until(s, proc(s: ^e2e.Session) -> bool {
		e, ok := find(e2e.a11y_tree(s), .Text_Input, "Address and search bar")
		return ok && e.value == "wren a11y"
	}, "the address bar to say it")

	first: Entry
	for e in e2e.a11y_tree(s) { if e.role == .Tab { first = e; break } }
	e2e.a11y_act(s, first, {action = .Click})
	e2e.wait_until(s, first.id, proc(s: ^e2e.Session, id: u64) -> bool {
		for e in e2e.a11y_tree(s) { if e.id == id { return .Selected in e.flags } }
		return false
	}, "the first tab to be selected")

	// (a button that opens a menu is expanded, not invoked)
	menu := wait_node(s, .Button, "Menu")
	e2e.a11y_act(s, menu, {action = .Expand})
	wait_node(s, .Menu_Item, "New tab", prefix = true)   // the menu shows its items
	menu = wait_node(s, .Button, "Menu")
	testing.expect(t, .Has_Expanded in menu.flags && .Expanded in menu.flags, "the Menu button says it is expanded")
	e2e.a11y_act(s, menu, {action = .Collapse})
	e2e.wait_until(s, proc(s: ^e2e.Session) -> bool { return count_role(e2e.a11y_tree(s), .Menu_Item) == 0 }, "collapse to close the menu")
}

// A page: its tree grafted under the chrome's, and what a screen reader's requests do to it.
@(test)
a11y_of_a_page :: proc(t: ^testing.T) {
	s := e2e.start(t, {size = A11Y_SIZE, url = e2e.file_url(fmt.tprintf("%s/examples/a11y/page.html", e2e.repo_root()))})
	e2e.a11y_capture(s)
	wait_node(s, .Document, "Accessibility sample")   // the page is a document named by its title
	wait_node(s, .Heading, "Accessibility sample")
	tree := e2e.a11y_tree(s)
	expect_node(t, tree, .Link, "Home")
	expect_node(t, tree, .Radio_Button, "Large")
	expect_node(t, tree, .Combo_Box, "Country")
	expect_node(t, tree, .Button, "Delete")               // named by its title
	expect_node(t, tree, .Table, "Scores")
	expect_node(t, tree, .Image, "A cat")                 // named by its alt
	expect_node(t, tree, .Slider, "Volume")
	expect_node(t, tree, .Dialog, "Confirm")
	field, has_field := find(tree, .Text_Input, "Your name")
	if testing.expect(t, has_field, "a field named by its label") { testing.expect_value(t, field.value, "Ada") }
	news, has_news := find(tree, .Check_Box, "Newsletter")
	if testing.expect(t, has_news, "a check box") { testing.expect(t, news.has_toggled && news.toggled == .True, "checked") }
	save, has_save := find(tree, .Button, "Save")
	if testing.expect(t, has_save, "a button") { testing.expect(t, .Disabled in save.flags, "disabled") }
	aria_tab, has_tab := find(tree, .Tab, "Grid")
	if testing.expect(t, has_tab, "tabs of ARIA") { testing.expect(t, .Selected in aria_tab.flags, "selected") }
	for name in ([]string{"Hidden", "Hidden too", "Inert", "Gone"}) { expect_no_name(t, tree, name) }   // aria-hidden, hidden, inert, display: none

	e2e.a11y_act(s, field, {action = .Set_Value, data = .Value, value = "Grace"})
	e2e.wait_js(s, "document.getElementById('name').value == 'Grace'")
	e2e.a11y_act(s, news, {action = .Click})
	e2e.wait_js(s, "!document.getElementById('news').checked")
	e2e.a11y_act(s, field, {action = .Focus})
	e2e.wait_js(s, "document.activeElement && document.activeElement.id == 'name'")
}

// A page that changes: its tree follows, node by node; a frame's document is in it; a text field's caret and selection are read and set; a second window shows its own.
@(test)
a11y_of_a_page_that_changes :: proc(t: ^testing.T) {
	root := e2e.repo_root()
	dynamic_page := e2e.file_url(fmt.tprintf("%s/examples/a11y/dynamic.html", root))
	sample_page := e2e.file_url(fmt.tprintf("%s/examples/a11y/page.html", root))
	s := e2e.start(t, {size = A11Y_SIZE, url = dynamic_page})
	e2e.a11y_capture(s)
	wait_node(s, .Document, "Accessibility updates")

	e2e.eval(s, "var b = document.createElement('button'); b.id = 'later'; b.textContent = 'Added later'; document.getElementById('host').appendChild(b); 'ok'")
	wait_node(s, .Button, "Added later")
	e2e.eval(s, "document.getElementById('h').textContent = 'Renamed heading'; 'ok'")
	wait_node(s, .Heading, "Renamed heading")
	e2e.eval(s, "var li = document.createElement('li'); li.textContent = 'Three'; document.getElementById('list').appendChild(li); 'ok'")
	e2e.wait_until(s, proc(s: ^e2e.Session) -> bool { return count_role(e2e.a11y_tree(s), .List_Item) == 3 }, "the list item the page adds")

	// static text has the bounds of its own line, not its block's
	item, text: Entry
	for e in e2e.a11y_tree(s) {
		if e.role == .List_Item && item.id == 0 { item = e }
		if e.role == .Label && e.value == "One" { text = e }
	}
	item_w, text_w := item.bounds[2] - item.bounds[0], text.bounds[2] - text.bounds[0]
	testing.expectf(t, text_w > 0 && text_w < item_w / 2, "a text's bounds are its own line's: item %v, text %v", item.bounds, text.bounds)

	e2e.eval(s, "document.getElementById('later').remove(); 'ok'")
	wait_no_node(s, .Button, "Added later")

	// a frame: its document in the page's tree, its button acts in the frame
	inner := wait_node(s, .Button, "Inside frame")
	testing.expect(t, inner.depth == 2, "the frame's document has its own tree")
	e2e.a11y_act(s, inner, {action = .Click})
	e2e.wait_js(s, "window.__msgs.includes('inner-click')")

	// the selection of a text field, and one made by the reader
	e2e.eval(s, "var f = document.getElementById('field'); f.focus(); f.setSelectionRange(0, 5); 'ok'")
	field := wait_node(s, .Text_Input, "Field")
	testing.expect_value(t, field.value, "Grace Hopper")
	run: Entry
	for e in e2e.a11y_tree(s) { if e.role == .Text_Run && e.value == "Grace Hopper" { run = e } }
	testing.expect(t, run.id != 0, "the field's text is a run of its own")
	e2e.a11y_act(s, field, {action = .Set_Text_Selection, data = .Text_Selection, sel = {run.id, SELECT_FROM, run.id, SELECT_TO}})
	e2e.wait_js(s, fmt.tprintf("(f => f.selectionStart == %d && f.selectionEnd == %d)(document.getElementById('field'))", SELECT_FROM, SELECT_TO))

	// a second window: each window shows its own page to the screen readers
	first := e2e.windows(s)[0].id
	e2e.run_command(s, "window.new")
	wins := e2e.windows(s)
	testing.expect_value(t, len(wins), 2)
	second := wins[0].id != first ? wins[0].id : wins[1].id
	{
		e2e.in_window(s, second)
		e2e.a11y_capture(s)
		e2e.navigate(s, sample_page)
		wait_node(s, .Document, "Accessibility sample")
		_, shows_first := find(e2e.a11y_tree(s), .Document, "Accessibility updates")
		testing.expect(t, !shows_first, "the second window does not show the first one's page")
	}
	{
		e2e.in_window(s, first)
		e2e.wait_frames(s)
		_, own := find(e2e.a11y_tree(s), .Document, "Accessibility updates")
		testing.expect(t, own, "the first window still shows its own")
	}
}
@(private = "file") SELECT_FROM :: 6
@(private = "file") SELECT_TO :: 12
