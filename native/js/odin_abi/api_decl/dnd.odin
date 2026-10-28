// HTML drag and drop (module dnd, api/js_dnd.odin; the engine side is native/js/odin/web_dnd.odin): the drag data store
// behind a DataTransfer, its items and files, and the files of an <input type=file>. The members the generated binding
// carries directly (getData, setData, clearData, setDragImage, dropEffect, effectAllowed) are not repeated here. A file
// and an element are handles of other modules (LocalFile, Element): plain abi.Handle here.
package api_decl

import "../abi"

DataTransfer :: distinct abi.Handle

// DataTransferItem.kind
DragItemKind :: enum i32 { String, File }

// new DataTransfer(): an empty store in read/write mode (0 when out of memory).
DataTransfer_create :: #type proc() -> DataTransfer
// The types, in order, "\n"-separated ("Files" last when there are files).
DataTransfer_typeList :: #type proc(dt: DataTransfer) -> string
// The number of items (0 in disabled mode).
DataTransfer_itemCount :: #type proc(dt: DataTransfer) -> i32
// An item's kind / type / string data (Invalid_State in protected mode) / file (0: not a file, or protected).
DataTransfer_itemKind   :: #type proc(dt: DataTransfer, index: i32) -> (DragItemKind, abi.Api_Error)
DataTransfer_itemType   :: #type proc(dt: DataTransfer, index: i32) -> (string, abi.Api_Error)
DataTransfer_itemString :: #type proc(dt: DataTransfer, index: i32) -> (string, abi.Api_Error)
DataTransfer_itemFile   :: #type proc(dt: DataTransfer, index: i32) -> (abi.Handle, abi.Api_Error)
// item.webkitGetAsEntry(): the entry of a file item (0: a string item, or the store is protected).
DataTransfer_itemEntry  :: #type proc(dt: DataTransfer, index: i32) -> (FileSystemEntry, abi.Api_Error)
// items.add(data, type) / add(file) of the browser / add(file) made by the page (its bytes copied). Invalid_State
// outside read/write mode, Not_Supported when a string item of the type exists, Quota past the page's memory.
DataTransfer_addString :: #type proc(dt: DataTransfer, data: string, type: string) -> abi.Api_Error
DataTransfer_addFile   :: #type proc(dt: DataTransfer, file: abi.Handle) -> abi.Api_Error
DataTransfer_addBytes  :: #type proc(dt: DataTransfer, name: string, type: string, data: []u8, last_modified: f64) -> abi.Api_Error
// items.remove(index), items.clear(): Invalid_State outside read/write mode.
DataTransfer_removeItem :: #type proc(dt: DataTransfer, index: i32) -> abi.Api_Error
DataTransfer_clearItems :: #type proc(dt: DataTransfer) -> abi.Api_Error
// dataTransfer.files: their number, one of them.
DataTransfer_fileCount :: #type proc(dt: DataTransfer) -> i32
DataTransfer_file      :: #type proc(dt: DataTransfer, index: i32) -> (abi.Handle, abi.Api_Error)
// item.getAsFileSystemHandle(): "root TAB path TAB kind TAB name", "" for a string item or outside read modes.
DataTransfer_itemFsHandle :: #type proc(dt: DataTransfer, index: i32) -> (string, abi.Api_Error)

// input.files: its length (0 for an element that is not a file input), one file, and input.files = dt.files.
InputFiles_count  :: #type proc(input: abi.Handle) -> i32
InputFiles_item   :: #type proc(input: abi.Handle, index: i32) -> (abi.Handle, abi.Api_Error)
InputFiles_assign :: #type proc(input: abi.Handle, from: DataTransfer) -> abi.Api_Error
