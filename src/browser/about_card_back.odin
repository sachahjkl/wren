package browser

import "core:image"
import "core:image/png"
import "core:math"
import "core:strings"
import "toolkit:font"

////////////////////////////////
// The back of the licence card (about:wren, shader card-back, shaders.odin): what the card shows when it is turned over in its manipulation
// mode. It is the same foil as the front, struck from the other side, and made natively like the front's relief:
//
//  - the relief (back_normal_map) is the front's turned inside out, as the other face of a struck piece is: the lip that stands out of the
//    front is a trough here, the guilloche's ridges are furrows and its furrows ridges, the micro-lettering stands up in the frame; the grain is
//    the same (about_card_relief.odin, relief_map with an `emboss` field);
//  - in the middle, the logo of Wren RAISED out of the foil, big and quiet, an easter egg for whoever turns the card over: the height of
//    the figure (logo_height_field) is the logo's own picture (assets/logo_256.png, the one the page already carries), its bird taken from the
//    light of the picture (white on the orange, or the blue, tile: the smallest of the three channels) and its alpha, softened for the bevel;
//  - along the bottom, a line of lettering raised like the front's, in silver (back_engraving; texture 1 of the shader, the channels of
//    about_card_engrave.odin): the brand, not translated, and nothing about the person the card is made out to.

// How tall the figure stands, in the units of the relief's height field (the front's lip is 1.8).
BACK_RELIEF :: 1.7

// The logo's picture is drawn BACK_LOGO_CSS css px wide (the bird is a little over half of that) with its middle BACK_LOGO_LIFT px above the
// card's, on the card's 440 px design (about_card.odin).
BACK_LOGO_CSS  :: 236.0
BACK_LOGO_LIFT :: 8.0
@(private = "file") BACK_BEVEL_R :: 4       // the box blur (radius, two passes) that makes the figure's bevel, in texels (2 to a css px here)

// The line along the bottom: size and tracking (css px, em), the baseline from the top of the design.
@(private = "file") BACK_TEXT_SIZE :: 10.0
@(private = "file") BACK_TEXT_TRACK :: 0.28
@(private = "file") BACK_TEXT_BASELINE :: 252.0

// The brand line of the back (never translated: a name, not a sentence).
back_text :: proc() -> string {
	return strings.concatenate({strings.to_upper(APP_NAME, context.temp_allocator), " \u00b7 FROMENT SOFTWARE"}, context.temp_allocator)
}

@(private = "file")
smooth_step :: proc(a, b, x: f32) -> f32 {
	t := clamp((x - a) / (b - a), 0, 1)
	return t * t * (3 - 2 * t)
}

// The bird of the logo as a coverage field, size x size (the picture's own pixels): its alpha where it is white. False when the picture cannot
// be decoded (it is built in, so this does not happen; a test says so).
logo_mask :: proc(allocator := context.allocator) -> (mask: []f32, size: int, ok: bool) {
	img, err := png.load_from_bytes(APP_LOGO_PNG, {.alpha_add_if_missing})
	if err != nil || img == nil { return nil, 0, false }
	defer image.destroy(img)
	if img.depth != 8 || img.channels != 4 || img.width != img.height { return nil, 0, false }
	px := img.pixels.buf[:]
	n := img.width * img.height
	if len(px) < n * 4 { return nil, 0, false }
	mask = make([]f32, n, allocator)
	for i in 0 ..< n {
		r, g, b, a := f32(px[i * 4]), f32(px[i * 4 + 1]), f32(px[i * 4 + 2]), f32(px[i * 4 + 3])
		mask[i] = (a / 255) * smooth_step(0.55, 0.85, min(r, min(g, b)) / 255)
	}
	return mask, img.width, true
}

// The raised figure on the back of the card: NORMAL_W x NORMAL_H values in 0 .. 1 (1 on the flat top of the bird, falling to 0 over its bevel).
// All zero when the picture cannot be had.
logo_height_field :: proc(allocator := context.allocator) -> []f32 {
	W, H :: NORMAL_W, NORMAL_H
	field := make([]f32, W * H, allocator)
	mask, size, ok := logo_mask()
	if !ok { return field }
	defer delete(mask)
	texels_per_css := f32(W) / 440
	cx, cy := f32(440) / 2, 440 / f32(CARD_ASPECT) / 2 - BACK_LOGO_LIFT
	at :: proc(mask: []f32, size, x, y: int) -> f32 {
		if x < 0 || y < 0 || x >= size || y >= size { return 0 }
		return mask[y * size + x]
	}
	for y in 0 ..< H {
		for x in 0 ..< W {
			u := ((f32(x) + 0.5) / texels_per_css - cx) / (BACK_LOGO_CSS / f32(size)) + f32(size) / 2 - 0.5
			v := ((f32(y) + 0.5) / texels_per_css - cy) / (BACK_LOGO_CSS / f32(size)) + f32(size) / 2 - 0.5
			x0, y0 := int(math.floor(u)), int(math.floor(v))
			fx, fy := u - f32(x0), v - f32(y0)
			field[y * W + x] = (at(mask, size, x0, y0) * (1 - fx) + at(mask, size, x0 + 1, y0) * fx) * (1 - fy) +
				(at(mask, size, x0, y0 + 1) * (1 - fx) + at(mask, size, x0 + 1, y0 + 1) * fx) * fy
		}
	}
	tmp := make([]f32, W * H)
	defer delete(tmp)
	for _ in 0 ..< 2 {
		for y in 0 ..< H {
			for x in 0 ..< W {
				s: f32
				for k in -BACK_BEVEL_R ..= BACK_BEVEL_R { s += field[y * W + clamp(x + k, 0, W - 1)] }
				tmp[y * W + x] = s / (2 * BACK_BEVEL_R + 1)
			}
		}
		for y in 0 ..< H {
			for x in 0 ..< W {
				s: f32
				for k in -BACK_BEVEL_R ..= BACK_BEVEL_R { s += tmp[clamp(y + k, 0, H - 1) * W + x] }
				field[y * W + x] = s / (2 * BACK_BEVEL_R + 1)
			}
		}
	}
	for &v in field { v = clamp(v, 0, 1) }
	return field
}

// The relief of the back: NORMAL_W x NORMAL_H texels of RGBA8, the channels of the front's (about_card_relief.odin). The same bytes every time.
back_normal_map :: proc(allocator := context.allocator) -> []u8 {
	figure := logo_height_field()
	defer delete(figure)
	return relief_map(figure, allocator)
}

// The lettering of the back (ENGRAVE_W x ENGRAVE_H RGBA8): `text` centred along the bottom, raised. False when no font can be had. Call it from
// the thread that draws.
back_engraving :: proc(fs: ^font.State, renderer: u64, text: string, allocator := context.allocator) -> (texels: []u8, ok: bool) {
	semibold, found := engrave_font(fs, renderer, true)
	if !found { return nil, false }
	blits := make([dynamic]Blit, context.temp_allocator)
	w := engrave_width(fs, semibold, text, BACK_TEXT_SIZE, BACK_TEXT_TRACK) - BACK_TEXT_TRACK * BACK_TEXT_SIZE
	engrave_line(fs, semibold, &blits, ENGRAVE_SCALE, text, 220 - w / 2, BACK_TEXT_BASELINE, BACK_TEXT_SIZE, BACK_TEXT_TRACK, false)
	cov := engrave_coverage(fs, blits[:], ENGRAVE_W, ENGRAVE_H)
	defer delete(cov)
	return engrave_raise(cov, ENGRAVE_W, ENGRAVE_H, allocator), true
}
