package browser

// The bookmarks bar (browser.bookmarks.bar; Ctrl+Shift+B, the toolbar's right click, the main menu): under the toolbar, at
// the top of the page's column, what the bar's folder holds (bookmarks.odin: Bookmarks.toolbar), as other browsers show it:
//   * a bookmark is its icon (the one the history knows for its address) and its title, cut past a width; a click opens it
//     here, a middle click or Ctrl+click in a new tab;
//   * a folder is its name: a click opens it as a menu, its folders as submenus, as deep as they go, and "Open all";
//   * what does not fit goes into the » menu at the end;
//   * a bookmark or a folder dragged sideways takes another place in the bar;
//   * a right click on one: its menu (open, edit, move, remove); on the bar itself: show or hide it, a new folder.

import "core:fmt"
import "core:math"
import "core:strings"
import "toolkit:draw"
import "toolkit:render"
import "toolkit:ui"
import lucide "toolkit:lucide"
import "wb:config"
import "wb:i18n"

BOOKMARKS_BAR_PREFS := [?]config.Def{
	{name = "browser.bookmarks.bar", kind = .Bool, default = {b = false}, category = "bookmarks",
		description = "The bookmarks bar under the toolbar: what the bar's folder holds, its folders as menus (Ctrl+Shift+B; a right click on the toolbar)."},
}

register_bookmarks_bar_prefs :: proc(p: ^config.Prefs) { config.register(p, BOOKMARKS_BAR_PREFS[:]) }

@(private = "file") BAR_ITEM_MAX_EM :: 11   // a bookmark's widest, title included
@(private = "file") BAR_ICON_EM     :: 1.05

// What the bar's menus are about (Bookmarks_View.bar).
Bookmarks_Bar_State :: struct {
	folder:   u64,     // the folder whose menu is open (0: none)
	overflow: bool,    // the » menu is open
	item:     u64,     // the bookmark whose right-click menu is open (0: none)
	own_menu: bool,    // the bar's own menu is open (show or hide, a new folder)
	fits:     int,     // how many of its items the bar showed last frame (the » menu lists the others)
	key:      ui.Key,  // the bar's box
}

bookmarks_bar_shown :: proc(app: ^App) -> bool { return app.cfg.bookmarks_bar }

bookmarks_bar_toggle :: proc(app: ^App) {
	set_pref_bool(app, "browser.bookmarks.bar", !bookmarks_bar_shown(app))
	request_frames(app, 2)
}

// The bar's items: the bar folder's children, in order (indexes into app.bms.items).
@(private = "file")
bar_items :: proc(app: ^App) -> []int {
	out := make([dynamic]int, context.temp_allocator)
	if app.bms.toolbar == 0 { return out[:] }
	for b, i in app.bms.items { if b.parent == app.bms.toolbar { append(&out, i) } }
	return out[:]
}

// The texture of the icon the history knows for `url` (0: none).
@(private = "file")
bar_icon_of :: proc(app: ^App, url: string) -> render.Texture {
	if k, ok := app.ub.idx.by_url[url]; ok && k < len(app.ub.idx.entries) && app.ub.idx.entries[k].icon != "" {
		if tex, tok := favicon_texture(app, app.ub.idx.entries[k].icon); tok { return tex }
	}
	return 0
}

@(private = "file")
Bar_Icon :: struct { tex: render.Texture }

@(private = "file")
bar_icon_draw :: proc(b: ^ui.Box, user: rawptr, dc: ^draw.Context) {
	ic := (^Bar_Icon)(user)
	r := b.rect
	s := min(r.max.x - r.min.x, r.max.y - r.min.y)
	c := draw.rect_center(r)
	at := draw.Rect{{math.round(c.x - s * 0.5), math.round(c.y - s * 0.5)}, {}}
	at.max = at.min + {s, s}
	draw.image(dc, ic.tex, at)
}

// The bar, when it is shown: one row across the page's column.
bookmarks_bar :: proc(app: ^App, t: ^Tab) {
	if !bookmarks_bar_shown(app) { return }
	em := ui.font_size()
	v := &app.bview
	h := math.round(ui.dense(em * 2.1))
	pad := math.round(em * 0.5)
	items := bar_items(app)
	font := ui.top_style().font
	// each item's width: icon, title (cut), padding
	widths := make([]f32, len(items), context.temp_allocator)
	for k, n in items {
		b := app.bms.items[k]
		title := b.title != "" ? b.title : default_tab_title(b.url)
		widths[n] = math.round(min(em * BAR_ITEM_MAX_EM, em * (BAR_ICON_EM + 0.45) + ui.text_width(font, em, safe_label(title, 40)) + pad * 2))
	}
	ui.next({width = ui.fill(), height = ui.px(h), axis = .X, cross = .Center, flags = {.Clip}})
	bar: ^ui.Box
	if ui.tags("panel") { bar = ui.build_box({.Clickable, .Draw_Background}, "###bookmarks_bar") }
	v.bar.key = bar.key
	room := max(bar.rect.max.x - bar.rect.min.x, 0)   // (last frame's width: the bar keeps its size)
	more_w := math.round(em * 2)
	// how many fit (with the » button when not all do)
	total: f32 = pad
	for w in widths { total += w + BAR_ITEM_GAP }
	fits := len(items)
	if total > room && room > 0 {
		x: f32 = pad
		fits = 0
		for w in widths {
			if x + w + BAR_ITEM_GAP > room - more_w - pad { break }
			x += w + BAR_ITEM_GAP
			fits += 1
		}
	}
	v.bar.fits = fits
	open_k, open_new := -1, false
	if ui.parent(bar) {
		slots := make([]f32, len(items), context.temp_allocator)
		x: f32 = pad
		for n in 0 ..< len(items) { slots[n] = x; x += widths[n] + BAR_ITEM_GAP }
		hi := max(x - pad - BAR_ITEM_GAP, 0)
		for k, n in items {
			if n >= fits { break }
			b := app.bms.items[k]
			key := ui.key_from_string(bar.key, fmt.tprintf("###bmbar_%d", b.id))
			pos, dragging := ui.reorder_item_pos(key, slots[n], ui.mouse_pos().x - bar.rect.min.x, pad, hi - widths[n])
			ui.next({fixed_x = pos, fixed_y = math.round((h - math.round(em * 1.8)) * 0.5), width = ui.px(widths[n]), height = ui.px(math.round(em * 1.8)),
				axis = .X, cross = .Center, radius = em * CHROME_BUTTON_RADIUS})
			btn: ^ui.Box
			if ui.tags("ghost_button") { btn = ui.build_box({.Clickable, .Draw_Background, .Draw_Hot_Effects, .Clip}, fmt.tprintf("###bmbar_%d", b.id)) }
			title := b.title != "" ? b.title : default_tab_title(b.url)
			ui.a11y_set(btn, {role = .Button, name = title})
			if ui.parent(btn) {
				ui.spacer(ui.px(pad))
				if b.folder {
					ui.next({width = ui.px(em * BAR_ICON_EM), height = ui.pct(1), font = app.lucide, font_size = em * BAR_ICON_EM, text_pad = 0})
					ui.label(fmt.tprintf("%s###bmbar_ic_%d", lucide.FOLDER, b.id))
				} else if tex := bar_icon_of(app, b.url); tex != 0 {
					ic := ui.frame_new(Bar_Icon)
					ic.tex = tex
					ui.next({width = ui.px(math.round(em * BAR_ICON_EM)), height = ui.pct(1)})
					ui.custom(fmt.tprintf("###bmbar_ic_%d", b.id), bar_icon_draw, ic)
				} else {
					ui.next({width = ui.px(em * BAR_ICON_EM), height = ui.pct(1), font = app.lucide, font_size = em * BAR_ICON_EM, text_pad = 0})
					ui.label(fmt.tprintf("%s###bmbar_ic_%d", lucide.GLOBE, b.id))
				}
				ui.spacer(ui.px(math.round(em * 0.45)))
				ui.next({width = ui.fill(), height = ui.pct(1), text_pad = 0})
				ui.label(fmt.tprintf("%s###bmbar_t_%d", safe_label(title, 40), b.id))
			}
			sig := ui.signal(btn)
			if !b.folder && !dragging { tip(sig, fmt.tprintf("%s\n%s", title, b.url)) }
			switch {
			case sig.clicked && b.folder:
				v.bar.folder, v.bar.overflow = b.id, false
				ui.ctx_menu_open_rect(ui.key_from_string(0, "###bmbar_folder_menu"), btn.rect)
			case sig.clicked:            open_k, open_new = k, .Ctrl in sig.mods
			case sig.middle_clicked && !b.folder: open_k, open_new = k, true
			case sig.right_clicked:
				v.bar.item = b.id
				ui.ctx_menu_open(ui.key_from_string(0, "###bmbar_item_menu"), ui.mouse_pos())
			}
			// dragged sideways: another place in the bar
			if sig.dragging && len(items) > 1 {
				press := ui.mouse_pos().x - sig.drag_delta.x - bar.rect.min.x
				_ = ui.reorder_begin(btn.key, ui.reorder_moved(sig.drag_delta, .X, false), 4 * ui.scale(), press, slots[n])
			}
			if ui.reorder_dragging(btn.key) {
				if to := bar_drag_slot(pos, pad, em, widths, n); to != n {
					if bookmark_move_to(&app.bms.items, b.id, app.bms.toolbar, to) { bookmarks_changed(app) }
				}
				request_frames(app, 2)
			}
		}
		if fits < len(items) {
			ui.next({fixed_x = room - more_w - pad * 0.5, fixed_y = math.round((h - math.round(em * 1.8)) * 0.5), width = ui.px(more_w), height = ui.px(math.round(em * 1.8)),
				radius = em * CHROME_BUTTON_RADIUS, text_pad = 0})
			if ui.tags("ghost_button") {
				mb := ui.button("»###bmbar_more")
				tip(mb, i18n.tr("More bookmarks"))
				if mb.clicked {
					v.bar.folder, v.bar.overflow = app.bms.toolbar, true
					ui.ctx_menu_open_rect(ui.key_from_string(0, "###bmbar_folder_menu"), mb.box.rect)
				}
			}
		}
		if len(items) == 0 {
			ui.spacer(ui.px(pad * 2))
			if ui.tags("weak") {
				ui.next({width = ui.fill(), height = ui.pct(1), text_pad = 0})
				ui.label(i18n.tr("Bookmarks you keep with the star (Ctrl+D) show here.###bmbar_empty"))
			}
		}
	}
	if ui.signal(bar).right_clicked { bookmarks_bar_menu(app, ui.mouse_pos()) }
	if open_k >= 0 { bookmark_open(app, t, app.bms.items[open_k].url, open_new) }
}

// Space between two items of the bar (px).
@(private = "file") BAR_ITEM_GAP :: 2
// How far past the swap point an item must go (em), so that it does not swap back on the pixel it swapped at.
@(private = "file") BAR_SWAP_HYSTERESIS_EM :: 0.2

// The place of the item `current` dragged with its leading edge at `pos` (bar px): it takes a neighbour's place as soon
// as its edge on that side is half into it. Measured against the middles, a short title had to pass the whole of a long
// one. (pure: bookmarks_bar_test.odin)
bar_drag_slot :: proc(pos, pad, em: f32, widths: []f32, current: int) -> int {
	return ui.reorder_slot_sized(pos, pad, BAR_ITEM_GAP, widths, current, into = 0.5, hysteresis = em * BAR_SWAP_HYSTERESIS_EM)
}

// The bar's own menu, which is the toolbar's too (toolbar_menu.odin: the right click on the bar, the toolbar, the row of
// tabs where no tab is, the free space of the title bar): show or hide the bar, a new folder in it, then the chrome's choices.
bookmarks_bar_menu :: proc(app: ^App, pos: [2]f32) {
	app.bview.bar.own_menu = true
	ui.ctx_menu_open(ui.key_from_string(0, "###bmbar_own_menu"), pos)
}

// A folder's items as a menu: its folders as submenus, its bookmarks to open; Open all at the end. `skip`: the items of
// the bar that show (the » menu lists the others).
@(private = "file")
folder_menu_items :: proc(app: ^App, t: ^Tab, folder: u64, skip: int = 0) -> (done: bool) {
	n, seen := 0, 0
	for b, i in app.bms.items {
		if b.parent != folder { continue }
		seen += 1
		if seen <= skip { continue }
		n += 1
		title := safe_label(b.title != "" ? b.title : default_tab_title(b.url), 60)
		if b.folder {
			if ui.menu_submenu(fmt.tprintf("%s###bmf_%d", title, b.id)) {
				if folder_menu_items(app, t, b.id) { return true }
			}
		} else if it := ui.menu_item(fmt.tprintf("%s###bmf_%d", title, b.id)); it.clicked {
			bookmark_open(app, t, strings.clone(app.bms.items[i].url, context.temp_allocator), .Ctrl in it.mods)
			ui.ctx_menu_close()
			return true
		}
	}
	if n == 0 {
		_ = ui.menu_item(fmt.tprintf("%s###bmf_empty_%d", i18n.tr("(empty)"), folder), enabled = false)
		return false
	}
	links := 0
	for b in app.bms.items { if b.parent == folder && !b.folder { links += 1 } }
	if links > 1 && skip == 0 {
		ui.menu_separator()
		if ui.menu_item(fmt.tprintf("%s###bmf_all_%d", i18n.tr("Open all in new tabs"), folder)).clicked {
			urls := make([dynamic]string, context.temp_allocator)
			for b in app.bms.items { if b.parent == folder && !b.folder { append(&urls, strings.clone(b.url, context.temp_allocator)) } }
			for u in urls { tab_open(app, u, origin = .User) }
			ui.ctx_menu_close()
			return true
		}
	}
	return false
}

// The bar's menus, each frame (built over everything, as the other menus).
bookmarks_bar_menus :: proc(app: ^App) {
	v := &app.bview
	t := current_tab(app)
	if v.bar.folder != 0 {
		key := ui.key_from_string(0, "###bmbar_folder_menu")
		if ui.ctx_menu(key) {
			// (the » menu: the items the bar does not show)
			_ = folder_menu_items(app, t, v.bar.folder, v.bar.overflow ? v.bar.fits : 0)
		} else {
			v.bar.folder, v.bar.overflow = 0, false
		}
	}
	if v.bar.item != 0 {
		if i := bookmark_index(app.bms.items[:], v.bar.item); i >= 0 {
			if ui.ctx_menu(ui.key_from_string(0, "###bmbar_item_menu")) { bookmark_menu_items(app, t, i) } else { v.bar.item = 0 }
		} else {
			v.bar.item = 0
		}
	}
	if v.bar.own_menu {
		if ui.ctx_menu(ui.key_from_string(0, "###bmbar_own_menu")) {
			if ui.menu_item(i18n.tr("Show the bookmarks bar"), "Ctrl+Shift+B", checked = bookmarks_bar_shown(app)).clicked {
				bookmarks_bar_toggle(app)
				ui.ctx_menu_close()
			}
			if ui.menu_item(i18n.tr("New folder in the bar…")).clicked {
				bookmark_folder_new(app, bookmarks_toolbar(app))
				ui.ctx_menu_close()
			}
			if ui.menu_item(i18n.tr("Bookmarks"), "Ctrl+Shift+O").clicked {
				open_bookmarks(app)
				ui.ctx_menu_close()
			}
			toolbar_menu_items(app, t)   // toolbar_menu.odin: the tabs, the address bar, the window's menu
		} else {
			v.bar.own_menu = false
		}
	}
}
