package style

import "base:runtime"
import "core:mem/virtual"
import "core:strings"
import "wb:css"

// What a style sheet uses that this engine drops: rules whose selectors do not parse, unknown properties, values a
// property rejects, @supports conditions that are false. For the console, for about: diagnostics and for the
// web-compatibility tooling (src/tools/cssaudit). Values with var() are only known per element and are not checked.

Audit_Kind :: enum u8 { Parse, Unknown_Property, Invalid_Value, Supports_False }

Audit_Entry :: struct {
	kind: Audit_Kind,
	text: string,     // allocated with the caller's allocator
}

// Appends what `sheet` uses and the engine does not take. Every rule is visited, whatever its conditions.
audit_sheet :: proc(e: ^Engine, sheet: ^css.Stylesheet, out: ^[dynamic]Audit_Entry, allocator := context.allocator) {
	for msg in sheet.errors { append(out, Audit_Entry{.Parse, strings.clone(msg, allocator)}) }
	arena: virtual.Arena
	_ = virtual.arena_init_growing(&arena)
	defer virtual.arena_destroy(&arena)
	a := virtual.arena_allocator(&arena)
	cx := probe_context(e, a)
	// var(): approximated by the last value each custom property gets anywhere in the sheet
	customs := new(Custom_Props, a)
	customs.values = make(map[string]string, a)
	collect :: proc(rules: []^css.Rule, m: ^map[string]string, a: runtime.Allocator) {
		for r in rules {
			for d in r.declarations {
				if r.kind != .Style || !strings.has_prefix(d.name, "--") { continue }
				if css_wide_keyword(d.value) != "" { delete_key(m, d.name); continue }   // guaranteed-invalid, mostly
				m[d.name] = css.serialize_values(d.value, a)
			}
			collect(r.nested, m, a)
			collect(r.rules, m, a)
		}
	}
	collect(sheet.rules, &customs.values, a)
	audit_vars = Var_Env{engine = e, alloc = a, final = customs}
	defer audit_vars = {}
	for r in sheet.rules { audit_rule(e, &cx, r, out, allocator) }
}

@(private, thread_local)
audit_vars: Var_Env

@(private)
value_ptr :: proc(vs: []css.Value) -> rawptr { return raw_data(vs) }

@(private)
audit_rule :: proc(e: ^Engine, cx: ^Cx, r: ^css.Rule, out: ^[dynamic]Audit_Entry, allocator := context.allocator) {
	switch r.kind {
	case .Style:
		audit_declarations(e, cx, r.declarations, out, allocator)
		for n in r.nested { audit_rule(e, cx, n, out, allocator) }
	case .Media, .Container, .Layer_Block:
		for n in r.rules { audit_rule(e, cx, n, out, allocator) }
	case .Supports:
		if !supports_condition(e, r.supports) {
			append(out, Audit_Entry{.Supports_False, strings.concatenate({"@supports ", css.serialize_values(r.supports, context.temp_allocator)}, allocator)})
		}
		for n in r.rules { audit_rule(e, cx, n, out, allocator) }
	case .Keyframes:
		for k in r.keyframes { audit_declarations(e, cx, k.declarations, out, allocator) }
	case .Import:
		if len(r.supports) > 0 && !supports_condition(e, r.supports) {
			append(out, Audit_Entry{.Supports_False, strings.concatenate({"@import supports(", css.serialize_values(r.supports, context.temp_allocator), ")"}, allocator)})
		}
	case .Font_Face, .Layer_Statement, .Namespace, .Page, .Property, .Unknown:
	}
}

@(private)
audit_declarations :: proc(e: ^Engine, cx: ^Cx, decls: []css.Declaration, out: ^[dynamic]Audit_Entry, allocator := context.allocator) {
	for d in decls {
		if strings.has_prefix(d.name, "--") { continue }
		p, sh, known := lookup_property(d.name)
		if !known {
			append(out, Audit_Entry{.Unknown_Property, strings.clone(d.name, allocator)})
			continue
		}
		value := d.value
		if contains_var(value) {
			audit_vars.budget = e.settings.max_var_bytes
			sub, good := substitute(&audit_vars, value, 0)
			if !good { continue }   // depends on a property this sheet never sets: unknown here
			value = sub
		}
		if css_wide_keyword(value) != "" { continue }
		ok := true
		if sh == .None {
			ok = apply_prop(cx, p, value)
		} else if longs, good := expand_shorthand(sh, value, cx.alloc); !good {
			ok = false
		} else {
			for l in longs { if css_wide_keyword(l.vals) == "" && !apply_prop(cx, l.prop, l.vals) { ok = false; break } }
		}
		if !ok {
			text := css.serialize_values(d.value, context.temp_allocator)
			if value_ptr(value) != value_ptr(d.value) { text = strings.concatenate({text, "  =>  ", css.serialize_values(value, context.temp_allocator)}, context.temp_allocator) }
			append(out, Audit_Entry{.Invalid_Value, strings.concatenate({d.name, ": ", text}, allocator)})
		}
	}
}
