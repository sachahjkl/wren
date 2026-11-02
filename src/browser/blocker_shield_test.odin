package browser

import "core:testing"
import "toolkit:draw"

// The toolbar button heights the shield is drawn at (from small to large interface zooms and scales), in pixels.
@(private = "file") BUTTON_HEIGHT_MIN :: 16
@(private = "file") BUTTON_HEIGHT_MAX :: 96

// The inner edge of the outlined shield (amber while loading, grey when off for a site) never crosses itself: where it did, at the
// shoulders, the even-odd fill showed a dark notch inside the outline. Same sizes as shield_draw.
@(test)
the_inner_edge_of_the_shield_never_crosses_itself :: proc(t: ^testing.T) {
	for bh in BUTTON_HEIGHT_MIN ..= BUTTON_HEIGHT_MAX {
		sh := f32(bh) * 0.60
		pts: [SHIELD_MAX]draw.Vec2
		n := shield_points(&pts, {50, 50}, sh * 0.86, sh)
		inner: [SHIELD_MAX]draw.Vec2
		m := shield_inset(inner[:], pts[:n], max(2, f32(bh) * 0.075))
		crossings := 0
		for i in 0 ..< m {
			for j in i + 2 ..< m {
				if i == 0 && j == m - 1 { continue }   // (the closing segment shares its point with the first)
				if _, ok := segments_cross(inner[i], inner[(i + 1) % m], inner[j], inner[(j + 1) % m]); ok { crossings += 1 }
			}
		}
		testing.expectf(t, m >= 3 && crossings == 0, "at a button %d px high: %d points, %d crossings", bh, m, crossings)
	}
}
