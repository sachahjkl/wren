package style

import "core:testing"
import "wb:dom"

// The user agent's style of media (HTML Standard, rendering: "video { object-fit: contain; }"): a video's frame keeps its
// shape in a box of another one, with bars, where an image fills its box.
@(test)
a_video_is_contained_an_image_fills :: proc(t: ^testing.T) {
	d := fixture_load(`<video id=v></video><img id=i><video id=s style="object-fit: cover"></video>`)
	defer fixture_unload(d)
	of :: proc(d: ^Fixture, id: string) -> Object_Fit { c := style_of(d.st, dom.find_by_id(d.doc, id)); return c != nil ? c.object_fit : nil }
	testing.expect_value(t, of(d, "v"), Object_Fit.Contain)
	testing.expect_value(t, of(d, "i"), Object_Fit.Fill)
	testing.expect_value(t, of(d, "s"), Object_Fit.Cover)   // a page's own value wins
}
