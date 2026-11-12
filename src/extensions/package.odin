package extensions

// The files of an extension package. An unpacked extension is read in place: its directory is walked once, off the
// interface thread, into an index of relative paths. A URL of the extension reaches only a file of that index, so a path
// that leaves the package, a symbolic link or a file added later is never served.

import "core:os"
import "core:strings"

Package_Error :: enum u8 { None, Not_Found, Too_Many_Files, Too_Large, Unreadable }

// One file of the package: its size when it was indexed.
File_Entry :: struct { size: i64 }

// Normalises a path inside the package: '/' separators, no '.' segment, no empty segment. False when it leaves the
// package ('..' above the root), is absolute, names a drive, or holds a NUL or a backslash (a path is a URL's path, never
// a system path). The result is allocated (allocator) only when it differs.
package_path_normalize :: proc(p: string, allocator := context.allocator) -> (string, bool) {
	if strings.contains_rune(p, 0) || strings.contains_rune(p, '\\') { return "", false }
	if len(p) >= 2 && p[1] == ':' { return "", false }
	rest := strings.trim_prefix(p, "/")
	if strings.has_prefix(rest, "/") { return "", false }   // "//host": not a path of the package
	parts := make([dynamic]string, 0, 8, context.temp_allocator)
	it := rest
	for seg in strings.split_iterator(&it, "/") {
		switch seg {
		case "", ".":
		case "..":
			if len(parts) == 0 { return "", false }
			pop(&parts)
		case:
			append(&parts, seg)
		}
	}
	if len(parts) == 0 { return "", true }
	joined := strings.join(parts[:], "/", context.temp_allocator)
	if joined == p { return p, true }
	return strings.clone(joined, allocator), true
}

// Walks `root` into `files` (relative path -> entry; keys allocated with `allocator`). Symbolic links are skipped: a link
// could lead out of the package. Iterative: a deep tree costs no native stack.
package_index_dir :: proc(root: string, s: ^Settings, files: ^map[string]File_Entry, allocator := context.allocator) -> Package_Error {
	if !os.is_dir(root) { return .Not_Found }
	total: i64
	stack := make([dynamic]string, 0, 16, context.temp_allocator)
	append(&stack, "")
	for len(stack) > 0 {
		rel := pop(&stack)
		dir := rel == "" ? root : strings.concatenate({root, "/", rel}, context.temp_allocator)
		infos, err := os.read_all_directory_by_path(dir, context.temp_allocator)
		if err != nil { return .Unreadable }
		for fi in infos {
			name := fi.name
			if name == "." || name == ".." { continue }
			child := rel == "" ? strings.clone(name, context.temp_allocator) : strings.concatenate({rel, "/", name}, context.temp_allocator)
			#partial switch fi.type {
			case .Directory:
				// (a folder Chrome writes into an unpacked extension: not part of it)
				if rel == "" && name == "_metadata" { continue }
				append(&stack, child)
			case .Regular:
				if len(files^) >= s.package_max_files { return .Too_Many_Files }
				total += fi.size
				if total > s.package_max_bytes { return .Too_Large }
				files^[strings.clone(child, allocator)] = File_Entry{size = fi.size}
			}
		}
	}
	return .None
}

package_error_text :: proc(e: Package_Error) -> string {
	switch e {
	case .None:           return ""
	case .Not_Found:      return "the folder does not exist"
	case .Too_Many_Files: return "the package has more files than extensions.package.max_files"
	case .Too_Large:      return "the package is larger than extensions.package.max_bytes"
	case .Unreadable:     return "a folder of the package cannot be read"
	}
	return ""
}

// Reads one file of the package (off the interface thread). Empty and false when it is not in the index or cannot be read.
package_read :: proc(root: string, files: ^map[string]File_Entry, rel: string, max_bytes: int, allocator := context.allocator) -> ([]byte, bool) {
	e, ok := files^[rel]
	if !ok || e.size > i64(max_bytes) { return nil, false }
	data, err := os.read_entire_file(strings.concatenate({root, "/", rel}, context.temp_allocator), allocator)
	if err != nil { return nil, false }
	return data, true
}
