package fuzz

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"

// A seed file larger than this makes every input of the target slow, and a fuzzer finds more with many small inputs.
MAX_SEED_BYTES :: 256 << 10
// Files of the repository per target, after the sort: a corpus of thousands only dilutes the mutations.
MAX_SEED_FILES :: 300

// The folders that never hold seeds and are deep: a walk into them costs seconds.
SKIPPED_DIRS :: [?]string{".git", "node_modules", "target", "build"}

// A target's seeds: its inline ones, the ones it makes, the files of the repository it names (sorted, capped), then every
// file of build/fuzz/<target>/corpus, uncapped: what a person put there on purpose.
load_corpus :: proc(t: ^Target) -> [][]u8 {
	out := make([dynamic][]u8)
	// (cloned: a parser that wrote into its input must not fault on a string literal's read-only page and look like a crash)
	for s in t.seeds { append(&out, slice.clone(transmute([]u8)s)) }
	if t.make_seeds != nil { t.make_seeds(&out) }

	paths := make([dynamic]string, context.temp_allocator)
	for f in t.files { collect(f.dir, f.suffixes, &paths) }
	slice.sort(paths[:])
	if len(paths) > MAX_SEED_FILES { resize(&paths, MAX_SEED_FILES) }
	own := make([dynamic]string, context.temp_allocator)
	collect(fmt.tprintf("%s/%s/corpus", FUZZ_DIR, t.name), nil, &own)
	slice.sort(own[:])
	append(&paths, ..own[:])

	for p in paths {
		data, err := os.read_entire_file(p, context.allocator)
		if err != nil { continue }
		if len(data) > MAX_SEED_BYTES { delete(data); continue }
		append(&out, data)
	}
	return out[:]
}

// The files under `dir` (recursively) whose name ends with one of `suffixes`; every file when `suffixes` is empty.
collect :: proc(dir: string, suffixes: []string, out: ^[dynamic]string) {
	entries, err := os.read_all_directory_by_path(dir, context.temp_allocator)
	if err != nil { return }
	walk: for e in entries {
		if e.type == .Directory {
			for s in SKIPPED_DIRS { if e.name == s { continue walk } }
			collect(e.fullpath, suffixes, out)
			continue
		}
		if len(suffixes) == 0 { append(out, e.fullpath); continue }
		for s in suffixes {
			if strings.has_suffix(e.name, s) { append(out, e.fullpath); break }
		}
	}
}
