// apidoc: the only tool that remains once the boundary is comptime. It reads the shared declarations (package
// api_decl) with core:odin/parser + core:odin/ast and emits one Markdown page per module (docs/api/<module>.md), the
// same documentation bindgen produced from the .widl files. The conformance report is produced the same way (the
// list of declared functions, their arguments and whether they raise); this prototype emits the docs and the
// function inventory, which is what the design note points at.
//
//   odin run native/js/odin_abi/apidoc -collection:wb=src -out:build/apidoc.exe -- native/js/odin_abi/api_decl docs/api
package apidoc

import "core:fmt"
import "core:odin/ast"
import "core:odin/parser"
import "core:os"
import "core:path/filepath"
import "core:strings"

Item :: struct {
	name: string,
	doc:  string,
	sig:  string,   // the declaration's source text (type or proc signature)
	kind: string,   // "handle", "enum", "dict", "proc"
}

main :: proc() {
	in_dir := len(os.args) > 1 ? os.args[1] : "native/js/odin_abi/api_decl"
	out_dir := len(os.args) > 2 ? os.args[2] : "build/apidoc"

	infos, derr := os.read_all_directory_by_path(in_dir, context.allocator)
	if derr != nil { fmt.eprintfln("apidoc: cannot read %s", in_dir); os.exit(1) }
	_ = os.make_directory_all(out_dir)

	total := 0
	for fi in infos {
		if !strings.has_suffix(fi.name, ".odin") { continue }
		data, rok := os.read_entire_file_from_path(fi.fullpath, context.allocator)
		if rok != nil { continue }
		items := extract(string(data), fi.fullpath)
		if len(items) == 0 { continue }
		module := strings.trim_suffix(fi.name, ".odin")
		md := render(module, items)
		path := filepath.join({out_dir, fmt.tprintf("%s.md", module)}) or_else ""
		if os.write_entire_file(path, transmute([]u8)md) == nil {
			fmt.printfln("apidoc: wrote %s (%d items)", path, len(items))
			total += len(items)
		}
	}
	fmt.printfln("apidoc: %d declarations documented", total)
}

extract :: proc(src, path: string) -> []Item {
	out := make([dynamic]Item)
	p := parser.default_parser()
	file := ast.File{src = src, fullpath = path}
	if !parser.parse_file(&p, &file) { fmt.eprintfln("apidoc: parse errors in %s", path) }

	for decl in file.decls {
		vd, ok := decl.derived_stmt.(^ast.Value_Decl)
		if !ok || len(vd.names) == 0 || vd.type != nil || len(vd.values) == 0 { continue }
		name_node := vd.names[0]
		id, idok := name_node.derived_expr.(^ast.Ident)
		if !idok { continue }
		value := vd.values[0]

		// The declaration's source text, from the name to the end of the value expression.
		sig := strings.trim_space(src[name_node.pos.offset:value.end.offset])
		doc := comment_text(vd.docs)

		kind := classify(value)
		if kind == "" { continue }
		append(&out, Item{name = id.name, doc = doc, sig = sig, kind = kind})
	}
	return out[:]
}

classify :: proc(value: ^ast.Expr) -> string {
	#partial switch v in value.derived_expr {
	case ^ast.Distinct_Type:
		return "handle"
	case ^ast.Enum_Type:
		return "enum"
	case ^ast.Struct_Type:
		return "dict"
	case ^ast.Proc_Type:
		return "proc"
	case ^ast.Helper_Type:
		// `#type proc(...)`: a proc signature wrapped in #type
		return classify(v.type)
	}
	return ""
}

comment_text :: proc(g: ^ast.Comment_Group) -> string {
	if g == nil { return "" }
	b := strings.builder_make()
	for tok, i in g.list {
		line := tok.text
		line = strings.trim_prefix(line, "//")
		line = strings.trim_space(line)
		if i > 0 { strings.write_byte(&b, ' ') }
		strings.write_string(&b, line)
	}
	return strings.to_string(b)
}

render :: proc(module: string, items: []Item) -> string {
	b := strings.builder_make()
	fmt.sbprintfln(&b, "# Module `%s`", module)
	fmt.sbprintln(&b, "")
	fmt.sbprintln(&b, "Generated from the shared declarations (`package api_decl`) by `apidoc` (core:odin/parser).")
	fmt.sbprintln(&b, "")

	section :: proc(b: ^strings.Builder, items: []Item, kind, title: string) {
		first := true
		for it in items {
			if it.kind != kind { continue }
			if first { fmt.sbprintfln(b, "## %s", title); fmt.sbprintln(b, ""); first = false }
			if it.doc != "" { fmt.sbprintfln(b, "%s", it.doc) }
			fmt.sbprintfln(b, "```odin\n%s\n```", it.sig)
			fmt.sbprintln(b, "")
		}
	}
	section(&b, items, "handle", "Handles")
	section(&b, items, "enum", "Enumerations")
	section(&b, items, "dict", "Dictionaries")
	section(&b, items, "proc", "Functions")
	return strings.to_string(b)
}
