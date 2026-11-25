package style

import "core:testing"
import "wb:dom"

@(test)
image_rendering_parsing_and_inheritance :: proc(t: ^testing.T) {
	d := fixture_load(`
		<style>
			#p { image-rendering: pixelated; }
			#c2 { image-rendering: crisp-edges; }
			#m { image-rendering: -moz-crisp-edges; }
			#w { image-rendering: -webkit-optimize-contrast; }
			#s { image-rendering: smooth; }
			#h { image-rendering: high-quality; }
			#os { image-rendering: optimizeSpeed; }
			#oq { image-rendering: pixelated; image-rendering: optimizeQuality; }
			#ov { image-rendering: crisp-edges; image-rendering: pixelated; }
			#bad { image-rendering: pixelated; image-rendering: bogus; image-rendering: 10px; image-rendering: pixelated auto; }
			#rst { image-rendering: initial; }
			#un { image-rendering: unset; }
		</style>
		<div id=def></div>
		<div id=p>
			<img id=c1>
			<img id=c2>
			<img id=rst>
			<img id=un>
		</div>
		<img id=m>
		<img id=w>
		<img id=s>
		<img id=h>
		<img id=os>
		<img id=oq>
		<canvas id=ov></canvas>
		<img id=bad>
	`)
	defer fixture_unload(d)

	ir :: proc(d: ^Fixture, id: string) -> Image_Rendering {
		c := style_of(d.st, dom.find_by_id(d.doc, id))
		return c != nil ? c.image_rendering : .Auto
	}

	testing.expect_value(t, ir(d, "def"), Image_Rendering.Auto)
	testing.expect_value(t, ir(d, "p"), Image_Rendering.Pixelated)
	testing.expect_value(t, ir(d, "c1"), Image_Rendering.Pixelated)   // inherited from #p
	testing.expect_value(t, ir(d, "c2"), Image_Rendering.Crisp_Edges) // child override
	testing.expect_value(t, ir(d, "rst"), Image_Rendering.Auto)       // initial resets
	testing.expect_value(t, ir(d, "un"), Image_Rendering.Pixelated)   // unset inherits on an inherited property
	testing.expect_value(t, ir(d, "m"), Image_Rendering.Crisp_Edges)
	testing.expect_value(t, ir(d, "w"), Image_Rendering.Crisp_Edges)
	testing.expect_value(t, ir(d, "s"), Image_Rendering.Smooth)
	testing.expect_value(t, ir(d, "h"), Image_Rendering.High_Quality)
	testing.expect_value(t, ir(d, "os"), Image_Rendering.Pixelated)
	testing.expect_value(t, ir(d, "oq"), Image_Rendering.Auto)
	testing.expect_value(t, ir(d, "ov"), Image_Rendering.Pixelated)   // later valid declaration wins
	testing.expect_value(t, ir(d, "bad"), Image_Rendering.Pixelated)  // invalid values ignored

	testing.expect_value(t, prop_tier(.Image_Rendering), Prop_Tier.Paint)
	testing.expect(t, dev_inherited_property("image-rendering"), "devtools marks image-rendering inherited")
	opt := parse_options(&d.eng.settings)
	testing.expect(t, supports_declaration(d.eng, "image-rendering", "pixelated", opt), "CSS.supports pixelated")
	testing.expect(t, supports_declaration(d.eng, "image-rendering", "crisp-edges", opt), "CSS.supports crisp-edges")
	testing.expect(t, supports_declaration(d.eng, "image-rendering", "-moz-crisp-edges", opt), "CSS.supports -moz-crisp-edges")
	testing.expect(t, !supports_declaration(d.eng, "image-rendering", "bogus", opt), "CSS.supports rejects invalid")

	a := style_of(d.st, dom.find_by_id(d.doc, "def"))
	b := style_of(d.st, dom.find_by_id(d.doc, "p"))
	testing.expect(t, !computed_equal(a, b), "different image-rendering differs in computed style")
	testing.expect(t, layout_equal(a, b), "image-rendering is paint-only and keeps layout")
}
