package dom

import "wb:base"

// Change counters finer than tree_version and attr_version, kept only for what someone watches: the children of one
// parent (a live childNodes or children list), the attributes of one name (a live getElementsByClassName list). A
// document-wide counter made such a list walk its subtree again after any mutation anywhere: a loop that changes the
// document and reads a list was quadratic.

Version_Watch :: struct {
	watchers: u32,
	version:  u64,
}

// `parent`'s children are watched (one more watcher): child_version moves on each insertion or removal among them.
child_watch :: proc(d: ^Document, parent: base.Handle) {
	w := d.child_versions[parent]
	w.watchers += 1
	d.child_versions[parent] = w
}

child_unwatch :: proc(d: ^Document, parent: base.Handle) {
	w, ok := &d.child_versions[parent]
	if !ok { return }
	w.watchers -= 1
	if w.watchers == 0 { delete_key(&d.child_versions, parent) }
}

// The counter of `parent`'s children (0 when nobody watches them).
child_version :: proc(d: ^Document, parent: base.Handle) -> u64 { return d.child_versions[parent].version }

@(private)
child_changed :: #force_inline proc(d: ^Document, parent: base.Handle) {
	if len(d.child_versions) == 0 { return }
	if w, ok := &d.child_versions[parent]; ok { w.version += 1 }
}

// Attributes named `name` are watched: attr_name_version moves on each change of one (any element, any namespace:
// its local name). `name` is kept as the key: a string of the program (a literal), never one that is freed.
attr_watch :: proc(d: ^Document, name: string) {
	w := d.attr_versions[name]
	w.watchers += 1
	d.attr_versions[name] = w
}

attr_unwatch :: proc(d: ^Document, name: string) {
	w, ok := &d.attr_versions[name]
	if !ok { return }
	w.watchers -= 1
	if w.watchers == 0 { delete_key(&d.attr_versions, name) }
}

// The counter of the attributes named `name` (0 when nobody watches them).
attr_name_version :: proc(d: ^Document, name: string) -> u64 { return d.attr_versions[name].version }

@(private)
attr_name_changed :: #force_inline proc(d: ^Document, name: string) {
	if len(d.attr_versions) == 0 { return }
	if w, ok := &d.attr_versions[name]; ok { w.version += 1 }
}

@(private)
versions_free :: proc(d: ^Document) {
	delete(d.child_versions)
	delete(d.attr_versions)
}
