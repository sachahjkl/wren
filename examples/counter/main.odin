// Page script for examples/site: wires the buttons of a parsed HTML document. The HTML names this module with
// <script type="application/wasm" src="counter.wasm">.
package counter

import "wren:console"
import "wren:core"
import "wren:dom"
import "wren:timers"

count: i64
count_node: dom.Element
ticks: i64
clock_node: dom.Element

itoa :: proc "contextless" (v: i64, buf: []u8) -> string {
	if v == 0 { buf[0] = '0'; return string(buf[:1]) }
	neg := v < 0
	n := neg ? -v : v
	i := len(buf)
	for n > 0 { i -= 1; buf[i] = u8('0' + n % 10); n /= 10 }
	if neg { i -= 1; buf[i] = '-' }
	return string(buf[i:])
}

show :: proc "contextless" () {
	b: [24]u8
	dom.Node_setTextContent(count_node, itoa(count, b[:]))
}

on_button :: proc "contextless" (user: i32, ev: core.Event) {
	if user == 0 { count = 0 } else { count += i64(user) }
	show()
	core.Event_preventDefault(ev)   // the buttons live inside links in the demo: do not navigate
}

on_tick :: proc "contextless" (user: i32) {
	ticks += 1
	b: [24]u8
	dom.Node_setTextContent(clock_node, itoa(ticks, b[:]))
}

@(export)
wb_main :: proc "contextless" () {
	count_node = dom.Document_getElementById("count")
	clock_node = dom.Document_getElementById("clock")
	if count_node == 0 {
		console.error("#count not found")
		return
	}
	core.EventTarget_addEventListener(dom.Document_getElementById("inc"), "click", on_button, 1)
	core.EventTarget_addEventListener(dom.Document_getElementById("dec"), "click", on_button, -1)
	core.EventTarget_addEventListener(dom.Document_getElementById("reset"), "click", on_button, 0)
	timers.setInterval(on_tick, 0, 1000)
	show()
	console.log("counter ready")
}
