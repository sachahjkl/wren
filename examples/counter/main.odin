// Page script for examples/site: wires the buttons of a parsed HTML document. The HTML names this module with
// <script type="application/wasm" src="counter.wasm">.
package counter

import "web:web"

count: i64
count_node: web.Element
ticks: i64
clock_node: web.Element

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
	web.Node_setTextContent(count_node, itoa(count, b[:]))
}

on_button :: proc "contextless" (user: i32, ev: web.Event) {
	if user == 0 { count = 0 } else { count += i64(user) }
	show()
	web.Event_preventDefault(ev)   // the buttons live inside links in the demo: do not navigate
}

on_tick :: proc "contextless" (user: i32) {
	ticks += 1
	b: [24]u8
	web.Node_setTextContent(clock_node, itoa(ticks, b[:]))
}

@(export)
wb_main :: proc "contextless" () {
	count_node = web.Document_getElementById("count")
	clock_node = web.Document_getElementById("clock")
	if count_node == 0 {
		web.console_error("#count not found")
		return
	}
	web.EventTarget_addEventListener(web.Document_getElementById("inc"), "click", on_button, 1)
	web.EventTarget_addEventListener(web.Document_getElementById("dec"), "click", on_button, -1)
	web.EventTarget_addEventListener(web.Document_getElementById("reset"), "click", on_button, 0)
	web.Timers_setInterval(on_tick, 0, 1000)
	show()
	web.console_log("counter ready")
}
