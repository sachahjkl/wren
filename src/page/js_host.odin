package page

// The browser side of the engine's own imports (api/js.widl, module js): console levels, uncaught exceptions,
// compiled code for the bytecode cache, the time zone, and the pins that tie DOM nodes to their JavaScript wrappers.

import "core:fmt"
import "core:strings"
import "wb:base"
import "wb:dom"
import "wb:js"

Engine_console :: proc(c: ^Call, level: Api_ConsoleLevel, text: string) {
	switch level {
	case .Warn: log(c.page, .Warn, text)
	case .Error: log(c.page, .Error, text)
	case .Log, .Info, .Debug: log(c.page, .Log, text)
	}
}

Engine_reportException :: proc(c: ^Call, message: string, stack: string, source: string, line: i32, column: i32) {
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, "Uncaught ")
	strings.write_string(&b, message)
	if stack != "" {
		strings.write_byte(&b, '\n')
		strings.write_string(&b, strings.trim_right_space(stack))
	} else if source != "" {
		fmt.sbprintf(&b, "\n    at %s:%d:%d", source, line, column)
	}
	if c.page.worker != nil { worker_report_error(c.page, strings.to_string(b)); return }
	log(c.page, .Error, strings.to_string(b))
}

Engine_storeBytecode :: proc(c: ^Call, code: []u8) {
	r := c.page.js
	if r == nil || !r.has_pending_key { return }
	js.store(r.pending_key, code)
	r.has_pending_key = false
}

Engine_timezoneOffset :: proc(c: ^Call, time_ms: f64) -> i32 { return js.timezone_offset(time_ms) }

Node_interface :: proc(c: ^Call, node: Api_Node) -> u32 { return js_node_interface(c.page, node.data) }

Node_pin :: proc(c: ^Call, node: Api_Node) { dom.pin(c.page.doc, H(node.handle)) }

Node_unpin :: proc(c: ^Call, node: u64) {
	d := call_doc(c)
	if d == nil { return }
	dom.unpin(d, H(node))
}

Node_treeRoots :: proc(c: ^Call, nodes: []u64, roots: []u8) {
	d := call_doc(c)
	n := min(len(nodes), len(roots) / 8)
	out := ([^]u64le)(raw_data(roots))
	// each walk stops at the first ancestor whose root is known already: linear in the size of the trees
	known := make(map[base.Handle]u64, 64, context.temp_allocator)
	path := make([dynamic]base.Handle, context.temp_allocator)
	for i in 0 ..< n {
		root: u64
		if d != nil {
			clear(&path)
			cur := H(nodes[i])
			found := false
			for {
				if r, ok := known[cur]; ok { root = r; found = true; break }
				node := dom.get(d, cur)
				if node == nil { break }
				append(&path, cur)
				if node.parent == base.NIL_HANDLE {
					root = cur == d.root ? 1 : u64(cur)
					found = true
					break
				}
				cur = node.parent
			}
			if !found { root = 0 }
			for h in path { known[h] = root }
		}
		out[i] = u64le(root)
	}
}
