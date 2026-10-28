// The File and Directory Entries API for what the user dropped (module entries, api/js_entries.odin; the engine side is
// native/js/odin/web_entries.odin). An entry is one handle kind for both of its interfaces: FileSystemEntry is the
// base the engine checks `this` against; whether it is a file or a directory is FsEntry_info's answer (a struct result,
// which travels by address: the engine calls that import directly). A handle an entry function returns is the
// caller's to release (the engine's wrapper owns it).
package api_decl

import "../abi"

FileSystemEntry :: distinct abi.Handle
FileSystemDirectoryEntry :: distinct abi.Handle
FileSystemDirectoryReader :: distinct abi.Handle

// entry.name / entry.fullPath / entry.filesystem.name
FsEntry_name           :: #type proc(entry: FileSystemEntry) -> string
FsEntry_fullPath       :: #type proc(entry: FileSystemEntry) -> string
FsEntry_filesystemName :: #type proc(entry: FileSystemEntry) -> string
// getParent(): the folder above (the top is its own parent); filesystem.root: the top of the entry's tree.
FsEntry_parent :: #type proc(entry: FileSystemEntry) -> FileSystemEntry
FsEntry_root   :: #type proc(entry: FileSystemEntry) -> FileSystemEntry
// fileEntry.file(): a browser promise of the File.
FsEntry_file :: #type proc(entry: FileSystemEntry) -> abi.Handle
// dirEntry.getFile(path) / getDirectory(path): a browser promise of the entry.
FsEntry_lookup :: #type proc(dir: FileSystemDirectoryEntry, path: string, directory: bool) -> abi.Handle
// dirEntry.createReader() (0 when out of memory).
FsEntry_createReader :: #type proc(dir: FileSystemDirectoryEntry) -> FileSystemDirectoryReader
// reader.readEntries(): a browser promise of the size of the next batch (0: the end), read with FsReader_entry.
FsReader_read  :: #type proc(reader: FileSystemDirectoryReader) -> abi.Handle
FsReader_entry :: #type proc(reader: FileSystemDirectoryReader, index: i32) -> FileSystemEntry
