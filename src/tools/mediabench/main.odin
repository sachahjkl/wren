// Decoding times of image files on one thread (the work one decoding thread does per image), whatever the format:
//   mediabench.exe FILE... [-n RUNS] [-w WIDTH -h HEIGHT]
// Prints, per file: format, natural size, best and mean time of a full decode (SVG: a render at its natural size, or at
// -w x -h), and of a probe (headers only).
package mediabench

import _ "wb:tools/crashtrace"   // a crash prints its symbolized stack

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strconv"
import "core:time"
import "wb:images"

main :: proc() {
	files := make([dynamic]string)
	runs, w, h := 10, 0, 0
	for i := 1; i < len(os.args); i += 1 {
		a := os.args[i]
		switch a {
		case "-n": i += 1; runs, _ = strconv.parse_int(os.args[i])
		case "-w": i += 1; w, _ = strconv.parse_int(os.args[i])
		case "-h": i += 1; h, _ = strconv.parse_int(os.args[i])
		case: append(&files, a)
		}
	}
	c: images.Codec_Context
	if !images.codec_init(&c) { fmt.eprintln("WIC unavailable"); os.exit(1) }
	defer images.codec_destroy(&c)
	fmt.printfln("%-24s %-5s %-11s %9s %9s %9s", "file", "fmt", "size", "best ms", "mean ms", "probe ms")
	for f in files {
		data, err := os.read_entire_file(f, context.allocator)
		if err != nil { fmt.eprintln("cannot read", f); continue }
		o := images.Decode_Options{limits = images.LIMITS_DEFAULT, target_w = w, target_h = h, first_frame_only = true}
		best, total := max(f64), 0.0
		info: images.Info
		e: images.Error
		for _ in 0 ..< max(runs, 1) {
			t := time.tick_now()
			img: ^images.Image
			img, info, e = images.decode_with(&c, data, o)
			ms := time.duration_milliseconds(time.tick_since(t))
			images.image_destroy(img)
			best = min(best, ms)
			total += ms
		}
		t := time.tick_now()
		_, _ = images.probe_with(&c, data, o)
		pms := time.duration_milliseconds(time.tick_since(t))
		if e != .None { fmt.printfln("%-24s error %v", filepath.base(f), e); continue }
		fmt.printfln("%-24s %-5s %-11s %9.2f %9.2f %9.2f", filepath.base(f), images.format_name(info.format), fmt.tprintf("%vx%v", info.width, info.height), best, total / f64(max(runs, 1)), pms)
		delete(data)
	}
}
