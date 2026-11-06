package style

import "core:fmt"
import "core:mem"
import "core:strings"
import "core:testing"
import "wb:dom"

CUSTOM_TEST_LAYERS :: 8

// A variable changed on the root: every element under it compares its set of hundreds of names with the old one. The digest says they
// differ, whatever the layers, without the map of every name each comparison made (CNN: a frame of 10.9 s, 11 500 elements); sets alike
// have the same digest however they were built.
@(test)
custom_properties_digest :: proc(t: ^testing.T) {
	VARS :: 300
	layer :: proc(parent: ^Custom_Props, max_layers := CUSTOM_TEST_LAYERS) -> ^Custom_Props { return custom_begin(parent, max_layers, context.temp_allocator) }
	root, changed := layer(nil), layer(nil)
	for i in 0 ..< VARS {
		name, value := fmt.tprintf("--v%d", i), fmt.tprintf("%dpx", i)
		custom_set(root, name, value)
		custom_set(changed, name, i == VARS / 2 ? "other" : value)
	}
	own_a, own_b := layer(root), layer(changed)
	custom_set(own_a, "--own", "1")
	custom_set(own_b, "--own", "1")
	{
		context.temp_allocator = mem.panic_allocator()   // (no name is read: a map of them would end the test here)
		testing.expect(t, !custom_equal(root, changed), "one value of three hundred")
		testing.expect(t, !custom_equal(own_a, own_b), "the same, a layer up")
	}
	// the same names and values by other ways: overridden, removed and set again, flat
	again := layer(nil)
	for i in 0 ..< VARS { custom_set(again, fmt.tprintf("--v%d", i), "before") }
	custom_set(again, "--gone", "x")
	custom_remove(again, "--gone", context.temp_allocator)
	for i in 0 ..< VARS { custom_set(again, fmt.tprintf("--v%d", i), fmt.tprintf("%dpx", i)) }
	testing.expect_value(t, again.digest, root.digest)
	testing.expect(t, custom_equal(root, again), "overridden, removed: the same set")
	over := layer(root)
	custom_set(over, "--v3", "changed")
	custom_remove(over, "--v4", context.temp_allocator)
	custom_set(over, "--v4", "4px")
	custom_set(over, "--v3", "3px")
	testing.expect_value(t, over.digest, root.digest)
	testing.expect(t, custom_equal(root, over), "a layer that says what is under it: the same set")
	flat := layer(own_a, 0)
	testing.expect_value(t, flat.digest, own_a.digest)
	gone := layer(root)
	custom_remove(gone, "--v5", context.temp_allocator)
	testing.expect(t, gone.digest != root.digest && !custom_equal(gone, root), "a name dropped")
	back := layer(gone)
	custom_set(back, "--v5", "5px")
	testing.expect_value(t, back.digest, root.digest)
}

// Hundreds of variables on :root and a few more set on every level of a deep tree (DuckDuckGo's pages): each element
// keeps a layer of its own names, not a copy of every inherited one, and reads the same values as with copies.
@(test)
custom_properties_layers :: proc(t: ^testing.T) {
	VARS :: 300
	DEPTH :: 40
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, "<style>:root{")
	for i in 0 ..< VARS { fmt.sbprintf(&b, "--v%d: %dpx;", i, i) }
	strings.write_string(&b, "} div { --depth: attr-less; } .bad { --v7: var(--nope); } .back { --v7: 77px; }")
	strings.write_string(&b, " @property --solo { syntax: '<length>'; inherits: false; initial-value: 0px; } .solo { --solo: 5px; }")
	for i in 0 ..< DEPTH { fmt.sbprintf(&b, " .l%d {{ --depth: %d }}", i, i) }
	strings.write_string(&b, "</style>")
	for i in 0 ..< DEPTH {
		cls := i == 10 ? "bad" : i == 20 ? "back" : i == 30 ? "solo" : ""
		fmt.sbprintf(&b, "<div id=d%d class='l%d %s'>", i, i, cls)
	}
	for _ in 0 ..< DEPTH { strings.write_string(&b, "</div>") }

	for max_layers in ([]int{8, 0}) {
		s := settings_default()
		s.custom_max_layers = max_layers
		f := fixture_load(strings.to_string(b), {set = &s})
		settings_destroy(&s)
		defer fixture_unload(f)
		for i in 0 ..< DEPTH {
			c := style_of(f.st, dom.find_by_id(f.doc, fmt.tprintf("d%d", i)))
			testing.expect(t, c != nil && c.custom != nil)
			if c == nil || c.custom == nil { return }
			p := c.custom
			v, ok := custom_get(p, "--depth")
			testing.expectf(t, ok && v == fmt.tprintf("%d", i), "d%d: --depth = %q", i, v)
			v, ok = custom_get(p, "--v299")
			testing.expectf(t, ok && v == "299px", "d%d inherits --v299: %q", i, v)
			// invalid at computed-value time below .bad: absent until .back sets it again
			v, ok = custom_get(p, "--v7")
			if i >= 10 && i < 20 { testing.expectf(t, !ok, "d%d: --v7 is invalid (%q)", i, v) } else {
				testing.expectf(t, ok && v == (i >= 20 ? "77px" : "7px"), "d%d: --v7 = %q", i, v)
			}
			// a registered property that does not inherit: on .solo only
			_, ok = custom_get(p, "--solo")
			testing.expectf(t, ok == (i == 30), "d%d: --solo present %v", i, ok)
			testing.expect_value(t, len(custom_flatten(p, context.temp_allocator)), p.total)
			testing.expect(t, p.depth <= max_layers)
			if max_layers > 0 {
				testing.expectf(t, p.parent == nil || len(p.values) <= 3, "d%d keeps only its own names (%d)", i, len(p.values))
			} else {
				testing.expect(t, p.parent == nil && len(p.values) == p.total)
			}
			// a flat copy has the same values as the layers
			flat := custom_begin(nil, max_layers, context.temp_allocator)
			for name, value in custom_flatten(p, context.temp_allocator) { custom_set(flat, name, value) }
			testing.expect(t, custom_equal(p, flat) && custom_equal(flat, p))
		}
	}
}

@(test)
custom_properties_layer_edits :: proc(t: ^testing.T) {
	a := context.temp_allocator
	root := custom_begin(nil, 4, a)
	custom_set(root, "--a", "1")
	custom_set(root, "--b", "2")
	testing.expect_value(t, root.total, 2)
	l := custom_begin(root, 4, a)
	custom_remove(l, "--a", a)
	custom_set(l, "--c", "3")
	custom_set(l, "--b", "20")
	testing.expect_value(t, l.total, 2)
	custom_set(l, "--a", "10")   // back after a removal
	testing.expect_value(t, l.total, 3)
	custom_remove(l, "--c", a)
	testing.expect_value(t, l.total, 2)
	custom_remove(l, "--zz", a)   // not there: nothing changes
	testing.expect_value(t, l.total, 2)
	v, ok := custom_get(l, "--a")
	testing.expect(t, ok && v == "10")
	v, ok = custom_get(l, "--b")
	testing.expect(t, ok && v == "20")
	testing.expect(t, !custom_has(l, "--c"))
	other := custom_begin(nil, 4, a)
	custom_set(other, "--b", "20")
	custom_set(other, "--a", "10")
	testing.expect(t, custom_equal(l, other))
	custom_set(other, "--a", "11")
	testing.expect(t, !custom_equal(l, other))
}

// The names and values a layer holds are its own copies: they come from the rules, which a rebuild of the rule index
// frees, while the previous styles of a page are still compared with the next ones (transitions). Before, a page whose
// sheets arrived between two passes crashed in string_eq (tailwindcss.com, then getbootstrap.com).
@(test)
custom_layer_owns_its_strings :: proc(t: ^testing.T) {
	name := strings.clone("--from-a-rule")
	value := strings.clone("12px")
	removed := strings.clone("--gone")
	defer { delete(name); delete(value); delete(removed) }
	parent := custom_begin(nil, 8, context.temp_allocator)
	custom_set(parent, "--gone", "1")
	p := custom_begin(parent, 8, context.temp_allocator)
	custom_set(p, name, value)
	custom_remove(p, removed, context.temp_allocator)
	for k, v in p.values {
		testing.expect(t, raw_data(k) != raw_data(name), "the name is a copy")
		testing.expect(t, raw_data(v) != raw_data(value), "the value is a copy")
	}
	testing.expect_value(t, len(p.removed), 1)
	testing.expect(t, raw_data(p.removed[0]) != raw_data(removed), "the removed name is a copy")
	got, ok := custom_get(p, "--from-a-rule")
	testing.expect(t, ok && got == "12px")
	_, gone := custom_get(p, "--gone")
	testing.expect(t, !gone)
}
// Sets alike are told by their digests: nothing of them is read, whatever their layers.
@(test)
custom_properties_equal_sets_are_not_read :: proc(t: ^testing.T) {
	a, b := custom_begin(nil, CUSTOM_TEST_LAYERS, context.temp_allocator), custom_begin(nil, CUSTOM_TEST_LAYERS, context.temp_allocator)
	custom_set(a, "--a", "1")
	custom_set(b, "--a", "1")
	b.values = nil
	testing.expect(t, custom_equal(a, b))
}