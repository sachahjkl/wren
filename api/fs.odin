// Converted from the matching api/*.widl by bindgen -convert-widl. The Odin form is the source of truth once the .widl is removed; see src/tools/bindgen/idl/odin_in.odin.
//@wb module name=fs order=19 exposed=(Window,Worker)
/// File handles (WHATWG File System, WICG File System Access; src/page/fs_store.odin, fs_api.odin;
/// native/js/runtime/web_fs.c). A handle is a root (the origin private file system of the realm's storage key, or a
/// folder of the user's disk given by a picker or a drop) and a "/"-joined path of names below it ("" is the root).
/// Errors carry their DOMException's name first in the message ("TypeMismatchError: ...").
package api_fs

/// navigator.storage.getDirectory(): the root of the realm's origin private file system. Security outside a secure
/// context, for an opaque origin or a profile without a folder. `bucket`: a storage bucket's (StorageBucket.getDirectory),
/// "" for the default one; Invalid_State once the bucket was deleted.
//@wb fn raises
Fs_opfsRoot :: proc(bucket: usvstring) -> u64

/// getFileHandle / getDirectoryHandle(name, {create}) on the directory at `path`: the child's path. Not_Found,
/// Type (an invalid name), Not_Allowed (no permission), Invalid_State ("TypeMismatchError": the other kind).
//@wb fn raises
Fs_getEntry :: proc(root: u64, path: string, name: string, directory: bool, create: bool) -> string

/// removeEntry(name, {recursive}): Invalid_Modification for a directory that is not empty, No_Modification_Allowed
/// for an entry in use.
//@wb fn raises
Fs_removeEntry :: proc(root: u64, path: string, name: string, recursive: bool)

/// The directory's entries: "f" or "d", a tab, the name, one per line.
//@wb fn raises
Fs_list :: proc(root: u64, path: string) -> string

/// resolve(): the names from the first entry down to the second, "/"-joined (Not_Found: not below it).
//@wb fn raises
Fs_resolve :: proc(root: u64, path: string, root2: u64, path2: string) -> string

/// isSameEntry
//@wb fn
Fs_same :: proc(root: u64, path: string, root2: u64, path2: string) -> bool

/// getFile(): a File object (a LocalFile of module dnd: read on demand).
//@wb fn raises
Fs_getFile :: proc(root: u64, path: string) -> u64

/// createWritable({keepExistingData}) (a temporary file) or createSyncAccessHandle() (`sync`: the file itself,
/// exclusive): an open entry's id. No_Modification_Allowed while it is locked.
//@wb fn raises
Fs_open :: proc(root: u64, path: string, keep: bool, sync: bool) -> u64

/// Writes at `at` (-1: the cursor): the bytes written. Quota past opfs.max_bytes_per_origin.
//@wb fn raises
Fs_write :: proc(id: u64, at: i64, data: bytes) -> i64

/// Reads into `into` from `at` (-1: the cursor): the bytes read.
//@wb fn raises out=into
Fs_read :: proc(id: u64, at: i64, into: bytes) -> i64

//@wb fn raises
Fs_seek :: proc(id: u64, position: i64)

//@wb fn raises
Fs_truncate :: proc(id: u64, size: i64)

//@wb fn raises
Fs_size :: proc(id: u64) -> i64

//@wb fn raises
Fs_flush :: proc(id: u64)

/// close(): a writable's temporary file replaces the entry (`commit` false: abort); a sync handle's lock goes.
//@wb fn raises
Fs_close :: proc(id: u64, commit: bool)

/// queryPermission: 0 granted, 1 prompt, 2 denied.
//@wb fn
Fs_permission :: proc(root: u64, write: bool) -> i32

/// requestPermission({mode}): a promise of the state after (the user may be asked).
//@wb fn raises
Fs_requestPermission :: proc(root: u64, write: bool) -> Promise

/// showOpenFilePicker (kind 0), showSaveFilePicker (1), showDirectoryPicker (2): a promise of the number of
/// handles, its text one line per handle: root TAB path TAB "f" or "d" TAB name. Abort when cancelled, Security
/// without a user gesture, Not_Supported when disabled. `types`: a line per type, description TAB patterns...
//@wb fn raises
Fs_showPicker :: proc(kind: i32, types: string, multiple: bool, exclude_all: bool, suggested: string, start_in: string, start_root: u64, start_path: string, id: string, readwrite: bool) -> Promise

/// A root as structuredClone keeps it ("" when unknown).
//@wb fn
Fs_describe :: proc(root: u64) -> string

/// The root a kept description stands for in this realm. Data_Clone for another origin's.
//@wb fn raises
Fs_restore :: proc(description: string) -> u64

