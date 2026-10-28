// Converted from the matching api/*.widl by bindgen -convert-widl. The Odin form is the source of truth once the .widl is removed; see src/tools/bindgen/idl/odin_in.odin.
//@wb module name=dnd order=27 exposed=Window
/// HTML drag and drop for JavaScript (src/page/dnd.odin; native/js/runtime/web_dnd.c): the drag data store behind a
/// DataTransfer (its items, its mode, dropEffect and effectAllowed, the drag image), the files a page was given (by a
/// drop, an <input type=file>) as browser objects read on demand, and HTMLInputElement.files. The store's mode follows
/// the event being dispatched (HTML "drag data store mode"): read/write in dragstart, read-only in drop, protected
/// otherwise (types and kinds are visible, data and files are not).
package api_js_dnd

//@wb handle parent=Object host=Drag_Store lookup=lookup_DataTransfer
DataTransfer :: distinct Handle

//@wb handle parent=Object host=Local_File lookup=lookup_LocalFile
LocalFile :: distinct Handle

/// DataTransferItem.kind
DragItemKind :: enum i32 {
	String,
	File,
}

/// The size and time of a file.
LocalFileInfo :: struct {
	/// bytes
	size: i64,
	/// File.lastModified (ms since the epoch)
	last_modified: f64,
}

/// new DataTransfer(): an empty store in read/write mode.
//@wb fn
DataTransfer_create :: proc() -> DataTransfer

/// dataTransfer.dropEffect ("none", "copy", "link", "move")
//@wb fn
DataTransfer_get_dropEffect :: proc(dt: DataTransfer) -> string

/// Values other than the four are ignored.
//@wb fn
DataTransfer_set_dropEffect :: proc(dt: DataTransfer, value: string)

/// dataTransfer.effectAllowed
//@wb fn
DataTransfer_get_effectAllowed :: proc(dt: DataTransfer) -> string

/// Ignored outside read/write mode and for a value that is not one of the nine.
//@wb fn
DataTransfer_set_effectAllowed :: proc(dt: DataTransfer, value: string)

/// getData(format): "" in protected mode or when absent ("text" is text/plain, "url" the first URL of text/uri-list).
//@wb fn
DataTransfer_getData :: proc(dt: DataTransfer, format: string) -> string

/// setData(format, data): ignored outside read/write mode.
//@wb fn
DataTransfer_setData :: proc(dt: DataTransfer, format: string, data: string)

/// clearData(format): every string item, or those of the format; ignored outside read/write mode.
//@wb fn optional=format
DataTransfer_clearData :: proc(dt: DataTransfer, format: string)

/// setDragImage(image, x, y): ignored outside read/write mode.
//@wb fn
DataTransfer_setDragImage :: proc(dt: DataTransfer, image: Element, x: i32, y: i32)

/// The types, in order, separated by "\n" ("Files" last when there are files).
//@wb fn
DataTransfer_typeList :: proc(dt: DataTransfer) -> string

/// The number of items (DataTransferItemList.length; 0 in disabled mode).
//@wb fn
DataTransfer_itemCount :: proc(dt: DataTransfer) -> i32

/// An item's kind (Invalid_Argument past the end).
//@wb fn raises
DataTransfer_itemKind :: proc(dt: DataTransfer, index: i32) -> DragItemKind

/// An item's type.
//@wb fn raises
DataTransfer_itemType :: proc(dt: DataTransfer, index: i32) -> string

/// A string item's data (Invalid_State in protected mode).
//@wb fn raises
DataTransfer_itemString :: proc(dt: DataTransfer, index: i32) -> string

/// A file item's file (0: not a file, or protected mode).
//@wb fn raises
DataTransfer_itemFile :: proc(dt: DataTransfer, index: i32) -> LocalFile

/// items.add(data, type): Invalid_State outside read/write mode, Not_Supported when a string item of the type exists.
//@wb fn raises
DataTransfer_addString :: proc(dt: DataTransfer, data: string, type: string)

/// items.add(file) for a file of the browser (a dropped or chosen one).
//@wb fn raises
DataTransfer_addFile :: proc(dt: DataTransfer, file: LocalFile)

/// items.add(file) for a File made by the page: its bytes are copied (Quota past the page's memory limit).
//@wb fn raises
DataTransfer_addBytes :: proc(dt: DataTransfer, name: string, type: string, data: bytes, last_modified: f64)

/// items.remove(index): Invalid_State outside read/write mode.
//@wb fn raises
DataTransfer_removeItem :: proc(dt: DataTransfer, index: i32)

/// items.clear(): Invalid_State outside read/write mode.
//@wb fn raises
DataTransfer_clearItems :: proc(dt: DataTransfer)

/// The files (dataTransfer.files: none outside read/write and read-only mode).
//@wb fn
DataTransfer_fileCount :: proc(dt: DataTransfer) -> i32

/// One of them.
//@wb fn raises
DataTransfer_file :: proc(dt: DataTransfer, index: i32) -> LocalFile

/// The mode: 0 protected, 1 read/write, 2 read-only.
//@wb fn
DataTransfer_mode :: proc(dt: DataTransfer) -> i32

/// A file's name (no directory).
//@wb fn exposed=(Window,Worker)
LocalFile_name :: proc(file: LocalFile) -> string

/// Its MIME type ("" when unknown).
//@wb fn exposed=(Window,Worker)
LocalFile_type :: proc(file: LocalFile) -> string

/// Its size and time.
//@wb fn exposed=(Window,Worker)
LocalFile_info :: proc(file: LocalFile) -> LocalFileInfo

/// Reads up to `into`'s capacity from `offset`: the number of bytes read (Not_Found when the file is gone or
/// changed since it was given: File API "NotReadableError").
//@wb fn raises exposed=(Window,Worker) out=into
LocalFile_read :: proc(file: LocalFile, offset: i64, into: bytes) -> i64

/// DataTransferItem.getAsFileSystemHandle(): the dropped file's or folder's handle (as Fs_showPicker describes one:
/// root TAB path TAB kind TAB name), "" for a string item or outside read-only and read/write mode.
//@wb fn raises
DataTransfer_itemFsHandle :: proc(dt: DataTransfer, index: i32) -> string

/// DragEvent.dataTransfer of an event the browser dispatches (0 for another event).
//@wb fn
DragEvent_dataTransfer :: proc(event: Event) -> DataTransfer

/// input.files.length (0 for an element that is not a file input).
//@wb fn
InputFiles_count :: proc(input: Element) -> i32

/// input.files[index]
//@wb fn raises
InputFiles_item :: proc(input: Element, index: i32) -> LocalFile

/// input.files = dataTransfer.files: the store's files become the input's selection (Invalid_State for an element
/// that is not a file input).
//@wb fn raises
InputFiles_assign :: proc(input: Element, from: DataTransfer)

