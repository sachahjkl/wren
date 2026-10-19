package browser

import "core:testing"

// The left part of the status bar in a narrow window (status_left_fit): short forms first, then items left out by
// priority, the page state kept, and nothing wider than the room (no item cut against the graph).
@(test)
status_left_items_yield :: proc(t: ^testing.T) {
	measure :: proc(text: string) -> f32 { return f32(len(text)) * 10 }   // 10 px per character
	mk :: proc() -> [5]Status_Left_Item {
		return {
			{kind = .State, text = "HTTP 200", priority = 100},                       // 80
			{kind = .Origin, text = "https://example.com", short = "example.com", priority = 80},   // 190 / 110
			{kind = .Requests, text = "0 requests", short = "0 req.", priority = 60},  // 100 / 60
			{kind = .Cookies, text = "3 cookies", short = "3 ck.", priority = 30},     // 90 / 50
			{kind = .Nodes, text = "2060 nodes", short = "2060 n.", priority = 40},    // 100 / 70
		}
	}
	width :: proc(items: []Status_Left_Item, sep: f32) -> f32 {
		w: f32
		n := 0
		for it in items { if it.shown { w += it.cut > 0 ? it.cut : it.width; n += 1 } }
		return w + f32(max(n - 1, 0)) * sep
	}
	SEP :: 10
	wide := mk()
	status_left_fit(wide[:], 1000, SEP, measure)
	for it in wide { testing.expect(t, it.shown && it.cut == 0 && it.width == measure(it.text), "everything fits as it is") }
	testing.expect(t, wide[4].text == "2060 nodes", "full text")

	mid := mk()
	status_left_fit(mid[:], 480, SEP, measure)   // full: 560 + 40; short cookies -> 520 + 40; short nodes -> 490 + 40; short requests -> 450 + 40...
	testing.expectf(t, width(mid[:], SEP) <= 480, "fits: %v", width(mid[:], SEP))
	testing.expect(t, mid[3].text == "3 ck." && mid[4].text == "2060 n.", "the lowest priorities are shortened first")
	for it in mid { testing.expect(t, it.shown, "nothing left out while short forms suffice") }

	narrow := mk()
	status_left_fit(narrow[:], 260, SEP, measure)
	testing.expectf(t, width(narrow[:], SEP) <= 260, "fits: %v", width(narrow[:], SEP))
	testing.expect(t, narrow[0].shown && narrow[1].shown, "the state and the origin stay")
	testing.expect(t, !narrow[3].shown, "cookies (lowest priority) left out first")

	tiny := mk()
	status_left_fit(tiny[:], 50, SEP, measure)
	testing.expect(t, tiny[0].shown && tiny[0].cut == 50, "the state alone, cut to the room")
	for it in tiny[1:] { testing.expect(t, !it.shown, "every other item left out") }
}
