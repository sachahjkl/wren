package layout

import "wb:config"
import "wb:css"

// What a user or an administrator may want to tune about page layout (about:config, `layout.*`). The engine reads a plain
// copy, so a layout pass never touches the registry.

Settings :: struct {
	max_depth:          int,       // boxes nested deeper are flattened into their ancestor at this depth
	max_stack_bytes:    int,       // native stack a layout pass may use before it stops descending
	scrollbar_width:    f32,       // CSS px
	scrollbar_min_thumb: f32,      // CSS px
	scrollbar_margin:   f32,       // CSS px between the bar and the padding edge
	scrollbar_thumb:    css.Color,
	scrollbar_track:    css.Color,
	document_scrollbar: bool,
	placeholder_w, placeholder_h: f32,   // CSS px: a replaced element with no known size (an image not decoded yet)
	embed_w, embed_h:   f32,       // CSS px: iframe, embed, object, video without a natural size (width: audio too)
	input_size:         int,       // characters of a text field without a size attribute
	textarea_cols, textarea_rows: int,
	select_arrow:       f32,       // CSS px kept on the right of a <select> for its arrow
	marker_gap:         f32,       // em: between an outside list marker and the content
	sub_shift, super_shift: f32,   // em of the parent: vertical-align sub / super
	paint_refresh:      bool,      // paint-only style changes refresh the existing layout instead of redoing it
	opacity_layers:     bool,      // opacity groups are composited from an offscreen layer (else per primitive)
	grid_max_tracks:    int,       // grid lines are clamped to ± this (explicit and implicit tracks per axis)
	grid_max_items:     int,       // grid items placed per container; the rest are not laid out
	table_max_columns:  int,       // columns of one table; cells past it share the last column
	// incremental layout (incremental.odin)
	incremental:        bool,      // lay out again only what changed
	inc_max_ratio:      f32,       // share of the boxes to rebuild or invalidate past which a full pass is done
	inc_garbage_ratio:  f32,       // memory left over by partial passes (share of what is alive) before a full pass
	inc_garbage_floor:  int,       // ... once it is over this many bytes
	inc_journal:        int,       // entries of the mutation and style journals
	inc_splice:         bool,      // patch the display list of what changed instead of building it again
	inc_verify:         bool,      // after each incremental pass, a full pass in parallel: both must agree
	inc_line_garbage:   f32,       // lines and fragments replaced, per one in use, before they are packed
	// threads (parallel.odin)
	threads:            int,       // helper threads of a full pass; -1: one less than the logical processors, at most 7
	threads_min_contexts: int,     // inline formatting contexts a document needs before they are laid out on threads
	threads_min_boxes:  int,       // elements (box tree) / boxes of a stacking context (display list) before threads help
	threads_incremental: bool,     // incremental passes that lay many paragraphs out again use the threads too
}

PREFS := [?]config.Def{
	{name = "layout.max_depth", kind = .Int, default = {i = 256}, bounded = true, min = 16, max = 4096,
		description = "Deepest nesting of boxes laid out as boxes. Deeper elements are flattened: their text joins the box at this depth (protects the native stack against hostile pages)."},
	{name = "layout.max_stack_bytes", kind = .Int, default = {i = 512 << 10}, bounded = true, min = 64 << 10, max = 16 << 20, bytes = true, unit = "bytes",
		description = "Native stack one layout pass may use, on the interface thread and on each layout thread (both have 32 MiB). Past it, deeper boxes get no size instead of crashing the browser."},
	{name = "layout.scrollbar.width_px", kind = .Float, default = {f = 6}, bounded = true, min = 1, max = 64, unit = "px",
		description = "Thickness of the scroll bars drawn over scrollable boxes and the page."},
	{name = "layout.scrollbar.min_thumb_px", kind = .Float, default = {f = 24}, bounded = true, min = 4, max = 400, unit = "px",
		description = "Shortest scroll bar thumb."},
	{name = "layout.scrollbar.margin_px", kind = .Float, default = {f = 2}, bounded = true, min = 0, max = 32, unit = "px",
		description = "Space between a scroll bar and the edge of its box."},
	{name = "layout.scrollbar.thumb_color", kind = .String, default = {s = "rgba(110, 110, 120, 0.65)"}, description = "Color of scroll bar thumbs (CSS color)."},
	{name = "layout.scrollbar.track_color", kind = .String, default = {s = "rgba(0, 0, 0, 0.06)"}, description = "Color of scroll bar tracks (CSS color, transparent = none)."},
	{name = "layout.scrollbar.document", kind = .Bool, default = {b = true}, description = "Draw a scroll bar for the page itself when it is taller than the window."},
	{name = "layout.replaced.placeholder_width_px", kind = .Float, default = {f = 0}, bounded = true, min = 0, max = 4096, unit = "px",
		description = "Width of an image whose size is not known yet and not given by width/height attributes."},
	{name = "layout.replaced.placeholder_height_px", kind = .Float, default = {f = 0}, bounded = true, min = 0, max = 4096, unit = "px",
		description = "Height of an image whose size is not known yet and not given by width/height attributes."},
	{name = "layout.replaced.embed_width_px", kind = .Float, default = {f = 300}, bounded = true, min = 0, max = 8192, unit = "px",
		description = "Default width of iframe, embed, object and video elements without a natural size, and of audio controls (a canvas without attributes is 300 x 150, as HTML says)."},
	{name = "layout.replaced.embed_height_px", kind = .Float, default = {f = 150}, bounded = true, min = 0, max = 8192, unit = "px",
		description = "Default height of iframe, embed, object and video elements without a natural size."},
	{name = "layout.form.input_size_chars", kind = .Int, default = {i = 20}, bounded = true, min = 1, max = 1000,
		description = "Width, in characters, of a text field without a size attribute."},
	{name = "layout.form.textarea_cols", kind = .Int, default = {i = 20}, bounded = true, min = 1, max = 1000,
		description = "Columns of a <textarea> without a cols attribute."},
	{name = "layout.form.textarea_rows", kind = .Int, default = {i = 2}, bounded = true, min = 1, max = 1000,
		description = "Rows of a <textarea> without a rows attribute."},
	{name = "layout.form.select_arrow_px", kind = .Float, default = {f = 20}, bounded = true, min = 0, max = 200, unit = "px",
		description = "Room kept on the right of a drop-down list for its arrow."},
	{name = "layout.list.marker_gap_em", kind = .Float, default = {f = 0.5}, bounded = true, min = 0, max = 10, unit = "em",
		description = "Space between an outside list marker and the item's text."},
	{name = "layout.text.sub_shift_em", kind = .Float, default = {f = 0.2}, bounded = true, min = 0, max = 2, unit = "em",
		description = "How far vertical-align: sub lowers text, in em of the parent."},
	{name = "layout.text.super_shift_em", kind = .Float, default = {f = 0.34}, bounded = true, min = 0, max = 2, unit = "em",
		description = "How far vertical-align: super raises text, in em of the parent."},
	{name = "layout.paint_refresh", kind = .Bool, default = {b = true},
		description = "When only paint-only values change (transform, opacity, colors, backgrounds, shadows: the usual animations and hover effects), keep the boxes and update matrices, opacities and colors instead of laying the page out again. Off: every style change lays the page out (diagnostics)."},
	{name = "layout.paint.opacity_layers", kind = .Bool, default = {b = true},
		description = "Paint an element with opacity below 1 into an offscreen layer and blend it once, as CSS requires (what overlaps inside it does not show through). Off: each shape is faded on its own (cheaper, inexact where children overlap)."},
	{name = "layout.grid.max_tracks", kind = .Int, default = {i = 10000}, bounded = true, min = 100, max = 1_000_000,
		description = "Largest grid line number honored, and most tracks of an axis (implicit ones and spans included). Placements further out are clamped, as CSS Grid allows (a hostile `grid-row: 10000000` stays cheap). The style engine already reads line numbers and repeat() counts up to 10000 at most."},
	{name = "layout.grid.max_items", kind = .Int, default = {i = 200_000}, bounded = true, min = 1000, max = 10_000_000,
		description = "Most children of one grid container that are placed and laid out. The rest are not laid out (no size, at the container's content origin)."},
	{name = "layout.table.max_columns", kind = .Int, default = {i = 10_000}, bounded = true, min = 100, max = 1_000_000, unit = "columns",
		description = "Most columns of one table (each cell's colspan is at most 1000, but rows of them add up: a hostile page of a few kilobytes asked for gigabytes). Cells past it are placed in the last column."},
	{name = "layout.incremental.enabled", kind = .Bool, default = {b = true},
		description = "After a change (window resized, page script editing the document, style or animation that moves boxes, image or font arriving), lay out again only the boxes it affects, from journals of the changes. Off: every change lays the whole page out (same result, slower)."},
	{name = "layout.incremental.max_ratio", kind = .Float, default = {f = 0.5}, bounded = true, min = 0, max = 1,
		description = "Share of the boxes a change must rebuild or invalidate past which the whole page is laid out instead (a full pass is cheaper than many small ones). 0: a change that rebuilds or invalidates any box is laid out in full (a window resized, an image or font arriving still lay out incrementally)."},
	{name = "layout.incremental.garbage_ratio", kind = .Float, default = {f = 0.5}, bounded = true, min = 0.05, max = 8,
		description = "Memory left behind by incremental passes (boxes, display items, texts, fonts replaced), as a share of what is in use, past which the next pass is a full one that starts afresh (once it is also over layout.incremental.garbage_floor_bytes)."},
	{name = "layout.incremental.garbage_floor_bytes", kind = .Int, default = {i = 16 << 20}, bounded = true, min = 0, max = 1 << 34, bytes = true, unit = "bytes",
		description = "Memory incremental passes may leave behind (boxes, display items, texts) before layout.incremental.garbage_ratio is looked at: a small page animated by a script rebuilds the same few boxes every frame, and without a floor its full pass (the frame that misses its refresh) would come several times a second."},
	{name = "layout.incremental.journal_entries", kind = .Int, default = {i = 65536}, bounded = true, min = 256, max = 16 << 20,
		description = "Changes remembered between two layouts (document mutations, style changes). More changes at once than this make a full layout."},
	{name = "layout.incremental.splice_display_list", kind = .Bool, default = {b = true},
		description = "When a change stays inside some text (nothing else moved), replace only its part of the display list instead of building the whole list again."},
	{name = "layout.incremental.verify", kind = .Bool, default = {b = false},
		description = "Diagnostics: after each incremental layout, also lay the page out from scratch and compare every box and display item; differences are reported to the console. Slow."},
	{name = "layout.incremental.line_garbage_ratio", kind = .Float, default = {f = 2}, bounded = true, min = 0.25, max = 16,
		description = "Lines of text laid out again leave the old ones behind. They are packed away once there are this many old lines (and fragments) for each one in use: higher packs less often (a window being resized lays out every line at each step) and keeps more memory."},
	{name = "layout.threads", kind = .Int, default = {i = -1}, bounded = true, min = -1, max = 256,
		description = "Threads that help the interface thread lay out a large page from scratch (a page load): the lines of independent paragraphs are built on them and parts of the display list are made on them. The result is the same as on one thread. -1 = one less than the logical processors, at most 7; 0 = only the interface thread."},
	{name = "layout.threads.min_inline_contexts", kind = .Int, default = {i = 256}, bounded = true, min = 0, max = 1 << 30, unit = "paragraphs",
		description = "Pages with fewer inline formatting contexts (paragraphs, headings, list items...) are laid out on the interface thread alone: sharing the work out would cost more than it saves."},
	{name = "layout.threads.min_boxes", kind = .Int, default = {i = 4096}, bounded = true, min = 0, max = 1 << 30, unit = "boxes",
		description = "A document with fewer elements builds its boxes without the help of the layout threads (they otherwise read the elements' styles ahead), and a stacking context (the page itself, usually) whose content has fewer boxes makes its display list on the interface thread alone; so is a display list with fewer items hashed by the compositor alone."},
	{name = "layout.threads.incremental", kind = .Bool, default = {b = true},
		description = "The layout threads also help partial layouts that build many paragraphs again (a window being resized changes the width of every paragraph): those are laid out on them ahead of the interface thread, which only places them. Same result as on one thread. Off: partial layouts stay on the interface thread."},
}

register_prefs :: proc(p: ^config.Prefs) { config.register(p, PREFS[:]) }

@(private)
color_pref :: proc(p: ^config.Prefs, name: string, fallback: css.Color) -> css.Color {
	text := config.string_of(p, name)
	toks := css.tokenize(text, context.temp_allocator)
	vals := make([dynamic]css.Value, context.temp_allocator)
	for t in toks { append(&vals, css.Value{kind = .Token, tok = t}) }
	if cv, ok := css.parse_color(vals[:], nil); ok && cv.kind == .Rgba { return cv.rgba }
	return fallback
}

settings_from_prefs :: proc(p: ^config.Prefs) -> Settings {
	return Settings{
		max_depth = int(config.int_of(p, "layout.max_depth")),
		max_stack_bytes = int(config.int_of(p, "layout.max_stack_bytes")),
		scrollbar_width = f32(config.float_of(p, "layout.scrollbar.width_px")),
		scrollbar_min_thumb = f32(config.float_of(p, "layout.scrollbar.min_thumb_px")),
		scrollbar_margin = f32(config.float_of(p, "layout.scrollbar.margin_px")),
		scrollbar_thumb = color_pref(p, "layout.scrollbar.thumb_color", {0.43, 0.43, 0.47, 0.65}),
		scrollbar_track = color_pref(p, "layout.scrollbar.track_color", {0, 0, 0, 0.06}),
		document_scrollbar = config.bool_of(p, "layout.scrollbar.document"),
		placeholder_w = f32(config.float_of(p, "layout.replaced.placeholder_width_px")),
		placeholder_h = f32(config.float_of(p, "layout.replaced.placeholder_height_px")),
		embed_w = f32(config.float_of(p, "layout.replaced.embed_width_px")),
		embed_h = f32(config.float_of(p, "layout.replaced.embed_height_px")),
		input_size = int(config.int_of(p, "layout.form.input_size_chars")),
		textarea_cols = int(config.int_of(p, "layout.form.textarea_cols")),
		textarea_rows = int(config.int_of(p, "layout.form.textarea_rows")),
		select_arrow = f32(config.float_of(p, "layout.form.select_arrow_px")),
		marker_gap = f32(config.float_of(p, "layout.list.marker_gap_em")),
		sub_shift = f32(config.float_of(p, "layout.text.sub_shift_em")),
		super_shift = f32(config.float_of(p, "layout.text.super_shift_em")),
		paint_refresh = config.bool_of(p, "layout.paint_refresh"),
		opacity_layers = config.bool_of(p, "layout.paint.opacity_layers"),
		grid_max_tracks = int(config.int_of(p, "layout.grid.max_tracks")),
		grid_max_items = int(config.int_of(p, "layout.grid.max_items")),
		table_max_columns = int(config.int_of(p, "layout.table.max_columns")),
		incremental = config.bool_of(p, "layout.incremental.enabled"),
		inc_max_ratio = f32(config.float_of(p, "layout.incremental.max_ratio")),
		inc_garbage_ratio = f32(config.float_of(p, "layout.incremental.garbage_ratio")),
		inc_garbage_floor = int(config.int_of(p, "layout.incremental.garbage_floor_bytes")),
		inc_journal = int(config.int_of(p, "layout.incremental.journal_entries")),
		inc_splice = config.bool_of(p, "layout.incremental.splice_display_list"),
		inc_verify = config.bool_of(p, "layout.incremental.verify"),
		inc_line_garbage = f32(config.float_of(p, "layout.incremental.line_garbage_ratio")),
		threads = int(config.int_of(p, "layout.threads")),
		threads_min_contexts = int(config.int_of(p, "layout.threads.min_inline_contexts")),
		threads_min_boxes = int(config.int_of(p, "layout.threads.min_boxes")),
		threads_incremental = config.bool_of(p, "layout.threads.incremental"),
	}
}

settings_default :: proc() -> Settings {
	p := config.prefs_make(context.temp_allocator)
	register_prefs(&p)
	return settings_from_prefs(&p)
}
