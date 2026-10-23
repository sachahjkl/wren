// Measures the content-blocking engine on real lists: compile time, blob size, load time, memory, requests per second
// and the latency distribution of single requests.
//   adblockbench.exe [-lists dir] [-requests file] [-n count] [-save blob]
// Lists are the *.txt files of the directory (default: the first argument). Without -requests, a corpus is
// synthesized: URLs derived from the rules themselves (blocked ones) and ordinary page resources (allowed ones).
package adblockbench

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import "core:time"
import win "core:sys/windows"
import "wb:adblock"

working_set :: proc() -> int {
	c: win.PROCESS_MEMORY_COUNTERS
	c.cb = size_of(c)
	win.GetProcessMemoryInfo(win.GetCurrentProcess(), &c, size_of(c))
	return int(c.WorkingSetSize)
}

now_ns :: proc() -> i64 { return time.now()._nsec }

Rng :: struct { s: u64 }
rnd :: proc(r: ^Rng) -> u64 {
	r.s ~= r.s << 13; r.s ~= r.s >> 7; r.s ~= r.s << 17
	return r.s
}

SITES := []string{
	"www.nytimes.com", "www.bbc.co.uk", "www.lemonde.fr", "www.cnn.com", "www.theguardian.com", "en.wikipedia.org", "github.com",
	"www.youtube.com", "www.reddit.com", "stackoverflow.com", "www.allrecipes.com", "weather.com", "www.twitch.tv", "www.imdb.com",
	"www.amazon.com", "www.ebay.com", "news.ycombinator.com", "www.linkedin.com", "medium.com", "www.forbes.com",
}
CDNS := []string{
	"cdn.jsdelivr.net", "fonts.gstatic.com", "fonts.googleapis.com", "static.xx.fbcdn.net", "i.ytimg.com", "upload.wikimedia.org",
	"images.unsplash.com", "cdnjs.cloudflare.com", "unpkg.com", "avatars.githubusercontent.com", "assets.example-cdn.net",
}
PATHS := []string{
	"/", "/static/js/main.4f9a1c.js", "/assets/app.min.css", "/api/v1/articles?limit=20&page=2", "/images/hero-1280x720.jpg",
	"/fonts/inter-var.woff2", "/video/seg_000123.ts", "/sw.js", "/favicon.ico", "/search?q=weather+tomorrow",
	"/s/files/1/0042/themes/assets/theme.js?v=1234567", "/embed/player.html", "/wp-content/uploads/2024/05/photo.jpg",
}
TYPES := []adblock.Resource{.Script, .Image, .Stylesheet, .Xhr, .Font, .Media, .Subdocument, .Other, .Ping}

Item :: struct { url, source: string, type: adblock.Resource }

main :: proc() {
	dir := ""
	count := 400000
	save := ""
	reqfile := ""
	args := os.args[1:]
	for i := 0; i < len(args); i += 1 {
		switch args[i] {
		case "-n": i += 1; count = parse_int(args[i])
		case "-save": i += 1; save = args[i]
		case "-requests": i += 1; reqfile = args[i]
		case "-lists": i += 1; dir = args[i]
		case: if dir == "" { dir = args[i] }
		}
	}
	if dir == "" { fmt.eprintln("usage: adblockbench lists-dir [-n count] [-requests file] [-save blob]"); os.exit(2) }

	ws0 := working_set()
	infos, _ := os.read_all_directory_by_path(dir, context.allocator)
	lists := make([dynamic]adblock.List_Text)
	total_bytes := 0
	id := u8(1)
	for fi in infos {
		if !strings.has_suffix(fi.name, ".txt") { continue }
		data, err := os.read_entire_file(fi.fullpath, context.allocator)
		if err != nil { continue }
		append(&lists, adblock.List_Text{id, strings.clone(fi.name), string(data)})
		total_bytes += len(data)
		id += 1
	}
	fmt.printfln("lists: %d files, %.1f MB of text", len(lists), f64(total_bytes) / 1e6)

	t0 := now_ns()
	blob := adblock.compile(lists[:])
	t1 := now_ns()
	fmt.printfln("compile: %.0f ms -> %.1f MB blob", f64(t1 - t0) / 1e6, f64(len(blob)) / 1e6)
	if save != "" { _ = os.write_entire_file(save, blob) }

	// load from disk like the browser does
	path := save != "" ? save : "build/adblock_bench.bin"
	_ = os.write_entire_file(path, blob)
	delete(blob)
	ws1 := working_set()
	t2 := now_ns()
	disk, _ := os.read_entire_file(path, context.allocator)
	words := make([]u64, (len(disk) + 7) / 8)
	copy(([^]byte)(raw_data(words))[:len(disk)], disk)
	delete(disk)
	b2 := ([^]byte)(raw_data(words))[:len(disk)]
	e, err := adblock.engine_load(b2, false, true)
	t3 := now_ns()
	if err != .None { fmt.eprintln("load failed:", err); os.exit(1) }
	fmt.printfln("cold load (read + verify + bloom): %.1f ms", f64(t3 - t2) / 1e6)
	ws2 := working_set()
	fmt.printfln("engine: %d network filters, %d cosmetic filters, %d keyed generic; memory delta after load %.1f MB (blob %.1f MB)",
		adblock.engine_filter_count(e), adblock.engine_cosmetic_count(e), adblock.cosmetic_keyed_count(e), f64(ws2 - ws1) / 1e6, f64(len(b2)) / 1e6)
	_ = ws0
	for s in adblock.engine_sources(e) { fmt.printfln("  %-34s net %7d  cosmetic %7d  invalid %6d", s.name, s.net, s.cosmetic, s.invalid) }

	for c in adblock.Class {
		s := adblock.engine_index_stats(e, c)
		fmt.printfln("  %-18v hosts %6d tokens %6d src %5d notoken %5d  biggest buckets %v", c, s.hosts, s.tokens, s.srcs, s.notoken, s.biggest)
	}

	// the corpus
	items := make([dynamic]Item, 0, count)
	rng := Rng{0x9E3779B97F4A7C15}
	if reqfile != "" {
		data, _ := os.read_entire_file(reqfile, context.allocator)
		rest := string(data)
		for line in strings.split_lines_iterator(&rest) {
			f := strings.split(strings.trim_space(line), "\t")
			if len(f) < 3 { continue }
			ty := adblock.Resource.Other
			for r in adblock.Resource { if adblock.resource_name(r) == f[0] { ty = r } }
			append(&items, Item{f[2], f[1], ty})
		}
	} else {
		blocked_urls := make([dynamic]string)
		for l in lists {
			ln := l.text
			for line in strings.split_lines_iterator(&ln) {
				if len(blocked_urls) > 60000 { break }
				if strings.has_prefix(line, "||") {
					end := strings.index_any(line[2:], "^$*|")
					end = end < 0 ? len(line) : end + 2
					host_path := line[2:end]
					if host_path == "" || strings.contains_rune(host_path, '"') { continue }
					append(&blocked_urls, strings.concatenate({"https://", host_path, strings.contains(host_path, "/") ? "" : PATHS[rnd(&rng) % u64(len(PATHS))]}))
				}
			}
		}
		for _ in 0 ..< count {
			site := SITES[rnd(&rng) % u64(len(SITES))]
			ty := TYPES[rnd(&rng) % u64(len(TYPES))]
			src := strings.concatenate({"https://", site, "/article/", fmt.tprint(rnd(&rng) % 1000)})
			if rnd(&rng) % 100 < 25 && len(blocked_urls) > 0 {
				append(&items, Item{blocked_urls[rnd(&rng) % u64(len(blocked_urls))], src, ty})
			} else if rnd(&rng) % 100 < 50 {
				host := CDNS[rnd(&rng) % u64(len(CDNS))]
				append(&items, Item{strings.concatenate({"https://", host, PATHS[rnd(&rng) % u64(len(PATHS))]}), src, ty})
			} else {
				append(&items, Item{strings.concatenate({"https://", site, PATHS[rnd(&rng) % u64(len(PATHS))]}), src, ty})
			}
		}
	}
	fmt.printfln("corpus: %d requests", len(items))

	// parsing of URLs/hosts is part of `make_request` (done by the caller in the browser); measure both
	reqs := make([]adblock.Request, len(items))
	t4 := now_ns()
	for it, i in items { reqs[i] = adblock.make_request(it.url, it.source, it.type) }
	t5 := now_ns()
	fmt.printfln("make_request: %.0f ns each", f64(t5 - t4) / f64(len(items)))

	// warm the caches and the lazily compiled regexes, then measure
	nblock := 0
	for i in 0 ..< len(reqs) { v := adblock.match(e, &reqs[i]); if v.action == .Block || v.action == .Redirect { nblock += 1 } }
	for round in 0 ..< 3 {
		ta := now_ns()
		hits := 0
		for i in 0 ..< len(reqs) { v := adblock.match(e, &reqs[i]); if v.action != .Allow { hits += 1 } }
		tb := now_ns()
		per := f64(tb - ta) / f64(len(reqs))
		fmt.printfln("round %d: %.2f us per request, %.2f M requests/s (%d blocked/excepted)", round, per / 1000, 1e3 / per, hits)
	}
	// latency distribution
	lat := make([]i64, len(reqs))
	for i in 0 ..< len(reqs) {
		a := now_ns()
		_ = adblock.match(e, &reqs[i])
		lat[i] = now_ns() - a
	}
	slice.sort(lat)
	p :: proc(l: []i64, q: f64) -> f64 { return f64(l[min(len(l) - 1, int(f64(len(l)) * q))]) / 1000 }
	fmt.printfln("latency us: p50 %.2f  p90 %.2f  p99 %.2f  p99.9 %.2f  max %.2f   (%d of %d blocked)", p(lat, 0.5), p(lat, 0.9), p(lat, 0.99), p(lat, 0.999), p(lat, 1), nblock, len(reqs))

	// the worst requests, to see what makes them slow
	if len(os.args) > 0 {
		worst := make([]struct { ns: i64, i: int }, 0)
		_ = worst
	}
}

parse_int :: proc(s: string) -> int {
	n := 0
	for c in s { if c >= '0' && c <= '9' { n = n * 10 + int(c - '0') } }
	return n
}
