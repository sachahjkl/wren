package html

import "core:fmt"
import "core:strings"
import "core:testing"
import "wb:base"
import "wb:dom"

@(private = "file")
dump :: proc(d: ^dom.Document, h: base.Handle, sb: ^strings.Builder) {
	// iterative pre-order with explicit close markers
	Item :: struct { h: base.Handle, close: bool }
	stack: [dynamic]Item
	defer delete(stack)
	append(&stack, Item{h, false})
	for len(stack) > 0 {
		it := pop(&stack)
		n := dom.get(d, it.h)
		if n == nil { continue }
		if it.close { fmt.sbprintf(sb, "</%s>", n.name); continue }
		switch n.kind {
		case .Element:
			fmt.sbprintf(sb, "<%s", n.name)
			for a in n.attrs { fmt.sbprintf(sb, " %s=%q", a.name, a.value) }
			strings.write_string(sb, ">")
			append(&stack, Item{it.h, true})
		case .Text: strings.write_string(sb, n.text)
		case .Comment: fmt.sbprintf(sb, "<!--%s-->", n.text)
		case .Document:
		}
		for ch := n.last_child; ch != base.NIL_HANDLE; ch = dom.get(d, ch).prev { append(&stack, Item{ch, false}) }
	}
}

@(private = "file")
parse :: proc(d: ^dom.Document, s: string) -> (string, Parse_Result) {
	r := parse_into(d, d.root, transmute([]byte)s)
	sb := strings.builder_make(context.temp_allocator)
	dump(d, d.root, &sb)
	return strings.to_string(sb), r
}

@(test)
html5_error_recovery_builds_html_head_body :: proc(t: ^testing.T) {
	d := dom.document_create()
	defer dom.document_destroy(d)
	out, r := parse(d, "<title>T</title><p>one<p>two")   // unclosed paragraphs, no html/head/body
	testing.expect(t, r.ok)
	testing.expect_value(t, out, "<html><head><title>T</title></head><body><p>one</p><p>two</p></body></html>")
	testing.expect_value(t, title(d), "T")
}

@(test)
attributes_entities_and_comments :: proc(t: ^testing.T) {
	d := dom.document_create()
	defer dom.document_destroy(d)
	out, r := parse(d, `<!doctype html><div ID=a class="x y" data-k='v&amp;w'>&lt;hi&gt; &copy;<!-- c --></div>`)
	testing.expect(t, r.ok)
	testing.expect_value(t, out, `<html><head></head><body><div id="a" class="x y" data-k="v&w"><hi> ©<!-- c --></div></body></html>`)   // entities are decoded; the dump does not re-escape
	testing.expect_value(t, dom.find_by_id(d, "a") != base.NIL_HANDLE, true)
}

@(test)
script_and_wasm_script_discovery :: proc(t: ^testing.T) {
	d := dom.document_create()
	defer dom.document_destroy(d)
	_, r := parse(d, `<head><script type="application/wasm" src="app.wasm"></script><script>x<y</script></head><body><script type="Application/WASM" src="b.wasm">`)
	testing.expect(t, r.ok)
	found := wasm_scripts(d)
	testing.expect_value(t, len(found), 2)
	src, _ := dom.get_attribute(d, found[0], "src")
	testing.expect_value(t, src, "app.wasm")
	src, _ = dom.get_attribute(d, found[1], "src")
	testing.expect_value(t, src, "b.wasm")
}

@(test)
very_deep_nesting_is_safe :: proc(t: ^testing.T) {
	d := dom.document_create()
	defer dom.document_destroy(d)
	sb := strings.builder_make()
	defer strings.builder_destroy(&sb)
	for _ in 0 ..< 50_000 { strings.write_string(&sb, "<b>") }
	strings.write_string(&sb, "deep")
	_, r := parse(d, strings.to_string(sb))
	testing.expect(t, r.ok)
	testing.expect(t, d.nodes.count > 1000)
}

@(test)
garbage_does_not_crash :: proc(t: ^testing.T) {
	d := dom.document_create()
	defer dom.document_destroy(d)
	_, r := parse(d, "\x00\xff<<<>>><a b='<c d=\">&#xD800;&#99999999;<svg><p></svg></table><td>")
	testing.expect(t, r.ok)
}
