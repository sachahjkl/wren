package ucd

// Shape of the generated Unicode data. `gen/` (an Odin program) downloads the pinned Unicode Character Database
// files, verifies their SHA-256, and writes `tables_generated.odin` holding values of exactly these types. The
// runtime never parses UCD text; it only reads these flat arrays. Keeping the format plain (sorted interval runs
// and a small case table) means the same data compiles for freestanding_wasm32 with no decoder state.
//
// We deliberately do NOT copy QuickJS's `libunicode-table.h`: its layout is a bespoke bit-packing tuned for the C
// decoder. Deriving our own tables from the authoritative UCD keeps provenance clear and lets the format suit Odin
// (comptime-known slices, no runtime index tables).

// A property or category stored as sorted, non-overlapping half-open [lo, hi) runs.
Range_Run :: struct {
	lo: u32,
	hi: u32,
}

// A named range table: the property/category/script name and its runs.
Named_Table :: struct {
	name: string,
	runs: []Range_Run,
}

// A property of strings (Basic_Emoji, RGI_Emoji, ...): `seqs` is a flat list where each sequence is its length
// followed by its code points.
Sequence_Table :: struct {
	name: string,
	seqs: []u32,
}

// One case-mapping entry. For a run of code points starting at `code` of length `len`, each maps by the given
// deltas. QuickJS packs this tightly; we keep one entry per contiguous rule and compute the mapping arithmetically
// where possible, falling back to explicit multi-char expansions in `Case_Full` for folding/upper that yield more
// than one code point.
Case_Entry :: struct {
	code:        u32, // first code point of the run
	count:       u32, // number of code points in the run
	kind:        Case_Kind,
	// Arithmetic parameters, meaning depends on kind (see case.odin).
	a:           i32,
	b:           i32,
}

Case_Kind :: enum u8 {
	// c -> c + delta for upper; the inverse for lower. Simple one-to-one mapping run.
	Delta_Upper,  // adding `a` lowercases; subtracting uppercases (QuickJS RUN_TYPE_U/L style)
	Delta_Lower,
	// Alternating upper/lower pairs (QuickJS RUN_TYPE_UL): even offset is upper, odd is lower.
	Alternating,
	// Explicit: index into Case_Full for a multi-code-point folding/mapping; `a` is the base index, `b` the count.
	Explicit,
}

// Full (multi-code-point) case foldings and special casings, referenced by Case_Entry of kind Explicit.
// Each logical entry is a (source, []mapped) pair; stored as a flat list indexed by Case_Entry.a.
Full_Case :: struct {
	source: u32,
	mapped: []u32, // 1..3 code points
}

// Simple case folding map: code point -> folded code point, for the common 1:1 case used by canonicalize. Sorted
// by `from`. Full folding (1:n) lives in `case_full_fold`.
Fold_Entry :: struct {
	from: u32,
	to:   u32,
}

// Canonical decomposition / composition data for normalization.
Decomp_Entry :: struct {
	code:    u32,
	compat:  bool,  // true: compatibility (NFKC/NFKD) only
	mapped:  []u32, // decomposition sequence
}

Combining_Entry :: struct {
	lo: u32,
	hi: u32,
	cc: u8,
}

Compose_Entry :: struct {
	a:      u32, // starter
	b:      u32, // combining
	result: u32,
}
