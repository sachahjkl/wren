// Converted from the matching api/*.widl by bindgen -convert-widl. The Odin form is the source of truth once the .widl is removed; see src/tools/bindgen/idl/odin_in.odin.
//@wb module name=entries order=39 exposed=Window
/// The File and Directory Entries API for what the user dropped (src/page/dnd_entries.odin;
/// native/js/runtime/web_entries.c): DataTransferItem.webkitGetAsEntry() gives a FileSystemFileEntry or a
/// FileSystemDirectoryEntry for a dropped file or folder; a folder is listed lazily, one directory at a time, on a
/// background thread (createReader().readEntries()), and its files are opened the same way (file()). Paths stay inside
/// what was dropped: a path that leaves it ("..") is refused.
package api_js_entries

//@wb handle parent=Object host=Fs_Entry lookup=lookup_FsEntry
FsEntry :: distinct Handle

//@wb handle parent=Object host=Fs_Reader lookup=lookup_FsReader
FsReader :: distinct Handle

/// What an entry is.
FsEntryInfo :: struct {
	is_dir: bool,
}

/// item.webkitGetAsEntry(): the entry of a file item (0: a string item, or the data store is protected).
//@wb fn raises
DataTransfer_itemEntry :: proc(dt: DataTransfer, index: i32) -> FsEntry

/// isFile / isDirectory
//@wb fn
FsEntry_info :: proc(entry: FsEntry) -> FsEntryInfo

/// entry.name
//@wb fn
FsEntry_name :: proc(entry: FsEntry) -> string

/// entry.fullPath ("/" then the dropped item's name and the path below it, "/" separated)
//@wb fn
FsEntry_fullPath :: proc(entry: FsEntry) -> string

/// entry.filesystem.name
//@wb fn
FsEntry_filesystemName :: proc(entry: FsEntry) -> string

/// getParent(): the folder above (an entry is its own parent at the top of what was dropped).
//@wb fn
FsEntry_parent :: proc(entry: FsEntry) -> FsEntry

/// entry.filesystem.root: the entry of what was dropped (the top of the entry's tree).
//@wb fn
FsEntry_root :: proc(entry: FsEntry) -> FsEntry

/// fileEntry.file(): a promise of the File (NotFoundError when it went away, TypeMismatchError for a folder).
//@wb fn
FsEntry_file :: proc(entry: FsEntry) -> Promise

/// dirEntry.getFile(path) / getDirectory(path): a promise of the entry (NotFoundError, TypeMismatchError when it is
/// the other kind, SecurityError for a path that leaves what was dropped).
//@wb fn
FsEntry_lookup :: proc(dir: FsEntry, path: string, directory: bool) -> Promise

/// dirEntry.createReader()
//@wb fn
FsEntry_createReader :: proc(dir: FsEntry) -> FsReader

/// reader.readEntries(): a promise of the number of entries of the next batch (0: the end), read with FsReader_entry.
//@wb fn
FsReader_read :: proc(reader: FsReader) -> Promise

/// The entries of the last batch.
//@wb fn
FsReader_entry :: proc(reader: FsReader, index: i32) -> FsEntry

