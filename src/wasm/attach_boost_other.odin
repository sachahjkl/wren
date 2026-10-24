#+build !windows
package wasm

import "core:thread"

@(private)
boost_for_join :: proc(t: ^thread.Thread) {}
