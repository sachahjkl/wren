// Page script of examples/site/mutation.html (and of the `mutation` scenario of tools\perf.ps1): builds a large
// document (323 sections of articles: 10 000 elements, about 17 000 nodes, like the generated p10k page), then changes the text of
// one element in the middle of it every 16 ms. What the browser should do each time is local: one paragraph laid out
// again, a few display items replaced.
package mutation

import "web:web"

SECTIONS :: 323
WORDS :: [?]string{"lorem", "ipsum", "dolor", "sit", "amet", "consectetur", "adipiscing", "elit", "sed", "do", "eiusmod", "tempor"}

target: web.Element
frames: i64
seed: u32 = 12345

rnd :: proc "contextless" () -> u32 {
	seed = seed * 1664525 + 1013904223
	return seed >> 8
}

itoa :: proc "contextless" (v: i64, buf: []u8) -> string {
	if v == 0 { buf[len(buf) - 1] = '0'; return string(buf[len(buf) - 1:]) }
	n := v
	i := len(buf)
	for n > 0 { i -= 1; buf[i] = u8('0' + n % 10); n /= 10 }
	return string(buf[i:])
}

el :: proc "contextless" (parent: web.Element, tag, class: string) -> web.Element {
	e, _ := web.Document_createElement(tag)
	if class != "" { web.Element_setAttribute(e, "class", class) }
	web.Node_appendChild(parent, e)
	return e
}

text :: proc "contextless" (s: string) -> web.Node {
	n, _ := web.Document_createTextNode(s)
	return n
}

sentence :: proc "contextless" (buf: []u8) -> string {
	words := WORDS
	n := 0
	for k in 0 ..< 8 {
		w := words[rnd() % len(words)]
		if k > 0 && n < len(buf) { buf[n] = ' '; n += 1 }
		for i in 0 ..< len(w) { if n < len(buf) { buf[n] = w[i]; n += 1 } }
	}
	if n < len(buf) { buf[n] = ' '; n += 1 }
	return string(buf[:n])
}

on_tick :: proc "contextless" (user: i32) {
	frames += 1
	b: [64]u8
	n := itoa(frames, b[32:])
	msg: [96]u8
	k := 0
	for c in transmute([]u8)string("frame ") { msg[k] = c; k += 1 }
	for i in 0 ..< len(n) { msg[k] = n[i]; k += 1 }
	for c in transmute([]u8)string(" updated by the module") { msg[k] = c; k += 1 }
	web.Node_setTextContent(target, string(msg[:k]))
}

@(export)
wb_main :: proc "contextless" () {
	root := web.Document_getElementById("root")
	if root == 0 { web.console_error("#root not found"); return }
	buf: [128]u8
	num: [24]u8
	for s in 0 ..< SECTIONS {
		sec := el(root, "section", "sec")
		for a in 0 ..< 5 {
			art := el(sec, "article", "")
			h := el(art, "h3", "")
			title: [32]u8
			t := itoa(i64(s * 5 + a), num[:])
			copy(title[:], "Title ")
			copy(title[6:], t)
			web.Node_appendChild(h, text(string(title[:6 + len(t)])))
			p := el(art, "p", "")
			for k in 0 ..< 3 {
				sp := el(p, "span", "")
				web.Node_appendChild(sp, text(sentence(buf[:])))
				if s == SECTIONS / 2 && a == 2 && k == 1 { target = sp }
			}
		}
	}
	web.Element_setAttribute(target, "id", "target")
	web.Timers_setInterval(on_tick, 0, 16)
	web.console_log("mutation page ready")
}
