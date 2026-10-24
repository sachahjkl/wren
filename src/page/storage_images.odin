package page

import "core:os"
import "core:strings"

// localStorage as whole-file images, to put it back later (the checkpoints of `wren ctl`, src/browser/remote_state.odin):
// storage_local_images copies what every origin holds now (the open areas from memory, the others from their files),
// storage_restore_local makes the profile hold exactly that. sessionStorage belongs to tabs, which a restore closes;
// IndexedDB is not part of an image.

Storage_Image :: struct {
	key:  string,   // the storage key (owned)
	data: []byte,   // the file's content (owned)
}

storage_images_destroy :: proc(images: []Storage_Image, allocator := context.allocator) {
	for i in images { delete(i.key, allocator); delete(i.data, allocator) }
	delete(images, allocator)
}

@(private)
EMPTY_LOCAL_IMAGE :: "WLS1\x00\x00\x00\x00"

storage_local_images :: proc(m: ^Storage_Manager, allocator := context.allocator) -> []Storage_Image {
	if m == nil || !m.ready { return nil }
	out := make([dynamic]Storage_Image, allocator)
	seen := make(map[string]bool, allocator = context.temp_allocator)
	for _, a in m.areas {
		if a.kind != .Local || a.state != .Loaded { continue }
		seen[a.origin] = true
		if len(a.items) == 0 { continue }
		append(&out, Storage_Image{strings.clone(a.origin, allocator), area_serialize(a, allocator)})
	}
	if m.dir != "" {
		if files, err := os.read_all_directory_by_path(storage_dir(m), context.temp_allocator); err == nil {
			for f in files {
				k, ok := key_of_file(f.name, ".wls")
				if !ok || seen[k] || f.size <= i64(len(EMPTY_LOCAL_IMAGE)) { continue }
				data, rerr := os.read_entire_file(area_path(m, k), allocator)
				if rerr != nil { continue }
				append(&out, Storage_Image{strings.clone(k, allocator), data})
			}
		}
	}
	return out[:]
}

// Every origin's localStorage becomes `images` (what storage_local_images returned). Pages must be closed: the open areas are
// dropped, and read again from the files when a page asks. Without a profile folder the areas are made from the images.
storage_restore_local :: proc(m: ^Storage_Manager, images: []Storage_Image) {
	if m == nil || !m.ready { return }
	// the origins that hold something now get an empty file first; the images are written after it (the commit gate keeps the
	// newest write of a file, so a background write that was still queued cannot land over these)
	keys := make(map[string]bool, allocator = context.temp_allocator)
	for _, a in m.areas { if a.kind == .Local { keys[strings.clone(a.origin, context.temp_allocator)] = true } }
	if m.dir != "" {
		if files, err := os.read_all_directory_by_path(storage_dir(m), context.temp_allocator); err == nil {
			for f in files { if k, ok := key_of_file(f.name, ".wls"); ok { keys[k] = true } }
		}
	}
	doomed := make([dynamic]string, context.temp_allocator)
	for id, a in m.areas { if a.kind == .Local { append(&doomed, id) } }
	for id in doomed {
		a := m.areas[id]
		delete_key(&m.areas, id)
		area_free(a)
	}
	if m.dir != "" {
		empty := EMPTY_LOCAL_IMAGE
		for k in keys { commit_local(m, k, transmute([]byte)empty) }
		for i in images { commit_local(m, i.key, i.data) }
		return
	}
	for i in images {
		a := area_new(m, i.key, i.key, .Local)
		area_parse(a, i.data)
		a.state = .Loaded
	}
}

@(private)
commit_local :: proc(m: ^Storage_Manager, key: string, data: []byte) {
	path := area_path(m, key)
	m.write_seq += 1
	gate_enter(path)
	storage_commit(path, data, m.write_seq)
}
