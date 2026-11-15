package browser

// The command palette (Ctrl+K, Ctrl+Shift+P, Menu > Command palette): the toolkit's (ui.Command_Palette), the same in
// every program of the family (ext/gui_toolkit/docs/palette.md). Each window has its own: the toolkit opens a palette
// over the window it is built in, and its `@` lists that window's tabs. Wren gives it its sources:
//
//     >  the registry's commands (commands.odin), as the toolkit's table; the views' moves are the toolkit's
//     @  the window's tabs, then the recently closed ones
//     /  the pages: the bookmarks, then the visited pages (global_history.odin); Ctrl+Enter opens one in a new tab
//     :  the preferences (about:config): a switch flips and the palette stays, another opens about:config on it
//     $  the Vault's items (vault_fill.odin): only while it is unlocked, never under remote control
//
// A source's answer is made on a chore (Palette_Job) from lines the source copied on the interface's thread when its
// data changed (its version), never at each frame. The toolkit ranks on its chores, owns the palette's keys and
// remembers the choices (palette_choices.txt of the profile; a private Wren keeps none). A choice of Wren's sources is
// done in palette_frame, at the top of the next build.

import "core:fmt"
import "core:slice"
import "core:strconv"
import "core:strings"
import lucide "toolkit:lucide"
import "toolkit:ui"
import "wb:base"
import "wb:config"
import "wb:i18n"
import "wb:vault"

// The registry's commands as the toolkit's table: one for the windows' palettes, made again when the registry's keys
// change (Command_Registry.version).
Palette_Table :: struct {
	arena:    base.Arena,
	ready:    bool,
	table:    []ui.Command,   // the commands the palette lists (the hidden ones left out), in the registry's order
	names:    []string,       // each one's name: its id, and its key in the usage memory ("command:<name>")
	rows:     []int,          // each one's index in the registry
	gated:    []int,          // the table's commands that have a condition (`enabled`)
	registry: u64,            // the registry's version it was made from
	version:  u64,            // counts the makes
}

// A window's palette and Wren's sources in it. In Window_Own: it does not move while the palette holds the sources.
Window_Palette :: struct {
	pal:      ui.Command_Palette,
	app:      ^App,
	tabs:     ui.Palette_Source,   // @
	pages:    ui.Palette_Source,   // /
	settings: ui.Palette_Source,   // :
	vault:    ui.Palette_Source,   // $
	started:  bool,
	open:     bool,                // its view was open at the last build of its window

	disabled: [dynamic]bool,       // by the table's index: what cannot act now
	table:    u64,                 // the table's version `disabled` is for
	version:  u64,                 // of the table and of `disabled`, as the palette compares them

	tabs_seen:   u64,              // the tabs' and the closed tabs' fingerprint at the last look
	prefs_seen:  u64,              // the preferences' version at the last look
	prefs_count: int,              // and how many were registered
	flipped:     bool,             // the palette flipped a switch since: its own change does not read the settings again
	vault_seen:  u64,              // the Vault's state at the last look

	// asked from outside a build (a command's key, a menu of another window, the remote control): done at the next one
	due, due_close: bool,
	due_typed:      string,        // (owned) what the field starts with

	// the Vault's question in flight: the helper searches, the answer is made when its rows came (vault_poll)
	vault_q:      ui.Palette_Question,
	vault_asking: bool,
	vault_query:  string,          // (owned) what it was asked for
}

////////////////////////////////
// What the rest of the browser calls

// Opens the palette of the active window at its next build, `typed` in its field ("$ ": the Vault).
palette_show :: proc(app: ^App, typed := "") {
	wp := &window_own(app).palette
	delete(wp.due_typed)
	wp.due, wp.due_close, wp.due_typed = true, false, strings.clone(typed)
	request_frames(app, 2)
}

// Closes the palette of every window at its next build (the Setup dialog opens, the remote control resets).
palette_hide :: proc(app: ^App) {
	hide :: proc(wp: ^Window_Palette) { wp.due, wp.due_close = false, wp.open }
	hide(&app.bare.own.palette)
	for w in app.windows { hide(&w.own.palette) }
	request_frames(app, 2)
}

// Opens or closes the active window's palette (a menu's line).
palette_toggle :: proc(app: ^App) {
	wp := &window_own(app).palette
	if wp.open {
		wp.due, wp.due_close = false, true
		request_frames(app, 2)
	} else {
		palette_show(app)
	}
}

// Whether the active window's palette is open: it has the keyboard (chrome_shortcuts, the built-in pages' typing).
palette_shown_here :: proc(app: ^App) -> bool { return window_own(app).palette.open }

// Whether a window's palette is open: the Vault's search rows stay while one is (vault_fill_frame).
palette_shown :: proc(app: ^App) -> bool {
	if app.bare.own.palette.open { return true }
	for w in app.windows { if w.own.palette.open { return true } }
	return false
}

// At the top of each build of a window (main.odin build_ui): the sources started, what was asked from outside a
// build, the palette's keys, the versions of what the sources list, the commands, the choice.
palette_frame :: proc(app: ^App) {
	wp := &window_own(app).palette
	palette_start(app, wp)
	if wp.due_close {
		wp.due_close = false
		ui.palette_close(&wp.pal)
	}
	if wp.due {
		wp.due = false
		ui.palette_open(&wp.pal, wp.due_typed)
		delete(wp.due_typed)
		wp.due_typed = ""
	}
	// (the Setup dialog keeps the window's keys: setup.odin)
	if !setup_is_open(app) { _ = ui.palette_keys(&wp.pal) }
	open := ui.palette_is_open(&wp.pal)
	// (opened: the tabs as they are now; their titles are not followed at each frame while it is open)
	if open && !wp.open { wp.tabs.version += 1 }
	if !open && wp.open { vault_question_end(wp) }
	wp.open = open
	if open {
		palette_versions(app, wp)
		vault_poll(app, wp)
	}
	palette_commands_give(app, wp)
	if c, ok := ui.palette_chosen(&wp.pal); ok { palette_run(app, wp, c) }
}

// Before the window's toolkit state goes (window_own_destroy, the browser's end): a question still held is ended, and
// the last palette writes the usage memory.
palette_window_destroy :: proc(wp: ^Window_Palette) {
	vault_question_end(wp)
	ui.palette_destroy(&wp.pal)
	delete(wp.disabled)
	delete(wp.due_typed)
	delete(wp.vault_query)
	wp^ = {}
}

palette_table_destroy :: proc(pt: ^Palette_Table) {
	if pt.ready { base.arena_destroy(&pt.arena) }
	pt^ = {}
}

////////////////////////////////
// The sources

// Once per window: the usage memory (shared by the windows: one file), the commands and Wren's sources.
palette_start :: proc(app: ^App, wp: ^Window_Palette) {
	if wp.started { return }
	wp.started, wp.app = true, app
	// (a window without a toolkit state, a test's: the memory stays in memory)
	if s := active_window(app).ui; s != nil {
		path := ""
		if app.cfg.persist_profile && !app.private { path = strings.concatenate({app.profile_dir, "/palette_choices.txt"}, context.temp_allocator) }
		ui.palette_memory_open(&wp.pal, s, path)
	}
	palette_commands_give(app, wp)   // (first: the commands come before Wren's sources)
	// (the tabs' ids and the pages' addresses change from one run to the next, and the pages are the history's to keep:
	// the usage memory keeps the commands and the settings only)
	wp.tabs = {
		name = "tab", title = i18n.later("Tabs"), prefix = .Go_To, plain = true, enter = i18n.later("Switch"),
		read = tabs_source_read, mark = tabs_source_mark, user = wp,
	}
	wp.pages = {
		name = "page", title = i18n.later("Pages"), prefix = .Paths, plain = true, enter = i18n.later("Open"),
		alternates = {ctrl = i18n.later("Open in a new tab")}, read = pages_source_read, user = wp,
	}
	wp.settings = {
		name = "setting", title = i18n.later("Settings"), prefix = .Settings, plain = true, remember = true, enter = i18n.later("Change"),
		read = settings_source_read, mark = settings_source_mark, user = wp,
	}
	// (the helper searches the words typed: asked again at each query)
	wp.vault = {
		name = "vault", title = i18n.later("Vault"), prefix = .Secrets, searches = true, enter = i18n.later("Choose"),
		read = vault_source_read, user = wp,
	}
	ui.palette_add(&wp.pal, &wp.tabs)
	ui.palette_add(&wp.pal, &wp.pages)
	ui.palette_add(&wp.pal, &wp.settings)
	ui.palette_add(&wp.pal, &wp.vault)
}

// While the palette is open: each source's version follows what it lists, by counters that cost nothing to read.
@(private = "file")
palette_versions :: proc(app: ^App, wp: ^Window_Palette) {
	mix :: proc(h, v: u64) -> u64 { return (h ~ v) * 0x100000001b3 }
	w := active_window(app)
	h := u64(0xcbf29ce484222325)
	h = mix(h, u64(len(w.tabs)))
	h = mix(h, u64(w.current))
	h = mix(h, app.recovery.writes.session_serial)
	h = mix(h, u64(len(app.closed.items)))
	if h != wp.tabs_seen { wp.tabs_seen, wp.tabs.version = h, wp.tabs.version + 1 }
	// (each serial only grows: their sum moves when either does)
	wp.pages.version = app.ghist.serial + app.bms.serial + 1
	// (a value changes the version, registering a preference does not)
	if app.prefs.version != wp.prefs_seen || len(app.prefs.entries) != wp.prefs_count {
		count_changed := len(app.prefs.entries) != wp.prefs_count
		wp.prefs_seen, wp.prefs_count = app.prefs.version, len(app.prefs.entries)
		// (a switch the palette flipped shows by its mark: the list is not ranked again)
		if wp.flipped && !count_changed { wp.flipped = false } else { wp.settings.version += 1 }
	}
	v := &app.vault.v
	vh := mix(u64(v.state) | (vault_usable(app) ? u64(1) << 8 : 0), v.sets[.Page].gen)
	vh = mix(vh, v.sets[.Frame].gen)
	if vh != wp.vault_seen { wp.vault_seen, wp.vault.version = vh, wp.vault.version + 1 }
}

// A choice of Wren's: a command, a tab, a page, a setting, a Vault's act (the toolkit's own sources acted already).
@(private = "file")
palette_run :: proc(app: ^App, wp: ^Window_Palette, c: ui.Palette_Choice) {
	if _, is := ui.palette_chosen_command(&wp.pal, c); is {
		// (by its name: the table may have been made again since it was ranked)
		cmd := command(app, c.id)
		if cmd == nil { return }
		if .Ctrl in c.mods && cmd.url != "" { open_in_new_tab(app, cmd.url, origin = .User) } else { command_run(app, current_tab(app), cmd) }
		return
	}
	id := strings.clone(c.id, context.temp_allocator)   // (the palette's until its next choice)
	if c.source == &wp.tabs {
		if strings.has_prefix(id, "t:") {
			if n, ok := strconv.parse_u64(id[2:]); ok {
				if x := tab_find(app, n); x != nil { tab_reveal(app, x) }
			}
		} else if strings.has_prefix(id, "c:") {
			reopen_closed_address(app, id[2:])
		}
	} else if c.source == &wp.pages {
		t := current_tab(app)
		if .Ctrl in c.mods || t == nil { open_in_new_tab(app, id, origin = .User) } else { navigate(app, t, id, origin = .User) }
	} else if c.source == &wp.settings {
		settings_choose(app, wp, id)
	} else if c.source == &wp.vault {
		vault_palette_activate(app, id, .Ctrl in c.mods)   // vault_fill.odin
	}
	request_frames(app, 2)
}

////////////////////////////////
// `>` The commands

// The table, made again when the registry's keys changed.
palette_table :: proc(app: ^App) -> ^Palette_Table {
	pt := &app.pal
	list := commands(app)
	if pt.ready && pt.registry == app.cmds.version { return pt }
	if pt.ready { base.arena_free_all(&pt.arena) } else { _ = base.arena_init_growing(&pt.arena); pt.ready = true }
	a := base.arena_allocator(&pt.arena)
	n := 0
	for c in list { if !c.hidden { n += 1 } }
	table := make([]ui.Command, n, a)
	names := make([]string, n, a)
	rows := make([]int, n, a)
	gated := make([dynamic]int, 0, n, a)
	k := 0
	for c, i in list {
		if c.hidden { continue }
		// (a command with a state on or off is a switch: its row has the mark, and choosing it keeps the palette)
		table[k] = c.spec
		table[k].toggle = c.checked != nil
		names[k], rows[k] = c.name, i
		if c.enabled != nil { append(&gated, k) }
		k += 1
	}
	pt.table, pt.names, pt.rows, pt.gated = table, names, rows, gated[:]
	pt.registry = app.cmds.version
	pt.version += 1
	return pt
}

// The commands source given its table, compared by the version: what can act is read at a build while the palette is
// open, for the commands that have a condition only.
@(private = "file")
palette_commands_give :: proc(app: ^App, wp: ^Window_Palette) {
	pt := palette_table(app)
	changed := false
	if wp.table != pt.version || len(wp.disabled) != len(pt.table) {
		wp.table = pt.version
		resize(&wp.disabled, len(pt.table))
		slice.fill(wp.disabled[:], false)
		changed = true
	}
	if wp.open || changed {
		t := current_tab(app)
		list := commands(app)
		for k in pt.gated {
			off := !command_enabled(app, t, &list[pt.rows[k]])
			if wp.disabled[k] != off { wp.disabled[k], changed = off, true }
		}
	}
	if changed { wp.version += 1 }
	ui.palette_commands(&wp.pal, pt.table, wp.disabled[:], {names = pt.names, version = wp.version, checked = command_checked, user = app})
}

// Whether the switch at `index` of the table is on now: read for the rows in view, at each build.
@(private = "file")
command_checked :: proc(user: rawptr, index: int) -> bool {
	app := (^App)(user)
	pt := &app.pal
	if index < 0 || index >= len(pt.rows) { return false }
	list := commands(app)
	c := &list[pt.rows[index]]
	return c.checked != nil && c.checked(app, current_tab(app), c)
}

////////////////////////////////
// `@` The tabs

// The window's tabs, then the closed ones, the most recent first: "t:<tab id>", "c:<address>".
@(private = "file")
tabs_source_read :: proc(p: ^ui.Command_Palette, src: ^ui.Palette_Source, q: ui.Palette_Question) {
	wp := (^Window_Palette)(src.user)
	app := wp.app
	w := active_window(app)
	closed := closed_items(app)
	job := palette_job_new(q, len(w.tabs) + len(closed))
	job.unique = true   // (two closed tabs of one address: one row)
	open_group := palette_job_text(job, i18n.tr("Open tabs"))
	closed_group := palette_job_text(job, i18n.tr("Closed tabs"))
	for x in w.tabs {
		palette_line_add(job, {id = fmt.tprintf("t:%d", x.id), title = x.title, detail = x.url, last = x.url, group = open_group, icon = lucide.APP_WINDOW})
	}
	for i := len(closed) - 1; i >= 0; i -= 1 {
		it := closed[i]
		palette_line_add(job, {id = fmt.tprintf("c:%s", it.address), title = closed_item_label(it), detail = it.address, last = it.address,
			group = closed_group, icon = lucide.ROTATE_CCW})
	}
	palette_job_send(p, job)
}

// The tab shown.
@(private = "file")
tabs_source_mark :: proc(src: ^ui.Palette_Source, id: string) -> bool {
	t := current_tab((^Window_Palette)(src.user).app)
	return t != nil && id == fmt.tprintf("t:%d", t.id)
}

////////////////////////////////
// `/` The pages

// The bookmarks, then the visited pages, the newest first, one row per address (a bookmark's wins). Their copy is the
// work of a change of the history or the bookmarks, not of a frame.
@(private = "file")
pages_source_read :: proc(p: ^ui.Command_Palette, src: ^ui.Palette_Source, q: ui.Palette_Question) {
	app := (^Window_Palette)(src.user).app
	marks := app.bms.items[:]
	visits := app.ghist.visits[:]
	job := palette_job_new(q, len(marks) + len(visits))
	job.unique = true
	marks_group := palette_job_text(job, i18n.tr("Bookmarks"))
	visits_group := palette_job_text(job, i18n.tr("History"))
	for b in marks {
		if b.folder || b.url == "" { continue }
		palette_line_add(job, {id = b.url, title = b.title, detail = b.url, last = b.url, group = marks_group, icon = lucide.BOOKMARK})
	}
	for i := len(visits) - 1; i >= 0; i -= 1 {
		v := visits[i]
		palette_line_add(job, {id = v.url, title = v.title, detail = v.url, last = v.url, group = visits_group, icon = lucide.GLOBE})
	}
	palette_job_send(p, job)
}

////////////////////////////////
// `:` The settings

// Every preference about:config shows, by its name: its value after it, its description and its title to find it by.
@(private = "file")
settings_source_read :: proc(p: ^ui.Command_Palette, src: ^ui.Palette_Source, q: ui.Palette_Question) {
	app := (^Window_Palette)(src.user).app
	prefs := &app.prefs
	job := palette_job_new(q, len(prefs.entries))
	job.sort = true
	modified := i18n.tr("(modified)")
	locked := i18n.tr("(locked)")
	for e, i in prefs.entries {
		d := e.def
		if d.hidden { continue }
		state := ""
		switch e.source {
		case .Default:
		case .Policy:               state = locked
		case .User, .Command_Line:  state = modified
		}
		detail := state
		if d.kind != .Bool {
			value := config.value_string(prefs, config.Ref(i))
			if value == "" { value = i18n.tr("(empty)") }
			detail = state != "" ? fmt.tprintf("%s  %s", value, state) : value
		}
		tags := make([]string, len(d.tags) + 1, context.temp_allocator)
		tags[0] = config.title_of(d)
		copy(tags[1:], d.tags)
		palette_line_add(job, {
			id = d.name, title = d.name, detail = detail, last = i18n.tr(d.description), tags = tags,
			icon = d.kind == .Bool ? lucide.TOGGLE_RIGHT : lucide.SLIDERS_HORIZONTAL,
			disabled = e.source == .Policy, stays = d.kind == .Bool,
		})
	}
	palette_job_send(p, job)
}

// A switch on.
@(private = "file")
settings_source_mark :: proc(src: ^ui.Palette_Source, id: string) -> bool {
	app := (^Window_Palette)(src.user).app
	r := config.ref_of(&app.prefs, id)
	if r == config.NO_REF { return false }
	e := config.entry(&app.prefs, r)
	return e.def.kind == .Bool && e.value.b
}

// A switch flips (the palette stays, its mark shows the new state); another setting opens about:config on it.
@(private = "file")
settings_choose :: proc(app: ^App, wp: ^Window_Palette, name: string) {
	r := config.ref_of(&app.prefs, name)
	if r == config.NO_REF { return }
	e := config.entry(&app.prefs, r)
	if e.def.kind == .Bool {
		wp.flipped = true
		set_pref_bool(app, name, !e.value.b)
		return
	}
	t := current_tab(app)
	if t == nil { t = tab_open(app, "about:config", origin = .User) } else { navigate(app, t, "about:config", origin = .User) }
	ui.line_edit_set(&app.config_view.search, name)
	app.config_view.focus_list = true
}

////////////////////////////////
// `$` The Vault

// The helper searches the words typed (off the interface's thread); the answer is made once its rows came
// (vault_poll). Nothing while the Vault is locked, off, or under remote control.
@(private = "file")
vault_source_read :: proc(p: ^ui.Command_Palette, src: ^ui.Palette_Source, q: ui.Palette_Question) {
	wp := (^Window_Palette)(src.user)
	app := wp.app
	v := &app.vault.v
	vault_question_end(wp)   // (an older query's)
	if !vault_usable(app) || v.state != .Unlocked {
		none: ui.Palette_Answer
		_ = ui.palette_answer(q, &none)
		return
	}
	delete(wp.vault_query)
	wp.vault_q, wp.vault_asking, wp.vault_query = q, true, strings.clone(q.query)
	vault.vault_search(v, wp.vault_query)   // (nothing when this query is asked already)
	vault_poll(app, wp)
}

// At each build while the palette is open: the question in flight is answered once the helper's rows for its query came.
@(private = "file")
vault_poll :: proc(app: ^App, wp: ^Window_Palette) {
	if !wp.vault_asking { return }
	v := &app.vault.v
	if !vault_usable(app) || v.state != .Unlocked {
		wp.vault_asking = false
		none: ui.Palette_Answer
		_ = ui.palette_answer(wp.vault_q, &none)
		return
	}
	rows, state, key := vault.vault_rows(v, .Search)
	if key != wp.vault_query { return }   // (the panel searches the same set meanwhile: the palette waits)
	#partial switch state {
	case .Ready:
		wp.vault_asking = false
		job := palette_job_new(wp.vault_q, len(rows) * 4)
		vault_palette_lines(app, job, rows)   // vault_fill.odin
		palette_job_send(&wp.pal, job)
	case .Failed:
		wp.vault_asking = false
		_ = ui.palette_answer_error(wp.vault_q, i18n.tr("the Vault did not answer"))
	}
}

// The Vault's question in flight, given up (a newer query, the palette closed or gone).
@(private = "file")
vault_question_end :: proc(wp: ^Window_Palette) {
	if !wp.vault_asking { return }
	wp.vault_asking = false
	ui.palette_question_drop(wp.vault_q)
}

////////////////////////////////
// An answer made on a chore

// What an item is made from, copied on the interface's thread (the data it comes from changes there). `group` and
// `icon` are constants or the job's (palette_job_text): they are not copied for each line.
Palette_Line :: struct {
	id, title, detail, last: string,
	group, icon:             string,
	tags:                    []string,
	disabled, stays:         bool,
}

// A question, the lines copied for it and the answer the chore makes of them, in the answer's arena.
Palette_Job :: struct {
	q:      ui.Palette_Question,
	answer: ui.Palette_Answer,
	lines:  [dynamic]Palette_Line,   // in the answer's arena
	unique: bool,                    // the first line of each id only (a page visited many times)
	sort:   bool,                    // the items by their title
}

palette_job_new :: proc(q: ui.Palette_Question, lines: int) -> ^Palette_Job {
	job := new(Palette_Job, base.process_allocator())
	job.q = q
	job.lines = make([dynamic]Palette_Line, 0, lines, ui.palette_answer_allocator(&job.answer))
	return job
}

// A text that many lines share (a group), copied once into the answer.
palette_job_text :: proc(job: ^Palette_Job, s: string) -> string { return strings.clone(s, ui.palette_answer_allocator(&job.answer)) }

// A line, its texts copied into the answer (an address said three times is copied once).
palette_line_add :: proc(job: ^Palette_Job, line: Palette_Line) {
	al := ui.palette_answer_allocator(&job.answer)
	l := line
	l.id = strings.clone(line.id, al)
	l.title = strings.clone(line.title, al)
	l.detail = line.detail == line.id ? l.id : strings.clone(line.detail, al)
	l.last = line.last == line.id ? l.id : line.last == line.detail ? l.detail : strings.clone(line.last, al)
	if len(line.tags) > 0 {
		l.tags = make([]string, len(line.tags), al)
		for t, i in line.tags { l.tags[i] = strings.clone(t, al) }
	}
	append(&job.lines, l)
}

// The items made on a chore; the window's palette takes the answer at its next build.
palette_job_send :: proc(p: ^ui.Command_Palette, job: ^Palette_Job) {
	if p.owner == nil {   // (never opened over a window: a test's palette)
		palette_job_work(job)
		palette_job_done(job, 0)
		return
	}
	ui.task(p.owner, palette_job_work, palette_job_done, job, palette_job_lost)
}

// (on a chore) The items, in the answer's arena; a page without a title is named by its address. (A test calls it.)
palette_job_work :: proc(data: rawptr) {
	job := (^Palette_Job)(data)
	al := ui.palette_answer_allocator(&job.answer)
	items := make([dynamic]ui.Palette_Item, 0, len(job.lines), al)
	seen: map[string]struct{}
	if job.unique { seen = make(map[string]struct{}, len(job.lines), base.process_allocator()) }
	defer if job.unique { delete(seen) }
	for l in job.lines {
		if job.unique {
			if l.id in seen { continue }
			seen[l.id] = {}
		}
		append(&items, ui.Palette_Item{
			id = l.id, title = l.title != "" ? l.title : address_words(l.detail), detail = l.detail, icon = l.icon, group = l.group,
			tags = l.tags, last = l.last, disabled = l.disabled, stays = l.stays,
		})
	}
	if job.sort { slice.sort_by(items[:], proc(a, b: ui.Palette_Item) -> bool { return a.title < b.title }) }
	job.answer.items = items[:]
}

// (on the interface's thread) The palette takes the arena whole, or drops it (a newer question).
@(private = "file")
palette_job_done :: proc(data: rawptr, _: u64) {
	job := (^Palette_Job)(data)
	_ = ui.palette_answer(job.q, &job.answer)
	free(job, base.process_allocator())
}

// The window went before the answer came: the question ends with none (from any thread).
@(private = "file")
palette_job_lost :: proc(data: rawptr) {
	job := (^Palette_Job)(data)
	ui.palette_answer_free(&job.answer)
	ui.palette_question_drop(job.q)
	free(job, base.process_allocator())
}

// What a page without a title is called: its address without its scheme and its root's "/" (a slice of it: a chore
// makes no copy).
address_words :: proc(address: string) -> string {
	s := address
	if i := strings.index(s, "://"); i >= 0 { s = s[i + 3:] }
	if strings.count(s, "/") == 1 && strings.has_suffix(s, "/") { s = s[:len(s) - 1] }
	return s
}
