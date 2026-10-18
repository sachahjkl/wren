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
	r := parse_into(d, d.root, transmute([]byte)s, 2_000_000)
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
	found := wasm_scripts(d, "application/wasm")
	testing.expect_value(t, len(found), 2)
	src, _ := dom.get_attribute(d, found[0], "src")
	testing.expect_value(t, src, "app.wasm")
	src, _ = dom.get_attribute(d, found[1], "src")
	testing.expect_value(t, src, "b.wasm")
}

@(test)
charset_sniffing_and_decoding :: proc(t: ^testing.T) {
	check :: proc(t: ^testing.T, data: []byte, header: string, want_text: string, want_enc: string, want_src: Encoding_Source, loc := #caller_location) {
		d, ok := decode_document(data, header, "windows-1252", context.temp_allocator)
		testing.expect(t, ok, "decode", loc = loc)
		testing.expect_value(t, string(d.text), want_text, loc = loc)
		testing.expect_value(t, d.encoding, want_enc, loc = loc)
		testing.expect_value(t, d.source, want_src, loc = loc)
	}
	check(t, {0xEF, 0xBB, 0xBF, 'h', 0xC3, 0xA9}, "iso-8859-1", "hé", "UTF-8", .Bom)              // the BOM beats the header
	check(t, {0xFF, 0xFE, 'h', 0, 0xE9, 0}, "", "hé", "UTF-16LE", .Bom)
	check(t, {0xFE, 0xFF, 0, 'h', 0, 0xE9}, "", "hé", "UTF-16BE", .Bom)
	check(t, {'c', 'a', 'f', 0xE9}, "latin1", "café", "windows-1252", .Header)                      // label alias, Latin-1 decoded
	check(t, {'c', 'a', 'f', 0xE9}, "ISO-8859-2", "café", "ISO-8859-2", .Header)
	check(t, {0x82, 0xA0}, "shift_jis", "あ", "Shift_JIS", .Header)
	check(t, transmute([]byte)string(`<meta charset="windows-1251"><p>`), "", "<meta charset=\"windows-1251\"><p>", "windows-1251", .Meta)
	check(t, {'a', 0xE9}, "not-an-encoding", "aé", "windows-1252", .Default)                          // unknown label: sniff, then default
	check(t, {'a', 0xFF, 'b'}, "utf-8", "a\uFFFDb", "UTF-8", .Header)                                 // invalid UTF-8 becomes U+FFFD
	check(t, {}, "", "", "windows-1252", .Default)

	// a transcoded document parses like any other
	d, _ := decode_document({'<', 'p', '>', 'c', 'a', 'f', 0xE9}, "windows-1252", "windows-1252", context.temp_allocator)
	doc := dom.document_create()
	defer dom.document_destroy(doc)
	parse_into(doc, doc.root, d.text, 2_000_000)
	testing.expect_value(t, dom.text_content(doc, dom.find_first_by_tag(doc, "p")), "café")
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
