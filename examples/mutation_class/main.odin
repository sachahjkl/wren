// Page script of examples/site/mutation_class.html (and of the `mutation_class` scenario of tools\perf.ps1): builds the
// same large document as examples/mutation (323 sections of articles, about 17 000 nodes), then toggles a class on the
// section in the middle every 16 ms. The page's rules reach from that class to the section's descendants (`.on p`),
// its children (`.on > article`) and its next sibling (`.on + .sec`): what the browser should restyle is that section's
// subtree and one more section, not the page.
package mutation_class

import "web:web"

SECTIONS :: 323
WORDS :: [?]string{"lorem", "ipsum", "dolor", "sit", "amet", "consectetur", "adipiscing", "elit", "sed", "do", "eiusmod", "tempor"}

target: web.Handle
on: bool
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

el :: proc "contextless" (parent: web.Handle, tag, class: string) -> web.Handle {
	e := web.create_element(tag)
	if class != "" { web.set_attribute(e, "class", class) }
	web.Node_appendChild(parent, e)
	return e
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
	on = !on
	web.set_attribute(target, "class", on ? "sec on" : "sec")
}

@(export)
wb_main :: proc "contextless" () {
	root := web.get_element_by_id("root")
	if root == web.NIL { web.error("#root not found"); return }
	buf: [128]u8
	num: [24]u8
	for s in 0 ..< SECTIONS {
		sec := el(root, "section", "sec")
		if s == SECTIONS / 2 { target = sec }
		for a in 0 ..< 5 {
			art := el(sec, "article", "")
			h := el(art, "h3", "")
			title: [32]u8
			t := itoa(i64(s * 5 + a), num[:])
			copy(title[:], "Title ")
			copy(title[6:], t)
			web.Node_appendChild(h, web.create_text(string(title[:6 + len(t)])))
			p := el(art, "p", "")
			for _ in 0 ..< 3 {
				sp := el(p, "span", "")
				web.Node_appendChild(sp, web.create_text(sentence(buf[:])))
			}
		}
	}
	web.set_attribute(target, "id", "target")
	web.Timers_setInterval(on_tick, 0, 16)
	web.log("mutation_class page ready")
}
