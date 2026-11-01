package e2e_scenarios

// A playing video is a plane of the page's paint order: the same picture every frame. examples/site/remote/video-layers.htm: a video in a rounded
// overflow:hidden box, a fixed dialog (z-index) and a bar over it, a rotated half-transparent rounded video, and a script that keeps the thread busy a few
// ms every frame (so that frames are made under it, as under a player's). Captures in a row while it plays, each the very next frame: in each the box's
// corners are rounded, the dialog and the bar are above the video, and what is not the video is the same pixel for pixel in every capture.

import "core:testing"
import "wb:base"
import "wb:e2e"

@(private = "file") PAGE :: "/site/remote/video-layers.htm"
@(private = "file") WINDOW := [2]int{1000, 500}
@(private = "file") CAPTURES :: 30
// With every allocation tracked (build\e2e_test_check.exe) a frame is far longer: it looks for leaks, the layers are looked at in the other build.
@(private = "file") CAPTURES_TRACKED :: 6
// Each sampled, not every pixel: a third of each way.
@(private = "file") SAMPLE_STEP :: 3
// The places (x, y, w, h) that are not the video: the dialog, the bar, the corners.
@(private = "file") STILL_REGIONS := [?][4]int{{236, 96, 250, 108}, {60, 242, 360, 26}, {41, 41, 14, 14}, {425, 41, 14, 14}, {41, 265, 14, 14}, {425, 265, 14, 14}}
@(private = "file") CORNER := [2]int{45, 45}
@(private = "file") DIALOG := [2]int{300, 150}
@(private = "file") BAR := [2]int{200, 255}
// Two places of the video.
@(private = "file") VIDEO_A := [2]int{120, 120}
@(private = "file") VIDEO_B := [2]int{330, 220}
// The grey of the box's corner, the same on all three channels within this.
@(private = "file") CORNER_GREY_MIN :: 200
@(private = "file") CORNER_GREY_MAX :: 240
@(private = "file") GREY_WITHIN :: 4
// The dialog is red, the bar blue.
@(private = "file") DIALOG_RED_MIN :: 190
@(private = "file") DIALOG_OTHER_MAX :: 70
@(private = "file") BAR_BLUE_MIN :: 180
@(private = "file") BAR_RED_MAX :: 60
@(private = "file") BAR_GREEN_MAX :: 110
// The video moves in more than this part of the captures.
@(private = "file") MOVING_PART :: 4
@(private = "file") MOVING_AT_LEAST :: 3

@(test)
a_playing_video_is_a_plane_of_the_pages_paint_order :: proc(t: ^testing.T) {
	s := e2e.start(t, {size = WINDOW, dpi = e2e.DPI_ONE, url = e2e.url(e2e.test_server(t), PAGE)})
	e2e.wait_idle(s)
	e2e.wait_js(s, `document.getElementById("v1").currentTime > 1 && document.getElementById("v2").currentTime > 1`)
	n := base.TRACK_MEMORY ? CAPTURES_TRACKED : CAPTURES
	shots := make([]e2e.Image, n, context.temp_allocator)
	for i in 0 ..< n { shots[i] = e2e.capture(s, {target = .Page, has_settle = true, settle = 0}) }

	at :: proc(i: e2e.Image, p: [2]int) -> e2e.Color { return e2e.pixel(i, p.x, p.y) }
	moved := 0
	for shot, i in shots {
		c, d, b := at(shot, CORNER), at(shot, DIALOG), at(shot, BAR)
		testing.expectf(t, c.r > CORNER_GREY_MIN && c.r < CORNER_GREY_MAX && abs(int(c.r) - int(c.g)) < GREY_WITHIN && abs(int(c.r) - int(c.b)) < GREY_WITHIN, "capture %d: the box's corner is rounded: %v", i, c)
		testing.expectf(t, d.r > DIALOG_RED_MIN && d.g < DIALOG_OTHER_MAX && d.b < DIALOG_OTHER_MAX, "capture %d: the dialog is above the video: %v", i, d)
		testing.expectf(t, b.b > BAR_BLUE_MIN && b.r < BAR_RED_MAX && b.g < BAR_GREEN_MAX, "capture %d: the bar is above the video: %v", i, b)
		if i == 0 { continue }
		before := shots[i - 1]
		for r in STILL_REGIONS {
			same := true
			for y := r[1]; y < r[1] + r[3] && same; y += SAMPLE_STEP {
				for x := r[0]; x < r[0] + r[2]; x += SAMPLE_STEP {
					if e2e.pixel(before, x, y) != e2e.pixel(shot, x, y) { same = false; break }
				}
			}
			testing.expectf(t, same, "capture %d: nothing but the video changes: the region %v did", i, r)
		}
		if at(before, VIDEO_A) != at(shot, VIDEO_A) || at(before, VIDEO_B) != at(shot, VIDEO_B) { moved += 1 }
	}
	testing.expectf(t, moved > min(MOVING_AT_LEAST, (n - 1) / MOVING_PART), "the video plays: %d of %d captures differ in it", moved, n - 1)
}
