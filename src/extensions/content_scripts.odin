package extensions

// Which content scripts a document gets (docs/extensions.md, section 3.6 "Injection"). The index is built once per list
// (an image's content_scripts at load, the registered scripts at each change), so a document costs one lookup per label
// of its host plus the entries that name any host. It never passes over every pattern of every extension.
//
// Matching, in Chrome's order: the URL is one of `matches`, none of `exclude_matches`, one of `include_globs` (when
// there are any), none of `exclude_globs`. A frame needs `all_frames`. A document without a URL of its own (about:blank,
// about:srcdoc, data:, blob:) matches through the URL of its creator only with `match_about_blank` or
// `match_origin_as_fallback`.

import "base:runtime"
import "core:strings"
import "wb:base"
import "wb:url"

Script_Index :: struct {
	by_host: map[string][dynamic]int,   // entries with a pattern for this host or its subdomains (the host in lower case)
	any:     [dynamic]int,              // entries with a pattern for any host (<all_urls>, "*", file:)
}

// Builds the index of `list` with `allocator` (the image's arena, or the registered scripts' arena).
script_index_build :: proc(ix: ^Script_Index, list: []Content_Script, allocator: runtime.Allocator) {
	ix.by_host = make(map[string][dynamic]int, 16, allocator)
	ix.any = make([dynamic]int, 0, 4, allocator)
	for cs, i in list {
		in_any := false
		for p in cs.matches {
			if p.all_urls || p.any_host {
				if !in_any { append(&ix.any, i); in_any = true }
				continue
			}
			key := base.ascii_lower_clone(p.host, allocator)
			bucket, found := &ix.by_host[key]
			if !found {
				ix.by_host[key] = make([dynamic]int, 0, 2, allocator)
				bucket = &ix.by_host[key]
			}
			if len(bucket^) == 0 || bucket^[len(bucket^) - 1] != i { append(bucket, i) }
		}
	}
}

// What a document is, for matching. `href` is the URL that matches: the document's own, or its creator's when
// `fallback` is set (a document without a URL of its own).
Script_Target :: struct {
	href:     string,
	top:      bool,   // the top document of its tab
	fallback: bool,
}

// Appends to `out` the indices of `list` that run in `target`, in list order, each once.
scripts_matching :: proc(ix: ^Script_Index, list: []Content_Script, target: Script_Target, out: ^[dynamic]int) {
	u, ok := url.parse(target.href, nil, context.temp_allocator)
	if !ok { return }
	candidates := make([dynamic]int, 0, 8, context.temp_allocator)
	append(&candidates, ..ix.any[:])
	// the host, then each parent domain: "a.b.example.com", "b.example.com", "example.com", "com"
	host := base.ascii_lower(u.host, context.temp_allocator)
	for host != "" {
		if bucket, found := ix.by_host[host]; found { append(&candidates, ..bucket[:]) }
		dot := strings.index_byte(host, '.')
		if dot < 0 { break }
		host = host[dot + 1:]
	}
	if len(candidates) == 0 { return }
	// list order, each once (a few entries: an insertion sort)
	for i in 1 ..< len(candidates) {
		for k := i; k > 0 && candidates[k - 1] > candidates[k]; k -= 1 { candidates[k - 1], candidates[k] = candidates[k], candidates[k - 1] }
	}
	last := -1
	for i in candidates {
		if i == last { continue }
		last = i
		if script_runs_in(list[i], u, target) { append(out, i) }
	}
}

// The full test of one entry (the index only finds the candidates).
script_runs_in :: proc(cs: Content_Script, u: url.URL, target: Script_Target) -> bool {
	if !target.top && !cs.all_frames { return false }
	if target.fallback && !cs.match_about_blank && !cs.match_origin_as_fallback { return false }
	matched := false
	for p in cs.matches { if pattern_matches(p, u) { matched = true; break } }
	if !matched { return false }
	for p in cs.exclude_matches { if pattern_matches(p, u) { return false } }
	if len(cs.include_globs) > 0 {
		found := false
		for g in cs.include_globs { if glob_match_question(g, target.href) { found = true; break } }
		if !found { return false }
	}
	for g in cs.exclude_globs { if glob_match_question(g, target.href) { return false } }
	return true
}

// Whether a document URL has no content of its own: its scripts match through its creator's URL.
url_needs_fallback :: proc(href: string) -> bool {
	return strings.has_prefix(href, "about:") || strings.has_prefix(href, "data:") || strings.has_prefix(href, "blob:")
}

////////////////////////////////
// Registered content scripts (scripting.registerContentScripts)

// One registered script, as the API gives it (strings: the caller's, copied by registered_set).
Registered_Spec :: struct {
	id:                string,
	matches, exclude_matches: []string,
	js, css:           []string,   // package paths, normalised
	run_at:            Run_At,
	all_frames:        bool,
	match_origin_as_fallback: bool,
	world:             World,
	persist:           bool,
}

// The registered scripts of an extension: one arena for all of them, made again at each change (at most
// extensions.scripting.max_registered entries: a change copies them all, a document never pays for it). The arena is
// on the heap: the allocator of its maps points to it, and the record may move.
Registered_Scripts :: struct {
	arena:   ^base.Arena,
	ids:     []string,
	persist: []bool,
	list:    []Content_Script,
	index:   Script_Index,
}

@(private = "file")
registered_arena_free :: proc(arena: ^base.Arena) {
	if arena == nil { return }
	base.arena_destroy(arena)
	free(arena, base.process_allocator())
}

registered_destroy :: proc(r: ^Registered_Scripts) {
	registered_arena_free(r.arena)
	r^ = {}
}

// Replaces the registered scripts with `specs`. Patterns that do not parse were refused by the caller. False: out of
// memory (the scripts stay as they were).
registered_set :: proc(r: ^Registered_Scripts, specs: []Registered_Spec) -> bool {
	old := r.arena
	arena := new(base.Arena, base.process_allocator())
	if base.arena_init_growing(arena) != .None { free(arena, base.process_allocator()); return false }
	a := base.arena_allocator(arena)
	ids := make([]string, len(specs), a)
	persist := make([]bool, len(specs), a)
	list := make([]Content_Script, len(specs), a)
	for s, i in specs {
		ids[i] = strings.clone(s.id, a)
		persist[i] = s.persist
		cs := Content_Script{run_at = s.run_at, all_frames = s.all_frames, match_origin_as_fallback = s.match_origin_as_fallback, world = s.world}
		cs.matches = registered_patterns(s.matches, a)
		cs.exclude_matches = registered_patterns(s.exclude_matches, a)
		cs.js = registered_strings(s.js, a)
		cs.css = registered_strings(s.css, a)
		list[i] = cs
	}
	r^ = {arena = arena, ids = ids, persist = persist, list = list}
	script_index_build(&r.index, list, a)
	registered_arena_free(old)
	return true
}

// The registered script with this id (-1: none).
registered_find :: proc(r: ^Registered_Scripts, id: string) -> int {
	for x, i in r.ids { if x == id { return i } }
	return -1
}

@(private = "file")
registered_strings :: proc(list: []string, a: runtime.Allocator) -> []string {
	out := make([]string, len(list), a)
	for s, i in list { out[i] = strings.clone(s, a) }
	return out
}

@(private = "file")
registered_patterns :: proc(list: []string, a: runtime.Allocator) -> []Pattern {
	out := make([dynamic]Pattern, 0, len(list), a)
	for s in list {
		// (the pattern's strings are slices of its source: the source lives in the arena with it)
		if p, ok := pattern_parse(strings.clone(s, a)); ok { append(&out, p) }
	}
	return out[:]
}
