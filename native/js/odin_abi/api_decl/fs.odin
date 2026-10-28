// File handles (module fs, api/fs.odin; the engine side is native/js/odin/web_fs.odin): WHATWG File System and WICG
// File System Access. A handle is a root id (the origin private file system of the realm's storage key, or a folder of
// the user's disk given by a picker or a drop) and a "/"-joined path of names below it ("" is the root); an open file
// (a writable, a sync access handle) is an id of its own. Errors carry their DOMException's name first in the message
// ("TypeMismatchError: ..."), read with Exception_message. A promise and a file are handles of other modules.
package api_decl

import "../abi"

// navigator.storage.getDirectory(): the root of the realm's origin private file system (`bucket`: a storage bucket's,
// "" for the default one).
Fs_opfsRoot :: #type proc(bucket: string) -> (u64, abi.Api_Error)
// getFileHandle / getDirectoryHandle(name, {create}) on the directory at `path`: the child's path.
Fs_getEntry :: #type proc(root: u64, path: string, name: string, directory: bool, create: bool) -> (string, abi.Api_Error)
// removeEntry(name, {recursive})
Fs_removeEntry :: #type proc(root: u64, path: string, name: string, recursive: bool) -> abi.Api_Error
// The directory's entries: "f" or "d", a tab, the name, one per line.
Fs_list :: #type proc(root: u64, path: string) -> (string, abi.Api_Error)
// resolve(): the names from the first entry down to the second, "/"-joined (Not_Found: not below it).
Fs_resolve :: #type proc(root: u64, path: string, root2: u64, path2: string) -> (string, abi.Api_Error)
// isSameEntry
Fs_same :: #type proc(root: u64, path: string, root2: u64, path2: string) -> bool
// getFile(): a LocalFile (module dnd), read on demand.
Fs_getFile :: #type proc(root: u64, path: string) -> (abi.Handle, abi.Api_Error)
// createWritable({keepExistingData}) (a temporary file) or createSyncAccessHandle() (`sync`): an open file's id.
Fs_open :: #type proc(root: u64, path: string, keep: bool, sync: bool) -> (u64, abi.Api_Error)
// Writes at `at` (-1: the cursor) / reads into `into` from `at`: the bytes written / read.
Fs_write :: #type proc(id: u64, at: i64, data: []u8) -> (i64, abi.Api_Error)
Fs_read  :: #type proc(id: u64, at: i64, into: []u8) -> (i64, abi.Api_Error)
Fs_seek     :: #type proc(id: u64, position: i64) -> abi.Api_Error
Fs_truncate :: #type proc(id: u64, size: i64) -> abi.Api_Error
Fs_size     :: #type proc(id: u64) -> (i64, abi.Api_Error)
Fs_flush    :: #type proc(id: u64) -> abi.Api_Error
// close(): a writable's temporary file replaces the entry (`commit` false: abort); a sync handle's lock goes.
Fs_close :: #type proc(id: u64, commit: bool) -> abi.Api_Error
// queryPermission: 0 granted, 1 prompt, 2 denied.
Fs_permission :: #type proc(root: u64, write: bool) -> i32
// requestPermission({mode}): a browser promise of the state after.
Fs_requestPermission :: #type proc(root: u64, write: bool) -> (abi.Handle, abi.Api_Error)
// showOpenFilePicker (kind 0), showSaveFilePicker (1), showDirectoryPicker (2): a browser promise whose text is one
// line per handle (root TAB path TAB "f" or "d" TAB name).
Fs_showPicker :: #type proc(kind: i32, types: string, multiple: bool, exclude_all: bool, suggested: string, start_in: string,
	start_root: u64, start_path: string, id: string, readwrite: bool) -> (abi.Handle, abi.Api_Error)
// A root as structuredClone keeps it ("" when unknown), and the root a kept description stands for in this realm.
Fs_describe :: #type proc(root: u64) -> string
Fs_restore  :: #type proc(description: string) -> (u64, abi.Api_Error)

// The message of the browser's last error (module web).
Exception_message :: #type proc() -> string
