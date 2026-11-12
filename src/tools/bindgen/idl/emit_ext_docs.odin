package idl

import "core:fmt"
import "core:strings"

// The reference of the extension namespaces (docs/api/ext): an index, then one page per namespace with its gate, its
// types, constants, methods and events, and the support status of each member.

@(private)
ext_doc_type :: proc(t: Ext_Type) -> string {
	name := t.name
	if t.item != nil { name = fmt.tprintf("[%s](%s.md#%s)", t.name, t.item.ns.name, strings.to_lower(t.name, context.temp_allocator)) }
	return t.seq ? fmt.tprintf("%s[]", name) : name
}

@(private)
ext_doc_gate :: proc(permission: string, contexts: Ext_Contexts, action: bool) -> string {
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, permission != "" ? fmt.tprintf("permission `%s`", permission) : "no permission")
	strings.write_string(&b, "; contexts: ")
	first := true
	for k in Ext_Context_Kind {
		if k not_in contexts { continue }
		if !first { strings.write_string(&b, ", ") }
		first = false
		strings.write_string(&b, EXT_CONTEXT_NAMES[k])
	}
	if action { strings.write_string(&b, "; the manifest has an `action`") }
	return strings.to_string(b)
}

@(private)
ext_doc_params :: proc(params: []Ext_Param) -> string {
	b := strings.builder_make(context.temp_allocator)
	for p, i in params {
		if i > 0 { strings.write_string(&b, ", ") }
		if p.optional { strings.write_string(&b, "optional ") }
		strings.write_string(&b, p.type.seq ? fmt.tprintf("%s[]", p.type.name) : p.type.name)
		strings.write_byte(&b, ' ')
		strings.write_string(&b, p.name)
	}
	return strings.to_string(b)
}

@(private)
ext_doc_bounds :: proc(p: Ext_Param) -> string {
	lo, has_lo := p.min.?
	hi, has_hi := p.max.?
	switch {
	case has_lo && has_hi: return fmt.tprintf(" (%d to %d)", lo, hi)
	case has_lo:           return fmt.tprintf(" (at least %d)", lo)
	case has_hi:           return fmt.tprintf(" (at most %d)", hi)
	}
	return ""
}

@(private)
ext_doc_one_line :: proc(doc: string) -> string {
	s, _ := strings.replace_all(doc, "\n", " ", context.temp_allocator)
	return s
}

emit_ext_docs :: proc(api: ^Api) -> []Doc_File {
	files := make([dynamic]Doc_File)
	idx := out_make()
	wl(&idx, "<!-- %s -->", GENERATED_BY)
	wl(&idx, "")
	wl(&idx, "# Extension APIs of Wren")
	wl(&idx, "")
	wl(&idx, "The `chrome.*` namespaces an extension context gets, generated from `api/ext_*.widl` (docs/extensions.md, section 3.9).")
	wl(&idx, "The same description produces the host's method table and argument decoders (`src/page/ext_api_generated.odin`),")
	wl(&idx, "the constants of `chrome.*` and the conformance cases (`src/page/ext_api_generated_test.odin`).")
	wl(&idx, "")
	wl(&idx, "* A namespace or a member exists in a context only when the manifest has its permission, the kind of context is")
	wl(&idx, "  listed, and the manifest has an `action` when it needs one. A call outside these rules fails in the host too.")
	wl(&idx, "* A method returns a promise. With a function as its last argument, it calls it with the result instead, and sets")
	wl(&idx, "  `chrome.runtime.lastError` during that call when it failed. `browser.*` (Firefox flavour) has promises only.")
	wl(&idx, "* Arguments are matched to the signature as in Chrome: an optional parameter is left out when the argument in its")
	wl(&idx, "  place does not have its type. A wrong type, a missing property or a value out of bounds is an error that names")
	wl(&idx, "  the parameter and the property.")
	wl(&idx, "* Status `host`: the browser answers. Status `realm`: the context answers itself, without the browser's loop.")
	wl(&idx, "")
	wl(&idx, "| Namespace | Gate | Methods | Events |")
	wl(&idx, "|---|---|---|---|")
	for ns in api.namespaces {
		methods, events := 0, 0
		for it in ns.items {
			#partial switch it.kind {
			case .Method: methods += 1
			case .Event:  events += 1
			}
		}
		wl(&idx, "| [%s](%s.md) | %s | %d | %d |", ns.name, ns.name, ext_doc_gate(ns.permission, ns.contexts, ns.action), methods, events)
	}
	append(&files, Doc_File{name = "README.md", text = out_text(&idx)})

	for ns in api.namespaces {
		o := out_make()
		wl(&o, "<!-- %s -->", GENERATED_BY)
		wl(&o, "")
		wl(&o, "# chrome.%s", ns.name)
		wl(&o, "")
		if ns.doc != "" { wl(&o, "%s", ext_doc_one_line(ns.doc)); wl(&o, "") }
		wl(&o, "Gate: %s. Source: `%s`.", ext_doc_gate(ns.permission, ns.contexts, ns.action), ns.file)
		wl(&o, "")
		section :: proc(o: ^Out, ns: ^Ext_Namespace, kind: Ext_Item_Kind, title: string) -> bool {
			for it in ns.items {
				if it.kind == kind || (kind == .Method && it.kind == .Property) {
					wl(o, "## %s", title)
					wl(o, "")
					return true
				}
			}
			return false
		}
		if section(&o, ns, .Method, "Methods and properties") {
			wl(&o, "| Member | Result | Status | Gate | |")
			wl(&o, "|---|---|---|---|---|")
			for it in ns.items {
				if it.kind != .Method && it.kind != .Property { continue }
				name := it.kind == .Method ? fmt.tprintf("`%s(%s)`", it.name, ext_doc_params(it.params)) : fmt.tprintf("`%s`", it.name)
				gate := ""
				if it.permission != ns.permission || it.contexts != ns.contexts || it.action != ns.action { gate = ext_doc_gate(it.permission, it.contexts, it.action) }
				wl(&o, "| %s | %s | %s | %s | %s |", name, ext_doc_type(it.result), it.local ? "realm" : "host", gate, ext_doc_one_line(it.doc))
			}
			wl(&o, "")
			for it in ns.items {
				if it.kind != .Method { continue }
				documented := false
				for p in it.params { if p.doc != "" || ext_doc_bounds(p) != "" { documented = true } }
				if !documented { continue }
				wl(&o, "`%s`:", it.name)
				wl(&o, "")
				for p in it.params { wl(&o, "* `%s`: %s%s %s", p.name, ext_doc_type(p.type), ext_doc_bounds(p), ext_doc_one_line(p.doc)) }
				wl(&o, "")
			}
		}
		if section(&o, ns, .Event, "Events") {
			wl(&o, "| Event | Listener's parameters | Gate | |")
			wl(&o, "|---|---|---|---|")
			for it in ns.items {
				if it.kind != .Event { continue }
				gate := ""
				if it.permission != ns.permission || it.contexts != ns.contexts || it.action != ns.action { gate = ext_doc_gate(it.permission, it.contexts, it.action) }
				wl(&o, "| `%s` | `%s` | %s | %s |", it.name, ext_doc_params(it.params), gate, ext_doc_one_line(it.doc))
			}
			wl(&o, "")
		}
		if section(&o, ns, .Const, "Constants") {
			for it in ns.items {
				if it.kind != .Const { continue }
				wl(&o, "* `%s` = `%s` %s", it.name, it.literal, ext_doc_one_line(it.doc))
			}
			wl(&o, "")
		}
		has_types := false
		for it in ns.items { if it.kind == .Enum || it.kind == .Struct || it.kind == .Union { has_types = true } }
		if has_types {
			wl(&o, "## Types")
			wl(&o, "")
			for it in ns.items {
				#partial switch it.kind {
				case .Enum:
					wl(&o, "### %s", it.name)
					wl(&o, "")
					if it.doc != "" { wl(&o, "%s", ext_doc_one_line(it.doc)); wl(&o, "") }
					b := strings.builder_make(context.temp_allocator)
					for v, i in it.values {
						if i > 0 { strings.write_string(&b, ", ") }
						fmt.sbprintf(&b, "`\"%s\"`", v)
					}
					wl(&o, "A string: %s. `chrome.%s.%s` names them.", strings.to_string(b), ns.name, it.name)
					wl(&o, "")
				case .Union:
					wl(&o, "### %s", it.name)
					wl(&o, "")
					if it.doc != "" { wl(&o, "%s", ext_doc_one_line(it.doc)); wl(&o, "") }
					b := strings.builder_make(context.temp_allocator)
					for m, i in it.members {
						if i > 0 { strings.write_string(&b, " or ") }
						strings.write_string(&b, ext_doc_type(m))
					}
					wl(&o, "One of: %s.", strings.to_string(b))
					wl(&o, "")
				case .Struct:
					wl(&o, "### %s", it.name)
					wl(&o, "")
					if it.doc != "" { wl(&o, "%s", ext_doc_one_line(it.doc)); wl(&o, "") }
					wl(&o, "| Property | Type | |")
					wl(&o, "|---|---|---|")
					for f in it.fields {
						wl(&o, "| `%s`%s | %s%s | %s |", f.name, f.optional ? " (optional)" : "", ext_doc_type(f.type), ext_doc_bounds(f), ext_doc_one_line(f.doc))
					}
					wl(&o, "")
				}
			}
		}
		append(&files, Doc_File{name = fmt.aprintf("%s.md", ns.name), text = out_text(&o)})
	}
	return files[:]
}
