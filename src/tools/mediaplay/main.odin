// mediaplay: decodes a file with the media package, without a window, and says what happened: tracks, the decoders
// chosen (GPU or not), frames and audio blocks with their times, decode time per frame. The tool the decoders are tried with.
//   mediaplay [-cpu] [-frames n] [-v] file.mp4|file.webm
package mediaplay

import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"
import win "core:sys/windows"
import "vendor:directx/d3d11"
import "wb:media"

Source :: struct {
	tracks:  [dynamic]media.Track,
	samples: [dynamic][dynamic]media.Sample,
}

main :: proc() {
	use_gpu := true
	max_frames := 1 << 30
	verbose := false
	play := false
	mute := false
	seek_to := -1.0
	path := ""
	args := os.args[1:]
	for i := 0; i < len(args); i += 1 {
		switch args[i] {
		case "-cpu": use_gpu = false
		case "-v": verbose = true
		case "-play": play = true
		case "-mute": mute = true
		case "-seek":
			i += 1
			if i < len(args) { seek_to = f64(atoi(args[i])) / 1000 }
		case "-frames":
			i += 1
			if i < len(args) { max_frames = atoi(args[i]) }
		case: path = args[i]
		}
	}
	if path == "" { fmt.eprintln("usage: mediaplay [-cpu] [-frames n] [-v] file"); os.exit(2) }
	data, err := os.read_entire_file(path, context.allocator)
	if err != nil { fmt.eprintln("cannot read", path); os.exit(2) }

	src: Source
	sink := media.Demux_Sink{
		user = &src,
		tracks = proc(user: rawptr, tracks: []media.Track, duration: media.Time) {
			s := (^Source)(user)
			for t in tracks { append(&s.tracks, media.track_clone(t)); append(&s.samples, make([dynamic]media.Sample)) }
			fmt.printfln("tracks: %d, duration %.3f s", len(tracks), media.time_seconds(duration))
			for t in tracks {
				fmt.printfln("  #%d %v %v %s  %dx%d  %d ch %d Hz  config %d bytes", t.id, t.kind, t.codec, t.codec_string, t.width, t.height, t.channels, t.sample_rate, len(t.config))
			}
		},
		sample = proc(user: rawptr, track: int, s: media.Sample) {
			append(&(^Source)(user).samples[track], s)
		},
	}
	if strings.has_suffix(path, ".webm") || strings.has_suffix(path, ".mkv") {
		d: media.Webm_Demuxer
		media.webm_init(&d, sink)
		if e := media.webm_feed(&d, data); e != .None { fmt.eprintln("demux error", e) }
	} else {
		d: media.Mp4_Demuxer
		media.mp4_init(&d, sink)
		if e := media.mp4_feed(&d, data); e != .None { fmt.eprintln("demux error", e) }
	}
	for l, i in src.samples { fmt.printfln("  track %d: %d samples", i, len(l)) }

	// a device like the renderer's
	device: ^d3d11.IDevice
	ctx: ^d3d11.IDeviceContext
	levels := [?]d3d11.FEATURE_LEVEL{._11_0}
	if use_gpu {
		hr := d3d11.CreateDevice(nil, .HARDWARE, nil, {.BGRA_SUPPORT, .VIDEO_SUPPORT}, &levels[0], 1, d3d11.SDK_VERSION, &device, nil, &ctx)
		if win.FAILED(hr) { fmt.eprintln("no D3D11 device", hr); use_gpu = false }
	}
	if use_gpu { media.set_gpu_device(device) }

	if play { play_stores(&src, mute, seek_to); return }
	for t, ti in src.tracks {
		switch t.kind {
		case .Video: decode_video(t, src.samples[ti][:], use_gpu, max_frames, verbose)
		case .Audio: decode_audio(t, src.samples[ti][:], max_frames, verbose)
		case .Other:
		}
	}
}

decode_video :: proc(t: media.Track, samples: []media.Sample, gpu: bool, max_frames: int, verbose: bool) {
	sup := media.mf_video_supported(t.codec)
	fmt.printfln("video %v: supported=%v", t.codec, sup)
	dec := media.mf_video_create(t, gpu)
	if dec == nil { fmt.eprintln("  no decoder"); return }
	defer dec.destroy(dec)
	fmt.printfln("  decoder: %s, hardware=%v", dec.name, dec.hardware)
	frames, gpu_frames := 0, 0
	last_pts := media.Time(-1)
	reorder_bad := 0
	t0 := time.tick_now()
	feed := 0
	pull_all :: proc(dec: ^media.Video_Decoder, frames, gpu_frames, reorder_bad: ^int, last_pts: ^media.Time, verbose: bool) {
		for {
			f: media.Video_Frame
			switch dec.pull(dec, &f) {
			case .Frame:
				frames^ += 1
				if f.gpu_texture != nil { gpu_frames^ += 1 }
				if f.pts < last_pts^ { reorder_bad^ += 1 }
				last_pts^ = f.pts
				if verbose || frames^ == 1 {
					fmt.printfln("  frame %d pts %.4f  %dx%d (surface %dx%d crop %v) %v gpu=%v color=%v", frames^, media.time_seconds(f.pts), f.width, f.height, f.surface[0], f.surface[1], f.crop, f.format, f.gpu_texture != nil, f.color)
				}
				media.frame_release(&f)
			case .Need_Input: return
			case .Format_Changed: fmt.println("  format changed")
			case .Error: fmt.println("  decode error"); return
			}
		}
	}
	for i := 0; i < len(samples) && frames < max_frames; i += 1 {
		s := &samples[i]
		for !dec.push(dec, s) { pull_all(dec, &frames, &gpu_frames, &reorder_bad, &last_pts, verbose) }
		feed += 1
		pull_all(dec, &frames, &gpu_frames, &reorder_bad, &last_pts, verbose)
	}
	dec.drain(dec)
	pull_all(dec, &frames, &gpu_frames, &reorder_bad, &last_pts, verbose)
	ms := time.duration_milliseconds(time.tick_since(t0))
	fmt.printfln("  fed %d samples, %d frames (%d on the GPU), %d out of order, %.1f ms (%.2f ms per frame)", feed, frames, gpu_frames, reorder_bad, ms, ms / f64(max(frames, 1)))
}

decode_audio :: proc(t: media.Track, samples: []media.Sample, max_frames: int, verbose: bool) {
	sup := media.mf_audio_supported(t.codec)
	fmt.printfln("audio %v: supported=%v", t.codec, sup)
	dec := media.mf_audio_create(t)
	if dec == nil { fmt.eprintln("  no decoder"); return }
	defer dec.destroy(dec)
	blocks, frames := 0, 0
	first_pts := media.Time(0)
	pull_all :: proc(dec: ^media.Audio_Decoder, blocks, frames: ^int, first: ^media.Time, verbose: bool) {
		for {
			b: media.Audio_Block
			switch dec.pull(dec, &b) {
			case .Frame:
				if blocks^ == 0 { first^ = b.pts; fmt.printfln("  first block pts %.4f, %d frames, %d ch, %d Hz", media.time_seconds(b.pts), b.frames, b.channels, b.rate) }
				blocks^ += 1
				frames^ += b.frames
				if verbose { fmt.printfln("  block %d pts %.4f %d frames", blocks^, media.time_seconds(b.pts), b.frames) }
				media.audio_block_destroy(&b)
			case .Need_Input: return
			case .Format_Changed: fmt.println("  format changed")
			case .Error: fmt.println("  decode error"); return
			}
		}
	}
	for i := 0; i < len(samples); i += 1 {
		s := &samples[i]
		for !dec.push(dec, s) { pull_all(dec, &blocks, &frames, &first_pts, verbose) }
		pull_all(dec, &blocks, &frames, &first_pts, verbose)
	}
	dec.drain(dec)
	pull_all(dec, &blocks, &frames, &first_pts, verbose)
	rate := max(t.sample_rate, 1)
	fmt.printfln("  %d blocks, %d frames = %.3f s", blocks, frames, f64(frames) / f64(rate))
}

atoi :: proc(s: string) -> int {
	v := 0
	for c in s { if c >= '0' && c <= '9' { v = v * 10 + int(c - '0') } }
	return v
}

// -play: the whole player, as the page uses it: stores, decode threads, clock; presents on a 5 ms loop and reports.
play_stores :: proc(src: ^Source, mute: bool, seek_to: f64) {
	vs, as: ^media.Track_Store
	for t, i in src.tracks {
		s: ^media.Track_Store
		switch t.kind {
		case .Video: if vs == nil { vs = media.store_create(); s = vs }
		case .Audio: if as == nil { as = media.store_create(); s = as }
		case .Other:
		}
		if s == nil { continue }
		media.store_set_config(s, 1, t)
		for smp in src.samples[i] { media.store_append(s, smp) }
		clear(&src.samples[i])
	}
	p := media.player_create(vs, as, media.PLAYER_SETTINGS_DEFAULT, nil, nil)
	defer media.player_destroy(p)
	media.player_set_source_ended(p, true)
	media.player_set_volume(p, mute ? 0 : 0.15, mute)
	if seek_to >= 0 { media.player_seek(p, media.seconds_time(seek_to)) }
	media.player_play(p)
	start := time.tick_now()
	last_report := 0.0
	shown := 0
	last_pts := media.Time(-1)
	max_err := 0.0
	for {
		wall := time.duration_seconds(time.tick_since(start))
		media.player_tick(p)
		f, changed := media.player_present(p)
		if changed {
			shown += 1
			err := abs(media.time_seconds(f.pts) - media.time_seconds(media.player_time(p)))
			max_err = max(max_err, err)
			if err > 0.045 { fmt.printfln("  late/early picture: pts %.3f clock %.3f (wall %.3f)", media.time_seconds(f.pts), media.time_seconds(media.player_time(p)), wall) }
			if f.pts < last_pts { fmt.println("  picture out of order") }
			last_pts = f.pts
		}
		if wall - last_report >= 0.5 {
			last_report = wall
			playing, stalled, ended, err := media.player_state(p)
			fmt.printfln("  wall %.2f  clock %.3f  playing=%v stalled=%v ended=%v err=%v  shown %d", wall, media.time_seconds(media.player_time(p)), playing, stalled, ended, err, shown)
		}
		_, _, ended, _ := media.player_state(p)
		if ended || wall > 10 { break }
		time.sleep(5 * time.Millisecond)
	}
	st := media.player_stats(p)
	fmt.printfln("done: %d pictures shown, %d decoded, %d dropped, max |picture - clock| %.1f ms, decoder %s hardware=%v", shown, st.decoded, st.dropped, max_err * 1000, st.decoder, st.hardware)
}