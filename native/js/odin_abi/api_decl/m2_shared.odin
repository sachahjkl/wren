// Declarations of other modules' functions the network, stream and blob domains call (written with them, M2): the
// browser's files (module dnd), Media Source URLs, buffers, events, URL resolution, compression. A later migration of
// those modules moves each next to its module's declarations; the shapes are the generated imports'.
package api_decl

import "../abi"

// ---- module dnd: a file of the browser behind a File ----
LocalFile :: distinct abi.Handle
// Its name and MIME type.
LocalFile_name :: #type proc(file: LocalFile) -> string
LocalFile_type :: #type proc(file: LocalFile) -> string
// Reads up to len(into) bytes at `offset`: the count read.
LocalFile_read :: #type proc(file: LocalFile, offset: i64, into: []u8) -> (i64, abi.Api_Error)

// ---- module media_source: object URLs of a MediaSource ----
MediaSource :: distinct abi.Handle
MediaSource_registerObjectURL :: #type proc(source: MediaSource, url: string) -> abi.Api_Error
MediaSource_revokeObjectURL :: #type proc(url: string)

// ---- module async: buffers, promises, streams ----
Buffer :: distinct abi.Handle
// A promise of the browser (settled to JS through wj_promise_from_host).
Promise :: distinct abi.Handle
// A stream of the browser (a response body read chunk by chunk).
Stream :: distinct abi.Handle
Buffer_length :: #type proc(buffer: Buffer) -> i64
// Copies bytes from `offset` into `destination`: the count copied.
Buffer_read :: #type proc(buffer: Buffer, offset: i64, destination: []u8) -> i32

// ---- module events ----

// ---- module document / workers: the base URL ----
Document_resolveURL :: #type proc(url: string) -> (string, abi.Api_Error)
WorkerGlobalScope_location :: #type proc() -> (string, abi.Api_Error)

// ---- module compression ----
Compressor :: distinct abi.Handle
CompressionFormat :: enum i32 { Gzip, Deflate, Deflate_Raw }
Compression_create :: #type proc(format: CompressionFormat, decompress: bool) -> (Compressor, abi.Api_Error)
