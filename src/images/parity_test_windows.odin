package images

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"

// The built-in decoders against WIC on every PNG, JPEG, GIF, BMP, ICO and TIFF of examples/site/images and
// examples/site/media: the same outcome, natural size, frame count, orientation and loop count, and the same pixels
// within PARITY_TOLERANCE per channel (JPEG's IDCT and the colour transforms round differently). A line per file says
// what differs: what the table of docs/portability.md was made from.

@(private = "file")
PARITY_TOLERANCE :: 24

@(test)
builtin_decoders_match_wic :: proc(t: ^testing.T) {
	files := 0
	for dir in ([]string{"examples/site/images", "examples/site/media"}) {
		infos, err := os.read_all_directory_by_path(dir, context.temp_allocator)
		if err != nil { continue }
		for fi in infos {
			if fi.type != .Regular { continue }
			data, rerr := os.read_entire_file(fi.fullpath, context.allocator)
			if rerr != nil { continue }
			defer delete(data)
			f := sniff_signature(data)
			if raster_code(f) == 0 { continue }
			files += 1
			parity_one(t, fi.name, data)
		}
	}
	testing.expectf(t, files >= 10, "fixtures found (%d)", files)
}

@(private = "file")
parity_one :: proc(t: ^testing.T, name: string, data: []byte) {
	sys := Decode_Options{limits = LIMITS_DEFAULT}
	sys.limits.system_decoders = true
	own := Decode_Options{limits = LIMITS_DEFAULT}
	a, ai, ae := decode_now(data, sys)
	defer image_destroy(a)
	b, bi, be := decode_now(data, own)
	defer image_destroy(b)
	diffs := strings.builder_make(context.temp_allocator)
	if ae != be { fmt.sbprintf(&diffs, " error %v / %v", ae, be) }
	if ae == .None && be == .None {
		if ai.width != bi.width || ai.height != bi.height { fmt.sbprintf(&diffs, " size %dx%d / %dx%d", ai.width, ai.height, bi.width, bi.height) }
		if ai.orientation != bi.orientation { fmt.sbprintf(&diffs, " orientation %d / %d", ai.orientation, bi.orientation) }
		if len(a.frames) != len(b.frames) { fmt.sbprintf(&diffs, " frames %d / %d", len(a.frames), len(b.frames)) }
		if ai.animated && ai.plays != bi.plays { fmt.sbprintf(&diffs, " plays %d / %d", ai.plays, bi.plays) }
		if a.width == b.width && a.height == b.height && len(a.frames) == len(b.frames) {
			worst := 0
			for fr, i in a.frames {
				pa, pb := fr.pixels, b.frames[i].pixels
				for k in 0 ..< min(len(pa), len(pb)) {
					// fully transparent pixels may keep any colour
					if pa[k - k % 4 + 3] == 0 && pb[k - k % 4 + 3] == 0 { continue }
					worst = max(worst, abs(int(pa[k]) - int(pb[k])))
				}
				if fr.delay_ms != b.frames[i].delay_ms { fmt.sbprintf(&diffs, " delay[%d] %d / %d", i, fr.delay_ms, b.frames[i].delay_ms) }
			}
			if worst > PARITY_TOLERANCE { fmt.sbprintf(&diffs, " pixels differ by up to %d", worst) }
		}
	}
	d := strings.to_string(diffs)
	if d == "" {
		fmt.printfln("parity %-28s %s %dx%d, %d frame(s): same", name, format_name(bi.format), bi.width, bi.height, b != nil ? len(b.frames) : 0)
	} else {
		fmt.printfln("parity %-28s %s: WIC / built-in:%s", name, format_name(bi.format), d)
	}
	testing.expectf(t, d == "", "%s: WIC / built-in:%s", name, d)
}
