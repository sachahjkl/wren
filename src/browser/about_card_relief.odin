package browser

import "core:encoding/base64"
import "core:fmt"
import "core:math"
import "core:sync"
import "wb:base"
import "wb:images"

////////////////////////////////
// The relief of the licence card: a height field (a guilloche like the ones of banknotes, two rosettes of wavy rings, and a raised
// frame with a bevel) from which three pictures are made, the way a normal map is used to light a surface:
//
//  - `emboss`: the surface lit from the top left, once for all (white where a slope faces the light, black where it turns away);
//  - `toward` and `away`: the slopes that face the direction the sheen travels in, and those that turn their back to it, as the alpha
//    of a white picture. The sheen (a CSS animation, about_card.odin) is a band of light that crosses the card; the light of a point
//    light moving over a bumpy surface reaches the slopes behind it by one side and the slopes ahead of it by the other, so the band
//    is drawn twice, a long tail behind it through the mask `toward` and a short glow in front of it through the mask `away`, and the
//    ridges of the guilloche glint as it passes, instead of a flat band sliding over a flat card.
//
// The pictures are made when the page is made (a few milliseconds) as PNG data: URLs in the temporary allocator, like the logo.

RELIEF_W :: 440
RELIEF_H :: 278   // (the card's ratio, 1.586)

// The direction the sheen travels in (CSS angle 105deg: a little below the horizontal, to the right), in the picture's pixels.
@(private = "file") SHEEN_DX :: 0.9659258
@(private = "file") SHEEN_DY :: 0.2588190

Card_Relief :: struct {
	emboss, toward, away: string,   // data: URLs
}

@(private = "file")
height_at :: proc(u, v: f64) -> f64 {
	// u in [0, 1.586], v in [0, 1]
	ring :: proc(u, v, cx, cy, rings, wobble, lobes, phase: f64) -> (h, w: f64) {
		dx, dy := u - cx, v - cy
		r := math.sqrt(dx * dx + dy * dy)
		a := math.atan2(dy, dx)
		h = math.sin(2 * math.PI * rings * r + wobble * math.sin(lobes * a + phase))
		w = math.exp(-r * r / 0.30)
		return
	}
	h1, w1 := ring(u, v, 0.46, 0.50, 30, 2.4, 9, 1.3)
	h2, w2 := ring(u, v, 1.22, 0.64, 24, 1.8, 7, 0.4)
	h := (h1 * w1 + h2 * w2) / (w1 + w2 + 0.05) * 0.5
	// the frame: raised, with a bevel
	edge := min(min(u, 1.586 - u), min(v, 1 - v))
	bevel := 1 - clamp(edge / 0.04, 0, 1)
	h += bevel * bevel * 1.6
	// the inner groove of the frame
	g := (edge - 0.055) / 0.006
	h -= 0.6 * math.exp(-g * g)
	return h
}

// Makes the three pictures. `allocator` holds the strings.
card_relief :: proc(allocator := context.temp_allocator) -> Card_Relief {
	W, H :: RELIEF_W, RELIEF_H
	hf := make([]f32, W * H, context.temp_allocator)
	for y in 0 ..< H {
		for x in 0 ..< W {
			hf[y * W + x] = f32(height_at((f64(x) + 0.5) / f64(H), (f64(y) + 0.5) / f64(H)))   // (square pixels: both axes in units of the height)
		}
	}
	// slopes by central differences
	nd := make([]f32, W * H, context.temp_allocator)   // along the sheen's direction
	ne := make([]f32, W * H, context.temp_allocator)   // towards the light of the embossing
	nd_max, ne_max: f32 = 1e-6, 1e-6
	LX, LY :: -0.6, -0.8   // the embossing light comes from the top left
	for y in 0 ..< H {
		for x in 0 ..< W {
			xm, xp := max(x - 1, 0), min(x + 1, W - 1)
			ym, yp := max(y - 1, 0), min(y + 1, H - 1)
			gx := (hf[y * W + xp] - hf[y * W + xm]) / f32(xp - xm)
			gy := (hf[yp * W + x] - hf[ym * W + x]) / f32(yp - ym)
			d := -(gx * SHEEN_DX + gy * SHEEN_DY)   // the normal's component along the direction of the sheen
			e := -(gx * LX + gy * LY)                // minus the slope along the light: > 0 where the surface faces it
			nd[y * W + x], ne[y * W + x] = d, e
			nd_max, ne_max = max(nd_max, abs(d)), max(ne_max, abs(e))
		}
	}
	emboss := make([]u8, W * H * 4, context.temp_allocator)
	toward := make([]u8, W * H * 4, context.temp_allocator)
	away := make([]u8, W * H * 4, context.temp_allocator)
	for i in 0 ..< W * H {
		d := clamp(nd[i] / (0.55 * nd_max), -1, 1)
		t, a := f32(math.pow(f64(max(d, 0)), 0.7)), f32(math.pow(f64(max(-d, 0)), 0.7))
		toward[i * 4 + 0], toward[i * 4 + 1], toward[i * 4 + 2], toward[i * 4 + 3] = 255, 255, 255, u8(t * 255)
		away[i * 4 + 0], away[i * 4 + 1], away[i * 4 + 2], away[i * 4 + 3] = 255, 255, 255, u8(a * 255)
		e := clamp(ne[i] / (0.6 * ne_max), -1, 1)
		c: u8 = e > 0 ? 255 : 0
		emboss[i * 4 + 0], emboss[i * 4 + 1], emboss[i * 4 + 2], emboss[i * 4 + 3] = c, c, c, u8(abs(e) * 200)
	}
	url :: proc(rgba: []u8, allocator := context.temp_allocator) -> string {
		png, ok := images.encode_rgba(rgba, RELIEF_W, RELIEF_H, .Png, 0, false)
		if !ok { return "" }
		defer delete(png)
		return fmt.aprintf("data:image/png;base64,%s", base64.encode(png, allocator = context.temp_allocator), allocator = allocator)
	}
	return Card_Relief{emboss = url(emboss, allocator), toward = url(toward, allocator), away = url(away, allocator)}
}

@(private = "file") relief_cache: Card_Relief
@(private = "file") relief_lock: sync.Mutex

// The pictures, made once (the first time a licence card is shown) and kept for the life of the program: they are what a licence card
// needs on every build of the page, a few hundred kilobytes, and they do not depend on anything. Held by the process allocator, outside the
// allocator the tests and the check build follow.
card_relief_cached :: proc() -> Card_Relief {
	sync.lock(&relief_lock)
	defer sync.unlock(&relief_lock)
	if relief_cache.emboss == "" {
		context.allocator = base.process_allocator()
		relief_cache = card_relief(context.allocator)
	}
	return relief_cache
}