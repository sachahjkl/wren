// Package layout: CSS visual formatting. From a document and its computed styles it builds a box tree, lays it out
// (block and inline formatting contexts with floats and margin collapsing, positioning, flexbox, tables, lists, replaced
// elements), and produces a display list in CSS 2.1 Appendix E paint order with the clips (rounded), scroll frames,
// sticky offsets, transforms and opacity groups each item is drawn under. Hit testing, scrolling and box queries work on
// that result, through the transforms (transform.odin). When only paint-only style values change, `run` refreshes the
// result instead of laying out again (refresh.odin); after other changes it lays out again only what they affect
// (incremental.odin).
//
// The package knows nothing about the graphics toolkit: text is measured through `Text_Api`, natural sizes of images
// come through `Replaced_Api`, and the shell paints the display list. Every length here is in device pixels (CSS px
// times `scale`) in layout coordinates: the origin is the top-left corner of the initial containing block, before any
// scrolling.
package layout

import "core:mem/virtual"
import "wb:base"
import "wb:css"
import "wb:dom"
import "wb:style"

Vec2 :: [2]f32
Rect :: struct { min, max: Vec2 }

rect_contains :: proc(r: Rect, p: Vec2) -> bool { return p.x >= r.min.x && p.x < r.max.x && p.y >= r.min.y && p.y < r.max.y }
rect_intersect :: proc(a, b: Rect) -> Rect { return {{max(a.min.x, b.min.x), max(a.min.y, b.min.y)}, {min(a.max.x, b.max.x), min(a.max.y, b.max.y)}} }
rect_union :: proc(a, b: Rect) -> Rect { return {{min(a.min.x, b.min.x), min(a.min.y, b.min.y)}, {max(a.max.x, b.max.x), max(a.max.y, b.max.y)}} }
rect_empty :: proc(r: Rect) -> bool { return r.max.x <= r.min.x || r.max.y <= r.min.y }
rect_shift :: proc(r: Rect, d: Vec2) -> Rect { return {r.min + d, r.max + d} }

////////////////////////////////
// What the shell provides

Font :: distinct u32   // a face chosen by the shell; layout only hands it back

Font_Metrics :: struct {
	ascent, descent: f32,   // device px above / below the baseline, both positive
	x_height:        f32,
}

Text_Api :: struct {
	user:    rawptr,
	// The face for a family list (as computed: generic names lower case), a weight (100..900) and slant.
	font:    proc(user: rawptr, families: []string, weight: u16, italic: bool) -> Font,
	// Advance width of one line of text at `size` device px: one directional run, shaped as a whole.
	width:   proc(user: rawptr, f: Font, size: f32, text: string) -> f32,
	metrics: proc(user: rawptr, f: Font, size: f32) -> Font_Metrics,
	// Optional. The font for everything the style says of it (stretch, oblique, OpenType features, variations); when
	// nil, `font` is used with the family list, weight and slant.
	font_request: proc(user: rawptr, req: ^Font_Request) -> Font,
	// Optional. Resolved bidi embedding level of each byte of `text`, one paragraph (UAX #9) in a left-to-right or
	// right-to-left base direction. Without it every paragraph is laid out left to right.
	bidi:    proc(user: rawptr, text: string, rtl: bool, levels: []u8),
	// Optional. The first line break opportunity inside `text` (a byte index > 0), or -1: for scripts written without
	// spaces between words (Thai, Lao, Khmer, Myanmar), whose words need a dictionary (UAX #14).
	line_break: proc(user: rawptr, text: string) -> int,
	// Optional. `width` of text drawn with letter spacing (added after each character), which turns optional ligatures
	// off; without it, `width` plus the spacing of each character.
	width_spaced: proc(user: rawptr, f: Font, size: f32, text: string, letter_spacing: f32) -> f32,
	// Optional (selection, find, carets: interaction code on the UI thread). The x of the caret before byte `index` of
	// a text fragment shaped as painted, from its left edge, and the byte index whose caret is nearest to `x`: through
	// the shaped clusters (a ligature or a grapheme of several characters is one cluster), right to left when
	// `run.rtl`. Without them, prefix widths (mirrored in right-to-left fragments).
	caret_x:   proc(user: rawptr, f: Font, size: f32, text: string, run: Text_Run, index: int) -> f32,
	hit_index: proc(user: rawptr, f: Font, size: f32, text: string, run: Text_Run, x: f32) -> int,
	// `width`, `bidi` and `line_break` may be called from several threads at once (`font` and `metrics` never are):
	// lines of independent paragraphs are then built on the layout threads (parallel.odin)
	concurrent: bool,
}

// How a text fragment is shaped and spaced when painted (Text_Api.caret_x / hit_index): one directional run, letter
// spacing after each character, word spacing after each space, `justify` after each space (text-align: justify).
Text_Run :: struct {
	rtl:            bool,
	letter_spacing: f32,
	word_spacing:   f32,
	justify:        f32,
}

// What the style says of a font (CSS Fonts 4), for Text_Api.font_request.
Font_Request :: struct {
	families:   []string,
	weight:     u16,
	italic:     bool,              // style != Normal
	style:      style.Font_Style,
	stretch:    f32,               // percentage
	features:   []Font_Feature,    // OpenType features in order (later settings of a tag win): font-variant-*,
	                               // font-kerning, then font-feature-settings
	variations: []Font_Variation,  // font-variation-settings
}

Font_Feature :: struct { tag: [4]u8, value: u32 }
Font_Variation :: struct { tag: [4]u8, value: f32 }

// Natural size, in CSS px, of the content of a replaced element (a decoded image...). ok = false: not known (yet).
// `ratio` (optional): the natural ratio (width / height) of content that has one but no natural size (an SVG with only
// a viewBox, an inline <svg>); such a box is as wide as its containing block (CSS 2.1 §10.3.2).
Replaced_Api :: struct {
	user:      rawptr,
	intrinsic: proc(user: rawptr, node: base.Handle) -> (w, h: f32, ok: bool),
	ratio:     proc(user: rawptr, node: base.Handle) -> f32,
}

Input :: struct {
	doc:      ^dom.Document,
	styled:   ^style.Styled,
	settings: ^Settings,
	text:     Text_Api,
	replaced: Replaced_Api,     // optional
	viewport: Vec2,             // device px
	scale:    f32,              // device px per CSS px
	band_h:   f32,              // CSS px
	// change counters of what layout reads besides the document and its styles: a different value since the last
	// pass makes an incremental pass check what they feed (natural sizes of replaced elements, faces of fonts)
	images_generation: u64,
	fonts_generation:  u64,
}

////////////////////////////////
// Box tree

Box_Kind :: enum u8 {
	Block,        // block container: block-level box, inline-block, float, absolutely positioned, cell contents...
	Inline,       // inline box: its content lives in the items of its inline formatting context
	Replaced,     // img, input, select, textarea, canvas...: content painted by the shell
	Flex,
	Grid,         // grid container (grid.odin); its children are laid out as grid items
	Table,
	Row_Group,
	Row,
	Cell,
	Caption,
}

Box_Flag :: enum u8 {
	Anonymous,
	Root,          // the initial containing block
	Atomic,        // inline-level atomic box (inline-block, inline-flex, inline-table, inline replaced)
	Block_In_Inline,   // a block-level box inside an inline box: laid out on its own line, full width
	Float,
	Abs,           // position: absolute or fixed
	Fixed,
	Relative,
	Sticky,
	Positioned,
	Stacking,      // establishes a stacking context
	Bfc,           // establishes a block formatting context
	Clips,         // overflow other than visible: clips its content
	Scroll,        // overflow scroll / auto: a scroll container when its content overflows
	Hidden,        // visibility hidden / collapse: not painted, not hit
	No_Pointer,    // pointer-events: none
	List_Item,
	Control,       // form control: painted through the shell's control hook
	Pseudo,        // ::before / ::after
	Ifc,           // the box is the root of an inline formatting context (items/lines are valid)
	Propagated,    // the root element / body whose overflow went to the viewport
	Flattened,     // children past the depth limit were flattened into this box
	Transformed,   // a transform applies (CSS Transforms: transformable boxes only, never a non-replaced inline box)
	Pseudo_After,  // Pseudo: ::after (else ::before)
	Bfc_Floats,    // some float inside takes part in the block formatting context this box is in (incremental.odin)
	Neg_Margins,   // some box inside, in the same block formatting context, may have a negative vertical margin
	Dead,          // left over by a partial rebuild of the box tree: in no tree, read by nothing
	// set with Stacking when the box is built (a change across these thresholds rebuilds the box, as for Stacking):
	// passes over every box read the style only for the boxes that have them
	Effects,       // may make an effect group (opacity, filter, backdrop-filter, mix-blend-mode, clip-path: box_effects)
	Blends,        // mix-blend-mode other than normal (isolated_contexts)
}
Box_Flags :: bit_set[Box_Flag; u32]

NONE :: i32(-1)

Box :: struct {
	node:      base.Handle,         // element (or the document for the root); NIL for anonymous boxes
	cs:        ^style.Computed,
	kind:      Box_Kind,
	flags:     Box_Flags,
	parent, first, last, next: i32,
	pos_ref:   i32,                 // `pos` is relative to this box's border-box origin
	cb:        i32,                 // absolutely positioned: the containing block
	abs_first, abs_last, abs_next: i32,   // boxes whose containing block this is, in tree order
	static_ref: i32,                // absolutely positioned: the block container its static position is relative to
	static_pos: Vec2,
	ifc_root:  i32,                 // inline-level boxes: the root of their inline formatting context
	items, lines: [2]i32,           // Ifc: [start, end) into Layout.inline_items / Layout.lines
	cur_anon:  i32,                 // building: the anonymous box that collects the current run of children
	fi:        i32,                 // font of the box's own text (index into Layout.fonts)
	// box model, device px: top, right, bottom, left
	margin, border, padding: [4]f32,
	auto_l, auto_r, auto_t, auto_b: bool,
	pos, size: Vec2,                // border box
	rel:       Vec2,                // relative-position offset
	abs:       Vec2,                // final border-box origin in layout coordinates
	baseline:  f32,                 // first line's baseline from the border-box top; < 0 = none
	last_baseline: f32,
	pre_h:     f32,                 // tables: height of the captions above the border box
	intr:      [2]f32,              // min-content / max-content border-box width
	intr_ok:   bool,
	cache_ok:  bool,                // layout cache: the result of the last layout_contents, valid for the same inputs
	cache_flow: bool,               // ... laid out in its parent's block formatting context (else on its own)
	cache_through: bool,
	cache_in:  [3]f32,
	cache_h:   f32,
	cache_end, cache_contrib: Strut,   // flow: trailing strut; margins it added to the strut it was given
	inc:       Inc_Flags,           // invalidation between passes (incremental.odin)
	// tables
	col, row, colspan, rowspan: i32,
	// list items
	marker:    string,              // outside marker text (bullets are drawn as shapes: empty text)
	marker_pos: Vec2,               // marker's left / baseline, relative to the border box
	marker_w:  f32,
	// finishing
	clip_owner, space, clip, content_space, content_clip: i32,
	group:     i32,
	overflow:  Rect,                // scrollable overflow (layout coordinates) of a scroll container
	scroll_space: i32,              // the scroll space this box owns, or NONE
	depth:     i32,
	layer:     i32,                 // inline boxes: nearest positioned inline ancestor-or-self (paints its fragments), or NONE
	tmp:       f32,                 // scratch of the current step (baseline shift of an inline box on the line being built)
	tmp_al:    i32,                 // scratch: top/bottom-aligned group of an inline box on the line being built
}

Inline_Kind :: enum u8 { Text, Open, Close, Atomic, Float, Abs, Break, Block }

// Where the style of an inline item comes from (to find it again after a restyle).
Item_Src :: enum u8 { Element, Before, After, Initial }

Inline_Item :: struct {
	kind:  Inline_Kind,
	src:   Item_Src,
	box:   i32,                     // Open/Close: the inline box; Atomic/Float/Abs/Block: the box; Text: enclosing inline box or NONE
	ifc:   i32,
	fi:    i32,                     // Text: font
	text:  string,
	cs:    ^style.Computed,         // Text: style of its element
	node:  base.Handle,             // Text: the element that owns it
	source: base.Handle,            // Text: the DOM text node it shows (NIL: generated content, markers)
	deco:  style.Decorations,       // Text: decorations of its ancestors up to the formatting context (CSS Text Decoration §2)
	deco_color: css.Color,
	deco_box: i32,                  // Text: the box the decoration color comes from (NONE: none)
}

Font_Info :: struct {
	font:     Font,
	size:     f32,                  // device px
	ascent, descent, x_height: f32,
	line_h:   f32,                  // used line-height
	space:    f32,                  // width of U+0020
	// what it was made from, to make it again when the faces change (families, features, variations: in the layout's
	// arena)
	families: []string,
	weight:   u16,
	italic:   bool,
	style:    style.Font_Style,
	stretch:  f32,
	features: []Font_Feature,
	variations: []Font_Variation,
}

Line :: struct {
	y, h, baseline: f32,            // relative to the IFC root's border box
	frags:     [2]i32,
	left, width: f32,               // the band the line was laid out in
}

Frag_Kind :: enum u8 { Text, Box, Atomic, Ellipsis }
Frag_Flag :: enum u8 { Left_Edge, Right_Edge }

Frag :: struct {
	kind:     Frag_Kind,
	flags:    bit_set[Frag_Flag; u8],
	level:    u8,                   // Text: bidi embedding level (odd: right to left; its text is one directional run)
	item:     i32,                  // Text: the inline item
	box:      i32,                  // Box: the inline box; Atomic: the atomic box; Text: the enclosing inline box or NONE
	fi:       i32,
	x, y, w, h: f32,                // relative to the IFC root's border box; Text: the glyph area
	baseline: f32,
	text:     string,
	extra:    f32,                  // justification: added after each space
	spaces:   i32,                  // building: expansion opportunities before the fragment
	nsp:      i32,                  // building: expansion opportunities inside the fragment
}

////////////////////////////////
// Display list

Item_Kind :: enum u8 {
	Box,          // background, shadows and borders of a box (also the hit region of boxes that paint nothing)
	Inline_Box,   // one line's piece of an inline box: background, borders
	Text,
	Marker,       // list marker: text, or a bullet shape (marker_type)
	Replaced,     // content area of a replaced element (image placeholder...)
	Control,      // content area of a form control: painted by the control hook
	Outline,
	Scrollbar,    // rect = track, thumb = the thumb
}

Item_Flag :: enum u8 { Hit, Left_Edge, Right_Edge, No_Background, Vertical }
Item_Flags :: bit_set[Item_Flag; u8]

Display_Item :: struct {
	kind:     Item_Kind,
	flags:    Item_Flags,
	level:    u8,                   // Text: bidi embedding level of its text (odd: right to left)
	space, clip, group: i32,
	box:      i32,
	node:     base.Handle,          // hit-test target: an element
	cs:       ^style.Computed,
	rect:     Rect,                 // layout coordinates
	text:     string,
	fi:       i32,
	baseline: f32,
	extra:    f32,
	thumb:    Rect,
	deco:     style.Decorations,    // Text: underline / overline / line-through to draw
	deco_color: css.Color,
	deco_box: i32,                  // Text: the box the decoration color comes from (NONE: none)
	item:     i32,                  // Text from a fragment: its inline item (whose style it shows), else NONE
}

Space_Kind :: enum u8 { Document, Fixed, Scroll, Sticky, Transform }

// A coordinate space items are drawn in: the document (shifted by the page scroll), the viewport (fixed boxes), the
// content of a scroll container (shifted by its scroll offset), a sticky box (shifted by its constraint), a transformed
// box and its content (mapped by its transformation; the box's own background and borders are in it too).
//
// Offsets (scroll, sticky) are translations; a view composes them first, then the matrices of the Transform spaces
// above, innermost first: viewport point = W(layout point + offset), W = product of the transforms (see View).
Space :: struct {
	kind:     Space_Kind,
	parent:   i32,
	box:      i32,
	frame:    i32,                  // Sticky: the scroll space (or document) it sticks in
	clip:     i32,                  // clip bounding everything in this space (NONE: unbounded)
	xform:    i32,                  // the innermost Transform space at or above this one (NONE: untransformed)
	port:     Rect,                 // Scroll: the container's padding box; Sticky: the box's normal border box
	limit:    Rect,                 // Sticky: the containing block's content box
	max_scroll: Vec2,               // Scroll
	inset:    [4]f32,               // Sticky: top right bottom left, NaN = auto
	mat:      Matrix,               // Transform: the box's transformation in layout coordinates (origin folded in)
	band0:    f32,                  // spatial index: layout y of the first band
	band_h:   f32,
	band_first, band_count: i32,    // its bands: [band_first, band_first + band_count) of Layout.band_start
}

// A clip: the padding box of `box` in the coordinates of `space` (so it follows the transforms of that space), with
// the inner corner radii of the box (CSS Backgrounds §5.3; draw corner order: top-left, bottom-left, top-right,
// bottom-right). Clips nest through `parent`; each one may live in a different space.
Clip :: struct { parent: i32, space: i32, box: i32, rect: Rect, radii: [4]f32 }

Matrix :: [6]f32   // 2D affine: x' = a x + c y + e, y' = b x + d y + f  (a b c d e f), as style.Matrix and CSS matrix()

// An effect group: a box with opacity below 1, a filter, a backdrop filter, a blend mode or a clip-path, or the
// stacking context a blending descendant must be isolated in (CSS Compositing 1 §3.2), and everything it paints.
// `reach`: how far (device px, the largest side) its filters and those of the groups around it spread what it paints.
Group :: struct { parent: i32, box: i32, alpha: f32, effects: Group_Effects, reach: f32 }

Pass_Kind :: enum u8 { None, Full, Refresh, Incremental }

Layout :: struct {
	// what this layout was made from
	mutations:  u64,
	serial:     u64,
	layout_serial: u64,         // styled.layout_serial at the last full layout: equal = only paint-only values changed since
	canvas:     css.Color,
	styled:     rawptr,         // the style pass this was laid out from (identity only)
	styled_pass: u64,           // its pass_id: the same records, changed since only as its journal says (incremental.odin)
	canvas_els: [2]base.Handle, // the root element and body: their backgrounds may be the canvas
	canvas_items: [2]i32,       // their Box display items (NONE: none)
	loose_styles: bool,         // some text's style is not the style of a box (its element has none: display: contents...)
	deco_items:   [dynamic]i32, // decorated Text items (their color follows text-decoration-color)
	viewport:   Vec2,
	scale:      f32,
	valid:      bool,
	last_pass:  Pass_Kind,      // what the last `run` did
	passes:     [Pass_Kind]u64, // how many of each `run` did (diagnostics, tests)
	restyled:   u64,            // bumps when a refresh re-points items to new style records (the compositor checks them)
	// results
	boxes:        [dynamic]Box,
	inline_items: [dynamic]Inline_Item,
	lines:        [dynamic]Line,
	frags:        [dynamic]Frag,
	fonts:        [dynamic]Font_Info,
	items:        [dynamic]Display_Item,   // paint order
	spaces:       [dynamic]Space,
	clips:        [dynamic]Clip,
	groups:       [dynamic]Group,
	band_start:   [dynamic]u32,
	band_items:   [dynamic]u32,
	node_box:     [dynamic]i32,            // handle index -> box
	height:       f32,                     // document scroll height
	doc_width:    f32,
	doc_scroll_y: bool,                    // false: the root element's overflow forbids scrolling the page
	settings:     Settings,
	stats:        [5]f32,                  // ms of the last run: box tree, layout, finishing, display list, spatial index
	// persistent across layouts
	scroll:       map[base.Handle]Vec2,    // scroll offset of each scroll container
	arena:        virtual.Arena,           // strings made up by layout (transformed text, markers, generated content)
	arena_ready:  bool,
	scratch:      [dynamic]u32,
	inc:          Inc_State,               // what incremental passes need between runs (incremental.odin)
	pre_chunks:   [dynamic]Pre_Chunk,      // storage of the lines laid out ahead on the layout threads (parallel.odin)
	pre_counts:   [2]int,                  // last full pass: contexts laid out ahead, and taken (diagnostics, tests)
	tree_order:   bool,                    // last full pass: the boxes are in tree order (finishing walks them as they are)
}

DOCUMENT_SPACE :: i32(0)
FIXED_SPACE :: i32(1)
