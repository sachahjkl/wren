package page

import "core:testing"
import "wb:style"

// Numbers of computed values: the shortest decimal that is the same f32 (20.7px reads back as written), at most six
// decimals, no exponent.
@(test)
css_numbers_serialize_short :: proc(t: ^testing.T) {
	testing.expect_value(t, css_num(20.7), "20.7")
	testing.expect_value(t, css_num(-0.2), "-0.2")
	testing.expect_value(t, css_num(1.0 / 3.0), "0.333333")
	testing.expect_value(t, css_num(12), "12")
	testing.expect_value(t, css_num(0.0000001), "0")
	testing.expect_value(t, css_num(-0.0000001), "0")
	testing.expect_value(t, css_px(150.25), "150.25px")
}

@(test)
computed_image_rendering_serializes :: proc(t: ^testing.T) {
	inh: style.Inherited_Group
	cs := style.Computed{inherited_group = &inh}
	testing.expect_value(t, computed_value(&cs, "image-rendering", {}), "auto")
	inh.image_rendering = .Smooth
	testing.expect_value(t, computed_value(&cs, "image-rendering", {}), "smooth")
	inh.image_rendering = .High_Quality
	testing.expect_value(t, computed_value(&cs, "image-rendering", {}), "high-quality")
	inh.image_rendering = .Crisp_Edges
	testing.expect_value(t, computed_value(&cs, "image-rendering", {}), "crisp-edges")
	inh.image_rendering = .Pixelated
	testing.expect_value(t, computed_value(&cs, "image-rendering", {}), "pixelated")
	found := false
	for name in COMPUTED_PROPERTIES {
		if name == "image-rendering" { found = true; break }
	}
	testing.expect(t, found, "image-rendering is listed in COMPUTED_PROPERTIES")
}
