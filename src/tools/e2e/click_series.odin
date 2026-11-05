package e2e_scenarios

// A series of clicks on text. The third click of a triple click lands on the word the second one selected, inside the selection,
// where a press also begins a drag of it: the press went to the drag, the series stopped there and the paragraph was not selected.

import "core:testing"
import "wb:e2e"

@(private = "file") SIZE :: [2]int{800, 300}
@(private = "file") PAGE :: `<!doctype html><style>body{margin:20px;font:20px monospace}</style><p>first <span id=word>second</span> third fourth</p><p>another paragraph</p>`
@(private = "file") WORD :: "second"
@(private = "file") PARAGRAPH :: "first second third fourth"

@(test)
a_triple_click_selects_the_paragraph_from_inside_the_word :: proc(t: ^testing.T) {
	s := e2e.start(t, {size = SIZE, dpi = e2e.DPI_ONE, url = "about:blank"})
	e2e.eval(s, "document.open(); document.write(`" + PAGE + "`); document.close(); 1")
	e2e.wait_frames(s)
	box := e2e.box_model(s, "#word").box
	at := e2e.Point{box.x + box.w / 2, box.y + box.h / 2}
	e2e.forget_clicks(s)
	e2e.click_at(s, at, count = 2)
	testing.expect_value(t, e2e.eval(s, "String(getSelection()).trim()"), WORD)
	e2e.forget_clicks(s)
	e2e.click_at(s, at, count = 3)
	testing.expect_value(t, e2e.eval(s, "String(getSelection()).trim()"), PARAGRAPH)
}
