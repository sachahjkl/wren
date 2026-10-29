package style

import "base:runtime"
import "core:strings"

// Custom properties as layers (types.odin, Custom_Props): an element that declares custom properties gets a layer of
// its own names over its parent's set instead of a copy of every inherited name. Sites define hundreds of variables on
// :root and set a few more on many elements: copies made the computed styles of such a page hundreds of megabytes.
// Lookups walk the layers; a layer is flattened into a map of its own when the chain under it would be longer than
// style.custom_properties.max_layers, so a lookup costs at most that many map probes.

// The value of custom property `name`, if the set has it.
custom_get :: proc(p: ^Custom_Props, name: string) -> (string, bool) {
	for l := p; l != nil; l = l.parent {
		if v, ok := l.values[name]; ok { return v, true }
		for r in l.removed { if r == name { return "", false } }
	}
	return "", false
}

// Whether the set has `name`.
custom_has :: proc(p: ^Custom_Props, name: string) -> bool {
	_, ok := custom_get(p, name)
	return ok
}

// Every name of the set with its value, in a new map.
custom_flatten :: proc(p: ^Custom_Props, allocator: runtime.Allocator) -> map[string]string {
	out := make(map[string]string, max(p != nil ? p.total : 0, 1), allocator)
	custom_flatten_into(p, &out)
	return out
}

@(private)
custom_flatten_into :: proc(p: ^Custom_Props, out: ^map[string]string) {
	if p == nil { return }
	custom_flatten_into(p.parent, out)
	for r in p.removed { delete_key(out, r) }
	for k, v in p.values { out[k] = v }
}

// A new layer over `parent` (nil: an empty set) in `a`, filled by custom_set / custom_remove and closed by
// custom_close. `max_layers`: past that many layers below, the new set is a flat copy instead.
custom_begin :: proc(parent: ^Custom_Props, max_layers: int, a: runtime.Allocator) -> ^Custom_Props {
	p := new(Custom_Props, a)
	if parent != nil && parent.depth + 1 > max_layers {
		p.values = custom_flatten(parent, a)
		p.total = len(p.values)
		return p
	}
	p.values = make(map[string]string, a)
	p.parent = parent
	p.total = parent != nil ? parent.total : 0
	p.depth = parent != nil ? parent.depth + 1 : 0
	return p
}

// Sets `name` in the layer being built. The strings are copied into the layer's own memory: the names and values come
// from the rules (a rebuild of the rule index frees them), while the previous styles of a page stay alive until the next
// pass has been compared with them (transitions: timeline_restyled).
custom_set :: proc(p: ^Custom_Props, name, value: string) {
	a := p.values.allocator
	if _, own := p.values[name]; !own {
		if i := removed_index(p, name); i >= 0 {
			unordered_remove_string(&p.removed, i)
			p.total += 1
		} else if p.parent == nil || !custom_has(p.parent, name) {
			p.total += 1
		}
		p.values[strings.clone(name, a)] = strings.clone(value, a)
		return
	}
	p.values[name] = strings.clone(value, a)
}

// Drops `name` from the layer being built (and from what it inherits).
custom_remove :: proc(p: ^Custom_Props, name: string, a: runtime.Allocator) {
	if _, own := p.values[name]; own {
		delete_key(&p.values, name)
		p.total -= 1
		if p.parent != nil && custom_has(p.parent, name) { p.total += 1 } else { return }
	}
	if p.parent == nil || removed_index(p, name) >= 0 || !custom_has(p.parent, name) { return }
	grown := make([]string, len(p.removed) + 1, a)
	copy(grown, p.removed)
	grown[len(p.removed)] = strings.clone(name, a)
	p.removed = grown
	p.total -= 1
}

@(private)
removed_index :: proc(p: ^Custom_Props, name: string) -> int {
	for r, i in p.removed { if r == name { return i } }
	return -1
}

@(private)
unordered_remove_string :: proc(s: ^[]string, i: int) {
	s[i] = s[len(s) - 1]
	s^ = s[:len(s) - 1]
}

// Value equality of two sets (whatever their layering).
custom_equal :: proc(a, b: ^Custom_Props) -> bool {
	if a == b { return true }
	if a == nil || b == nil { return false }
	if a.total != b.total { return false }
	// the usual case of a restyle: the same layering, layer by layer
	if a.parent == b.parent || (a.parent != nil && b.parent != nil && a.depth == b.depth) {
		if len(a.values) == len(b.values) && len(a.removed) == len(b.removed) && layer_equal(a, b) {
			if a.parent == b.parent || custom_equal(a.parent, b.parent) { return true }
		}
	}
	// otherwise every name of one set looked up in the other (the totals are equal)
	fa := custom_flatten(a, context.temp_allocator)
	for k, v in fa { if w, ok := custom_get(b, k); !ok || w != v { return false } }
	return true
}

@(private)
layer_equal :: proc(a, b: ^Custom_Props) -> bool {
	for k, v in a.values { if w, ok := b.values[k]; !ok || w != v { return false } }
	for r in a.removed { if removed_index(b, r) < 0 { return false } }
	return true
}
