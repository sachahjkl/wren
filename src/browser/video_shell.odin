package browser

// <video> in the shell: the current picture of a media element drawn into its box, and when the next one is due.
//
// A decoded picture is a Direct3D 11 texture of the decoder (NV12 / P010) that stays on the GPU: render.video_convert
// turns it into an RGBA texture (one small draw, only when a new picture came) and draw.image puts that texture in the
// box like any other image, so border-radius, object-fit, opacity, filters and transforms work as they do for <img>. The
// page is not painted again for a picture: the video is an immediate item of the compositor (compositor.odin), drawn
// at its place in the already recorded page. While a video plays, a timer asks for a frame when the next picture is due,
// so the browser composes once per video frame; a paused video asks for nothing.

import "toolkit:draw"
import "toolkit:render"
import "wb:base"
import "wb:host"
import "wb:media"
import "wb:page"
import "wb:style"

@(private = "file")
Video_Key :: struct {
	page: u64,
	node: base.Handle,
}

@(private = "file")
Video_Target :: struct {
	tex:   render.Texture,
	size:  [2]int,
	epoch: u64,
	frames: int,         // pictures converted into it
}

@(private = "file")
Video_Shell :: struct {
	targets:   map[Video_Key]^Video_Target,
	epoch:     u64,
	next_ns:   i64,              // the nearest due picture of this frame's videos (< 0: none)
	wake:      base.Handle,
	generation: u64,             // render.Renderer.device_generation the targets were made on
	gpu_set:   bool,
	converted: int,              // statistics: pictures converted
	painted:   int,
}

@(private = "file")
vshell: Video_Shell

// The renderer's Direct3D 11 device goes to the decoders: pictures stay in its memory.
video_shell_init :: proc(app: ^App) {
	vshell.next_ns = -1
	when !render.USE_WGPU {
		if app.r.device != nil && !vshell.gpu_set {
			media.set_gpu_device(rawptr(app.r.device))
			vshell.gpu_set = true
		}
	}
}

video_shell_destroy :: proc(app: ^App) {
	for _, t in vshell.targets {
		render.destroy_texture(&app.r, t.tex)
		free(t)
	}
	delete(vshell.targets)
	if vshell.wake != base.NIL_HANDLE { host.clear_timer(&app.loop, vshell.wake) }
	if vshell.gpu_set { media.set_gpu_device(nil) }
	vshell = {}
}

video_shell_begin_frame :: proc(app: ^App) {
	if app.r.device_generation != vshell.generation {
		vshell.generation = app.r.device_generation
		for _, t in vshell.targets { free(t) }
		clear(&vshell.targets)   // (the textures went with the device)
	}
	vshell.epoch += 1
	vshell.next_ns = -1
}

// After the page was painted: the wake-up for the next picture, and the targets nobody drew for a while released.
video_shell_after_paint :: proc(app: ^App) {
	if vshell.wake != base.NIL_HANDLE { host.clear_timer(&app.loop, vshell.wake); vshell.wake = base.NIL_HANDLE }
	if vshell.next_ns >= 0 {
		delay_ms := max(f64(vshell.next_ns) / 1e6 - 0.5, 0.25)
		vshell.wake = host.set_timer(&app.loop, delay_ms, 0, proc(data: rawptr) {
			vshell.wake = base.NIL_HANDLE
			a := (^App)(data)
			// exactly the frame this picture needs: the timer is the one that asked, the loop does not add its own two
			host.quiet_note(&a.loop)
			a.frames_requested = max(a.frames_requested, 1)
		}, app)
	}
	for k, t in vshell.targets {
		if vshell.epoch - t.epoch > 120 {
			render.destroy_texture(&app.r, t.tex)
			free(t)
			delete_key(&vshell.targets, k)
		}
	}
}

@(private = "file")
pixel_format :: proc(f: media.Pixel_Format) -> render.Video_Format {
	switch f {
	case .NV12, .None: return .NV12
	case .P010: return .P010
	case .I420: return .I420
	case .I420_10: return .I420_10
	}
	return .NV12
}

// The picture a decoder made, as the renderer wants it described.
@(private = "file")
picture_of :: proc(f: ^media.Video_Frame) -> render.Video_Picture {
	pic := render.Video_Picture{
		format = pixel_format(f.format), size = f.surface, crop_origin = f.crop, crop_size = {f.width, f.height},
		rotation = f.rotation, full_range = f.color.full_range,
		gpu_texture = f.gpu_texture, gpu_index = f.gpu_index, planes = f.planes, strides = f.strides,
	}
	switch f.color.coeffs {
	case .BT709, .Identity, .SMPTE240: pic.coeffs = .BT709
	case .BT601: pic.coeffs = .BT601
	case .BT2020: pic.coeffs = .BT2020
	case .Unspecified: pic.coeffs = f.height >= 720 || f.width >= 1280 ? .BT709 : .BT601   // (the usual guess: HD is 709, SD is 601)
	}
	switch f.color.transfer {
	case .PQ: pic.transfer = .PQ
	case .HLG: pic.transfer = .HLG
	case .SDR, .Unspecified:
	}
	return pic
}

// The texture holding the picture a <video> shows now (converted from its decoder's surface if a new one came), for a canvas
// that draws it: no copy through the CPU.
video_texture_for_canvas :: proc(app: ^App, p: ^page.Page, node: base.Handle) -> (tex: render.Texture, size: [2]int, ok: bool) {
	if app == nil || p == nil { return }
	t, view, vok := video_current(app, p, node)
	if !vok || t == nil || t.frames == 0 { return }
	_ = view
	return t.tex, t.size, true
}

// The target of a video with its current picture converted into it (made when there is none).
@(private = "file")
video_current :: proc(app: ^App, p: ^page.Page, node: base.Handle) -> (t: ^Video_Target, view: page.Media_View, ok: bool) {
	view, ok = page.media_view(p, node)
	if !ok { return }
	if view.next_due_ns >= 0 { vshell.next_ns = vshell.next_ns < 0 ? view.next_due_ns : min(vshell.next_ns, view.next_due_ns) }
	key := Video_Key{page.page_id(p), node}
	t = vshell.targets[key]
	if view.frame != nil {
		pic := picture_of(view.frame)
		want := render.video_target_size(pic)
		if t != nil && t.size != want {
			render.destroy_texture(&app.r, t.tex)
			free(t)
			delete_key(&vshell.targets, key)
			t = nil
		}
		if t == nil && want.x > 0 && want.y > 0 {
			tex := render.create_video_target(&app.r, want.x, want.y)
			if tex != 0 {
				t = new(Video_Target)
				t.tex, t.size = tex, want
				vshell.targets[key] = t
			}
		}
		if t != nil && (view.changed || t.frames == 0) {
			if render.video_convert(&app.r, t.tex, pic) { t.frames += 1; vshell.converted += 1 }
		}
	}
	if t != nil { t.epoch = vshell.epoch }
	return t, view, true
}

// Paints the <video> element `node` into `content`. Always true: the video owns its box.
video_paint_content :: proc(dc: ^draw.Context, p: ^page.Page, node: base.Handle, content, border: draw.Rect, cs: ^style.Computed, scale: f32) -> bool {
	app := the_app
	if app == nil { return true }
	t, view, ok := video_current(app, p, node)
	if !ok { return true }
	if view.ready { draw.rect(dc, content, draw.Color{0, 0, 0, 1}) }
	if t != nil && t.frames > 0 {
		dst := fit_rect(content, {f32(t.size.x), f32(t.size.y)}, cs, scale)
		radii := content_radii(cs, border, content, scale)
		clip := dst.min.x < content.min.x || dst.min.y < content.min.y || dst.max.x > content.max.x || dst.max.y > content.max.y || radii != {}
		if clip { draw.push_clip_rounded(dc, content, radii) }
		draw.image(dc, t.tex, dst, {}, draw.Color{1, 1, 1, 1})
		if clip { draw.pop_clip(dc) }
		vshell.painted += 1
	}
	return true
}
