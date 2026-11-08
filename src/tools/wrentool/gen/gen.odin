// Package gen: what is made from something else and committed, or read by a person: tables, fixtures, the documentation site, lists.
//   wrentool gen psl | unicode [-Force] | idna | media-fixtures | video-fixtures | perf-media [-Force] | rust-crates [-Check]
//   wrentool docs [-Check] [-NoBuild] [-ChartUpdate]
//   wrentool license keygen|pubkey|issue|verify ...         (src/tools/license)
//   wrentool i18n [-Missing] [-Json out.json]
//   wrentool portability [-Target t] [-Only a,b] [-Csv f] [-Expect file]
//   wrentool engine test262 [-Filter d] [-Stride n] [-Jobs n] [-NoBuild] | rx-diff [-Seed n] [-Fuzz n] [-NoC]
//   wrentool desktop <program> [arguments]                  a command on a Windows desktop of its own
//   wrentool trace start | stop [-Out file.etl] | cancel   a WPR recording with Wren's profile (trace.odin)
package gen

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "core:time"
import "wb:base"
import "wb:tools/tooling"

EXIT_USAGE :: 2

run_gen :: proc(args: []string) -> int {
	if len(args) == 0 { fmt.eprintln("wrentool gen psl | unicode | idna | media-fixtures | video-fixtures | perf-media | rust-crates"); return EXIT_USAGE }
	rest := args[1:]
	switch args[0] {
	case "psl": return gen_psl()
	case "unicode": return gen_unicode(rest)
	case "idna": return gen_idna(rest)
	case "media-fixtures": return gen_media_fixtures()
	case "video-fixtures": return gen_video_fixtures()
	case "perf-media": return gen_perf_media(rest)
	case "rust-crates": return gen_rust_crates(rest)
	}
	fmt.eprintfln("nothing to generate called %s", args[0])
	return EXIT_USAGE
}

////////////////////////////////
// The Public Suffix List

PSL_URL :: "https://publicsuffix.org/list/public_suffix_list.dat"
PSL_FILE :: "src/url/public_suffix_list.dat"

// (embedded with #load: rebuild afterwards, and run the url tests)
gen_psl :: proc() -> int {
	if tooling.run({command = {"curl", "-fsSL", "-o", PSL_FILE, PSL_URL}}) != 0 { fmt.eprintln("the download failed"); return 1 }
	data, _ := os.read_entire_file(PSL_FILE, context.temp_allocator)
	for line in strings.split_lines(string(data), context.temp_allocator) {
		if strings.has_prefix(line, "// VERSION") { fmt.printfln("updated: %s", strings.trim_right(line, "\r")); break }
	}
	return 0
}

////////////////////////////////
// The Unicode tables

UNICODE_VERSION :: "17.0.0"
UNICODE_BASE :: "https://www.unicode.org/Public/" + UNICODE_VERSION
UNICODE_CACHE :: "build/ucd/" + UNICODE_VERSION
UNICODE_TABLES :: "src/engine/unicode/tables_generated.odin"
UNICODE_GEN :: "build/unicode_gen" + tooling.EXE_SUFFIX
// A file of the Character Database: where it is under the version's folder, where it is cached, its pinned digest. A download whose hash does not match is deleted: the tables are reproducible from the authoritative source.
Ucd_File :: struct { url, cached, sha: string }
UCD_FILES := []Ucd_File{
	{"ucd/UnicodeData.txt", "UnicodeData.txt", "2e1efc1dcb59c575eedf5ccae60f95229f706ee6d031835247d843c11d96470c"},
	{"ucd/DerivedCoreProperties.txt", "DerivedCoreProperties.txt", "24c7fed1195c482faaefd5c1e7eb821c5ee1fb6de07ecdbaa64b56a99da22c08"},
	{"ucd/PropList.txt", "PropList.txt", "130dcddcaadaf071008bdfce1e7743e04fdfbc910886f017d9f9ac931d8c64dd"},
	{"ucd/Scripts.txt", "Scripts.txt", "9f5e50d3abaee7d6ce09480f325c706f485ae3240912527e651954d2d6b035bf"},
	{"ucd/ScriptExtensions.txt", "ScriptExtensions.txt", "ec2107e58825a1586acee8e0911ce18260394ac8b87e535ca325f1ccbeb06bc6"},
	{"ucd/CaseFolding.txt", "CaseFolding.txt", "ff8d8fefbf123574205085d6714c36149eb946d717a0c585c27f0f4ef58c4183"},
	{"ucd/SpecialCasing.txt", "SpecialCasing.txt", "efc25faf19de21b92c1194c111c932e03d2a5eaf18194e33f1156e96de4c9588"},
	{"ucd/DerivedNormalizationProps.txt", "DerivedNormalizationProps.txt", "71fd6a206a2c0cdd41feb6b7f656aa31091db45e9cedc926985d718397f9e488"},
	{"ucd/extracted/DerivedGeneralCategory.txt", "extracted/DerivedGeneralCategory.txt", "d62e5bab70ca74f099343f71224fa051cb1fdd61a1ab45c0488c44cfc0b6102e"},
	{"ucd/extracted/DerivedJoiningType.txt", "extracted/DerivedJoiningType.txt", "f39ebe974825d6736aee15582250307aa532b2cfab3caf3f86bd23fddc9c5c4d"},
	{"ucd/extracted/DerivedBidiClass.txt", "extracted/DerivedBidiClass.txt", "4867b4b7f0731ed1bfcd34cc6251211ff1542541fce0734b6fbda139ee80b3a4"},
	{"ucd/emoji/emoji-data.txt", "emoji/emoji-data.txt", "2cb2bb9455cda83e8481541ecf5b6dfda66a3bb89efa3fa7c5297eccf607b72b"},
	{"emoji/emoji-sequences.txt", "emoji-seq/emoji-sequences.txt", "12cc8267dc33cbd11ed32bcf6fc5dc2ad9c7a77bae1bdfba2f41b1b9b3ead8dd"},
	{"emoji/emoji-zwj-sequences.txt", "emoji-seq/emoji-zwj-sequences.txt", "5b25441daed2322b068c5e70cda522946a4f0274df864445a1965a92e5fc5cad"},
}

gen_unicode :: proc(args: []string) -> int {
	f, ok := tooling.parse_flags(args, "-Force")
	if !ok { return EXIT_USAGE }
	for u in UCD_FILES {
		path := fmt.tprintf("%s/%s", UNICODE_CACHE, u.cached)
		if tooling.flag_has(f, "-Force") { _ = os.remove(path) }
		if !tooling.download_pinned(fmt.tprintf("%s/%s", UNICODE_BASE, u.url), path, u.sha) { return 1 }
	}
	_ = os.write_entire_file(fmt.tprintf("%s/VERSION", UNICODE_CACHE), UNICODE_VERSION)   // (the generator stamps it into the output)
	if tooling.run({command = {tooling.odin_program(), "build", "src/engine/unicode/gen", "-out:" + UNICODE_GEN, "-o:speed"}}) != 0 { return 1 }
	if tooling.run({command = {UNICODE_GEN, UNICODE_CACHE, UNICODE_TABLES}}) != 0 { return 1 }
	fmt.printfln("wrote %s", UNICODE_TABLES)
	return 0
}

////////////////////////////////
// Fixtures (committed: the tests need none of these programs)

MEDIA_OUT :: "examples/site/media"
VIDEO_OUT :: "examples/site/media/video"
FFMPEG_QUIET := []string{"ffmpeg", "-hide_banner", "-loglevel", "error", "-y"}
FRAGMENTED := []string{"-c", "copy", "-movflags", "frag_keyframe+empty_moov+default_base_moof+separate_moof"}
// The AVIF box whose colour primaries and transfer are rewritten in p3.avif: nclx, primaries 12, sRGB transfer.
NCLX_P3 := []u8{0, 12, 0, 13}

@(private) ffmpeg :: proc(args: ..[]string) -> bool {
	cmd := make([dynamic]string, context.temp_allocator)
	append(&cmd, ..FFMPEG_QUIET)
	for a in args { append(&cmd, ..a) }
	return tooling.run({command = cmd[:]}) == 0
}

@(private) magick :: proc(args: ..string) -> bool {
	cmd := make([dynamic]string, context.temp_allocator)
	append(&cmd, "magick")
	append(&cmd, ..args)
	return tooling.run({command = cmd[:]}) == 0
}

@(private) in_media :: proc(name: string) -> string { return fmt.tprintf("%s/%s", MEDIA_OUT, name) }
@(private) in_video :: proc(name: string) -> string { return fmt.tprintf("%s/%s", VIDEO_OUT, name) }

// The AVIF, WebP and colour-managed files of examples/site/media. Needs ImageMagick 7 (libheif + libaom, libwebp) and FFmpeg (libaom-av1). The SVG files there are written by hand. "quad": 32 x 16,
// quadrants red, lime, blue, white; "a" variants have the bottom right quadrant at alpha 128.
gen_media_fixtures :: proc() -> int {
	tmp := fmt.tprintf("%s/wren-media-fixtures", base.temp_dir(context.temp_allocator))
	_ = os.make_directory_all(tmp)
	_ = os.make_directory_all(MEDIA_OUT)
	defer base.remove_tree(tmp)
	in_tmp :: proc(tmp, name: string) -> string { return fmt.tprintf("%s/%s", tmp, name) }
	quad, quada, mid := in_tmp(tmp, "quad.png"), in_tmp(tmp, "quada.png"), in_tmp(tmp, "mid.png")
	ok := magick("-size", "16x8", "xc:red", "xc:lime", "+append", "(", "-size", "16x8", "xc:blue", "xc:white", "+append", ")", "-append", fmt.tprintf("PNG24:%s", quad)) &&
		magick(quad, "(", "-size", "32x16", "xc:white", "-fill", "gray50", "-draw", "rectangle 16,8 31,15", ")", "-alpha", "off", "-compose", "CopyOpacity", "-composite", fmt.tprintf("PNG32:%s", quada)) &&
		// AVIF: 8 bits with alpha, 10 bits with alpha, 4:4:4 opaque
		magick(quada, "-quality", "92", "-depth", "8", in_media("quad8a.avif")) &&
		magick(quada, "-quality", "92", "-depth", "10", in_media("quad10a.avif")) &&
		magick(quad, "-quality", "95", "-define", "heic:chroma=444", in_media("quad444.avif")) &&
		// orientation: libheif writes irot / imir from the EXIF orientation it is given
		magick(quad, "-orient", "RightTop", "-quality", "95", in_media("rot90.avif")) &&
		magick(quad, "-orient", "TopRight", "-quality", "95", in_media("mirror.avif")) &&
		magick(quad, "-orient", "RightBottom", "-quality", "95", in_media("transverse.avif")) &&
		magick("-size", "16x16", "xc:rgb(40,160,60)", fmt.tprintf("PNG24:%s", mid)) &&
		magick(mid, "-quality", "100", "-define", "heic:chroma=444", in_media("p3.avif"))
	if !ok { return 1 }
	// Display P3: encoded as BT.709, then the colr box rewritten in place
	p3, err := os.read_entire_file(in_media("p3.avif"), context.temp_allocator)
	at := err == nil ? strings.index(string(p3), "nclx") : -1
	if at < 0 { fmt.eprintln("p3.avif: no nclx colr box"); return 1 }
	copy(p3[at + len("nclx"):], NCLX_P3)
	_ = os.write_entire_file(in_media("p3.avif"), p3)
	// animation: three 10 x 10 frames, 200 ms each; WebP: lossy, lossless with alpha, animation (delays 100 / 200 / 300 ms, 3 plays)
	colors := []string{"red", "blue", "lime"}
	for c, i in colors {
		if !magick("-size", "10x10", fmt.tprintf("xc:%s", c), fmt.tprintf("PNG24:%s", in_tmp(tmp, fmt.tprintf("g_%d.png", i + 1)))) { return 1 }
	}
	ok = ffmpeg({"-framerate", "5", "-i", in_tmp(tmp, "g_%d.png"), "-c:v", "libaom-av1", "-crf", "10", "-pix_fmt", "yuv420p", in_media("anim.avif")}) &&
		magick(quad, "-quality", "90", in_media("quad-lossy.webp")) &&
		magick(quada, "-define", "webp:lossless=true", in_media("quad-lossless.webp")) &&
		magick(quada, "-quality", "90", "-define", "webp:alpha-quality=100", in_media("quad-lossy-alpha.webp")) &&
		magick("-delay", "10", in_tmp(tmp, "g_1.png"), "-delay", "20", in_tmp(tmp, "g_2.png"), "-delay", "30", in_tmp(tmp, "g_3.png"), "-loop", "3", "-define", "webp:lossless=true", in_media("anim.webp"))
	if !ok { return 1 }
	// ICC: the Adobe RGB (1998) profile Windows ships, embedded in a JPEG and a PNG
	windir, _ := os.lookup_env("WINDIR", context.temp_allocator)
	adobe := fmt.tprintf("%s/System32/spool/drivers/color/AdobeRGB1998.icc", windir)
	if os.exists(adobe) {
		if !magick(mid, "-profile", adobe, "-quality", "95", in_media("adobe.jpg")) || !magick(mid, "-profile", adobe, fmt.tprintf("PNG24:%s", in_media("adobe.png"))) { return 1 }
	}
	fmt.printfln("written in %s", MEDIA_OUT)
	return 0
}

// The video files of examples/site/media/video. Needs FFmpeg (libx264, libsvtav1, libvpx-vp9, libopus, aac). clip: FFmpeg's testsrc2, H.264 main + AAC, 320x180, 24 fps, 4 s, the tone steps every second.
gen_video_fixtures :: proc() -> int {
	_ = os.make_directory_all(VIDEO_OUT)
	clip_mp4, clip_webm := in_video("clip.mp4"), in_video("clip.webm")
	src := []string{"-f", "lavfi", "-i", "testsrc2=s=320x180:r=24:d=4", "-f", "lavfi", "-i", "aevalsrc=sin(2*PI*t*(440+floor(t)*110))*0.3|sin(2*PI*t*(440+floor(t)*110))*0.3:s=44100:d=4"}
	enc := []string{"-c:v", "libx264", "-profile:v", "main", "-preset", "medium", "-bf", "2", "-g", "24", "-pix_fmt", "yuv420p", "-crf", "28", "-c:a", "aac", "-b:a", "64k", "-shortest"}
	quad_filter := "color=c=red:s=32x16:d=1,format=yuv420p[a];color=c=lime:s=32x16:d=1,format=yuv420p[b];color=c=blue:s=32x16:d=1,format=yuv420p[c];color=c=white:s=32x16:d=1,format=yuv420p[d];[a][b][c][d]xstack=inputs=4:layout=0_0|w0_0|0_h0|w0_h0"
	ok := ffmpeg(src, enc, {"-movflags", "+faststart", clip_mp4}) &&
		ffmpeg(src, enc, {in_video("clip_moov_end.mp4")}) &&
		ffmpeg({"-i", clip_mp4}, FRAGMENTED, {in_video("clip_frag.mp4")}) &&
		ffmpeg({"-i", clip_mp4, "-c:v", "libsvtav1", "-preset", "10", "-crf", "40", "-g", "24", "-c:a", "libopus", "-b:a", "48k", clip_webm}) &&
		ffmpeg({"-i", clip_mp4, "-c:v", "libvpx-vp9", "-b:v", "200k", "-g", "24", "-deadline", "realtime", "-cpu-used", "8", "-c:a", "libopus", "-b:a", "48k", in_video("clip_vp9.webm")}) &&
		ffmpeg({"-i", clip_mp4, "-vn", "-c:a", "libopus", "-b:a", "48k", in_video("tone_opus.webm")}) &&
		ffmpeg({"-f", "lavfi", "-i", "testsrc2=s=160x90:r=24:d=1", "-c:v", "libvpx", "-b:v", "100k", "-g", "12", "-deadline", "realtime", "-cpu-used", "8", "-an", in_video("clip_vp8.webm")}) &&
		ffmpeg({"-i", clip_webm, "-an", "-c", "copy", in_video("clip_av1_video.webm")}) &&
		ffmpeg({"-i", clip_webm, "-c", "copy", "-live", "1", "-f", "webm", in_video("clip_live.webm")}) &&
		ffmpeg({"-filter_complex", quad_filter, "-r", "24", "-c:v", "libx264", "-preset", "slow", "-crf", "10", "-pix_fmt", "yuv420p", "-colorspace", "bt709", "-color_primaries", "bt709", "-color_trc", "bt709", "-color_range", "tv", "-movflags", "+faststart", "-an", in_video("quad.mp4")}) &&
		ffmpeg({"-f", "lavfi", "-i", "sine=frequency=440:duration=2", "-c:a", "aac", "-b:a", "64k", "-movflags", "+faststart", in_video("tone.m4a")})
	if !ok { return 1 }
	fmt.printfln("written in %s", VIDEO_OUT)
	return 0
}

// The 1080p files of the yt_* scenarios of `bench perf` (not committed: 100 MB). For each, _frag (one fragmented file), _v and _a (video and audio alone, fragmented: what a DASH player appends).
gen_perf_media :: proc(args: []string) -> int {
	f, ok := tooling.parse_flags(args, "-Force")
	if !ok { return EXIT_USAGE }
	_ = os.make_directory_all(VIDEO_OUT)
	audio := "aevalsrc=0.2*sin(2*PI*t*440)|0.2*sin(2*PI*t*554):s=48000:d=30"
	h264 := []string{"-c:v", "libx264", "-profile:v", "high", "-level", "4.2", "-preset", "veryfast", "-crf", "27", "-pix_fmt", "yuv420p"}
	Clip :: struct { name, video: string, codec, codec2: []string }
	clips := []Clip{
		{"perf_h264_1080p60", "testsrc2=s=1920x1080:r=60:d=30,noise=alls=5:allf=t", h264, {"-g", "120", "-bf", "2"}},
		{"perf_av1_1080p30", "testsrc2=s=1920x1080:r=30:d=30,noise=alls=5:allf=t", {"-c:v", "libsvtav1", "-preset", "9", "-crf", "38", "-g", "120", "-pix_fmt", "yuv420p"}, nil},
		{"perf_short_1080x1920", "testsrc2=s=1080x1920:r=30:d=30,noise=alls=5:allf=t", h264, {"-g", "60", "-bf", "2"}},
	}
	for c in clips {
		mp4 := in_video(fmt.tprintf("%s.mp4", c.name))
		if os.exists(mp4) && !tooling.flag_has(f, "-Force") { fmt.printfln("%s exists", c.name); continue }
		good := ffmpeg({"-f", "lavfi", "-i", c.video, "-f", "lavfi", "-i", audio}, c.codec, c.codec2, {"-c:a", "aac", "-b:a", "128k", "-shortest", "-movflags", "+faststart", mp4}) &&
			ffmpeg({"-i", mp4}, FRAGMENTED, {in_video(fmt.tprintf("%s_frag.mp4", c.name))}) &&
			ffmpeg({"-i", mp4, "-an"}, FRAGMENTED, {in_video(fmt.tprintf("%s_v.mp4", c.name))}) &&
			ffmpeg({"-i", mp4, "-vn"}, FRAGMENTED, {in_video(fmt.tprintf("%s_a.mp4", c.name))})
		if !good { return 1 }
		fmt.printfln("made %s", c.name)
	}
	return 0
}

////////////////////////////////
// The list of Rust crates

RUST_CRATES :: "native/rust-crates.txt"
RUST_CRATES_HEAD :: "Rust crates of native/ (wren_native.lib, linked into wren.exe), from Cargo.lock: the whole graph, with the\nbuild-time and test-only crates (they are not in wren.exe).\nEach crate's license text is in its source package (crates.io) or repository.\n\n"

// Every Rust crate linked into the library, with its license and source, from cargo metadata of the locked graph (all features: the release's text backend is an optional one). wren.exe embeds the file (about:licenses).
rust_crates_text :: proc() -> (text: string, ok: bool) {
	text_out, code := tooling.capture({"cargo", "metadata", "--quiet", "--manifest-path", "native/Cargo.toml", "--format-version", "1", "--locked", "--all-features"}, allocator = context.temp_allocator)
	if code != 0 { fmt.eprintln("cargo metadata failed"); return "", false }
	data := transmute([]u8)text_out[max(strings.index_byte(text_out, '{'), 0):]
	v, perr := json.parse(data, allocator = context.temp_allocator)
	if perr != nil { fmt.eprintln("cargo metadata: not JSON"); return "", false }
	root := v.(json.Object) or_else nil
	own := make(map[string]bool, context.temp_allocator)
	members, _ := root["workspace_members"].(json.Array)
	for m in members { own[m.(json.String) or_else ""] = true }
	own_names := make(map[string]bool, context.temp_allocator)
	packages, _ := root["packages"].(json.Array)
	Line :: struct { name, version, text: string }
	lines := make([dynamic]Line, context.temp_allocator)
	for p in packages {
		o := p.(json.Object) or_else nil
		if own[o["id"].(json.String) or_else ""] { own_names[o["name"].(json.String) or_else ""] = true }
	}
	for p in packages {
		o := p.(json.Object) or_else nil
		name := o["name"].(json.String) or_else ""
		if own_names[name] { continue }
		version := o["version"].(json.String) or_else ""
		license := o["license"].(json.String) or_else ""
		repository := o["repository"].(json.String) or_else ""
		if repository == "" { repository = fmt.tprintf("https://crates.io/crates/%s", name) }
		append(&lines, Line{name, version, fmt.tprintf("%s %s  [%s]  %s", name, version, license, repository)})
	}
	slice.sort_by(lines[:], proc(a, b: Line) -> bool { return a.name != b.name ? a.name < b.name : a.version < b.version })
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, RUST_CRATES_HEAD)
	for l in lines { fmt.sbprintln(&b, l.text) }
	return strings.to_string(b), true
}

// Is the file what Cargo.lock says? (what a package checks)
rust_crates_up_to_date :: proc() -> bool {
	text, ok := rust_crates_text()
	if !ok { return false }
	have, err := os.read_entire_file(RUST_CRATES, context.temp_allocator)
	normal, _ := strings.replace_all(string(have), "\r\n", "\n", context.temp_allocator)
	if err != nil || normal != text { fmt.eprintfln("%s is out of date: run wrentool gen rust-crates and commit it", RUST_CRATES); return false }
	return true
}

gen_rust_crates :: proc(args: []string) -> int {
	f, ok := tooling.parse_flags(args, "-Check")
	if !ok { return EXIT_USAGE }
	if tooling.flag_has(f, "-Check") {
		if !rust_crates_up_to_date() { return 1 }
		fmt.println("rust-crates.txt is up to date")
		return 0
	}
	text, good := rust_crates_text()
	if !good { return 1 }
	_ = os.write_entire_file(RUST_CRATES, text)
	fmt.printfln("wrote %s", RUST_CRATES)
	return 0
}

////////////////////////////////
// A tool of src/tools that stays a program of its own: built when its sources are newer, run with the arguments

// `sources`: what it depends on beside its own folder.
@(private)
tool_run :: proc(dir, exe: string, also: []string, args: []string) -> int {
	built, has := tooling.modified(exe)
	stale := !has
	if has {
		always :: proc(path: string) -> bool { return strings.has_suffix(path, ".odin") && !strings.has_suffix(path, "_test.odin") }
		stale = tooling.any_newer(dir, built, always)
		for a in also { stale = stale || tooling.any_newer(a, built, always) }
	}
	if stale && tooling.run({command = {tooling.odin_program(), "build", dir, "-collection:wb=src", "-vet", fmt.tprintf("-out:%s", exe)}}) != 0 { return 1 }
	cmd := make([dynamic]string, context.temp_allocator)
	append(&cmd, exe)
	append(&cmd, ..args)
	return tooling.run({command = cmd[:]})
}

// Wren's licences (docs/licence.md): the signing key pair and the licences issued. Offline.
run_license :: proc(args: []string) -> int { return tool_run("src/tools/license", "build/license" + tooling.EXE_SUFFIX, {"src/license"}, args) }

// The documentation site: docs/*.md to site/docs, generated by src/tools/docsite (deterministic: -Check verifies it without writing), every internal link and anchor checked.
run_docs :: proc(args: []string) -> int {
	f, ok := tooling.parse_flags(args, "-Check -NoBuild -ChartUpdate")
	if !ok { return EXIT_USAGE }
	pass := make([dynamic]string, context.temp_allocator)
	if tooling.flag_has(f, "-Check") { append(&pass, "-check") }
	if tooling.flag_has(f, "-ChartUpdate") { append(&pass, "-chart-update") }
	exe := "build/docsite" + tooling.EXE_SUFFIX
	if tooling.flag_has(f, "-NoBuild") {
		cmd := make([dynamic]string, context.temp_allocator)
		append(&cmd, exe)
		append(&cmd, ..pass[:])
		return tooling.run({command = cmd[:]})
	}
	return tool_run("src/tools/docsite", exe, {"src/base"}, pass[:])
}

////////////////////////////////
// What the code says to translate

I18N_UI_CALLS := []string{"label", "button", "text", "checkbox", "toggle", "menu_item", "menu_heading", "tab", "tooltip", "heading", "title", "set_tooltip"}

// A string literal at `at`: its text, and what comes after. ok false: no literal there.
@(private)
literal_at :: proc(s: string, at: int) -> (text: string, after: int, ok: bool) {
	i := at
	for i < len(s) && (s[i] == ' ' || s[i] == '\t') { i += 1 }
	if i >= len(s) || s[i] != '"' { return "", at, false }
	j := i + 1
	for j < len(s) && s[j] != '"' { j += 1 }
	if j >= len(s) { return "", at, false }
	return s[i + 1:j], j + 1, true
}

@(private) ident_char :: proc(c: u8) -> bool { return c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9' || c == '_' }

I18n_Text :: struct { text, ctx, plural, file: string, line: int }

// tr("text"), tr("context", "text"), tr(count, "one", "other"): a pattern on the call sites, not a parse (keep each text one literal in the call).
i18n_calls :: proc(line: string, file: string, line_no: int, into: ^[dynamic]I18n_Text) {
	from := 0
	for {
		i := strings.index(line[from:], "tr(")
		if i < 0 { return }
		at := from + i
		from = at + len("tr(")
		if at > 0 && ident_char(line[at - 1]) { continue }
		a, after, has_first := literal_at(line, from)
		if has_first {
			if after < len(line) && line[after] == ',' {
				if b, _, has_second := literal_at(line, after + 1); has_second { append(into, I18n_Text{b, a, "", file, line_no}); continue }
			}
			append(into, I18n_Text{a, "", "", file, line_no})
			continue
		}
		comma := from
		for comma < len(line) && (ident_char(line[comma]) || line[comma] == '.' || line[comma] == ' ') { comma += 1 }
		if comma < len(line) && line[comma] == ',' {
			one, after_one, has_one := literal_at(line, comma + 1)
			if has_one && after_one < len(line) && line[after_one] == ',' {
				other, _, has_other := literal_at(line, after_one + 1)
				if has_other { append(into, I18n_Text{one, "", other, file, line_no}) }
			}
		}
	}
}

// A user interface call with a literal text in a line that has no tr: its text.
i18n_missing :: proc(line: string) -> (text: string, found: bool) {
	if strings.contains(line, "tr(") { return "", false }
	from := 0
	for {
		i := strings.index(line[from:], "ui.")
		if i < 0 { return "", false }
		at := from + i + len("ui.")
		from = at
		end := at
		for end < len(line) && ident_char(line[end]) { end += 1 }
		if end >= len(line) || line[end] != '(' { continue }
		for name in I18N_UI_CALLS {
			if strings.has_prefix(line[at:end], name) {
				if t, _, ok := literal_at(line, end + 1); ok { return t, true }
			}
		}
	}
}

@(private)
odin_sources :: proc(dir: string, into: ^[dynamic]string) {
	entries, err := os.read_all_directory_by_path(dir, context.temp_allocator)
	if err != nil { return }
	for e in entries {
		if e.type == .Directory { if e.name != "i18n" { odin_sources(e.fullpath, into) } ; continue }
		if strings.has_suffix(e.name, ".odin") && !strings.has_suffix(e.name, "_test.odin") { append(into, e.fullpath) }
	}
}

// The texts the code passes to the i18n package; -Missing: the interface's strings that do not go through it yet; -Json: { text, context, file, line }.
run_i18n :: proc(args: []string) -> int {
	f, ok := tooling.parse_flags(args, "-Missing -Json=")
	if !ok { return EXIT_USAGE }
	files := make([dynamic]string, context.temp_allocator)
	odin_sources("src", &files)
	slice.sort(files[:])
	found := make([dynamic]I18n_Text, context.temp_allocator)
	missing := 0
	for file in files {
		data, err := os.read_entire_file(file, context.temp_allocator)
		if err != nil { continue }
		for line, i in strings.split_lines(string(data), context.temp_allocator) {
			if tooling.flag_has(f, "-Missing") {
				if t, is_missing := i18n_missing(line); is_missing { fmt.printfln("%s:%d: %s", file, i + 1, t); missing += 1 }
			} else {
				i18n_calls(line, file, i + 1, &found)
			}
		}
	}
	if tooling.flag_has(f, "-Missing") { fmt.printfln("%d interface texts bypass tr", missing); return 0 }
	if path := tooling.flag(f, "-Json"); path != "" {
		b := strings.builder_make(context.temp_allocator)
		strings.write_string(&b, "[\n")
		for t, i in found {
			fmt.sbprintf(&b, "%s  {{\"text\": %q, \"context\": %q, \"plural\": %q, \"file\": %q, \"line\": %d}}", i > 0 ? ",\n" : "", t.text, t.ctx, t.plural, t.file, t.line)
		}
		strings.write_string(&b, "\n]\n")
		_ = os.write_entire_file(path, strings.to_string(b))
		fmt.printfln("wrote %s (%d texts)", path, len(found))
		return 0
	}
	last := ""
	for t in found {
		if t.file != last { fmt.printfln("%s", t.file); last = t.file }
		fmt.printfln("  %d: %s", t.line, t.text)
	}
	fmt.printfln("%d texts", len(found))
	return 0
}

////////////////////////////////
// Portability

PORTABILITY_TARGET :: "linux_amd64"
PORTABILITY_FLAGS := []string{"-no-entry-point", "-collection:wb=src", "-collection:toolkit=ext/gui_toolkit/src", "-max-error-count:2000", "-define:FONT_NATIVE_LINK=false", "-define:A11Y_NATIVE_LINK=false"}

@(private)
packages_under :: proc(dir: string, into: ^[dynamic]string) {
	entries, err := os.read_all_directory_by_path(dir, context.temp_allocator)
	if err != nil { return }
	has := false
	for e in entries {
		if e.type == .Directory {
			if e.name != ".git" && e.name != "build" && e.name != "target" && e.name != "node_modules" { packages_under(fmt.tprintf("%s/%s", dir, e.name), into) }
		} else if strings.has_suffix(e.name, ".odin") { has = true }
	}
	if has { append(into, dir) }
}

// Every Odin package of Wren and of the toolkit checked for another target (odin check): a table of what passes, with the errors in a package's own files. -Expect file: a package it lists that does not pass fails.
run_portability :: proc(args: []string) -> int {
	f, ok := tooling.parse_flags(args, "-Target= -Only= -Csv= -Expect=")
	if !ok { return EXIT_USAGE }
	target := tooling.flag(f, "-Target", PORTABILITY_TARGET)
	packages := make([dynamic]string, context.temp_allocator)
	packages_under("src", &packages)
	packages_under("ext/gui_toolkit", &packages)
	only := tooling.flag_list(f, "-Only")
	if path := tooling.flag(f, "-Expect"); path != "" {
		data, _ := os.read_entire_file(path, context.temp_allocator)
		list := make([dynamic]string, context.temp_allocator)
		for l in strings.split_lines(string(data), context.temp_allocator) {
			line := strings.trim_space(l)
			if line != "" && !strings.has_prefix(line, "#") { append(&list, line) }
		}
		only = list[:]
	}
	csv := strings.builder_make(context.temp_allocator)
	strings.write_string(&csv, "package,status,own,total\n")
	passed, count, failed := 0, 0, 0
	for p in packages {
		if len(only) > 0 && !slice.contains(only, p) { continue }
		cmd := make([dynamic]string, context.temp_allocator)
		append(&cmd, tooling.odin_program(), "check", p, fmt.tprintf("-target:%s", target))
		append(&cmd, ..PORTABILITY_FLAGS)
		text, code := tooling.capture(cmd[:], allocator = context.temp_allocator)
		own, total := 0, 0
		for line in strings.split_lines(text, context.temp_allocator) {
			if !strings.contains(line, ") Error:") && !strings.contains(line, ") Syntax Error:") { continue }
			total += 1
			normal, _ := strings.replace_all(line, "\\", "/", context.temp_allocator)
			paren := strings.index_byte(normal, '(')
			if paren > 0 && strings.has_suffix(filepath.dir(normal[:paren]), p) { own += 1 }
		}
		status := code == 0 ? "ok" : own > 0 ? "own" : total > 0 ? "deps" : "fail"
		fmt.printfln("%-48s %-5s own %d, total %d", p, status, own, total)
		fmt.sbprintfln(&csv, "%s,%s,%d,%d", p, status, own, total)
		count += 1
		if code == 0 { passed += 1 } else { failed += 1 }
	}
	fmt.printfln("%d / %d packages pass odin check for %s", passed, count, target)
	if path := tooling.flag(f, "-Csv"); path != "" { _ = os.write_entire_file(path, strings.to_string(csv)) }
	return tooling.flag_has(f, "-Expect") && failed > 0 ? 1 : 0
}

////////////////////////////////
// The engines' own tools

JUDGE_EXE :: "build/jsrt_judge" + tooling.EXE_SUFFIX
JUDGE_STACK :: "-extra-linker-flags:/STACK:67108864"   // the judge lets the engine use 48 MiB of it (deep recursion tests)
TEST262_RUN :: "build/test262/run"
RXDIFF_DIR :: "build/cref"
RXDIFF_STACK :: "-extra-linker-flags:/STACK:268435456"
RXDIFF_SEED :: 12345
RXDIFF_FUZZ :: 20000
RXDIFF_QJS :: "build/js/src/quickjs-0.17.0"
RXDIFF_FILES := []string{"libregexp.c", "libregexp.h", "libregexp-opcode.h", "libunicode.c", "libunicode.h", "libunicode-table.h", "cutils.h"}

run_engine :: proc(args: []string) -> int {
	if len(args) == 0 { fmt.eprintln("wrentool engine test262 [-Filter d] [-Stride n] [-Jobs n] [-NoBuild] | rx-diff [-Seed n] [-Fuzz n] [-NoC]"); return EXIT_USAGE }
	switch args[0] {
	case "test262": return engine_test262(args[1:])
	case "rx-diff": return engine_rx_diff(args[1:])
	}
	fmt.eprintfln("no engine tool %s", args[0])
	return EXIT_USAGE
}

// test262 on the Odin JavaScript engine, judged against QuickJS-ng's results (docs/engine/runtime.md): build/test262/jsrt_errors.txt, build/test262/jsrt_table.md.
@(private)
engine_test262 :: proc(args: []string) -> int {
	f, ok := tooling.parse_flags(args, "-Filter= -Stride= -Jobs= -NoBuild")
	if !ok { return EXIT_USAGE }
	if !os.exists(fmt.tprintf("%s/test262.conf", TEST262_RUN)) { fmt.eprintln("test262 not found: run build/test262 first (build/test262/run)"); return 1 }
	if !tooling.flag_has(f, "-NoBuild") && tooling.run({command = {tooling.odin_program(), "build", "src/engine/jsrt/judge", "-collection:wb=src", "-out:" + JUDGE_EXE, "-o:speed", JUDGE_STACK}}) != 0 { return 1 }
	cmd := make([dynamic]string, context.temp_allocator)
	append(&cmd, JUDGE_EXE, "test262", "-dir", TEST262_RUN, "-stride", tooling.flag(f, "-Stride", "1"))
	if tooling.flag_has(f, "-Filter") { append(&cmd, "-filter", tooling.flag(f, "-Filter")) }
	if tooling.flag_has(f, "-Jobs") { append(&cmd, "-j", tooling.flag(f, "-Jobs")) }
	return tooling.run({command = cmd[:]})
}

// The Odin regexp and Unicode engine against QuickJS-ng's C over thousands of inputs, and a speed comparison (docs/engine/regexp.md). -NoC: the Odin side's own fuzz. Needs zig for the C reference library.
@(private)
engine_rx_diff :: proc(args: []string) -> int {
	f, ok := tooling.parse_flags(args, "-Seed= -Fuzz= -NoC")
	if !ok { return EXIT_USAGE }
	_ = os.make_directory_all(RXDIFF_DIR)
	for file in RXDIFF_FILES {
		to := fmt.tprintf("%s/%s", RXDIFF_DIR, file)
		if os.exists(to) { continue }
		if os.copy_file(to, fmt.tprintf("%s/%s", RXDIFF_QJS, file)) != nil { fmt.eprintln("QuickJS 0.17 sources not found: run src/tools/buildjs first"); return 1 }
	}
	if tooling.run({command = {"zig", "cc", "-shared", "-O2", "-o", "creflib.dll", "shim.c", "libregexp.c", "libunicode.c", "-D_CRT_SECURE_NO_WARNINGS"}, dir = RXDIFF_DIR}) != 0 { fmt.eprintln("the C reference library did not build"); return 1 }
	exe := fmt.tprintf("%s/rxdiff%s", RXDIFF_DIR, tooling.EXE_SUFFIX)
	if tooling.run({command = {tooling.odin_program(), "build", "src/engine/regexp/diff", "-collection:wb=src", fmt.tprintf("-out:%s", exe), "-o:speed", RXDIFF_STACK}}) != 0 { return 1 }
	full, _ := filepath.abs(exe, context.temp_allocator)
	env := tooling.flag_has(f, "-NoC") ? []string{"RXDIFF_NO_C=1"} : nil
	return tooling.run({command = {full, tooling.flag(f, "-Seed", fmt.tprint(RXDIFF_SEED)), tooling.flag(f, "-Fuzz", fmt.tprint(RXDIFF_FUZZ))}, dir = RXDIFF_DIR, env = env})
}

////////////////////////////////
// A command on a desktop of its own

COMMAND_LIMIT :: 30 * time.Minute

// What it opens cannot take the focus, the mouse or the keyboard of the person at the machine, whatever it does, and their clicks cannot reach it. Prints what the command prints, and ends with its exit code. (Real input goes nowhere there: what needs one is `test_all -Ui`.)
run_desktop :: proc(args: []string) -> int {
	if len(args) == 0 { fmt.eprintln("wrentool desktop <program> [arguments]"); return EXIT_USAGE }
	code: int
	if tooling.on_own_desktop(&code, "build/tmp") { return code }
	return tooling.run({command = args}, COMMAND_LIMIT)
}
