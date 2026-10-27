package desktop

// Linux: inotify watches the directories an integration lives in, so the box that shows its state reads the disk again
// the moment one changes instead of on a timer. The places are the applications directory (the <slug>.desktop file),
// the hicolor icon theme root (an icon of any size), and ~/.local/bin (the "Add to PATH" symlink). One named thread
// polls the inotify descriptor and an eventfd used to stop it; a change wakes the program, which rereads the state.
//
// A directory that does not exist yet (a fresh profile has no ~/.local/share/applications) cannot be watched: the
// thread adds a watch for it again on a short timeout, and the directory coming back is itself a change. The watcher
// never ends because one place was missing. inotify follows the directory, not files below it, which is enough: the
// integration's files are direct children of these directories (the icons are read at the theme root level only for
// "present or not": a size directory appearing wakes the reader, which then scans the sizes).

import "core:strings"
import "core:sys/linux"
import "wb:host"

WATCH_LINUX_PLACES :: 3
WATCH_LINUX_RETRY_MS :: 3000

@(private = "file")
Watch_Place :: struct {
	path: string,     // owned ("" = nothing to watch here)
	wd:   linux.Wd,   // -1: not added now
}

@(private = "file")
Watch_Linux :: struct {
	inotify: linux.Fd,
	stop:    linux.Fd,   // eventfd, signalled to end the thread
	places:  [WATCH_LINUX_PLACES]Watch_Place,
	thread:  ^host.Thread,
	wake:    Watch_Proc,
	user:    rawptr,
}

@(private = "file")
WATCH_MASK :: linux.Inotify_Event_Mask{.CREATE, .DELETE, .MOVED_FROM, .MOVED_TO, .CLOSE_WRITE, .ATTRIB, .DELETE_SELF, .MOVE_SELF}

watch_start_linux :: proc(o: ^Options, wake: Watch_Proc, user: rawptr) -> ^Watcher {
	ino, ierr := linux.inotify_init1({.NONBLOCK, .CLOEXEC})
	if ierr != .NONE { return nil }
	ev, everr := linux.eventfd(0, {.CLOEXEC})
	if everr != .NONE { linux.close(ino); return nil }

	st := new(Watch_Linux)
	st.inotify, st.stop = ino, ev
	st.wake, st.user = wake, user

	// The applications directory and the icons root come from the same layout the integration uses; the bin directory
	// is the "Add to PATH" place. A place the options do not set falls back to the XDG default.
	apps := o.applications_dir != "" ? o.applications_dir : apps_dir_default()
	icons := o.icons_dir != "" ? o.icons_dir : icons_dir_default()
	bin := xdg_bin_dir()
	st.places[0] = {path = clone_or_empty(apps, context.allocator), wd = linux.Wd(-1)}
	st.places[1] = {path = clone_or_empty(icons, context.allocator), wd = linux.Wd(-1)}
	st.places[2] = {path = clone_or_empty(bin, context.allocator), wd = linux.Wd(-1)}

	added := false
	for &p in st.places { if watch_place_add(st, &p) { added = true } }
	if !added {
		// Nothing exists to watch yet: keep the watcher so it picks a place up when it appears (the retry timeout).
	}

	st.thread = host.thread_start(watch_linux_thread, st, name = "wren-desktop-watch", priority = .Below_Normal)
	if st.thread == nil {
		watch_linux_free(st)
		return nil
	}
	w := new(Watcher)
	w.user, w.wake, w.impl = user, wake, st
	return w
}

@(private = "file")
apps_dir_default :: proc() -> string {
	d := xdg_data_home()
	return d == "" ? "" : strings.concatenate({d, "/applications"}, context.temp_allocator)
}

@(private = "file")
icons_dir_default :: proc() -> string {
	d := xdg_data_home()
	return d == "" ? "" : strings.concatenate({d, "/icons/hicolor"}, context.temp_allocator)
}

@(private = "file")
watch_place_add :: proc(st: ^Watch_Linux, p: ^Watch_Place) -> bool {
	if p.wd >= linux.Wd(0) || p.path == "" { return p.wd >= linux.Wd(0) }
	c := strings.clone_to_cstring(p.path, context.temp_allocator)
	wd, err := linux.inotify_add_watch(st.inotify, c, WATCH_MASK)
	if err != .NONE { p.wd = linux.Wd(-1); return false }
	p.wd = wd
	return true
}

@(private = "file")
watch_linux_thread :: proc(data: rawptr) {
	st := (^Watch_Linux)(data)
	buf: [4096]u8
	for {
		missing := false
		for p in st.places { if p.wd < linux.Wd(0) && p.path != "" { missing = true } }
		fds := [2]linux.Poll_Fd{
			{fd = st.stop, events = {.IN}},
			{fd = st.inotify, events = {.IN}},
		}
		n, perr := linux.poll(fds[:], i32(missing ? WATCH_LINUX_RETRY_MS : -1))
		if perr != .NONE && perr != .EINTR { return }
		if perr == .EINTR { continue }
		if n == 0 {
			// Timed out with something missing: try to add the watches again; a place that comes back is a change.
			back := false
			for &p in st.places { if p.wd < linux.Wd(0) && watch_place_add(st, &p) { back = true } }
			if back { st.wake(st.user) }
			continue
		}
		if .IN in fds[0].revents {
			return   // stop was signalled
		}
		if .IN in fds[1].revents {
			// Drain the events (we do not read the names: any event in these directories means "reread the state").
			changed := false
			for {
				r, rerr := linux.read(st.inotify, buf[:])
				if rerr == .EAGAIN || rerr == .EWOULDBLOCK { break }
				if rerr != .NONE || r <= 0 { break }
				changed = true
				// A watched directory itself went (DELETE_SELF): forget its descriptor so the retry re-adds it.
				watch_mark_lost(st, buf[:r])
			}
			if changed { st.wake(st.user) }
		}
	}
}

// Walks the inotify records in `data`; a record with IGNORED or DELETE_SELF frees the matching watch descriptor.
@(private = "file")
watch_mark_lost :: proc(st: ^Watch_Linux, data: []u8) {
	off := 0
	for off + size_of(linux.Inotify_Event) <= len(data) {
		e := (^linux.Inotify_Event)(raw_data(data[off:]))
		if .DELETE_SELF in e.mask || .MOVE_SELF in e.mask || .UNMOUNT in e.mask {
			for &p in st.places { if p.wd == e.wd { p.wd = linux.Wd(-1) } }
		}
		off += size_of(linux.Inotify_Event) + int(e.len)
	}
}

watch_stop_linux :: proc(w: ^Watcher) {
	st := (^Watch_Linux)(w.impl)
	if st == nil { return }
	if st.stop >= linux.Fd(0) {
		one := u64(1)
		bytes := (^[8]u8)(&one)^
		_, _ = linux.write(st.stop, bytes[:])
	}
	if st.thread != nil { host.thread_join(st.thread) }
	watch_linux_free(st)
	w.impl = nil
}

@(private = "file")
watch_linux_free :: proc(st: ^Watch_Linux) {
	if st.inotify >= linux.Fd(0) { linux.close(st.inotify) }
	if st.stop >= linux.Fd(0) { linux.close(st.stop) }
	for p in st.places { delete(p.path) }
	free(st)
}
