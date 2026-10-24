package config

import "core:strings"

// A copy of every preference with the layer that decides it, to put them back later: `wren ctl reset` and its checkpoints
// (src/browser/remote_state.odin) return a running browser to the preferences it started with, whatever was changed since
// by about:config, by `wren ctl pref set`, or over the command line's value with `--override`. Policy values are never touched.

Pref_State :: struct {
	name:      string,   // owned
	value:     Value,    // `s` owned
	source:    Source,
	user_text: string,   // owned: the user layer under a higher one
	has_user:  bool,
}

snapshot :: proc(p: ^Prefs, allocator := context.allocator) -> []Pref_State {
	out := make([]Pref_State, len(p.entries), allocator)
	for &e, i in p.entries {
		out[i] = Pref_State{
			name = strings.clone(e.def.name, allocator), value = e.value, source = e.source,
			user_text = strings.clone(e.user_text, allocator), has_user = e.has_user,
		}
		out[i].value.s = strings.clone(e.value.s, allocator)
	}
	return out
}

snapshot_destroy :: proc(s: []Pref_State, allocator := context.allocator) {
	for st in s { delete(st.name, allocator); delete(st.value.s, allocator); delete(st.user_text, allocator) }
	delete(s, allocator)
}

// Puts every preference back as `s` has it; returns how many were different. A preference that policy decides, or that the
// snapshot does not know (registered since), stays as it is.
restore :: proc(p: ^Prefs, s: []Pref_State) -> (changed: int) {
	for st in s {
		i, ok := p.index[st.name]
		if !ok { continue }
		e := &p.entries[i]
		if e.locked || e.source == .Policy { continue }
		same_value := e.value.b == st.value.b && e.value.i == st.value.i && e.value.f == st.value.f && e.value.s == st.value.s
		same_user := e.has_user == st.has_user && e.user_text == st.user_text
		if same_value && e.source == st.source && same_user { continue }
		changed += 1
		assign(p, i, st.value, st.source)
		if !same_user {
			delete(e.user_text, p.allocator)
			e.user_text, e.has_user = strings.clone(st.user_text, p.allocator), st.has_user
			p.dirty = true
		}
	}
	return
}
