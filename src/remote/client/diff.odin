package client

// `wren ctl diff a.png b.png [--tolerance n] [--out diff.png] [--max-percent p]`: two pictures compared pixel by pixel.
// A pixel differs when any channel differs by more than the tolerance (0..255). It prints the share of pixels that differ and
// the largest difference, writes an image of the differences (the second picture faded, each difference in red) and exits 0
// when the share is within --max-percent (default 0), else 1. Pictures of different sizes differ (exit 1).

import "core:fmt"
import "core:os"
import "wb:images"
import "wb:remote/api"

@(private)
load_picture_or_say :: proc(path: string) -> (api.Image, bool) {
	p, ok := api.load_image(path)
	if !ok { errln(fmt.tprintf("wren ctl diff: %s: %s", path, api.last_failure().message)) }
	return p, ok
}

cmd_diff :: proc(ctx: ^Context, args: []string) -> int {
	if len(args) != 2 { return usage("diff", "usage: diff <a.png> <b.png> [--tolerance n] [--out diff.png] [--max-percent p]") }
	pa, ok1 := load_picture_or_say(args[0])
	pb, ok2 := load_picture_or_say(args[1])
	if !ok1 || !ok2 { return EXIT_FAILED }
	a, aw, ah := pa.rgba, pa.width, pa.height
	b, bw, bh := pb.rgba, pb.width, pb.height
	if aw != bw || ah != bh {
		outln(fmt.tprintf("sizes differ: %dx%d against %dx%d", aw, ah, bw, bh))
		return EXIT_FAILED
	}
	count, worst, picture := api.diff_pictures(a, b, aw, ah, opt_int(&ctx.o, "tolerance", 0))
	percent := f64(count) * 100 / f64(aw * ah)
	if path := opt(&ctx.o, "out"); path != "" {
		png_bytes, ok := images.encode_rgba(picture, aw, ah, .Png, 0, false)
		if !ok || os.write_entire_file(abs_path(path), png_bytes) != nil { errln("wren ctl diff: cannot write the difference picture"); return EXIT_FAILED }
		delete(png_bytes)
	}
	outln(fmt.tprintf("%.4f %% of %d pixels differ (%d pixels, largest channel difference %d)", percent, aw * ah, count, worst))
	limit := 0.0
	if s := opt(&ctx.o, "max-percent"); s != "" { limit, _ = parse_float(s) }
	return percent <= limit ? EXIT_OK : EXIT_FAILED
}
