package browser

// The system's icons of files, as its file manager shows them (gui_toolkit desktop.file_icon: the person's icon theme on
// Linux, the shell's icon on Windows), as textures: one per icon key (desktop.file_icon_key: two files of one type share
// it) and size. Asked from a frame; the file is read on the blocking pool, the texture made on the interface thread when
// it is back, and the frame after shows it. A file the system has no icon for keeps its own drawing (none is asked again).

import "core:fmt"
import "core:strings"
import desktop "toolkit:desktop"
import "toolkit:render"
import "wb:base"
import "wb:host"

System_Icon :: struct {
	tex:   render.Texture,   // 0: not there (asked, or none)
	asked: bool,
}

System_Icons :: struct {
	by_key: map[string]System_Icon,   // "<desktop.file_icon_key>@<px>" (keys owned)
	jobs:   int,                      // out on the blocking pool
}

// The texture of the icon of `path` at `px` pixels (0: not yet, or none: the caller draws its own).
system_file_icon :: proc(app: ^App, path: string, folder: bool, px: int) -> render.Texture {
	if path == "" || px <= 0 { return 0 }
	key := fmt.tprintf("%s@%d", desktop.file_icon_key(path, folder, context.temp_allocator), px)
	if e, ok := app.sysicons.by_key[key]; ok { return e.tex }
	app.sysicons.by_key[strings.clone(key, base.process_allocator())] = {asked = true}
	Job :: struct { app: ^App, key, path: string, folder: bool, px: int, icon: desktop.File_Icon, ok: bool }
	j := new(Job, base.process_allocator())
	j^ = {app = app, key = strings.clone(key, base.process_allocator()), path = strings.clone(path, base.process_allocator()), folder = folder, px = px}
	app.sysicons.jobs += 1
	host.run_blocking(&app.blocking, proc(data: rawptr) {
		j := (^Job)(data)
		j.icon, j.ok = desktop.file_icon(j.path, j.folder, j.px, allocator = base.process_allocator())
		free_all(context.temp_allocator)
	}, proc(data: rawptr) {
		j := (^Job)(data)
		app := j.app
		app.sysicons.jobs -= 1
		if j.ok && j.icon.size.x > 0 && j.icon.size.y > 0 && len(j.icon.rgba) >= j.icon.size.x * j.icon.size.y * 4 {
			tex := render.create_texture_rgba(&app.r, j.icon.size.x, j.icon.size.y)
			render.update_texture_rgba(&app.r, tex, 0, 0, j.icon.size.x, j.icon.size.y, j.icon.rgba)
			if e, ok := &app.sysicons.by_key[j.key]; ok { e.tex = tex } else { render.destroy_texture(&app.r, tex) }
			request_frames(app, 2)
		}
		desktop.file_icon_destroy(&j.icon, base.process_allocator())
		delete(j.key, base.process_allocator()); delete(j.path, base.process_allocator())
		free(j, base.process_allocator())
	}, j)
	return 0
}

// At the end: the jobs out are waited for, the textures go (before the renderer).
system_icons_destroy :: proc(app: ^App) {
	for app.sysicons.jobs > 0 { host.blocking_settle(&app.blocking) }
	for k, e in app.sysicons.by_key {
		if e.tex != 0 { render.destroy_texture(&app.r, e.tex) }
		delete(k, base.process_allocator())
	}
	delete(app.sysicons.by_key)
	app.sysicons = {}
}
